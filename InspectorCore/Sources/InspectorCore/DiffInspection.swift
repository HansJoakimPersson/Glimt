import Foundation

/// Classification of a line in a unified diff hunk.
public enum DiffLineKind: String, Equatable, Sendable {
    case context, addition, deletion, metadata
}

/// File-level operation inferred from diff headers and paths.
public enum DiffFileChangeKind: String, Equatable, Sendable {
    case create, delete, rename, modify, unknown
}

/// One hunk line with its content and optional old/new source line numbers.
public struct DiffLine: Equatable, Sendable {
    public let kind: DiffLineKind
    /// The source line without its unified-diff marker.
    public let text: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
}

/// A unified-diff hunk with header ranges, section label, and parsed lines.
public struct DiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let section: String
    public let lines: [DiffLine]
}

/// Parsed changes for one file, including binary status and any textual hunks.
public struct DiffFileChange: Equatable, Sendable {
    public let oldPath: String?
    public let newPath: String?
    public let change: DiffFileChangeKind
    public let isBinary: Bool
    public let hunks: [DiffHunk]
}

/// Hard upper bounds for bytes and lines accepted by the diff inspector.
public struct DiffInspectionLimits: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumLines: Int

    /// Clamps requested limits to the inspector's supported safety ceilings.
    public init(maximumBytes: Int = 1_048_576, maximumLines: Int = 20_000) {
        self.maximumBytes = min(max(maximumBytes, 0), 1_048_576)
        self.maximumLines = min(max(maximumLines, 0), 20_000)
    }
}

/// Parsed diff metadata together with the bounded original text and diagnostics.
public struct DiffInspectionResult: Equatable, Sendable {
    public let files: [DiffFileChange]
    public let rawText: String
    public let diagnostics: [InspectionDiagnostic]
    public let lineCount: Int
    public let isTruncated: Bool

    public var addedLineCount: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .addition }.count
    }

    public var removedLineCount: Int {
        files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .deletion }.count
    }
}

/// Bounded parser for unified and Git-style patch text. It never applies changes or accesses paths.
public enum DiffInspector {
    private static let maximumLineBytes = 65_536

    /// Parses structural metadata from already-decoded bounded input and always retains the source.
    public static func inspect(text: String, fileSize: Int,
                               limits: DiffInspectionLimits = .init()) throws -> DiffInspectionResult {
        try Task.checkCancellation()
        let boundedUTF8 = text.utf8.prefix(limits.maximumBytes)
        let boundedText = String(decoding: boundedUTF8, as: UTF8.self)
        let inputTruncated = fileSize > boundedText.utf8.count || text.utf8.count > limits.maximumBytes
        var parser = DiffParserState()
        var cancellation: CancellationError?

        boundedText.enumerateLines { line, stop in
            if parser.lineCount & 63 == 0 {
                do { try Task.checkCancellation() }
                catch { cancellation = error as? CancellationError ?? CancellationError(); stop = true; return }
            }
            guard parser.lineCount < limits.maximumLines else {
                parser.markLimitExceeded("Diff inspection reached its line limit.")
                stop = true
                return
            }
            parser.lineCount += 1
            guard line.utf8.count <= maximumLineBytes else {
                parser.markLimitExceeded("A diff line exceeded the per-line inspection limit.")
                stop = true
                return
            }
            parser.consume(String(line))
        }
        if let cancellation { throw cancellation }
        try Task.checkCancellation()

        if inputTruncated {
            parser.isTruncated = true
            parser.diagnostics.append(.init(code: .truncated, message: "The diff input was truncated to the inspection byte limit."))
        }
        parser.finish()
        if parser.files.isEmpty, !parser.isTruncated {
            parser.diagnostics.append(.init(code: .unsupported, message: "No unified diff file sections were recognized."))
        }
        return DiffInspectionResult(files: parser.files, rawText: boundedText, diagnostics: parser.diagnostics,
                                    lineCount: parser.lineCount, isTruncated: parser.isTruncated)
    }
}

/// Incrementally assembles file sections while tracking truncation and parser diagnostics.
private struct DiffParserState {
    var files: [DiffFileChange] = []
    var diagnostics: [InspectionDiagnostic] = []
    var lineCount = 0
    var isTruncated = false

    private var file: DiffFileBuilder?

    /// Marks the parse incomplete once and records why further input was not consumed.
    mutating func markLimitExceeded(_ message: String) {
        guard !isTruncated else { return }
        isTruncated = true
        diagnostics.append(.init(code: .limitExceeded, message: message))
    }

    /// Adds one bounded source line to the active file or hunk state.
    mutating func consume(_ line: String) {
        if line.hasPrefix("diff --git ") {
            finishFile()
            file = DiffFileBuilder(gitHeader: line)
            return
        }
        if line.hasPrefix("--- ") {
            if file == nil { file = DiffFileBuilder() }
            file?.setOldPath(Self.patchPath(String(line.dropFirst(4)), prefix: "a/"))
            return
        }
        if line.hasPrefix("+++ ") {
            if file == nil { file = DiffFileBuilder() }
            file?.setNewPath(Self.patchPath(String(line.dropFirst(4)), prefix: "b/"))
            return
        }
        guard file != nil else { return }

        if line.hasPrefix("rename from ") {
            file?.renameFrom = Self.patchPath(String(line.dropFirst("rename from ".count)), prefix: "")
        } else if line.hasPrefix("rename to ") {
            file?.renameTo = Self.patchPath(String(line.dropFirst("rename to ".count)), prefix: "")
        } else if line.hasPrefix("new file mode ") {
            file?.isNewFile = true
        } else if line.hasPrefix("deleted file mode ") {
            file?.isDeletedFile = true
        } else if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
            file?.isBinary = true
        } else if line.hasPrefix("@@ ") {
            file?.startHunk(line, diagnostics: &diagnostics)
        } else if line == "\\ No newline at end of file" {
            file?.appendMetadata(line)
        } else if file?.hasActiveHunk == true {
            file?.appendHunkLine(line, diagnostics: &diagnostics)
        } else if line.hasPrefix("@@") {
            diagnostics.append(.init(code: .parseError, message: "A diff hunk header is malformed."))
        }
    }

    /// Finalizes the active file after the input stream has ended.
    mutating func finish() { finishFile() }

    /// Closes the active hunk and appends the completed file record.
    private mutating func finishFile() {
        guard var current = file else { return }
        current.finishHunk(diagnostics: &diagnostics)
        files.append(current.build())
        file = nil
    }

    /// Removes patch timestamps and conventional path prefixes, preserving `/dev/null` as nil.
    private static func patchPath(_ raw: String, prefix: String) -> String? {
        let value = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        guard value != "/dev/null" else { return nil }
        let unquoted = unquoteGitPath(value)
        return unquoted.hasPrefix(prefix) ? String(unquoted.dropFirst(prefix.count)) : unquoted
    }

    /// Decodes Git's quoted path escapes without interpreting shell syntax or touching the path.
    fileprivate static func unquoteGitPath(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        var output: [UInt8] = []
        var index = value.index(after: value.startIndex)
        let end = value.index(before: value.endIndex)
        while index < end {
            let character = value[index]
            index = value.index(after: index)
            guard character == "\\", index < end else { output.append(contentsOf: String(character).utf8); continue }
            let escape = value[index]
            index = value.index(after: index)
            switch escape {
            case "a": output.append(7)
            case "b": output.append(8)
            case "t": output.append(9)
            case "n": output.append(10)
            case "v": output.append(11)
            case "f": output.append(12)
            case "r": output.append(13)
            case "\\", "\"": output.append(contentsOf: String(escape).utf8)
            case "0"..."7":
                var octal = String(escape)
                while octal.count < 3, index < end, value[index].isNumber, ("0"..."7").contains(String(value[index])) {
                    octal.append(value[index]); index = value.index(after: index)
                }
                output.append(UInt8(octal, radix: 8) ?? 0)
            default:
                output.append(92)
                output.append(contentsOf: String(escape).utf8)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Collects patch headers and hunks for a single file before producing its immutable model.
private struct DiffFileBuilder {
    private var oldPath: String?
    private var newPath: String?
    var renameFrom: String?
    var renameTo: String?
    var isNewFile = false
    var isDeletedFile = false
    var isBinary = false
    private var hunks: [DiffHunk] = []
    private var activeHunk: DiffHunkBuilder?

    var hasActiveHunk: Bool { activeHunk != nil }

    /// Starts a file builder before path headers are encountered.
    init() {}

    /// Seeds old and new paths from a Git `diff --git` header.
    init(gitHeader: String) {
        let paths = Self.gitHeaderPaths(gitHeader)
        oldPath = paths.old
        newPath = paths.new
    }

    /// Stores the path from a unified diff's old-file header.
    mutating func setOldPath(_ path: String?) { oldPath = path }
    /// Stores the path from a unified diff's new-file header.
    mutating func setNewPath(_ path: String?) { newPath = path }

    /// Finishes any previous hunk and starts a new hunk when its header is valid.
    mutating func startHunk(_ header: String, diagnostics: inout [InspectionDiagnostic]) {
        finishHunk(diagnostics: &diagnostics)
        guard let range = Self.parseHunkHeader(header) else {
            diagnostics.append(.init(code: .parseError, message: "A diff hunk header is malformed."))
            return
        }
        activeHunk = DiffHunkBuilder(oldStart: range.oldStart, oldCount: range.oldCount,
            newStart: range.newStart, newCount: range.newCount, section: range.section)
    }

    /// Retains a non-source marker such as the no-newline-at-end-of-file notice.
    mutating func appendMetadata(_ text: String) {
        guard var hunk = activeHunk else { return }
        hunk.lines.append(.init(kind: .metadata, text: text, oldLineNumber: nil, newLineNumber: nil))
        activeHunk = hunk
    }

    /// Adds a context, addition, deletion, or malformed line and advances source cursors.
    mutating func appendHunkLine(_ line: String, diagnostics: inout [InspectionDiagnostic]) {
        guard var hunk = activeHunk, let marker = line.first else { return }
        let content = String(line.dropFirst())
        switch marker {
        case " ":
            hunk.lines.append(.init(kind: .context, text: content, oldLineNumber: hunk.oldCursor, newLineNumber: hunk.newCursor))
            hunk.oldCursor += 1
            hunk.newCursor += 1
            hunk.actualOldCount += 1
            hunk.actualNewCount += 1
        case "-":
            hunk.lines.append(.init(kind: .deletion, text: content, oldLineNumber: hunk.oldCursor, newLineNumber: nil))
            hunk.oldCursor += 1
            hunk.actualOldCount += 1
        case "+":
            hunk.lines.append(.init(kind: .addition, text: content, oldLineNumber: nil, newLineNumber: hunk.newCursor))
            hunk.newCursor += 1
            hunk.actualNewCount += 1
        default:
            diagnostics.append(.init(code: .parseError, message: "A diff hunk contains a line without a valid marker."))
            hunk.lines.append(.init(kind: .metadata, text: line, oldLineNumber: nil, newLineNumber: nil))
        }
        activeHunk = hunk
    }

    /// Checks declared versus observed hunk counts and appends the completed hunk.
    mutating func finishHunk(diagnostics: inout [InspectionDiagnostic]) {
        guard let hunk = activeHunk else { return }
        if hunk.actualOldCount != hunk.oldCount || hunk.actualNewCount != hunk.newCount {
            diagnostics.append(.init(code: .parseError, message: "Diff hunk line counts do not match its header."))
        }
        hunks.append(hunk.build())
        activeHunk = nil
    }

    /// Produces a file-change record, resolving rename and create/delete precedence.
    func build() -> DiffFileChange {
        let finalOldPath = renameFrom ?? oldPath
        let finalNewPath = renameTo ?? newPath
        let kind: DiffFileChangeKind
        if isNewFile || finalOldPath == nil { kind = .create }
        else if isDeletedFile || finalNewPath == nil { kind = .delete }
        else if renameFrom != nil || renameTo != nil || finalOldPath != finalNewPath { kind = .rename }
        else if finalOldPath != nil || finalNewPath != nil { kind = .modify }
        else { kind = .unknown }
        return .init(oldPath: finalOldPath, newPath: finalNewPath, change: kind, isBinary: isBinary, hunks: hunks)
    }

    /// Reads old/new ranges and the optional section label from a unified hunk header.
    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String)? {
        guard header.hasPrefix("@@ -"), let close = header.range(of: " @@", range: header.index(header.startIndex, offsetBy: 3)..<header.endIndex) else { return nil }
        let body = header[header.index(header.startIndex, offsetBy: 3)..<close.lowerBound]
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              let old = parseRange(String(parts[0]), marker: "-"),
              let new = parseRange(String(parts[1]), marker: "+") else { return nil }
        let sectionStart = header.index(close.lowerBound, offsetBy: 3)
        let section = String(header[sectionStart...]).trimmingCharacters(in: .whitespaces)
        return (old.start, old.count, new.start, new.count, section)
    }

    /// Parses a marked line range, applying unified-diff's default count of one.
    private static func parseRange(_ value: String, marker: Character) -> (start: Int, count: Int)? {
        guard value.first == marker else { return nil }
        let parts = value.dropFirst().split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(parts[0]), start >= 0 else { return nil }
        let count: Int
        if parts.count == 1 { count = 1 }
        else if let parsed = Int(parts[1]), parsed >= 0 { count = parsed }
        else { return nil }
        return (start, count)
    }

    /// Extracts the two path tokens from a Git file header and removes `a/` and `b/` prefixes.
    private static func gitHeaderPaths(_ header: String) -> (old: String?, new: String?) {
        let body = header.dropFirst("diff --git ".count)
        guard let (old, remainder) = gitPathToken(String(body)),
              let (new, _) = gitPathToken(remainder.trimmingCharacters(in: .whitespaces)), !new.isEmpty else { return (nil, nil) }
        return (Self.cleanGitPath(old, prefix: "a/"), Self.cleanGitPath(new, prefix: "b/"))
    }

    /// Reads one quoted or whitespace-delimited path token without interpreting shell syntax.
    private static func gitPathToken(_ source: String) -> (String, String)? {
        guard !source.isEmpty else { return nil }
        if source.first == "\"" {
            var escaped = false
            for index in source.indices.dropFirst() {
                let character = source[index]
                if character == "\"" && !escaped {
                    return (String(source[...index]), String(source[source.index(after: index)...]))
                }
                if character == "\\" && !escaped { escaped = true } else { escaped = false }
            }
            return nil
        }
        guard let end = source.firstIndex(where: \.isWhitespace) else { return (source, "") }
        return (String(source[..<end]), String(source[end...]))
    }

    /// Decodes Git quoting and removes the expected side prefix from a path.
    private static func cleanGitPath(_ raw: String, prefix: String) -> String? {
        let unquoted = DiffParserState.unquoteGitPath(raw)
        return unquoted.hasPrefix(prefix) ? String(unquoted.dropFirst(prefix.count)) : unquoted
    }
}

/// Tracks declared hunk ranges, observed line counts, and source line cursors while parsing.
private struct DiffHunkBuilder {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let section: String
    var oldCursor: Int
    var newCursor: Int
    var actualOldCount = 0
    var actualNewCount = 0
    var lines: [DiffLine] = []

    /// Initializes source cursors and expected counts from a validated hunk header.
    init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        oldCursor = oldStart
        newCursor = newStart
    }

    /// Freezes the accumulated lines and header metadata into a hunk value.
    func build() -> DiffHunk {
        .init(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
              section: section, lines: lines)
    }
}
