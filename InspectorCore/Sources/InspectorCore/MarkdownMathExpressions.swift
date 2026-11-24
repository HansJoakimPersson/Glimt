import Foundation

/// Marked Markdown text and restoration data for bounded math expressions.
struct MarkdownMathPass {
    /// One expression's LaTeX body, layout mode, and exact original fallback text.
    struct Entry {
        let latex: String
        let mode: MarkdownMathExpression.Mode
        let fallbackText: String
    }

    let text: String
    private let entries: [UInt32: Entry]

    /// Stores the marked source and marker lookup used to restore fallback text after parsing.
    init(text: String, entries: [UInt32: Entry]) {
        self.text = text
        self.entries = entries
    }

    /// Replaces surviving private markers with fallback source and records each resulting UTF-16 range.
    func restore(_ value: String) -> (text: String, expressions: [(range: NSRange, entry: Entry)]) {
        guard !entries.isEmpty else { return (value, []) }
        var text = ""
        var length = 0
        var expressions: [(range: NSRange, entry: Entry)] = []
        for scalar in value.unicodeScalars {
            if let entry = entries[scalar.value] {
                let range = NSRange(location: length, length: entry.fallbackText.utf16.count)
                text += entry.fallbackText
                length += range.length
                expressions.append((range, entry))
            } else {
                text.unicodeScalars.append(scalar)
                length += scalar.utf16.count
            }
        }
        return (text, expressions)
    }
}

/// Protects supported math expressions from Foundation parsing and restores source fallbacks.
enum MarkdownMathExpressions {
    /// Delimiter form determines closing syntax and inline/display edge constraints.
    private enum Delimiter: Equatable {
        case inlineDollar, displayDollar, inlineParen, displayBracket

        var openingLength: Int { self == .inlineDollar ? 1 : self == .displayDollar ? 2 : 2 }
        var closingLength: Int { self == .inlineDollar ? 1 : self == .displayDollar ? 2 : 2 }
        var isDisplay: Bool { self == .displayDollar || self == .displayBracket }
        var requiresTightEdges: Bool { self == .inlineDollar }
    }

    private static let markerStart: UInt32 = 0xE022
    private static let maximumExpressionLength = 2_048
    private static let maximumTotalLength = 16_384
    private static let maximumExpressionCount = 128
    private static let maximumBraceDepth = 32

    /// Hides bounded math expressions from Foundation's Markdown parser while preserving code spans verbatim.
    static func mark(in text: String, checkpoint: () throws -> Void) throws -> MarkdownMathPass {
        let source = text as NSString
        let markerRange = markerStart..<(markerStart + UInt32(maximumExpressionCount))
        guard !text.unicodeScalars.contains(where: { markerRange.contains($0.value) }) else {
            return .init(text: text, entries: [:])
        }

        let codeRanges = try codeRanges(in: text, checkpoint: checkpoint)
        var codeIndex = 0
        var index = 0
        var totalLength = 0
        var entries: [UInt32: MarkdownMathPass.Entry] = [:]
        var replacements: [(NSRange, String)] = []

        while index < source.length {
            try checkpoint()
            while codeIndex < codeRanges.count, NSMaxRange(codeRanges[codeIndex]) <= index { codeIndex += 1 }
            if codeIndex < codeRanges.count, NSLocationInRange(index, codeRanges[codeIndex]) {
                index = NSMaxRange(codeRanges[codeIndex])
                continue
            }
            guard let delimiter = openingDelimiter(in: source, at: index), !isEscaped(source, at: index) else {
                index += 1
                continue
            }
            if delimiter == .displayBracket, !isWhitespaceOnlyBefore(source, at: index) {
                index += delimiter.openingLength
                continue
            }

            let delimiterLength = delimiter.openingLength
            let bodyStart = index + delimiterLength
            guard bodyStart < source.length,
                  (!delimiter.requiresTightEdges || !isWhitespace(source.character(at: bodyStart))) else {
                index += delimiterLength
                continue
            }

            guard let closing = closingDelimiter(in: source, from: bodyStart, delimiter: delimiter) else {
                index += delimiterLength
                continue
            }
            if delimiter == .displayBracket, !isWhitespaceOnlyAfter(source, at: closing + delimiter.closingLength) {
                index = closing + delimiter.closingLength
                continue
            }
            let bodyLength = closing - bodyStart
            let fullLength = closing + delimiter.closingLength - index
            guard bodyLength > 0, fullLength <= maximumExpressionLength,
                  (!delimiter.requiresTightEdges || !isWhitespace(source.character(at: closing - 1))) else {
                index = closing + delimiter.closingLength
                continue
            }
            let latex = source.substring(with: NSRange(location: bodyStart, length: bodyLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty, isStructurallyBounded(latex) else {
                index = closing + delimiterLength
                continue
            }
            guard entries.count < maximumExpressionCount,
                  totalLength <= maximumTotalLength - bodyLength else { break }

            let scalar = markerStart + UInt32(entries.count)
            let fallback = source.substring(with: NSRange(location: index, length: fullLength))
            entries[scalar] = .init(latex: latex, mode: delimiter.isDisplay ? .display : .inline, fallbackText: fallback)
            guard let marker = UnicodeScalar(scalar) else { continue }
            replacements.append((NSRange(location: index, length: fullLength), String(marker)))
            totalLength += bodyLength
            index = closing + delimiter.closingLength
        }

        guard !replacements.isEmpty else { return .init(text: text, entries: [:]) }
        let result = NSMutableString(string: text)
        for (range, marker) in replacements.reversed() { result.replaceCharacters(in: range, with: marker) }
        return .init(text: result as String, entries: entries)
    }

    /// Finds inline code spans that must be excluded from math delimiter scanning.
    private static func inlineCodeRanges(in text: String) throws -> [NSRange] {
        let expression = try NSRegularExpression(pattern: #"(`+)[^`\n]*?(?:`(?!\1)[^`\n]*?)*\1(?!`)"#)
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range).sorted { $0.location < $1.location }
    }

    /// Finds fenced and indented code ranges so delimiter-like text there is never treated as math.
    private static func codeRanges(in text: String, checkpoint: () throws -> Void) throws -> [NSRange] {
        let source = text as NSString
        var ranges = try inlineCodeRanges(in: text)
        var lineStart = 0
        var fence: (marker: unichar, length: Int)?
        var fenceStart: Int?
        while lineStart < source.length {
            try checkpoint()
            var lineEnd = lineStart
            while lineEnd < source.length, source.character(at: lineEnd) != 10,
                  source.character(at: lineEnd) != 13 { lineEnd += 1 }
            var nextLine = lineEnd
            if nextLine < source.length {
                if source.character(at: nextLine) == 13, nextLine + 1 < source.length,
                   source.character(at: nextLine + 1) == 10 { nextLine += 2 }
                else { nextLine += 1 }
            }

            var markerIndex = lineStart
            while markerIndex < lineEnd, markerIndex - lineStart < 4,
                  source.character(at: markerIndex) == 32 { markerIndex += 1 }
            let indentation = markerIndex - lineStart
            let marker = markerIndex < lineEnd ? source.character(at: markerIndex) : 0
            var markerEnd = markerIndex
            while markerEnd < lineEnd, source.character(at: markerEnd) == marker { markerEnd += 1 }
            let markerLength = markerEnd - markerIndex

            if let open = fence {
                if indentation <= 3, marker == open.marker, markerLength >= open.length,
                   (markerEnd..<lineEnd).allSatisfy({ isWhitespace(source.character(at: $0)) }) {
                    ranges.append(.init(location: fenceStart ?? lineStart, length: nextLine - (fenceStart ?? lineStart)))
                    fence = nil
                    fenceStart = nil
                }
            } else if indentation <= 3, (marker == 96 || marker == 126), markerLength >= 3 {
                fence = (marker, markerLength)
                fenceStart = lineStart
            } else if indentation == 4 || (lineStart < lineEnd && source.character(at: lineStart) == 9) {
                ranges.append(.init(location: lineStart, length: nextLine - lineStart))
            }
            lineStart = nextLine
        }
        if let fenceStart {
            ranges.append(.init(location: fenceStart, length: source.length - fenceStart))
        }
        return ranges.sorted { $0.location < $1.location }
    }

    /// Recognizes the four supported math opening forms at a UTF-16 source offset.
    private static func openingDelimiter(in source: NSString, at index: Int) -> Delimiter? {
        let unit = source.character(at: index)
        if unit == 36 {
            return index + 1 < source.length && source.character(at: index + 1) == 36 ? .displayDollar : .inlineDollar
        }
        guard unit == 92, index + 1 < source.length else { return nil }
        let delimiter: Delimiter? = switch source.character(at: index + 1) {
        case 40: .inlineParen
        case 91: .displayBracket
        default: nil
        }
        return delimiter
    }

    /// Finds a matching unescaped closer, rejecting line breaks in inline expressions.
    private static func closingDelimiter(in source: NSString, from start: Int, delimiter: Delimiter) -> Int? {
        var index = start
        while index < source.length {
            if !delimiter.isDisplay, source.character(at: index) == 10 || source.character(at: index) == 13 { return nil }
            guard isCloseDelimiter(source, at: index, delimiter: delimiter), !isEscaped(source, at: index) else {
                index += 1
                continue
            }
            if delimiter == .inlineDollar,
               index + 1 < source.length, source.character(at: index + 1) == 36 {
                index += 1
                continue
            }
            if delimiter != .inlineDollar || index + 1 == source.length || source.character(at: index + 1) != 36 {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Checks whether the source at a UTF-16 position contains the matching delimiter form.
    private static func isCloseDelimiter(_ source: NSString, at index: Int, delimiter: Delimiter) -> Bool {
        switch delimiter {
        case .inlineDollar: source.character(at: index) == 36
        case .displayDollar: index + 1 < source.length && source.character(at: index) == 36 && source.character(at: index + 1) == 36
        case .inlineParen: index + 1 < source.length && source.character(at: index) == 92 && source.character(at: index + 1) == 41
        case .displayBracket: index + 1 < source.length && source.character(at: index) == 92 && source.character(at: index + 1) == 93
        }
    }

    /// Treats a delimiter as escaped only when preceded by an odd-length backslash run.
    private static func isEscaped(_ source: NSString, at index: Int) -> Bool {
        var cursor = index
        var backslashes = 0
        while cursor > 0, source.character(at: cursor - 1) == 92 {
            backslashes += 1
            cursor -= 1
        }
        return !backslashes.isMultiple(of: 2)
    }

    /// Recognizes the ASCII whitespace characters used by line-boundary math rules.
    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 9 || unit == 10 || unit == 13 || unit == 32
    }

    /// Determines whether only whitespace precedes an expression on its physical line.
    private static func isWhitespaceOnlyBefore(_ source: NSString, at index: Int) -> Bool {
        var cursor = index
        while cursor > 0, source.character(at: cursor - 1) != 10, source.character(at: cursor - 1) != 13 {
            cursor -= 1
        }
        return (cursor..<index).allSatisfy { isWhitespace(source.character(at: $0)) }
    }

    /// Determines whether only whitespace follows an expression on its physical line.
    private static func isWhitespaceOnlyAfter(_ source: NSString, at index: Int) -> Bool {
        var cursor = index
        while cursor < source.length, source.character(at: cursor) != 10, source.character(at: cursor) != 13 {
            cursor += 1
        }
        return (index..<cursor).allSatisfy { isWhitespace(source.character(at: $0)) }
    }

    /// Rejects unmatched braces and excessive nesting before expressions reach the renderer.
    private static func isStructurallyBounded(_ latex: String) -> Bool {
        var depth = 0
        for scalar in latex.unicodeScalars {
            if scalar == "{" {
                depth += 1
                if depth > maximumBraceDepth { return false }
            } else if scalar == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }
}
