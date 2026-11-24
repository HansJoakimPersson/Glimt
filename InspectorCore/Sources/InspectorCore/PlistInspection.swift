import CoreFoundation
import Foundation

/// Property-list values stay typed; binary data is summarized by the renderer, not dumped into Tree.
public indirect enum PlistValue: Equatable, Sendable {
    case dictionary([PlistMember])
    case array([PlistValue])
    case string(String)
    case integer(String)
    case real(Double)
    case boolean(Bool)
    case date(Date)
    case data(Data)
}

/// A dictionary key and its typed property-list value.
public struct PlistMember: Equatable, Sendable {
    public let key: String
    public let value: PlistValue
}

/// Parsed property-list content and pretty output alongside the original bounded bytes.
public struct PlistInspectionResult: Equatable, Sendable {
    public let rawBytes: Data
    public let rawText: String?
    public let rawIsComplete: Bool
    public let content: PlistValue?
    public let prettyText: String?
    public let diagnostics: [InspectionDiagnostic]
    public let isBinary: Bool
}

/// Native plist parsing, with bounded XML/OpenStep/binary shape checks before Foundation constructs values.
public enum PlistInspector {
    /// Uses a small, non-resolving XML probe only to inform routing; full limits apply in `inspect`.
    public static func looksLikePropertyList(bytes: Data) -> Bool {
        if bytes.starts(with: Data("bplist00".utf8)) { return true }
        let prefix = Data(bytes.prefix(65_536))
        let analysis = TextAnalysis.analyze(bytes: prefix, fileSize: bytes.count, maximumBytes: 65_536)
        guard !analysis.isBinary, !analysis.text.contains("<!ENTITY") else { return false }
        let parser = XMLParser(data: prefix)
        let probe = PlistRootProbe()
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = probe
        _ = parser.parse()
        return probe.isPlist
    }

    /// Converts the already-budgeted typed model back to Foundation values for XML pretty output.
    private static func propertyListObject(_ value: PlistValue, checkpoint: () throws -> Void) throws -> Any {
        try checkpoint()
        switch value {
        case .dictionary(let members):
            var result: [String: Any] = [:]
            for member in members { result[member.key] = try propertyListObject(member.value, checkpoint: checkpoint) }
            return result
        case .array(let values): return try values.map { try propertyListObject($0, checkpoint: checkpoint) }
        case .string(let value): return value
        case .integer(let value):
            if let signed = Int64(value) { return NSNumber(value: signed) }
            if let unsigned = UInt64(value) { return NSNumber(value: unsigned) }
            throw PlistFailure.unsupported
        case .real(let value): return NSNumber(value: value)
        case .boolean(let value): return NSNumber(value: value)
        case .date(let value): return value
        case .data(let value): return value
        }
    }

    /// Preflights XML or binary structure before Foundation constructs objects, then budgets normalized output.
    public static func inspect(bytes: Data, fileSize: Int? = nil,
                               limits: StructuredInspectionLimits = .init()) throws -> PlistInspectionResult {
        try Task.checkCancellation()
        let checkpoint = { try Task.checkCancellation() }
        let raw = Data(bytes.prefix(limits.maximumBytes))
        let size = fileSize ?? bytes.count
        let complete = size >= 0 && size == bytes.count && raw.count == bytes.count
        let markedBinary = bytes.starts(with: Data("bplist00".utf8))
        let analysis = TextAnalysis.analyze(bytes: raw, fileSize: raw.count, maximumBytes: limits.maximumBytes)
        let binary = markedBinary || analysis.isBinary
        let text = binary ? nil : Optional(analysis.text)
        /// Returns the retained Raw representation with diagnostics when semantic conversion fails.
        func result(_ diagnostics: [InspectionDiagnostic], content: PlistValue? = nil,
                    pretty: String? = nil) -> PlistInspectionResult {
            .init(rawBytes: raw, rawText: text, rawIsComplete: complete, content: content,
                  prettyText: pretty, diagnostics: diagnostics, isBinary: binary)
        }
        guard complete else {
            var diagnostics: [InspectionDiagnostic] = []
            if size > limits.maximumBytes || bytes.count > limits.maximumBytes {
                diagnostics.append(.init(code: .limitExceeded, message: "Property list input limit reached. Raw contains the retained prefix."))
            }
            diagnostics.append(.init(code: .truncated, message: "Property list input is incomplete. Raw remains available."))
            return result(diagnostics)
        }
        do {
            try checkpoint()
            let parsingBytes: Data
            var sourceFormat: PropertyListSerialization.PropertyListFormat
            if markedBinary {
                // Validate object-table offsets and declared sizes before Foundation allocates plist objects.
                try PlistBinaryPreflight(bytes: raw, limits: limits, checkpoint: checkpoint).validate()
                parsingBytes = raw
                sourceFormat = .binary
            } else {
                guard let text, analysis.encoding != .windows1252 else { throw PlistFailure.syntax }
                if text.drop(while: { $0.isWhitespace }).first == "<" {
                    // Validate XML structure and declarations before invoking the native property-list decoder.
                    parsingBytes = try PlistXMLPreflight.validate(bytes: raw, text: text, encoding: analysis.encoding,
                                                                limits: limits, checkpoint: checkpoint)
                    sourceFormat = .xml
                } else {
                    // .strings files use Apple's legacy OpenStep plist syntax; bound nesting and tokens first.
                    try OpenStepPlistPreflight(bytes: raw, limits: limits, checkpoint: checkpoint).validate()
                    parsingBytes = raw
                    sourceFormat = .openStep
                }
            }
            try checkpoint()
            // Native conversion runs only after the bounded shape preflight has accepted the input.
            let object = try PropertyListSerialization.propertyList(from: parsingBytes, options: [], format: &sourceFormat)
            try checkpoint()
            var budget = PlistValueBudget(limits: limits, checkpoint: checkpoint)
            let content = try budget.normalize(object, depth: 0)
            guard !budget.hasFractionalDates else {
                return result([.init(code: .unsupported, message: "Lossless XML Pretty is unavailable for fractional dates. Tree and Raw remain available.")], content: content)
            }
            // The graph was checked before parsing; normalized values were checked again above.
            let prettyBytes = try PropertyListSerialization.data(fromPropertyList: propertyListObject(content, checkpoint: checkpoint), format: .xml, options: 0)
            try checkpoint()
            guard prettyBytes.count <= limits.maximumOutputBytes,
                  let pretty = String(data: prettyBytes, encoding: .utf8) else { throw PlistFailure.limit }
            return result([], content: content, pretty: pretty)
        } catch is CancellationError { throw CancellationError() }
        catch PlistFailure.limit {
            return result([.init(code: .limitExceeded, message: "Property list processing limit reached. Raw remains available.")])
        } catch PlistFailure.unsupported {
            return result([.init(code: .unsupported, message: "Unsupported property list structure. Raw remains available.")])
        } catch {
            return result([.init(code: .parseError, message: "Invalid property list. Raw remains available.")])
        }
    }
}

private enum PlistFailure: Error { case syntax, limit, unsupported }

/// Bounds the legacy OpenStep strings grammar before Foundation allocates its object graph.
private struct OpenStepPlistPreflight {
    let bytes: Data
    let limits: StructuredInspectionLimits
    let checkpoint: () throws -> Void

    /// Rejects property-list constructs that violate the configured structural limits.
    func validate() throws {
        let input = Array(bytes)
        var index = 0
        var depth = 0
        var values = 0
        var quoted = false
        var escaped = false
        var blockComment = false
        var lineComment = false

        while index < input.count {
            if index % 256 == 0 { try checkpoint() }
            let byte = input[index]

            if lineComment {
                if byte == 0x0A || byte == 0x0D { lineComment = false }
                index += 1
                continue
            }
            if blockComment {
                if byte == 0x2A, index + 1 < input.count, input[index + 1] == 0x2F {
                    blockComment = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if quoted {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { quoted = false }
                index += 1
                continue
            }

            if byte == 0x2F, index + 1 < input.count {
                if input[index + 1] == 0x2F { lineComment = true; index += 2; continue }
                if input[index + 1] == 0x2A { blockComment = true; index += 2; continue }
            }
            if byte == 0x23 { lineComment = true; index += 1; continue }
            if byte == 0x22 { quoted = true; values += 1; index += 1; continue }
            switch byte {
            case 0x7B, 0x28:
                depth += 1
                values += 1
                guard depth <= limits.maximumDepth else { throw PlistFailure.limit }
            case 0x7D, 0x29:
                depth -= 1
                guard depth >= 0 else { throw PlistFailure.syntax }
            case 0x3B, 0x2C, 0x3D:
                values += 1
            default:
                if ![0x20, 0x09, 0x0A, 0x0D].contains(byte),
                   index == 0 || [0x20, 0x09, 0x0A, 0x0D, 0x3B, 0x2C, 0x3D, 0x7B, 0x28].contains(input[index - 1]) {
                    values += 1
                }
            }
            guard values <= limits.maximumValues else { throw PlistFailure.limit }
            index += 1
        }

        guard !quoted, !escaped, !blockComment, depth == 0 else { throw PlistFailure.syntax }
        guard Self.hasValidRoot(input) else { throw PlistFailure.syntax }
    }

    private static func hasValidRoot(_ input: [UInt8]) -> Bool {
        var index = 0
        while index < input.count {
            if [0x20, 0x09, 0x0A, 0x0D].contains(input[index]) { index += 1; continue }
            if input[index] == 0x23 || (input[index] == 0x2F && index + 1 < input.count && input[index + 1] == 0x2F) {
                while index < input.count && input[index] != 0x0A && input[index] != 0x0D { index += 1 }
                continue
            }
            if input[index] == 0x2F && index + 1 < input.count && input[index + 1] == 0x2A {
                index += 2
                while index + 1 < input.count && !(input[index] == 0x2A && input[index + 1] == 0x2F) { index += 1 }
                guard index + 1 < input.count else { return false }
                index += 2
                continue
            }
            return input[index] == 0x7B || input[index] == 0x22 || isWordByte(input[index])
        }
        return false
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
    }
}

private struct PlistValueBudget {
    let limits: StructuredInspectionLimits
    let checkpoint: () throws -> Void
    var used = 0
    var estimatedOutput = 256
    var hasFractionalDates = false

    /// Converts native values into the typed tree while accounting for depth, entries and escaped output size.
    mutating func normalize(_ object: Any, depth: Int) throws -> PlistValue {
        try checkpoint()
        try consume()
        try reserveOutput(128 + depth * 4)
        if let string = object as? String { try reserveEscaped(string); return .string(string) }
        if let data = object as? Data {
            try reserveOutput(data.count * 2)
            return .data(data)
        }
        if let date = object as? Date {
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else { throw PlistFailure.unsupported }
            hasFractionalDates = hasFractionalDates || seconds.rounded(.towardZero) != seconds
            return .date(date)
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            let type = String(cString: number.objCType)
            if type == "f" || type == "d" { return .real(number.doubleValue) }
            return .integer(number.stringValue)
        }
        if let values = object as? [Any] {
            guard depth < limits.maximumDepth else { throw PlistFailure.limit }
            return .array(try values.map { try normalize($0, depth: depth + 1) })
        }
        if let values = object as? [String: Any] {
            guard depth < limits.maximumDepth else { throw PlistFailure.limit }
            var members: [PlistMember] = []
            for key in values.keys.sorted() {
                try consume() // Dictionary keys count toward the entry budget too.
                try reserveOutput(128 + depth * 4)
                try reserveEscaped(key)
                guard let value = values[key] else { throw PlistFailure.syntax }
                members.append(.init(key: key, value: try normalize(value, depth: depth + 1)))
            }
            return .dictionary(members)
        }
        throw PlistFailure.unsupported
    }

    /// Reserves estimated serialized bytes before normalization grows the plist tree.
    private mutating func reserveOutput(_ count: Int) throws {
        guard count <= limits.maximumOutputBytes - estimatedOutput else { throw PlistFailure.limit }
        estimatedOutput += count
    }

    /// Accounts for XML escaping expansion in untrusted string and dictionary-key content.
    private mutating func reserveEscaped(_ string: String) throws {
        var checked = 0
        for scalar in string.unicodeScalars {
            checked += 1
            if checked % 256 == 0 { try checkpoint() }
            let count: Int
            switch scalar.value {
            case 38: count = 5
            case 60, 62: count = 4
            case 34, 39: count = 6
            default: count = scalar.utf8.count
            }
            try reserveOutput(count)
        }
    }

    /// Charges one semantic value or key against the structured entry limit.
    private mutating func consume() throws {
        guard used < limits.maximumValues else { throw PlistFailure.limit }
        used += 1
    }
}

private final class PlistRootProbe: NSObject, XMLParserDelegate {
    var isPlist = false
    /// Accepts only a plist root and aborts as soon as XML depth or node limits are exceeded.
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        isPlist = elementName == "plist"
        parser.abortParsing()
    }
    /// Stops root probing if an internal entity declaration is encountered.
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    /// Stops root probing if an external entity declaration is encountered.
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    /// Refuses external resolution even if parser defaults change.
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { parser.abortParsing(); return nil }
}

/// Only XML plist shape validation. DTDs are never resolved and are removed before plist parsing.
private final class PlistXMLPreflight: NSObject, XMLParserDelegate {
    let limits: StructuredInspectionLimits
    let checkpoint: () throws -> Void
    var failure: Error?
    var depth = 0
    var nodes = 0
    var textBytes = 0
    var rootSeen = false

    /// Creates a property-list XML delegate with node, depth, and time-budget checks.
    init(limits: StructuredInspectionLimits, checkpoint: @escaping () throws -> Void) {
        self.limits = limits
        self.checkpoint = checkpoint
    }

    /// Removes inert XML declarations after validating them and rejects prohibited plist XML structure.
    static func validate(bytes: Data, text: String, encoding: TextEncoding?, limits: StructuredInspectionLimits,
                         checkpoint: @escaping () throws -> Void) throws -> Data {
        // XML names are case-sensitive. Conservatively disallow declarations even inside comments.
        guard !text.contains("<!ENTITY") else { throw PlistFailure.unsupported }
        var cleaned = text
        var index = text.startIndex
        var removals: [Range<String.Index>] = []
        while index < text.endIndex {
            try checkpoint()
            if text[index].isWhitespace { index = text.index(after: index); continue }
            let tail = text[index...]
            if tail.hasPrefix("<!--") {
                guard let end = tail.range(of: "-->") else { throw PlistFailure.syntax }
                index = end.upperBound
            } else if tail.hasPrefix("<?") {
                guard let end = tail.range(of: "?>") else { throw PlistFailure.syntax }
                if tail.hasPrefix("<?xml") {
                    let declaration = String(text[index..<end.upperBound])
                    try validateEncoding(declaration, encoding: encoding, text: text)
                    removals.append(index..<end.upperBound)
                }
                index = end.upperBound
            } else if tail.hasPrefix("<!DOCTYPE") {
                guard let end = tail.firstIndex(of: ">") else { throw PlistFailure.syntax }
                let range = index..<text.index(after: end)
                let declaration = String(text[range])
                let pattern = #"^<!DOCTYPE\s+plist\s+PUBLIC\s+(["'])-//Apple//DTD PLIST 1\.0//EN\1\s+(["'])https?://www\.apple\.com/DTDs/PropertyList-1\.0\.dtd\2\s*>$"#
                guard declaration.range(of: pattern, options: .regularExpression) != nil else { throw PlistFailure.unsupported }
                removals.append(range)
                index = range.upperBound
            } else { break }
        }
        let delegate = PlistXMLPreflight(limits: limits, checkpoint: checkpoint)
        let parser = XMLParser(data: bytes)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        let valid = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard valid, delegate.rootSeen else { throw PlistFailure.syntax }
        for range in removals.reversed() { cleaned.removeSubrange(range) }
        return Data(cleaned.utf8)
    }

    /// Rejects XML declarations that disagree with the encoding already used for text decoding.
    private static func validateEncoding(_ declaration: String, encoding: TextEncoding?, text: String) throws {
        let pattern = #"encoding\s*=\s*(["'])([A-Za-z0-9._-]+)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: declaration, range: NSRange(declaration.startIndex..., in: declaration)),
              let range = Range(match.range(at: 2), in: declaration) else { return }
        let declared = declaration[range].lowercased()
        let compatible: Bool
        switch encoding {
        case .utf8, .utf8BOM: compatible = declared == "utf-8" || (declared == "us-ascii" && text.utf8.allSatisfy { $0 < 128 })
        case .utf16LittleEndian: compatible = declared == "utf-16" || declared == "utf-16le"
        case .utf16BigEndian: compatible = declared == "utf-16" || declared == "utf-16be"
        case .utf32LittleEndian: compatible = declared == "utf-32" || declared == "utf-32le"
        case .utf32BigEndian: compatible = declared == "utf-32" || declared == "utf-32be"
        default: compatible = false
        }
        guard compatible else { throw PlistFailure.unsupported }
    }

    /// Turns callback work or budget errors into a parser abort before more input is accepted.
    private func check(_ parser: XMLParser, _ work: () throws -> Void) {
        guard failure == nil else { return }
        do { try checkpoint(); try work() }
        catch { failure = error; parser.abortParsing() }
    }

    /// Enforces the plist root, XML nesting depth, and node count during SAX parsing.
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        check(parser) {
            if !rootSeen { guard elementName == "plist" else { throw PlistFailure.syntax }; rootSeen = true }
            depth += 1
            nodes += 1
            guard depth <= limits.maximumDepth + 1, nodes <= limits.maximumValues else { throw PlistFailure.limit }
        }
    }
    /// Balances the depth counter maintained by the matching start-element callback.
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    /// Accounts for XML text as it arrives so oversized values stop before native decoding.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        check(parser) {
            textBytes += string.utf8.count
            guard textBytes <= limits.maximumOutputBytes else { throw PlistFailure.limit }
        }
    }
    /// Counts comments as nodes so comment-heavy input cannot bypass the structural limit.
    func parser(_ parser: XMLParser, foundComment comment: String) {
        check(parser) { nodes += 1; guard nodes <= limits.maximumValues else { throw PlistFailure.limit } }
    }
    /// Rejects internal declarations even if XML pre-validation did not detect them.
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { failure = PlistFailure.unsupported; parser.abortParsing() }
    /// Rejects external declarations so the parser cannot resolve document-provided entities.
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { failure = PlistFailure.unsupported; parser.abortParsing() }
    /// Refuses external resolution even if parser configuration changes unexpectedly.
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { failure = PlistFailure.unsupported; parser.abortParsing(); return nil }
}

/// Validate bplist object references and expanded reachability before Foundation walks the graph.
private struct PlistBinaryPreflight {
    let bytes: Data
    let limits: StructuredInspectionLimits
    let checkpoint: () throws -> Void

    /// Validates trailer offsets and reachable object graph before Foundation walks binary plist data.
    func validate() throws {
        guard bytes.count >= 40 else { throw PlistFailure.syntax }
        let trailer = bytes.count - 32
        let offsetSize = Int(bytes[trailer + 6]), referenceSize = Int(bytes[trailer + 7])
        guard (1...8).contains(offsetSize), (1...8).contains(referenceSize) else { throw PlistFailure.syntax }
        let objectCount = try integer(trailer + 8, 8)
        let root = try integer(trailer + 16, 8)
        let offsetTable = try integer(trailer + 24, 8)
        guard objectCount > 0, objectCount <= limits.maximumValues else { throw PlistFailure.limit }
        guard root < objectCount, offsetTable >= 8, offsetTable <= trailer,
              objectCount <= (trailer - offsetTable) / offsetSize else { throw PlistFailure.syntax }
        var offsets: [Int] = []
        for id in 0..<objectCount {
            try checkpoint()
            let offset = try integer(offsetTable + id * offsetSize, offsetSize)
            guard offset >= 8, offset < offsetTable else { throw PlistFailure.syntax }
            offsets.append(offset)
        }
        var work: [(id: Int, depth: Int, exit: Bool)] = [(root, 0, false)]
        var active = Set<Int>()
        var pending = 1
        var visited = 0
        var expandedPayloadBytes = 0
        while let entry = work.popLast() {
            try checkpoint()
            if entry.exit { active.remove(entry.id); continue }
            pending -= 1
            visited += 1
            guard visited + pending <= limits.maximumValues else { throw PlistFailure.limit }
            guard active.insert(entry.id).inserted else { throw PlistFailure.syntax }
            let offset = offsets[entry.id]
            let marker = bytes[offset], kind = marker >> 4, info = Int(marker & 15)
            var payload = offset + 1
            /// Checks a payload's end against the object table before any indexed read.
            func checkedEnd(_ count: Int) throws {
                guard count >= 0, payload <= offsetTable, count <= offsetTable - payload else { throw PlistFailure.syntax }
            }
            /// Reads an inline or extended object length with overflow-safe bounds checks.
            func length() throws -> Int {
                if info < 15 { return info }
                guard payload < offsetTable, bytes[payload] >> 4 == 1 else { throw PlistFailure.syntax }
                let exponent = Int(bytes[payload] & 15)
                guard exponent <= 3 else { throw PlistFailure.limit }
                let size = 1 << exponent
                payload += 1
                guard size <= offsetTable - payload else { throw PlistFailure.syntax }
                let value = try integer(payload, size)
                payload += size
                return value
            }
            var references: [Int] = []
            switch kind {
            case 0:
                guard info == 8 || info == 9 else { throw PlistFailure.unsupported }
            case 1:
                guard info <= 4 else { throw PlistFailure.limit }
                try checkedEnd(1 << info)
            case 2:
                guard info == 2 || info == 3 else { throw PlistFailure.unsupported }
                try checkedEnd(1 << info)
            case 3:
                guard info == 3 else { throw PlistFailure.syntax }; try checkedEnd(8)
            case 4, 5, 6, 7:
                let count = try length()
                let width = kind == 6 ? 2 : 1
                guard count <= limits.maximumBytes / width else { throw PlistFailure.limit }
                try checkedEnd(count * width)
                guard count * width <= limits.maximumOutputBytes - expandedPayloadBytes else { throw PlistFailure.limit }
                expandedPayloadBytes += count * width
            case 10, 13:
                guard entry.depth < limits.maximumDepth else { throw PlistFailure.limit }
                let count = try length()
                let width = kind == 13 ? 2 : 1
                guard count <= limits.maximumValues / width else { throw PlistFailure.limit }
                let total = count * width
                guard total <= (offsetTable - payload) / referenceSize else { throw PlistFailure.syntax }
                pending += total
                guard visited + pending <= limits.maximumValues else { throw PlistFailure.limit }
                for index in 0..<total {
                    let id = try integer(payload + index * referenceSize, referenceSize)
                    guard id < objectCount else { throw PlistFailure.syntax }
                    references.append(id)
                }
            default: throw PlistFailure.unsupported
            }
            work.append((entry.id, entry.depth, true))
            for id in references.reversed() { work.append((id, entry.depth + 1, false)) }
        }
    }

    /// Reads a bounded big-endian integer and rejects values that do not fit the host index type.
    private func integer(_ start: Int, _ count: Int) throws -> Int {
        guard start >= 0, count > 0, count <= 8, start <= bytes.count, count <= bytes.count - start else { throw PlistFailure.syntax }
        var value: UInt64 = 0
        for byte in bytes[start..<(start + count)] { value = (value << 8) | UInt64(byte) }
        guard value <= UInt64(Int.max) else { throw PlistFailure.limit }
        return Int(value)
    }
}
