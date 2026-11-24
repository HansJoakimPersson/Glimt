import Foundation

/// Semantic category assigned to one bounded source syntax range.
public enum SyntaxTokenKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case comment, string, keyword, number, type, variable, directive
}

/// UTF-16 range into the unchanged source, directly usable by native text rendering.
public struct HighlightRun: Equatable, Sendable {
    public let range: NSRange
    public let kind: SyntaxTokenKind

    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Ordered lexical token ranges over the unchanged source text.
public struct HighlightedSource: Equatable, Sendable {
    public let runs: [HighlightRun]
    public init(runs: [HighlightRun]) { self.runs = runs }
}

/// Implementations return ordered, nonoverlapping UTF-16 ranges; the inspector validates them.
public protocol SyntaxHighlighting: Sendable {
    /// Returns ordered, nonoverlapping UTF-16 token ranges; callers validate them before rendering.
    func highlight(_ source: String, language: SourceLanguage) throws -> HighlightedSource
    /// Supports a narrow literate source mode while keeping the original text and UTF-16 ranges.
    func highlight(_ source: String, language: SourceLanguage, literateHaskell: Bool) throws -> HighlightedSource
}

extension SyntaxHighlighting {
    /// Lets format adapters provide a narrow lexical mode while preserving existing highlighter conformers.
    func highlight(_ source: String, language: SourceLanguage, literateHaskell: Bool) throws -> HighlightedSource {
        try highlight(source, language: language)
    }
}

/// Bounded source text, line metadata, optional highlighting, and diagnostics for one file.
public struct SourceDocument: Equatable, Sendable {
    public let source: String
    public let language: SourceLanguage
    public let encoding: TextEncoding?
    public let lineEnding: TextLineEnding
    public let lineCount: Int
    public let truncated: Bool
    /// Starts of logical CR/LF/CRLF lines in UTF-16, excluding a phantom trailing empty line.
    public let lineStarts: [Int]
    public let highlighting: HighlightedSource
    public let diagnostics: [InspectionDiagnostic]
}

/// Builds a bounded source preview. Highlighting failure never discards readable source.
public enum SourceCodeInspector {
    /// Clips source on UTF-16 scalar boundaries and treats highlighting as optional decoration.
    public static func inspect(analysis: TextAnalysis, language: SourceLanguage,
                               highlighter: any SyntaxHighlighting = InternalSyntaxHighlighter(),
                               maximumLines: Int = 20_000, literateHaskell: Bool = false) throws -> SourceDocument {
        try Task.checkCancellation()
        let lineLimit = min(max(0, maximumLines), 20_000)
        let unitLimit = 1_048_576
        let units = Array(analysis.text.utf16.prefix(unitLimit + 1))
        var end = min(units.count, unitLimit)
        // Do not cut a UTF-16 surrogate pair at the retained preview boundary.
        if end > 0, end < units.count, isHighSurrogate(units[end - 1]), isLowSurrogate(units[end]) { end -= 1 }
        var starts: [Int] = end > 0 && lineLimit > 0 ? [0] : []
        if lineLimit == 0 { end = 0 }
        var index = 0
        while index < end {
            if index % 256 == 0 { try Task.checkCancellation() }
            let unit = units[index]
            index += 1
            guard unit == 10 || unit == 13 else { continue }
            if unit == 13, index < end, units[index] == 10 { index += 1 }
            if index < end {
                if starts.count == lineLimit { end = index; break }
                starts.append(index)
            }
        }
        let source = String(decoding: units[..<end], as: UTF16.self)
        let truncated = analysis.truncated || end < units.count
        var diagnostics: [InspectionDiagnostic] = truncated
            ? [.init(code: .truncated, message: "Preview truncated. Showing the retained source prefix.")] : []
        var highlighted = HighlightedSource(runs: [])
        do {
            // Third-party or injected highlighters cannot supply out-of-range or overlapping text attributes.
            let candidate = try highlighter.highlight(source, language: language, literateHaskell: literateHaskell)
            try Task.checkCancellation()
            guard valid(candidate, units: units, end: end) else { throw SyntaxHighlightingFailure.invalidRuns }
            highlighted = candidate
        } catch is CancellationError {
            throw CancellationError()
        } catch SyntaxHighlightingFailure.limit {
            diagnostics.append(.init(code: .limitExceeded, message: "Syntax highlighting limit reached. Showing plain text."))
        } catch {
            diagnostics.append(.init(code: .unsupported, message: "Syntax highlighting unavailable. Showing plain text."))
        }
        return .init(source: source, language: language, encoding: analysis.encoding,
                     lineEnding: analysis.lineEnding, lineCount: starts.count, truncated: truncated,
                     lineStarts: starts, highlighting: highlighted, diagnostics: diagnostics)
    }

    /// Rejects token runs that overlap, escape the retained prefix, or split a UTF-16 surrogate pair.
    private static func valid(_ highlighted: HighlightedSource, units: [UInt16], end: Int) -> Bool {
        // NSTextView consumes UTF-16 ranges, so each run must be ordered and avoid splitting surrogate pairs.
        guard highlighted.runs.count <= 50_000 else { return false }
        var previousEnd = 0
        for run in highlighted.runs {
            let range = run.range
            guard range.location >= previousEnd, range.location <= end,
                  range.length > 0, range.length <= end - range.location else { return false }
            let next = range.location + range.length
            for boundary in [range.location, next] where boundary > 0 && boundary < end {
                if isHighSurrogate(units[boundary - 1]), isLowSurrogate(units[boundary]) { return false }
            }
            previousEnd = next
        }
        return true
    }

    /// Identifies a UTF-16 high surrogate for safe source-prefix clipping and range validation.
    private static func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }
    /// Low-surrogate check pairs with the high-surrogate guard when validating UTF-16 boundaries.
    private static func isLowSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
}

/// Reasons a syntax highlighter cannot safely return a complete set of highlight runs.
enum SyntaxHighlightingFailure: Error { case limit, invalidRuns }
