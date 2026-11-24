import Foundation

/// One XML attribute with its qualified source name and decoded value.
public struct XMLAttribute: Equatable, Sendable {
    public let name: String
    public let value: String
}

/// XML element with qualified name, attributes, and ordered child nodes.
public struct XMLElement: Equatable, Sendable {
    /// Qualified source name, retaining namespace prefixes. xmlns declarations remain attributes.
    public let name: String
    public let attributes: [XMLAttribute]
    public let children: [XMLNode]
}

/// Typed XML tree node that preserves elements, text, and comments separately.
public indirect enum XMLNode: Equatable, Sendable {
    case element(XMLElement)
    case text(String)
    case comment(String)
}

/// Parsed XML root and pretty output with the bounded original source and diagnostics.
public struct XMLInspectionResult: Equatable, Sendable {
    public let rawBytes: Data
    public let rawText: String?
    public let rawIsComplete: Bool
    public let root: XMLNode?
    public let prettyText: String?
    public let diagnostics: [InspectionDiagnostic]
    public let table: XMLTable?
    /// Optional geospatial projection. The parsed XML tree and exact source remain available.
    public let domainSummary: StructuredValue?

    init(rawBytes: Data, rawText: String?, rawIsComplete: Bool, root: XMLNode?, prettyText: String?,
         diagnostics: [InspectionDiagnostic], domainSummary: StructuredValue? = nil) {
        self.rawBytes = rawBytes
        self.rawText = rawText
        self.rawIsComplete = rawIsComplete
        self.root = root
        self.prettyText = prettyText
        self.diagnostics = diagnostics
        table = root.flatMap { XMLTable(root: $0) }
        self.domainSummary = domainSummary
    }
}

/// Tabular projection of repeated XML records; the original XML tree remains available separately.
public struct XMLTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]

    fileprivate init?(root: XMLNode) {
        func shouldStop() -> Bool { Task.isCancelled }
        guard case .element(let container) = root else { return nil }
        let elements = container.children.compactMap { node -> XMLElement? in
            guard case .element(let element) = node else { return nil }
            return element
        }
        var groups: [String: [XMLElement]] = [:]
        var orderedNames: [String] = []
        for element in elements {
            if shouldStop() { return nil }
            if groups[element.name] == nil { orderedNames.append(element.name) }
            groups[element.name, default: []].append(element)
        }
        guard let records = orderedNames.compactMap({ groups[$0] }).first(where: { $0.count > 1 }) else { return nil }

        var columns: [String] = []
        for record in records {
            if shouldStop() { return nil }
            for attribute in record.attributes {
                let key = "@\(attribute.name)"
                if !columns.contains(key), columns.count < 64 { columns.append(key) }
            }
            for child in record.children {
                guard case .element(let element) = child,
                      !columns.contains(element.name), columns.count < 64 else { continue }
                columns.append(element.name)
            }
        }
        guard !columns.isEmpty else { return nil }
        guard records.count <= 50_000 / columns.count else { return nil }
        headers = columns
        var projectedRows: [[String]] = []
        projectedRows.reserveCapacity(records.count)
        for record in records {
            if shouldStop() { return nil }
            projectedRows.append(columns.map { column in
                if column.first == "@" {
                    return record.attributes.first(where: { "@\($0.name)" == column })?.value ?? ""
                }
                guard let child = record.children.compactMap({ node -> XMLElement? in
                    guard case .element(let element) = node else { return nil }
                    return element
                }).first(where: { $0.name == column }) else { return "" }
                return child.children.compactMap { node -> String? in
                    guard case .text(let text) = node else { return nil }
                    return text
                }.joined()
            })
        }
        rows = projectedRows
    }
}

/// SAX parsing of supplied bytes only. DTDs/entities are rejected before native parsing.
public enum XMLInspector {
    /// Rejects incomplete input and dangerous declarations before building an XML tree with Foundation's SAX parser.
    public static func inspect(bytes: Data, fileSize: Int? = nil,
                               limits: StructuredInspectionLimits = .init()) throws -> XMLInspectionResult {
        try Task.checkCancellation()
        let size = fileSize ?? bytes.count
        let raw = Data(bytes.prefix(limits.maximumBytes))
        let complete = size >= 0 && size == bytes.count && raw.count == bytes.count
        let analysis = TextAnalysis.analyze(bytes: raw, fileSize: raw.count, maximumBytes: limits.maximumBytes)
        let text = analysis.isBinary ? nil : Optional(analysis.text)
        /// Keeps original bytes and text available across every parser failure path.
        func result(_ diagnostics: [InspectionDiagnostic], root: XMLNode? = nil, pretty: String? = nil) -> XMLInspectionResult {
            .init(rawBytes: raw, rawText: text, rawIsComplete: complete, root: root,
                  prettyText: pretty, diagnostics: diagnostics)
        }
        guard complete else {
            var diagnostics: [InspectionDiagnostic] = []
            if bytes.count > limits.maximumBytes || size > limits.maximumBytes {
                diagnostics.append(.init(code: .limitExceeded, message: "XML input limit reached. Raw contains the retained prefix."))
            }
            diagnostics.append(.init(code: .truncated, message: "XML input is incomplete. Raw remains available."))
            return result(diagnostics)
        }
        guard let text else { return result([.init(code: .parseError, message: "XML requires readable text. Original bytes remain available.")]) }
        let checkpoint = { try Task.checkCancellation() }
        do {
            try checkpoint()
            // Reject DTD/entity syntax before XMLParser sees the document; external resolution stays disabled below.
            try validateDeclaration(text, encoding: analysis.encoding)
            try rejectDTD(in: text, checkpoint: checkpoint)
            let builder = XMLTreeBuilder(limits: limits, checkpoint: checkpoint)
            let parser = XMLParser(data: raw)
            parser.shouldProcessNamespaces = false
            parser.shouldReportNamespacePrefixes = false
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            // The delegate enforces tree/output limits as SAX callbacks arrive instead of building an unbounded DOM.
            parser.delegate = builder
            let success = parser.parse()
            if let failure = builder.failure { throw failure }
            guard success, let root = builder.root else {
                return result([.init(code: .parseError, message: "Malformed XML · Line \(max(1, parser.lineNumber)), column \(max(1, parser.columnNumber)). Raw remains available.")])
            }
            try checkpoint()
            let pretty: String
            if builder.preserveRawPretty || requiresRawPretty(root) {
                guard text.utf8.count <= limits.maximumOutputBytes else { throw XMLFailure.limit }
                pretty = text
            } else {
                var writer = XMLPrettyWriter(limit: limits.maximumOutputBytes, checkpoint: checkpoint)
                try writer.write(root, depth: 0)
                pretty = writer.output
            }
            try checkpoint()
            return result([], root: root, pretty: pretty)
        } catch is CancellationError { throw CancellationError() }
        catch XMLFailure.limit { return result([.init(code: .limitExceeded, message: "XML processing limit reached. Raw remains available.")]) }
        catch XMLFailure.dtd { return result([.init(code: .unsupported, message: "XML DTDs and entity declarations are not resolved. Raw remains available.")]) }
        catch XMLFailure.encoding { return result([.init(code: .unsupported, message: "XML declaration encoding is incompatible with the text preview. Raw remains available.")]) }
        catch { return result([.init(code: .parseError, message: "Malformed XML. Raw remains available.")]) }
    }

    /// Accepts an XML declaration only when its stated encoding agrees with decoded source bytes.
    private static func validateDeclaration(_ text: String, encoding: TextEncoding?) throws {
        var declared: String?
        if text.hasPrefix("<?xml"), let end = text.range(of: "?>"),
           text.dropFirst(5).first?.isWhitespace == true {
            let declaration = text[..<end.lowerBound]
            if let key = declaration.range(of: "encoding") {
                var tail = declaration[key.upperBound...].drop(while: \.isWhitespace)
                guard tail.first == "=" else { return }
                tail = tail.dropFirst().drop(while: \.isWhitespace)
                guard let quote = tail.first, quote == "\"" || quote == "'" else { return }
                tail = tail.dropFirst()
                guard let close = tail.firstIndex(of: quote) else { return }
                declared = tail[..<close].uppercased().replacingOccurrences(of: "-", with: "")
            }
        }
        guard let declared else {
            if encoding == .windows1252 { throw XMLFailure.encoding }
            return
        }
        let allowed: Set<String>
        switch encoding {
        case .utf8, .utf8BOM: allowed = ["UTF8", "USASCII", "ASCII"]
        case .utf16LittleEndian: allowed = ["UTF16", "UTF16LE"]
        case .utf16BigEndian: allowed = ["UTF16", "UTF16BE"]
        case .utf32LittleEndian: allowed = ["UTF32", "UTF32LE"]
        case .utf32BigEndian: allowed = ["UTF32", "UTF32BE"]
        case .windows1252: allowed = ["WINDOWS1252", "CP1252"]
        case nil: allowed = []
        }
        guard allowed.contains(declared) else { throw XMLFailure.encoding }
    }

    /// A declaration guard, not an XML grammar: skip inert comments/CDATA/PIs before matching DTD keywords.
    private static func rejectDTD(in text: String, checkpoint: () throws -> Void) throws {
        // Scan bounded text while respecting comments/CDATA so only active declarations trigger rejection.
        let bytes = Array(text.utf8)
        let comment = Array("<!--".utf8), cdata = Array("<![CDATA[".utf8), pi = Array("<?".utf8)
        let doctype = Array("<!DOCTYPE".utf8), entity = Array("<!ENTITY".utf8)
        var index = 0
        /// Checks a token at an in-bounds byte offset without allocating a substring.
        func matches(_ token: [UInt8], at position: Int) -> Bool {
            position + token.count <= bytes.count && bytes[position..<(position + token.count)].elementsEqual(token)
        }
        /// Skips an inert XML region while still checking cancellation.
        func skip(_ terminator: [UInt8], from start: Int) throws -> Int {
            var position = start
            while position < bytes.count {
                if position % 256 == 0 { try checkpoint() }
                if matches(terminator, at: position) { return position + terminator.count }
                position += 1
            }
            return bytes.count
        }
        while index < bytes.count {
            if index % 256 == 0 { try checkpoint() }
            if matches(comment, at: index) { index = try skip(Array("-->".utf8), from: index + comment.count) }
            else if matches(cdata, at: index) { index = try skip(Array("]]>".utf8), from: index + cdata.count) }
            else if matches(pi, at: index) { index = try skip(Array("?>".utf8), from: index + pi.count) }
            else if matches(doctype, at: index) || matches(entity, at: index) { throw XMLFailure.dtd }
            else { index += 1 }
        }
    }

    /// Preserves mixed-content or `xml:space` subtrees where indentation would change document text.
    private static func requiresRawPretty(_ node: XMLNode) -> Bool {
        guard case .element(let element) = node else { return false }
        if element.attributes.contains(where: { $0.name == "xml:space" && $0.value == "preserve" }) { return true }
        let hasStructure = element.children.contains { if case .text = $0 { return false }; return true }
        let hasText = element.children.contains { if case .text(let text) = $0 { return !text.isEmpty }; return false }
        return (hasStructure && hasText) || element.children.contains(where: requiresRawPretty)
    }
}

private enum XMLFailure: Error { case limit, syntax, dtd, encoding }

private final class XMLFrame {
    let name: String
    let attributes: [XMLAttribute]
    var children: [XMLNode] = []
    var text = ""
    /// Creates an XML element with its qualified name and decoded attributes.
    init(name: String, attributes: [XMLAttribute]) { self.name = name; self.attributes = attributes }
    /// Moves buffered SAX text into the child list before structural content is appended.
    func flushText() {
        if !text.isEmpty { children.append(.text(text)); text = "" }
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    let limits: StructuredInspectionLimits
    let checkpoint: () throws -> Void
    var failure: Error?
    var root: XMLNode?
    var preserveRawPretty = false
    private var frames: [XMLFrame] = []
    private var count = 0
    private var textBytes = 0

    /// Creates a streaming XML delegate that enforces depth, node, and attribute limits.
    init(limits: StructuredInspectionLimits, checkpoint: @escaping () throws -> Void) {
        self.limits = limits
        self.checkpoint = checkpoint
    }

    /// Converts callback errors into a parser abort so no further nodes are appended after a limit/failure.
    private func perform(_ parser: XMLParser, _ action: () throws -> Void) {
        guard failure == nil else { return }
        do { try checkpoint(); try action() }
        catch { failure = error; parser.abortParsing() }
    }

    /// Reserves element and attribute slots against the configured structured-value limit.
    private func use(_ amount: Int) throws {
        guard amount <= limits.maximumValues - count else { throw XMLFailure.limit }
        count += amount
    }

    /// Accounts for decoded text bytes before appending them to the semantic tree.
    private func useText(_ text: String) throws {
        let bytes = text.utf8.count
        guard bytes <= limits.maximumOutputBytes - textBytes else { throw XMLFailure.limit }
        textBytes += bytes
    }

    /// Pushes one bounded element frame after accounting for its element and attribute budget.
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        perform(parser) {
            guard frames.count < limits.maximumDepth else { throw XMLFailure.limit }
            if frames.isEmpty, root != nil { throw XMLFailure.syntax }
            try use(1 + attributeDict.count)
            frames.last?.flushText()
            let attributes = attributeDict.keys.sorted().map { XMLAttribute(name: $0, value: attributeDict[$0] ?? "") }
            frames.append(XMLFrame(name: qName ?? elementName, attributes: attributes))
        }
    }

    /// Completes a balanced frame and attaches it to its parent or establishes the document root.
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        perform(parser) {
            guard let frame = frames.popLast(), frame.name == (qName ?? elementName) else { throw XMLFailure.syntax }
            frame.flushText()
            let node = XMLNode.element(.init(name: frame.name, attributes: frame.attributes, children: frame.children))
            if let parent = frames.last { parent.children.append(node) } else { root = node }
        }
    }

    /// Appends SAX character data while charging text and leaf-value budgets.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        perform(parser) {
            guard let frame = frames.last else { return }
            try useText(string)
            if frame.text.isEmpty && !string.isEmpty { try use(1) }
            frame.text += string
        }
    }

    /// Routes ignorable whitespace through the same bounded text accounting as other character data.
    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { self.parser(parser, foundCharacters: whitespaceString) }

    /// Accepts CDATA only as UTF-8 and aborts instead of silently replacing invalid bytes.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { failure = XMLFailure.syntax; parser.abortParsing(); return }
        self.parser(parser, foundCharacters: text)
    }

    /// Preserves comments and retains raw formatting for document-level comments.
    func parser(_ parser: XMLParser, foundComment comment: String) {
        perform(parser) {
            try use(1)
            try useText(comment)
            if let frame = frames.last { frame.flushText(); frame.children.append(.comment(comment)) }
            else { preserveRawPretty = true }
        }
    }

    /// Retains the original document when processing instructions could change under pretty output.
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        perform(parser) { preserveRawPretty = true }
    }

    /// Refuses external entity resolution even if a parser configuration changes unexpectedly.
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        failure = XMLFailure.dtd
        parser.abortParsing()
        return nil
    }

    /// Aborts if an internal entity declaration reaches the delegate despite pre-validation.
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { failure = XMLFailure.dtd; parser.abortParsing() }
    /// Aborts if an external entity declaration reaches the delegate despite parser hardening.
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { failure = XMLFailure.dtd; parser.abortParsing() }
}

private struct XMLPrettyWriter {
    let limit: Int
    let checkpoint: () throws -> Void
    var output = ""
    private var count = 0

    /// Creates a bounded source scanner that periodically checks the inspection budget.
    init(limit: Int, checkpoint: @escaping () throws -> Void) { self.limit = limit; self.checkpoint = checkpoint }

    /// Appends output only when its UTF-8 byte count fits the configured pretty-text cap.
    private mutating func append(_ value: String) throws {
        let bytes = value.utf8.count
        guard bytes <= limit - count else { throw XMLFailure.limit }
        count += bytes
        output += value
    }

    /// Emits an escaped pretty representation under a byte cap, preserving mixed content via the caller's raw fallback.
    mutating func write(_ node: XMLNode, depth: Int) throws {
        try checkpoint()
        switch node {
        case .text(let text): try append(escape(text, attribute: false))
        case .comment(let comment): try append("<!--" + comment + "-->")
        case .element(let element):
            try append("<" + element.name)
            for attribute in element.attributes { try append(" " + attribute.name + "=\"" + escape(attribute.value, attribute: true) + "\"") }
            guard !element.children.isEmpty else { try append("/>"); return }
            try append(">")
            let structural = element.children.contains { if case .text = $0 { return false }; return true }
            for child in element.children {
                if structural {
                    if case .text(let text) = child, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    try append("\n" + String(repeating: "  ", count: depth + 1))
                }
                try write(child, depth: depth + 1)
            }
            if structural { try append("\n" + String(repeating: "  ", count: depth)) }
            try append("</" + element.name + ">")
        }
    }

    /// Escapes markup text and applies the additional whitespace escapes required in attributes.
    private func escape(_ string: String, attribute: Bool) -> String {
        var value = string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            value = value.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\t", with: "&#x9;").replacingOccurrences(of: "\n", with: "&#xA;").replacingOccurrences(of: "\r", with: "&#xD;")
        } else { value = value.replacingOccurrences(of: "\r", with: "&#xD;") }
        return value
    }
}
