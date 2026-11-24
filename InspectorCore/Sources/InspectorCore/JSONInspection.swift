import Foundation

// Compatibility names retained for existing JSON clients.
/// Compatibility alias for the shared structured value model used by JSON clients.
public typealias JSONValue = StructuredValue
/// Compatibility alias for a key/value member in the shared structured model.
public typealias JSONMember = StructuredMember
/// Compatibility alias for bounded structured inspection limits.
public typealias JSONInspectionLimits = StructuredInspectionLimits
/// Compatibility alias for shared parse and resource diagnostics.
public typealias JSONDiagnostic = InspectionDiagnostic

/// Accepted JSON syntax for catalog-routed JSON-family files.
public enum JSONSyntax: Sendable, Equatable { case strict, jsonc, json5 }

/// Parsed JSON content and pretty output alongside the exact bounded source bytes.
public struct JSONInspectionResult: Equatable, Sendable {
    public let rawBytes: Data
    public let rawText: String?
    public let rawIsComplete: Bool
    public let content: JSONValue?
    public let prettyText: String?
    public let diagnostics: [JSONDiagnostic]
    /// Optional domain projection; JSON content and exact source remain independently available.
    public let domainSummary: StructuredValue?

    init(rawBytes: Data, rawText: String?, rawIsComplete: Bool, content: JSONValue?, prettyText: String?,
         diagnostics: [JSONDiagnostic], domainSummary: StructuredValue? = nil) {
        self.rawBytes = rawBytes
        self.rawText = rawText
        self.rawIsComplete = rawIsComplete
        self.content = content
        self.prettyText = prettyText
        self.diagnostics = diagnostics
        self.domainSummary = domainSummary
    }
}

/// Pure inspection of supplied bytes. Never reads files or executes file content.
public enum JSONInspector {
    /// Converts the supported Zig Object Notation value subset into JSON while retaining original Raw bytes.
    public static func inspectZON(bytes: Data, fileSize: Int? = nil,
                                  limits: JSONInspectionLimits = .init()) throws -> JSONInspectionResult {
        try Task.checkCancellation()
        let size = fileSize ?? bytes.count
        let raw = Data(bytes.prefix(limits.maximumBytes))
        let analysis = TextAnalysis.analyze(bytes: raw, fileSize: raw.count, maximumBytes: limits.maximumBytes)
        let complete = size >= 0 && size == bytes.count && raw.count == bytes.count
        /// Builds the safe Raw-only result returned for a non-cancellation ZON failure.
        func rawResult(_ diagnostic: InspectionDiagnostic) -> JSONInspectionResult {
            .init(rawBytes: raw, rawText: analysis.isBinary ? nil : analysis.text,
                  rawIsComplete: complete, content: nil, prettyText: nil, diagnostics: [diagnostic])
        }
        guard complete else {
            var diagnostics: [InspectionDiagnostic] = []
            if size > limits.maximumBytes || bytes.count > limits.maximumBytes {
                diagnostics.append(.init(code: .limitExceeded, message: "ZON input limit reached. Raw contains the retained prefix."))
            }
            diagnostics.append(.init(code: .truncated, message: "ZON input is incomplete. Raw remains available."))
            return .init(rawBytes: raw, rawText: analysis.isBinary ? nil : analysis.text,
                         rawIsComplete: false, content: nil, prettyText: nil, diagnostics: diagnostics)
        }
        guard !analysis.isBinary, analysis.encoding != .windows1252 else {
            return rawResult(.init(code: .parseError, message: "ZON requires valid Unicode text. Raw remains available."))
        }

        let checkpoint = { try Task.checkCancellation() }
        do {
            var parser = ZONJSONTranslator(source: analysis.text, limits: limits, checkpoint: checkpoint)
            let json = try parser.translate()
            let parsed = try inspect(bytes: Data(json.utf8), fileSize: json.utf8.count, limits: limits)
            guard let content = parsed.content, let pretty = parsed.prettyText else {
                return rawResult(parsed.diagnostics.first ?? .init(code: .parseError, message: "Invalid ZON value. Raw remains available."))
            }
            return .init(rawBytes: raw, rawText: analysis.text, rawIsComplete: true,
                         content: content, prettyText: pretty, diagnostics: [])
        } catch is CancellationError {
            throw CancellationError()
        } catch ZONFailure.limit {
            return rawResult(.init(code: .limitExceeded, message: "ZON processing limit reached. Raw remains available."))
        } catch {
            return rawResult(.init(code: .parseError, message: "Invalid or unsupported ZON value. Raw remains available."))
        }
    }

    /// Parses a complete bounded JSON document and returns diagnostics with the original prefix on failure.
    /// Inspects supplied bytes only; clipped input and parser failures always retain a Raw fallback.
    public static func inspect(bytes: Data, fileSize: Int? = nil,
                               limits: JSONInspectionLimits = .init(),
                               syntax: JSONSyntax = .strict) throws -> JSONInspectionResult {
        try Task.checkCancellation()
        let size = fileSize ?? bytes.count
        let raw = Data(bytes.prefix(limits.maximumBytes))
        let complete = size >= 0 && size == bytes.count && raw.count == bytes.count
        let analysis = TextAnalysis.analyze(bytes: raw, fileSize: raw.count, maximumBytes: limits.maximumBytes)
        let text: String? = analysis.isBinary ? nil : analysis.text
        /// Preserves the bounded Raw payload alongside every semantic parse outcome.
        func result(_ diagnostics: [JSONDiagnostic], content: JSONValue? = nil,
                    pretty: String? = nil) -> JSONInspectionResult {
            .init(rawBytes: raw, rawText: text, rawIsComplete: complete,
                  content: content, prettyText: pretty, diagnostics: diagnostics)
        }
        guard complete else {
            // Never parse a clipped JSON document as if it were a complete value.
            var diagnostics: [JSONDiagnostic] = []
            if bytes.count > limits.maximumBytes || size > limits.maximumBytes {
                diagnostics.append(.init(code: .limitExceeded, message: "JSON input limit reached. Raw contains the retained prefix."))
            }
            diagnostics.append(.init(code: .truncated, message: "JSON input is incomplete. Raw remains available."))
            return result(diagnostics)
        }
        guard let text, analysis.encoding != .windows1252 else {
            return result([.init(code: .parseError, message: "JSON requires valid Unicode text. Raw remains available.")])
        }
        do {
            try Task.checkCancellation()
            // The custom parser enforces depth/value/work bounds before constructing the semantic tree.
            let parserBytes: [UInt8]
            switch syntax {
            case .strict:
                parserBytes = Array(text.utf8)
            case .jsonc, .json5:
                guard let normalized = try JSONRelaxedNormalizer.normalize(Array(text.utf8), json5: syntax == .json5) else {
                    return result([.init(code: .parseError, message: "Invalid JSON-family syntax. Raw remains available.")])
                }
                guard normalized.count <= limits.maximumBytes else {
                    return result([.init(code: .limitExceeded, message: "JSON normalization limit reached. Raw remains available.")])
                }
                parserBytes = normalized
            }
            var parser = JSONParser(bytes: parserBytes, limits: limits)
            let content = try parser.parse()
            var writer = JSONPrettyWriter(limits: limits)
            try writer.write(content, depth: 0)
            try Task.checkCancellation()
            return result([], content: content, pretty: writer.output)
        } catch is CancellationError {
            throw CancellationError()
        } catch JSONProcessingFailure.limit {
            return result([.init(code: .limitExceeded, message: "JSON processing limit reached. Raw remains available.")])
        } catch {
            return result([.init(code: .parseError, message: "Invalid JSON. Raw remains available.")])
        }
    }
}

/// Internal parser outcomes used to distinguish malformed input from exhausted budgets.
private enum JSONProcessingFailure: Error { case syntax, limit }

// MARK: - Bounded recursive descent

/// Parses strict JSON bytes with explicit depth, value-count, and work budgets.
private struct JSONParser {
    let bytes: [UInt8]
    let limits: JSONInspectionLimits
    private var position = 0
    private var values = 0
    private var work = 0

    /// Creates a parser over bounded UTF-8 bytes and a callback for budget checkpoints.
    init(bytes: [UInt8], limits: JSONInspectionLimits) {
        self.bytes = bytes
        self.limits = limits
    }

    /// Parses one complete root value and rejects trailing non-whitespace bytes.
    mutating func parse() throws -> JSONValue {
        // Require the root value to consume the entire input; trailing tokens are not silently ignored.
        let value = try parseValue(depth: 0)
        try skipWhitespace()
        guard position == bytes.count else { throw JSONProcessingFailure.syntax }
        return value
    }

    /// Amortizes cancellation checks while ensuring a long token cannot avoid them.
    private mutating func checkpoint() throws {
        // Amortize cancellation checks while bounding parser work between checkpoints.
        work += 1
        if work % 256 == 0 { try Task.checkCancellation() }
    }

    /// Consumes only JSON's four permitted whitespace bytes, checking the work budget as it advances.
    private mutating func skipWhitespace() throws {
        while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) {
            position += 1
            try checkpoint()
        }
    }

    /// Advances exactly one byte only when the expected structural token is present.
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    /// Parses one JSON value while applying depth and total-value limits before allocation grows.
    private mutating func parseValue(depth: Int) throws -> JSONValue {
        try checkpoint()
        try skipWhitespace()
        values += 1
        guard values <= limits.maximumValues else { throw JSONProcessingFailure.limit }
        guard position < bytes.count else { throw JSONProcessingFailure.syntax }
        switch bytes[position] {
        case 0x7B, 0x5B:
            guard depth < limits.maximumDepth else { throw JSONProcessingFailure.limit }
            if consume(0x7B) {
                var members: [JSONMember] = []
                try skipWhitespace()
                if consume(0x7D) { return .object(members) }
                repeat {
                    try skipWhitespace()
                    let key = try parseString()
                    try skipWhitespace()
                    guard consume(0x3A) else { throw JSONProcessingFailure.syntax }
                    members.append(.init(key: key, value: try parseValue(depth: depth + 1)))
                    try skipWhitespace()
                    if consume(0x7D) { return .object(members) }
                    guard consume(0x2C) else { throw JSONProcessingFailure.syntax }
                } while true
            }
            position += 1
            var elements: [JSONValue] = []
            try skipWhitespace()
            if consume(0x5D) { return .array(elements) }
            repeat {
                elements.append(try parseValue(depth: depth + 1))
                try skipWhitespace()
                if consume(0x5D) { return .array(elements) }
                guard consume(0x2C) else { throw JSONProcessingFailure.syntax }
            } while true
        case 0x22: return .string(try parseString())
        case 0x74: try literal("true"); return .boolean(true)
        case 0x66: try literal("false"); return .boolean(false)
        case 0x6E: try literal("null"); return .null
        case 0x2D, 0x30...0x39: return .number(try parseNumber())
        default: throw JSONProcessingFailure.syntax
        }
    }

    /// Matches a fixed JSON keyword at the current byte offset; the caller checks token boundaries.
    private mutating func literal(_ value: String) throws {
        // Literals must match at the current byte offset; parseValue handles token boundaries afterward.
        let token = Array(value.utf8)
        guard bytes[position...].starts(with: token) else { throw JSONProcessingFailure.syntax }
        position += token.count
    }

    /// Validates string control bytes and delegates bounded escape decoding to JSONDecoder.
    private mutating func parseString() throws -> String {
        let start = position
        guard consume(0x22) else { throw JSONProcessingFailure.syntax }
        while position < bytes.count {
            try checkpoint()
            let byte = bytes[position]
            position += 1
            if byte == 0x22 {
                // Foundation decodes only this already-bounded token, including escaped surrogate pairs.
                let value = try JSONDecoder().decode(String.self, from: Data(bytes[start..<position]))
                try Task.checkCancellation()
                return value
            }
            guard byte >= 0x20 else { throw JSONProcessingFailure.syntax }
            if byte == 0x5C {
                guard position < bytes.count else { throw JSONProcessingFailure.syntax }
                position += 1
            }
        }
        throw JSONProcessingFailure.syntax
    }

    /// Validates JSON number grammar before retaining its original token spelling.
    private mutating func parseNumber() throws -> String {
        // Enforce JSON's no-leading-zero and required fraction/exponent digit rules before retaining the token.
        let start = position
        _ = consume(0x2D)
        if !consume(0x30) {
            guard position < bytes.count, (0x31...0x39).contains(bytes[position]) else { throw JSONProcessingFailure.syntax }
            try digits()
        }
        if consume(0x2E) {
            let before = position
            try digits()
            guard position > before else { throw JSONProcessingFailure.syntax }
        }
        if consume(0x65) || consume(0x45) {
            if !consume(0x2B) { _ = consume(0x2D) }
            let before = position
            try digits()
            guard position > before else { throw JSONProcessingFailure.syntax }
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// Consumes decimal digits while checking cancellation within long numbers.
    private mutating func digits() throws {
        // Check the time/cancellation budget during long numeric tokens, not only between values.
        while position < bytes.count, (0x30...0x39).contains(bytes[position]) {
            position += 1
            try checkpoint()
        }
    }
}

// MARK: - Bounded formatting

/// Serializes a structured JSON value with bounded depth, output size, and cancellation checks.
private struct JSONPrettyWriter {
    let limits: JSONInspectionLimits
    private(set) var output = ""
    private var byteCount = 0
    private var work = 0

    /// Creates a JSON value builder constrained by the supplied inspection limits.
    init(limits: JSONInspectionLimits) {
        self.limits = limits
    }

    /// Adds formatted text only when its UTF-8 size remains within the configured output cap.
    private mutating func append(_ text: String) throws {
        // Count UTF-8 output bytes before appending so pretty printing cannot exceed its output ceiling.
        let count = text.utf8.count
        guard count <= limits.maximumOutputBytes - byteCount else { throw JSONProcessingFailure.limit }
        output += text
        byteCount += count
        work += 1
        if work % 256 == 0 { try Task.checkCancellation() }
    }

    /// Escapes JSON control characters and quotes without changing ordinary Unicode scalars.
    private mutating func quoted(_ string: String) throws {
        // Escape control characters explicitly while preserving ordinary Unicode scalars.
        try append("\"")
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: try append("\\\"")
            case 0x5C: try append("\\\\")
            case 0x08: try append("\\b")
            case 0x0C: try append("\\f")
            case 0x0A: try append("\\n")
            case 0x0D: try append("\\r")
            case 0x09: try append("\\t")
            case 0..<0x20: try append(String(format: "\\u%04X", scalar.value))
            default: try append(String(scalar))
            }
        }
        try append("\"")
    }

    /// Serializes the parsed tree with bounded output and periodic cancellation checks.
    mutating func write(_ value: JSONValue, depth: Int) throws {
        // The inspector checked nesting depth during parse; output bytes and work are bounded again here.
        switch value {
        case .object(let members):
            try append("{")
            for (index, member) in members.enumerated() {
                try append(index == 0 ? "\n" : ",\n")
                try append(String(repeating: "  ", count: depth + 1))
                try quoted(member.key)
                try append(": ")
                try write(member.value, depth: depth + 1)
            }
            if !members.isEmpty { try append("\n" + String(repeating: "  ", count: depth)) }
            try append("}")
        case .array(let elements):
            try append("[")
            for (index, element) in elements.enumerated() {
                try append(index == 0 ? "\n" : ",\n")
                try append(String(repeating: "  ", count: depth + 1))
                try write(element, depth: depth + 1)
            }
            if !elements.isEmpty { try append("\n" + String(repeating: "  ", count: depth)) }
            try append("]")
        case .string(let value): try quoted(value)
        case .number(let value): try append(value)
        case .boolean(let value): try append(value ? "true" : "false")
        case .null: try append("null")
        }
    }
}

/// Internal Zig Object Notation translation outcomes for invalid or unsupported constructs.
private enum ZONFailure: Error { case syntax, limit, unsupported }

/// Parses bounded ZON literals and emits a JSON-compatible value without executing Zig code.
private struct ZONJSONTranslator {
    let bytes: [UInt8]
    let limits: JSONInspectionLimits
    let checkpoint: () throws -> Void
    var index = 0
    var values = 0
    var outputByteCount = 0
    var output = ""

    /// Creates a JSON parser from source text and a budget-checkpoint callback.
    init(source: String, limits: JSONInspectionLimits, checkpoint: @escaping () throws -> Void) {
        self.bytes = Array(source.utf8)
        self.limits = limits
        self.checkpoint = checkpoint
    }

    /// Translates one complete ZON value and rejects any trailing non-whitespace source.
    mutating func translate() throws -> String {
        try whitespace()
        try value(depth: 0)
        try whitespace()
        guard index == bytes.count else { throw ZONFailure.syntax }
        return output
    }

    /// Parses one bounded value and appends its JSON representation to the output buffer.
    private mutating func value(depth: Int) throws {
        try checkpoint()
        guard depth <= limits.maximumDepth else { throw ZONFailure.limit }
        values += 1
        guard values <= limits.maximumValues else { throw ZONFailure.limit }
        try whitespace()
        guard index < bytes.count else { throw ZONFailure.syntax }
        if take(0x2E) {
            if take(0x7B) { try structure(depth: depth + 1); return }
            let name = try identifier()
            try quoted(name)
            return
        }
        if peek == 0x22 { try quoted(try string()); return }
        if peek == 0x74, takeWord("true") { try append("true"); return }
        if peek == 0x66, takeWord("false") { try append("false"); return }
        if peek == 0x6E, takeWord("null") { try append("null"); return }
        try number()
    }

    /// Parses a ZON object or array body, enforcing nesting and output limits.
    private mutating func structure(depth: Int) throws {
        guard depth <= limits.maximumDepth else { throw ZONFailure.limit }
        try whitespace()
        if take(0x7D) { try append("{}"); return }
        let isObject = fieldAssignmentAhead()
        try append(isObject ? "{" : "[")
        var count = 0
        while true {
            try whitespace()
            if count > 0 { try append(",") }
            if isObject {
                guard take(0x2E), !take(0x7B) else { throw ZONFailure.syntax }
                let key = try identifier()
                try whitespace()
                guard take(0x3D) else { throw ZONFailure.syntax }
                try quoted(key)
                try append(":")
            } else if fieldAssignmentAhead() {
                throw ZONFailure.syntax
            }
            try value(depth: depth)
            count += 1
            try whitespace()
            if take(0x7D) { break }
            guard take(0x2C) else { throw ZONFailure.syntax }
            try whitespace()
            if take(0x7D) { break }
        }
        try append(isObject ? "}" : "]")
    }

    /// Reads a numeric token and converts supported hexadecimal integer literals to decimal.
    private mutating func number() throws {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x7D].contains(bytes[index]) {
            if index % 256 == 0 { try checkpoint() }
            index += 1
        }
        guard start < index, let token = String(bytes: bytes[start..<index], encoding: .utf8) else { throw ZONFailure.syntax }
        let negative = token.hasPrefix("-")
        let magnitude = negative ? String(token.dropFirst()) : token
        if magnitude.hasPrefix("0x"), let integer = UInt64(magnitude.dropFirst(2), radix: 16) {
            try append((negative ? "-" : "") + String(integer))
        } else {
            try append(token)
        }
    }

    /// Decodes supported quoted-string escapes without evaluating Zig expressions.
    private mutating func string() throws -> String {
        guard take(0x22) else { throw ZONFailure.syntax }
        var result = ""
        var literal: [UInt8] = []
        while index < bytes.count {
            if index % 256 == 0 { try checkpoint() }
            let byte = bytes[index]
            index += 1
            if byte == 0x22 {
                guard let tail = String(bytes: literal, encoding: .utf8) else { throw ZONFailure.syntax }
                result += tail
                return result
            }
            guard byte == 0x5C else { literal.append(byte); continue }
            guard let escaped = next() else { throw ZONFailure.syntax }
            guard let tail = String(bytes: literal, encoding: .utf8) else { throw ZONFailure.syntax }
            result += tail
            literal.removeAll(keepingCapacity: true)
            switch escaped {
            case 0x22: result.append("\"")
            case 0x5C: result.append("\\")
            case 0x6E: result.append("\n")
            case 0x72: result.append("\r")
            case 0x74: result.append("\t")
            case 0x30: result.append("\0")
            case 0x78:
                guard let high = next(), let low = next(), let scalar = UInt8(String(bytes: [high, low], encoding: .utf8) ?? "", radix: 16) else { throw ZONFailure.syntax }
                result.append(Character(UnicodeScalar(scalar)))
            case 0x75:
                guard take(0x7B) else { throw ZONFailure.syntax }
                let start = index
                while index < bytes.count && bytes[index] != 0x7D { index += 1 }
                guard index < bytes.count, let value = UInt32(String(bytes: bytes[start..<index], encoding: .utf8) ?? "", radix: 16),
                      let scalar = UnicodeScalar(value) else { throw ZONFailure.syntax }
                index += 1
                result.append(Character(scalar))
            default: throw ZONFailure.syntax
            }
        }
        throw ZONFailure.syntax
    }

    /// Appends a JSON-escaped string literal using Foundation's string serializer.
    private mutating func quoted(_ string: String) throws {
        let data = try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let encoded = String(data: data, encoding: .utf8) else { throw ZONFailure.syntax }
        try append(encoded)
    }

    /// Reads an ASCII identifier used by ZON field names and enum-like values.
    private mutating func identifier() throws -> String {
        let start = index
        guard let first = peek, isIdentifierStart(first) else { throw ZONFailure.syntax }
        index += 1
        while let byte = peek, isIdentifierContinue(byte) { index += 1 }
        guard let result = String(bytes: bytes[start..<index], encoding: .utf8) else { throw ZONFailure.syntax }
        return result
    }

    /// Detects whether the next structure member begins with a `.field =` assignment.
    private func fieldAssignmentAhead() -> Bool {
        var cursor = index
        while cursor < bytes.count && [0x20, 0x09, 0x0A, 0x0D].contains(bytes[cursor]) { cursor += 1 }
        guard cursor < bytes.count, bytes[cursor] == 0x2E else { return false }
        cursor += 1
        guard cursor < bytes.count, isIdentifierStart(bytes[cursor]) else { return false }
        cursor += 1
        while cursor < bytes.count && isIdentifierContinue(bytes[cursor]) { cursor += 1 }
        while cursor < bytes.count && [0x20, 0x09, 0x0A, 0x0D].contains(bytes[cursor]) { cursor += 1 }
        return cursor < bytes.count && bytes[cursor] == 0x3D
    }

    /// Skips JSON whitespace and ZON line comments, then checks cancellation.
    private mutating func whitespace() throws {
        while index < bytes.count {
            if [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1; continue }
            if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                index += 2
                while index < bytes.count && bytes[index] != 0x0A && bytes[index] != 0x0D { index += 1 }
                continue
            }
            break
        }
        try checkpoint()
    }

    /// Appends output only when translated JSON remains within the configured byte bound.
    private mutating func append(_ value: String) throws {
        let byteCount = value.utf8.count
        guard byteCount <= limits.maximumOutputBytes - outputByteCount else { throw ZONFailure.limit }
        output += value
        outputByteCount += byteCount
    }

    /// Consumes a keyword only when its following byte cannot continue an identifier.
    private mutating func takeWord(_ word: String) -> Bool {
        let token = Array(word.utf8)
        guard index + token.count <= bytes.count,
              Array(bytes[index..<(index + token.count)]) == token,
              index + token.count == bytes.count || !isIdentifierContinue(bytes[index + token.count]) else { return false }
        index += token.count
        return true
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
    /// Consumes one expected byte and leaves the cursor unchanged when it does not match.
    private mutating func take(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        index += 1
        return true
    }
    /// Returns the current byte and advances the cursor by one position.
    private mutating func next() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }
    /// Checks whether a byte can start the translator's ASCII identifier subset.
    private func isIdentifierStart(_ byte: UInt8) -> Bool { byte == 0x5F || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
    /// Checks whether a byte can continue an ASCII identifier after its first character.
    private func isIdentifierContinue(_ byte: UInt8) -> Bool { isIdentifierStart(byte) || (0x30...0x39).contains(byte) }
}
