import Foundation

/// A half-open zero-based line interval. Deleted lines have an empty working interval at the
/// insertion boundary; this preserves gutter placement at EOF and between adjacent lines.
public struct VCSLineChange: Equatable, Sendable {
    /// Whether the hunk adds lines, removes lines, or replaces one range with another.
    public enum Kind: String, Equatable, Sendable { case added, modified, deleted }
    public let kind: Kind
    public let baselineLines: Range<Int>
    public let workingLines: Range<Int>
    /// Creates a change using half-open, zero-based ranges in both snapshots.
    public init(kind: Kind, baselineLines: Range<Int>, workingLines: Range<Int>) {
        self.kind = kind; self.baselineLines = baselineLines; self.workingLines = workingLines
    }
}

/// Bounded line comparison with change ranges anchored in baseline and working snapshots.
public struct VCSLineDiff: Equatable, Sendable {
    /// Resource ceilings for input size, dynamic-programming cells, and elapsed comparison time.
    public struct Limits: Equatable, Sendable {
        public let maximumBytes: Int
        public let maximumMatrixCells: Int
        public let maximumDuration: Duration
        /// Creates explicit comparison limits; callers should keep the matrix bound conservative.
        public init(maximumBytes: Int = 1_048_576, maximumMatrixCells: Int = 2_000_000,
                    maximumDuration: Duration = .milliseconds(100)) {
            self.maximumBytes = maximumBytes; self.maximumMatrixCells = maximumMatrixCells
            self.maximumDuration = maximumDuration
        }
    }
    public let changes: [VCSLineChange]
    public let baselineLineCount: Int
    public let workingLineCount: Int
    /// Creates a diff result from validated changes and the total line counts of both inputs.
    public init(changes: [VCSLineChange], baselineLineCount: Int, workingLineCount: Int) {
        self.changes = changes; self.baselineLineCount = baselineLineCount; self.workingLineCount = workingLineCount
    }

    /// Builds a bounded LCS diff; rejects binary, oversized, over-budget or cancelled comparisons.
    public static func compare(baseline: Data, working: Data, limits: Limits = .init()) throws -> Self {
        // LCS uses O(n×m) memory, so validate byte, matrix, cancellation, and elapsed-time bounds first.
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: limits.maximumDuration)
        try check(clock, deadline)
        guard baseline.count <= limits.maximumBytes, working.count <= limits.maximumBytes else { throw VCSLineDiffError.inputTooLarge }
        let left = try normalizedLines(baseline)
        let right = try normalizedLines(working)
        try check(clock, deadline)
        let rows = left.count.addingReportingOverflow(1), columns = right.count.addingReportingOverflow(1)
        let cells = rows.partialValue.multipliedReportingOverflow(by: columns.partialValue)
        guard !rows.overflow, !columns.overflow, !cells.overflow, cells.partialValue <= limits.maximumMatrixCells else {
            throw VCSLineDiffError.comparisonTooLarge
        }
        let width = columns.partialValue
        var dp = Array(repeating: UInt32(0), count: cells.partialValue)
        if !left.isEmpty && !right.isEmpty {
            // Fill the dynamic-programming table backwards so each recurrence reads already-computed cells.
            for i in stride(from: left.count - 1, through: 0, by: -1) {
                var visited = 0
                for j in stride(from: right.count - 1, through: 0, by: -1) {
                    if visited & 4_095 == 0 { try check(clock, deadline) }
                    visited += 1
                    let index = i * width + j
                    dp[index] = left[i] == right[j] ? dp[(i + 1) * width + j + 1] + 1
                        : max(dp[(i + 1) * width + j], dp[i * width + j + 1])
                }
            }
        }

        /// Intermediate alignment operation used while coalescing changed line ranges.
        enum Edit { case keep, delete, insert }
        var edits: [Edit] = []; edits.reserveCapacity(left.count + right.count)
        var i = 0, j = 0
        while i < left.count || j < right.count {
            if (i + j) & 255 == 0 { try check(clock, deadline) }
            if i < left.count, j < right.count, left[i] == right[j] { edits.append(.keep); i += 1; j += 1 }
            else if i < left.count, j == right.count || dp[(i + 1) * width + j] >= dp[i * width + j + 1] {
                edits.append(.delete); i += 1
            } else { edits.append(.insert); j += 1 }
        }

        var changes: [VCSLineChange] = [], baselineLine = 0, workingLine = 0, cursor = 0
        while cursor < edits.count {
            if case .keep = edits[cursor] { baselineLine += 1; workingLine += 1; cursor += 1; continue }
            let startBase = baselineLine, startWork = workingLine
            var deleted = 0, inserted = 0
            while cursor < edits.count {
                switch edits[cursor] {
                case .keep: break
                case .delete: deleted += 1; baselineLine += 1
                case .insert: inserted += 1; workingLine += 1
                }
                if case .keep = edits[cursor] { break }
                cursor += 1
            }
            let kind: VCSLineChange.Kind = deleted == 0 ? .added : inserted == 0 ? .deleted : .modified
            changes.append(.init(kind: kind, baselineLines: startBase..<(startBase + deleted), workingLines: startWork..<(startWork + inserted)))
            try check(clock, deadline)
        }
        return .init(changes: changes, baselineLineCount: left.count, workingLineCount: right.count)
    }

    /// Decodes supported text, normalizes newline forms and preserves encoding identity per line.
    private static func normalizedLines(_ bytes: Data) throws -> [String] {
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
        guard !analysis.isBinary, let encoding = analysis.encoding else { throw VCSLineDiffError.binaryContent }
        let text = analysis.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Preserve empty files as zero lines and ignore only the presence of a final terminator.
        guard !text.isEmpty else { return [] }
        // Keep the final unterminated line but do not invent an empty line for a terminal newline.
        let lines = text.components(separatedBy: "\n")
        let result = text.hasSuffix("\n") ? Array(lines.dropLast()) : lines
        return result.map { "\(encoding.rawValue):\($0)" }
    }

    /// Stops cooperative work on cancellation before checking the elapsed-time deadline.
    private static func check(_ clock: ContinuousClock, _ deadline: ContinuousClock.Instant) throws {
        // Check cooperative cancellation before the wall-clock budget so callers stop promptly.
        try Task.checkCancellation()
        guard clock.now < deadline else { throw VCSLineDiffError.timeLimitReached }
    }
}

/// Failure reasons for bounded local line comparison.
public enum VCSLineDiffError: Error, Equatable, Sendable {
    case inputTooLarge, comparisonTooLarge, timeLimitReached, binaryContent, unsupportedEncoding
}
