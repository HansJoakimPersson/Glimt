import Foundation

/// Key/value syntax selected by the format catalog for conservative configuration inspection.
public enum ConfigurationDialect: Sendable { case toml, ini, dotenv, javaProperties }

/// One decoded configuration assignment with its optional section and original line number.
public struct ConfigurationEntry: Equatable, Sendable {
    public let section: String?
    public let key: String
    public let value: String
    public let line: Int
}

/// Parsed assignments and diagnostics together with whether all source text was inspected.
public struct ConfigurationInspectionResult: Sendable {
    public let entries: [ConfigurationEntry]
    public let diagnostics: [InspectionDiagnostic]
    public let rawIsComplete: Bool
}

/// Conservative, local parsers for common key/value configuration forms. Original text is separate.
public enum ConfigurationInspector {
    /// Parses a bounded subset of the selected dialect while preserving the source separately.
    public static func inspect(_ text: String, dialect: ConfigurationDialect, isComplete: Bool = true,
                               maximumLines: Int = 20_000) throws -> ConfigurationInspectionResult {
        let lines = text.components(separatedBy: .newlines)
        let count = min(lines.count, min(maximumLines, 20_000))
        var entries: [ConfigurationEntry] = []
        var diagnostics: [InspectionDiagnostic] = []
        var section: String?
        var seen: Set<String> = []
        var index = 0
        while index < count {
            try Task.checkCancellation()
            let lineNumber = index + 1
            var line = lines[index]
            if dialect == .javaProperties {
                while Self.hasContinuation(line), index + 1 < count {
                    line.removeLast(); index += 1; line += lines[index].drop(while: \.isWhitespace)
                }
            }
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || Self.isComment(trimmed, dialect: dialect) { continue }
            if dialect == .toml || dialect == .ini, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty && !(dialect == .toml && inner.hasPrefix("[")) { section = inner; continue }
                diagnostics.append(.init(code: .unsupported, message: "Unsupported or malformed section at line \(lineNumber).")); continue
            }
            let pair: (String, String)?
            switch dialect {
            case .toml, .dotenv: pair = Self.split(line, separators: "=")
            case .ini: pair = Self.split(line, separators: "=:")
            case .javaProperties: pair = Self.propertiesPair(line)
            }
            guard let (rawKey, rawValue) = pair else {
                diagnostics.append(.init(code: .parseError, message: "Expected a key/value assignment at line \(lineNumber).")); continue
            }
            var key = rawKey.trimmingCharacters(in: .whitespaces)
            var value = rawValue.trimmingCharacters(in: .whitespaces)
            if dialect == .dotenv, key.hasPrefix("export ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            if dialect == .javaProperties {
                guard let decodedKey = Self.unescape(key), let decodedValue = Self.unescape(value) else {
                    diagnostics.append(.init(code: .parseError, message: "Invalid Unicode escape at line \(lineNumber).")); continue
                }
                key = decodedKey; value = decodedValue
            }
            if dialect == .dotenv { value = Self.stripMatchingQuotes(value) }
            guard !key.isEmpty else { diagnostics.append(.init(code: .parseError, message: "Empty key at line \(lineNumber).")); continue }
            if dialect == .toml && !Self.validTOMLKey(key) {
                diagnostics.append(.init(code: .unsupported, message: "TOML key syntax outside the supported subset at line \(lineNumber).")); continue
            }
            let identity = (section ?? "") + "\u{0}" + key
            if !seen.insert(identity).inserted {
                switch dialect {
                case .toml: diagnostics.append(.init(code: .parseError, message: "Duplicate TOML key at line \(lineNumber)."))
                case .ini, .dotenv: diagnostics.append(.init(code: .unsupported, message: "Repeated key at line \(lineNumber); source order is preserved."))
                case .javaProperties: break
                }
            }
            entries.append(.init(section: section, key: key, value: dialect == .toml ? Self.tomlValue(value) : value, line: lineNumber))
            if entries.count >= 10_000 { diagnostics.append(.init(code: .limitExceeded, message: "Configuration entry limit reached.")); break }
        }
        let complete = isComplete && count == lines.count && !diagnostics.contains { $0.code == .limitExceeded }
        if !complete && !diagnostics.contains(where: { $0.code == .truncated || $0.code == .limitExceeded }) {
            diagnostics.append(.init(code: .truncated, message: "Configuration preview is incomplete; Raw retains the available text."))
        }
        return .init(entries: entries, diagnostics: diagnostics, rawIsComplete: complete)
    }

    /// Recognizes full-line comment prefixes that are valid for the selected dialect.
    private static func isComment(_ line: String, dialect: ConfigurationDialect) -> Bool {
        line.hasPrefix("#") || ((dialect == .ini || dialect == .dotenv) && line.hasPrefix(";"))
    }
    /// Splits an assignment at its first dialect-approved separator.
    private static func split(_ line: String, separators: String) -> (String, String)? {
        guard let index = line.firstIndex(where: { separators.contains($0) }) else { return nil }
        return (String(line[..<index]), String(line[line.index(after: index)...]))
    }
    /// Finds the first unescaped Java Properties separator and skips its delimiter spacing.
    private static func propertiesPair(_ line: String) -> (String, String)? {
        let source = line.drop(while: \.isWhitespace)
        var escaped = false
        for index in source.indices {
            let char = source[index]
            if !escaped && (char == "=" || char == ":" || char.isWhitespace) {
                var valueIndex = source.index(after: index)
                while valueIndex < source.endIndex && (source[valueIndex].isWhitespace || source[valueIndex] == "=" || source[valueIndex] == ":") { valueIndex = source.index(after: valueIndex) }
                return (String(source[..<index]), String(source[valueIndex...]))
            }
            if char == "\\" { escaped.toggle() } else { escaped = false }
        }
        return source.isEmpty ? nil : (String(source), "")
    }
    /// Detects an odd trailing backslash count, which continues a Properties value.
    private static func hasContinuation(_ line: String) -> Bool {
        let count = line.reversed().prefix(while: { $0 == "\\" }).count
        return count % 2 == 1
    }
    /// Rejects key syntax outside the supported conservative TOML subset.
    private static func validTOMLKey(_ key: String) -> Bool {
        !key.isEmpty && !key.contains("=") && !key.contains("[") && !key.contains("]")
    }
    /// Removes one matching quote pair from simple TOML string values for display.
    private static func tomlValue(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, (first == "\"" || first == "'") , value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }
    /// Removes one matching quote pair from dotenv values without evaluating escapes.
    private static func stripMatchingQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, (first == "\"" || first == "'"), value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }
    /// Decodes Java Properties escapes and rejects malformed four-digit Unicode sequences.
    private static func unescape(_ value: String) -> String? {
        let input = Array(value.utf16)
        var output: [UInt16] = []; var index = 0
        while index < input.count {
            guard input[index] == 92 else { output.append(input[index]); index += 1; continue }
            guard index + 1 < input.count else { output.append(input[index]); index += 1; continue }
            index += 1
            switch input[index] {
            case 116: output.append(9)
            case 110: output.append(10)
            case 114: output.append(13)
            case 102: output.append(12)
            case 117:
                guard index + 4 < input.count else { return nil }
                let digits = input[(index + 1)...(index + 4)]
                var decoded: UInt16 = 0
                for unit in digits {
                    let nibble: UInt16
                    switch unit { case 48...57: nibble = unit - 48; case 65...70: nibble = unit - 55; case 97...102: nibble = unit - 87; default: nibble = 0 }
                    guard (48...57).contains(unit) || (65...70).contains(unit) || (97...102).contains(unit) else { return nil }
                    decoded = (decoded << 4) | nibble
                }
                output.append(decoded); index += 4
            default: output.append(input[index])
            }
            index += 1
        }
        return String(decoding: output, as: UTF16.self)
    }
}

/// Bounded semantic result for an fstab text prefix. Raw text and bytes remain on the shared result.
struct FstabInspectionResult: Sendable {
    let rows: [StructuredValue]
    let diagnostics: [InspectionDiagnostic]
    let rawIsComplete: Bool
}

/// Injectable fstab ceilings used by deterministic parser tests; callers cannot raise production limits.
struct FstabInspectionLimits: Sendable {
    let maximumLines: Int
    let maximumRecords: Int
    let maximumRowWarnings: Int

    init(maximumLines: Int = 20_000, maximumRecords: Int = 10_000, maximumRowWarnings: Int = 98) {
        self.maximumLines = min(max(maximumLines, 0), 20_000)
        self.maximumRecords = min(max(maximumRecords, 0), 10_000)
        self.maximumRowWarnings = min(max(maximumRowWarnings, 0), 98)
    }
}

/// Parses inert, whitespace-separated fstab rows without resolving or interpreting any field value.
enum FstabInspector {
    private struct ParsedRow {
        let fields: [String]
        let dump: StructuredValue
        let pass: StructuredValue
    }
    private struct RowFailure: Error {
        let category: String
    }

    /// Parses LF/CRLF physical lines with recovery, hard limits, and cancellation before result commit.
    static func inspect(_ text: String, isComplete: Bool = true,
                        limits: FstabInspectionLimits = .init(),
                        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> FstabInspectionResult {
        let bytes = Array(text.utf8)
        var physicalLine = 1
        var finalFragmentLine: Int?

        // Find the final incomplete line up front so parser caps can still report input truncation.
        if !isComplete, !bytes.isEmpty, bytes.last != 10 {
            for (index, byte) in bytes.enumerated() {
                if index.isMultiple(of: 4_096) { try cancellationCheck() }
                if byte == 10 { physicalLine += 1 }
            }
            finalFragmentLine = physicalLine
        }

        var rows: [StructuredValue] = []
        var rowWarnings: [InspectionDiagnostic] = []
        var limitDiagnostic: InspectionDiagnostic?
        var lineStart = 0
        physicalLine = 1
        var eligibleLines = 0
        var stopped = false

        while !stopped, lineStart < bytes.count {
            try cancellationCheck()

            var end = lineStart
            while end < bytes.count, bytes[end] != 10 {
                if (end - lineStart).isMultiple(of: 256) { try cancellationCheck() }
                end += 1
            }

            let hasLF = end < bytes.count
            let hasFragment = !hasLF && !isComplete
            if hasFragment {
                finalFragmentLine = physicalLine
                break
            }

            eligibleLines += 1
            if eligibleLines > limits.maximumLines {
                limitDiagnostic = Self.limitDiagnostic(line: physicalLine, reason: "line")
                break
            }

            var contentEnd = end
            if hasLF, contentEnd > lineStart, bytes[contentEnd - 1] == 13 { contentEnd -= 1 }
            let parsed: Result<ParsedRow?, RowFailure> = Self.parseLine(bytes[lineStart..<contentEnd])
            switch parsed {
            case .failure(let failure):
                if rowWarnings.count < limits.maximumRowWarnings {
                    rowWarnings.append(.init(code: .parseError,
                                             message: "Malformed fstab row at line \(physicalLine): \(failure.category)."))
                }
            case .success(nil): break
            case .success(let row?):
                try cancellationCheck()
                if rows.count >= limits.maximumRecords {
                    limitDiagnostic = Self.limitDiagnostic(line: physicalLine, reason: "record")
                    stopped = true
                    break
                }
                rows.append(Self.structuredRow(row, line: physicalLine))
            }
            if stopped { break }
            if hasLF {
                lineStart = end + 1
                physicalLine += 1
            } else {
                lineStart = bytes.count
            }
        }

        try cancellationCheck()
        var diagnostics = rowWarnings
        if let limitDiagnostic { diagnostics.append(limitDiagnostic) }
        if !isComplete {
            let message = finalFragmentLine.map { "Input prefix is incomplete after line \($0); the fragment was not parsed." }
                ?? "Input prefix is incomplete; additional lines may be unavailable."
            diagnostics.append(.init(code: .truncated, message: message))
        }
        return FstabInspectionResult(rows: rows, diagnostics: diagnostics, rawIsComplete: isComplete)
    }

    private static func parseLine(_ bytes: ArraySlice<UInt8>) -> Result<ParsedRow?, RowFailure> {
        var fields: [[UInt8]] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            while index < bytes.endIndex, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
            guard index < bytes.endIndex else { break }
            if bytes[index] == 35 { break }
            let start = index
            while index < bytes.endIndex, bytes[index] != 32, bytes[index] != 9 {
                if bytes[index] == 13 { return .failure(RowFailure(category: "bareCR")) }
                index += 1
            }
            fields.append(Array(bytes[start..<index]))
        }
        guard !fields.isEmpty else { return .success(nil) }
        guard (4...6).contains(fields.count) else { return .failure(RowFailure(category: "fieldCount")) }
        let textFields = fields.prefix(4).map { String(decoding: $0, as: UTF8.self) }
        let dump: StructuredValue
        let pass: StructuredValue
        if fields.count >= 5 {
            guard let number = Self.canonicalNumber(fields[4]) else { return .failure(RowFailure(category: "numericField")) }
            dump = .number(number)
        } else {
            dump = .null
        }
        if fields.count >= 6 {
            guard let number = Self.canonicalNumber(fields[5]) else { return .failure(RowFailure(category: "numericField")) }
            pass = .number(number)
        } else {
            pass = .null
        }
        return .success(ParsedRow(fields: textFields, dump: dump, pass: pass))
    }

    private static func canonicalNumber(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, bytes.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(String(decoding: bytes, as: UTF8.self)) else { return nil }
        return String(value)
    }

    private static func structuredRow(_ row: ParsedRow, line: Int) -> StructuredValue {
        .object([
            .init(key: "Line", value: .number(String(line))),
            .init(key: "Filesystem specification", value: .string(row.fields[0])),
            .init(key: "Mount point", value: .string(row.fields[1])),
            .init(key: "Filesystem type", value: .string(row.fields[2])),
            .init(key: "Options", value: .string(row.fields[3])),
            .init(key: "Dump frequency", value: row.dump),
            .init(key: "Pass number", value: row.pass)
        ])
    }

    private static func limitDiagnostic(line: Int, reason: String) -> InspectionDiagnostic {
        .init(code: .limitExceeded, message: "Fstab inspection \(reason) limit reached at line \(line).")
    }
}
