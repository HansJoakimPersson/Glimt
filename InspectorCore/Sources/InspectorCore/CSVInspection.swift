import Foundation

/// Explicit delimiter selected by the catalog or caller for table inspection.
public enum CSVDelimiter: Equatable, Sendable {
    case comma
    case tab

    fileprivate var byte: UInt8 { self == .comma ? 0x2C : 0x09 }
}

/// A table with a header row and data rows, preserving cell text as parsed.
public struct CSVTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]

    public var columnCount: Int { max(headers.count, rows.map(\.count).max() ?? 0) }

    /// Compact, bounded plain-text projection used only by the thumbnail renderer.
    /// Produces a short projection with independent hard caps for rows, columns and cell length.
    public func thumbnailText(maximumRows: Int = 8, maximumColumns: Int = 6,
                              maximumCellScalars: Int = 80) -> String {
        let rowLimit = min(max(0, maximumRows), 32)
        let columnLimit = min(max(0, maximumColumns), 16)
        let cellLimit = min(max(0, maximumCellScalars), 256)
        let selectedRows = [headers] + rows.prefix(rowLimit)
        return selectedRows.map { row in
            row.prefix(columnLimit).map { value in
                let clipped = String(value.unicodeScalars.prefix(cellLimit))
                return clipped == value ? clipped : clipped + "…"
            }.joined(separator: "  │  ")
        }.joined(separator: "\n")
    }
}

/// Byte, row, column, and cell ceilings for CSV/TSV inspection.
public struct CSVInspectionLimits: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumRows: Int
    public let maximumColumns: Int
    public let maximumCells: Int

    public init(maximumBytes: Int = 1_048_576, maximumRows: Int = 10_000,
                maximumColumns: Int = 256, maximumCells: Int = 50_000) {
        // Clamp caller values to security ceilings; callers may tighten limits but cannot relax them.
        self.maximumBytes = min(max(maximumBytes, 0), 1_048_576)
        self.maximumRows = min(max(maximumRows, 0), 10_000)
        self.maximumColumns = min(max(maximumColumns, 0), 256)
        self.maximumCells = min(max(maximumCells, 0), 50_000)
    }
}

/// Parsed table, diagnostics, and completeness facts with the bounded source prefix.
public struct CSVInspectionResult: Equatable, Sendable {
    public let rawBytes: Data
    public let rawText: String?
    public let rawIsComplete: Bool
    public let table: CSVTable?
    public let diagnostics: [InspectionDiagnostic]
}

/// Parses bounded CSV/TSV text. It never opens files, guesses dialects, or rewrites Raw bytes.
public enum CSVInspector {
    /// Inspects one explicitly selected delimiter and preserves Raw even when parsing is incomplete or malformed.
    public static func inspect(bytes: Data, fileSize: Int? = nil, delimiter: CSVDelimiter,
                               limits: CSVInspectionLimits = .init()) throws -> CSVInspectionResult {
        try Task.checkCancellation()
        let size = max(0, fileSize ?? bytes.count)
        let retained = Data(bytes.prefix(min(bytes.count, limits.maximumBytes)))
        let complete = size == bytes.count && retained.count == bytes.count
        let analysis = TextAnalysis.analyze(bytes: retained, fileSize: retained.count, maximumBytes: limits.maximumBytes)
        let text = analysis.isBinary ? nil : analysis.text
        /// Returns the retained Raw payload alongside diagnostics when a semantic table is unavailable.
        func result(_ diagnostics: [InspectionDiagnostic], table: CSVTable? = nil) -> CSVInspectionResult {
            .init(rawBytes: retained, rawText: text, rawIsComplete: complete, table: table, diagnostics: diagnostics)
        }

        guard complete else {
            var diagnostics: [InspectionDiagnostic] = []
            if bytes.count > limits.maximumBytes || size > limits.maximumBytes {
                diagnostics.append(.init(code: .limitExceeded, message: "CSV input limit reached. Raw contains the retained prefix."))
            }
            diagnostics.append(.init(code: .truncated, message: "CSV input is incomplete. Raw remains available."))
            return result(diagnostics)
        }
        guard let text else {
            return result([.init(code: .unsupported, message: "CSV requires readable text. Raw bytes remain available.")])
        }

        do {
            var parser = CSVParser(text: text, delimiter: delimiter, limits: limits)
            let records = try parser.parse()
            let header = records.first ?? []
            return result([], table: .init(headers: header, rows: Array(records.dropFirst())))
        } catch is CancellationError {
            throw CancellationError()
        } catch CSVFailure.limit {
            return result([.init(code: .limitExceeded, message: "CSV processing limit reached. Raw remains available.")])
        } catch {
            return result([.init(code: .parseError, message: "Malformed CSV. Raw remains available.")])
        }
    }
}

private enum CSVFailure: Error { case malformed, limit }
private enum CSVFieldState: Equatable { case unquoted, quoted, closedQuote }

private struct CSVParser {
    let bytes: [UInt8]
    let delimiter: UInt8
    let limits: CSVInspectionLimits
    private var index = 0
    private var work = 0
    private var cellCount = 0

    /// Creates a CSV parser that enforces field, row, column, and cell limits.
    init(text: String, delimiter: CSVDelimiter, limits: CSVInspectionLimits) {
        bytes = Array(text.utf8)
        self.delimiter = delimiter.byte
        self.limits = limits
    }

    /// Parses quoted records incrementally so configured row/cell limits stop memory growth early.
    mutating func parse() throws -> [[String]] {
        // Parse records incrementally so row, column, and cell budgets stop growth early.
        var records: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var state = CSVFieldState.unquoted
        var recordStarted = false

        /// Decodes each cell strictly so malformed UTF-8 fails the table without losing Raw preview.
        func decodedField(_ bytes: [UInt8]) -> String? { String(bytes: bytes, encoding: .utf8) }

        /// Enforces column bounds before a field is committed to the current row.
        func checkColumnLimit(_ count: Int) throws {
            guard count <= limits.maximumColumns else { throw CSVFailure.limit }
        }

        /// Decodes and accounts for one cell before clearing its reusable byte buffer.
        func appendField() throws {
            // Decode each field strictly as UTF-8 and count cells before retaining it in the result.
            guard let value = decodedField(field) else { throw CSVFailure.malformed }
            row.append(value)
            field.removeAll(keepingCapacity: true)
            cellCount += 1
            guard cellCount <= limits.maximumCells else { throw CSVFailure.limit }
            try checkColumnLimit(row.count)
        }

        /// Commits a complete row only if the configured row bound still permits it.
        func appendRecord() throws {
            // Row count is enforced before another record can grow the result array.
            records.append(row)
            row.removeAll(keepingCapacity: true)
            guard records.count <= limits.maximumRows else { throw CSVFailure.limit }
        }

        while index < bytes.count {
            try checkpoint()
            let byte = bytes[index]
            switch state {
            case .unquoted:
                if byte == delimiter {
                    try appendField()
                    recordStarted = true
                    index += 1
                } else if byte == 0x0A || byte == 0x0D {
                    try appendField()
                    try appendRecord()
                    recordStarted = false
                    state = .unquoted
                    consumeLineEnding()
                } else if byte == 0x22 {
                    guard field.isEmpty else { throw CSVFailure.malformed }
                    recordStarted = true
                    state = .quoted
                    index += 1
                } else {
                    field.append(byte)
                    recordStarted = true
                    index += 1
                }
            case .quoted:
                // Inside quotes, delimiters/newlines are data and doubled quotes escape one literal quote.
                if byte == 0x22 {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        field.append(0x22)
                        index += 2
                    } else {
                        state = .closedQuote
                        index += 1
                    }
                } else {
                    field.append(byte)
                    index += 1
                }
            case .closedQuote:
                // After a closing quote, only a delimiter, newline, or end-of-input is valid.
                if byte == delimiter {
                    try appendField()
                    recordStarted = true
                    state = .unquoted
                    index += 1
                } else if byte == 0x0A || byte == 0x0D {
                    try appendField()
                    try appendRecord()
                    recordStarted = false
                    state = .unquoted
                    consumeLineEnding()
                } else {
                    throw CSVFailure.malformed
                }
            }
        }

        try checkpoint()
        guard state != .quoted else { throw CSVFailure.malformed }
        if recordStarted || !row.isEmpty || !field.isEmpty || state == .closedQuote {
            try appendField()
            try appendRecord()
        }
        return records
    }

    /// Consumes CRLF as one record separator and handles lone CR or LF consistently.
    private mutating func consumeLineEnding() {
        if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2 }
        else { index += 1 }
    }

    /// Amortizes cancellation checks while bounding work in long records or fields.
    private mutating func checkpoint() throws {
        work += 1
        if work.isMultiple(of: 256) { try Task.checkCancellation() }
    }
}
