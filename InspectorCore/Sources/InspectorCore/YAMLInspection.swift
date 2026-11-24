import Foundation
import Yams
import CYaml

/// A bounded YAML stream, retaining original input independently of normalized documents.
public struct YAMLInspectionResult: Equatable, Sendable {
    public let rawBytes: Data
    public let rawText: String?
    public let rawIsComplete: Bool
    public let documents: [StructuredValue]?
    public let prettyText: String?
    public let diagnostics: [InspectionDiagnostic]
}

/// Consumes libyaml events iteratively so limits apply before recursive nodes or aliases expand.
public enum YAMLInspector {
    /// Converts libyaml events into a bounded semantic tree while retaining the source bytes verbatim.
    public static func inspect(bytes: Data, fileSize: Int? = nil,
                               limits: StructuredInspectionLimits = .init(),
                               maximumDocuments: Int = 64) throws -> YAMLInspectionResult {
        try Task.checkCancellation()
        let size = fileSize ?? bytes.count
        let raw = Data(bytes.prefix(limits.maximumBytes))
        let complete = size >= 0 && size == bytes.count && raw.count == bytes.count
        let analysis = TextAnalysis.analyze(bytes: raw, fileSize: raw.count, maximumBytes: limits.maximumBytes)
        let text = analysis.isBinary ? nil : Optional(analysis.text)
        /// Keeps the original bounded bytes available even when libyaml rejects the document.
        func result(_ diagnostics: [InspectionDiagnostic], documents: [StructuredValue]? = nil,
                    pretty: String? = nil) -> YAMLInspectionResult {
            .init(rawBytes: raw, rawText: text, rawIsComplete: complete, documents: documents,
                  prettyText: pretty, diagnostics: diagnostics)
        }
        guard complete else {
            var diagnostics: [InspectionDiagnostic] = []
            if bytes.count > limits.maximumBytes || size > limits.maximumBytes {
                diagnostics.append(.init(code: .limitExceeded, message: "YAML input limit reached. Raw contains the retained prefix."))
            }
            diagnostics.append(.init(code: .truncated, message: "YAML input is incomplete. Raw remains available."))
            return result(diagnostics)
        }
        guard let text, analysis.encoding != .windows1252 else {
            return result([.init(code: .parseError, message: "YAML requires valid Unicode text. Raw remains available.")])
        }
        let checkpoint = { try Task.checkCancellation() }
        do {
            try checkpoint()
            // Event consumption applies alias, nesting, node, and output limits before expansion.
            var stream = YAMLStream(limits: limits, maximumDocuments: min(max(maximumDocuments, 0), 64), checkpoint: checkpoint)
            let (documents, pretty) = try stream.parse(text)
            try checkpoint()
            return result([], documents: documents, pretty: pretty)
        } catch is CancellationError {
            throw CancellationError()
        } catch YAMLFailure.limit {
            return result([.init(code: .limitExceeded, message: "YAML processing or alias-expansion limit reached. Raw remains available.")])
        } catch YAMLFailure.unsupportedKey {
            return result([.init(code: .unsupported, message: "Complex YAML mapping keys are not supported in Tree/Pretty. Raw remains available.")])
        } catch {
            return result([.init(code: .parseError, message: "Invalid YAML. Raw remains available.")])
        }
    }
}

private enum YAMLFailure: Error { case syntax, limit, unsupportedKey }

private struct YAMLAtom {
    let value: StructuredValue
    let scalarKey: String?
    let cost: Int
    let height: Int
}

private struct YAMLFrame {
    let mapping: Bool
    let anchor: String?
    var values: [StructuredValue] = []
    var members: [StructuredMember] = []
    var pendingKey: String?
    var keys: Set<String> = []
    var cost = 1
    var height = 1
}

/// Only accessed synchronously by the emitter callback while its unmanaged pointer is valid.
private final class YAMLOutput {
    var bytes = Data()
    var failure: Error?
    let maximumBytes: Int
    let checkpoint: () throws -> Void

    /// Creates a bounded YAML byte sink that checks cancellation.
    init(maximumBytes: Int, checkpoint: @escaping () throws -> Void) {
        self.maximumBytes = maximumBytes
        self.checkpoint = checkpoint
    }

    /// Serves libyaml's callback contract and records output-budget failures for the caller to throw.
    func append(_ buffer: UnsafeMutablePointer<UInt8>?, count: Int) -> Int32 {
        do {
            try checkpoint()
            // The callback returns failure immediately when output would exceed its hard cap.
            guard count <= maximumBytes - bytes.count else { throw YAMLFailure.limit }
            if count > 0 {
                guard let buffer else { throw YAMLFailure.syntax }
                bytes.append(buffer, count: count)
            }
            return 1
        } catch {
            failure = error
            return 0
        }
    }
}

private struct YAMLStream {
    let limits: StructuredInspectionLimits
    let maximumDocuments: Int
    let checkpoint: () throws -> Void
    private var frames: [YAMLFrame] = []
    private var anchors: [String: YAMLAtom] = [:]
    private var documents: [StructuredValue] = []
    private var root: StructuredValue?
    private var valuesUsed = 0
    private var documentsStarted = 0

    /// Creates a YAML event builder with byte, node, depth, and document limits.
    init(limits: StructuredInspectionLimits, maximumDocuments: Int, checkpoint: @escaping () throws -> Void) {
        self.limits = limits
        self.maximumDocuments = maximumDocuments
        self.checkpoint = checkpoint
    }

    /// Streams parser events to both the bounded semantic model and a capped normalized emitter.
    mutating func parse(_ text: String) throws -> ([StructuredValue], String) {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) == 1 else { throw YAMLFailure.limit }
        defer { yaml_parser_delete(&parser) }
        var emitter = yaml_emitter_t()
        guard yaml_emitter_initialize(&emitter) == 1 else { throw YAMLFailure.limit }
        defer { yaml_emitter_delete(&emitter) }
        let output = YAMLOutput(maximumBytes: limits.maximumOutputBytes, checkpoint: checkpoint)
        yaml_emitter_set_output(&emitter, { context, bytes, count in
            guard let context else { return 0 }
            return Unmanaged<YAMLOutput>.fromOpaque(context).takeUnretainedValue().append(bytes, count: count)
        }, Unmanaged.passUnretained(output).toOpaque())
        yaml_emitter_set_unicode(&emitter, 1)
        yaml_emitter_set_indent(&emitter, 2)
        yaml_emitter_set_encoding(&emitter, YAML_UTF8_ENCODING)
        let input = text.utf8CString
        try input.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { throw YAMLFailure.syntax }
            yaml_parser_set_encoding(&parser, YAML_UTF8_ENCODING)
            yaml_parser_set_input_string(&parser, UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self), buffer.count - 1)
            while true {
                try checkpoint()
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) == 1 else {
                    // The library's own lookahead bound can fire before our next event is delivered.
                    if let problem = parser.problem,
                       String(cString: problem).hasPrefix("Maximum nesting level reached") {
                        throw YAMLFailure.limit
                    }
                    throw YAMLFailure.syntax
                }
                let isEnd = event.type == YAML_STREAM_END_EVENT
                do {
                    try consume(event)
                } catch {
                    yaml_event_delete(&event)
                    throw error
                }
                // yaml_emitter_emit takes ownership of the event, including on failure.
                guard yaml_emitter_emit(&emitter, &event) == 1 else {
                    throw output.failure ?? YAMLFailure.syntax
                }
                if isEnd { break }
            }
        }
        guard let pretty = String(data: output.bytes, encoding: .utf8) else { throw YAMLFailure.syntax }
        return (documents, pretty)
    }

    /// Reserves semantic nodes against the configured entry budget before expanding collections.
    private mutating func use(_ count: Int) throws {
        guard count <= limits.maximumValues - valuesUsed else { throw YAMLFailure.limit }
        valuesUsed += count
    }

    /// Updates the iterative stack and alias table before forwarding each event to the YAML emitter.
    private mutating func consume(_ event: yaml_event_t) throws {
        switch event.type {
        case YAML_DOCUMENT_START_EVENT:
            guard documentsStarted < maximumDocuments else { throw YAMLFailure.limit }
            documentsStarted += 1
            anchors.removeAll(keepingCapacity: true)
            root = nil
        case YAML_DOCUMENT_END_EVENT:
            guard frames.isEmpty, let root else { throw YAMLFailure.syntax }
            documents.append(root)
        case YAML_MAPPING_START_EVENT, YAML_SEQUENCE_START_EVENT:
            try use(1)
            guard frames.count < limits.maximumDepth else { throw YAMLFailure.limit }
            let mapping = event.type == YAML_MAPPING_START_EVENT
            let anchor = mapping ? string(event.data.mapping_start.anchor) : string(event.data.sequence_start.anchor)
            frames.append(YAMLFrame(mapping: mapping, anchor: anchor))
        case YAML_MAPPING_END_EVENT, YAML_SEQUENCE_END_EVENT:
            guard let frame = frames.popLast(), frame.pendingKey == nil else { throw YAMLFailure.syntax }
            let value: StructuredValue = frame.mapping ? .object(frame.members) : .array(frame.values)
            let atom = YAMLAtom(value: value, scalarKey: nil, cost: frame.cost, height: frame.height)
            if let anchor = frame.anchor { anchors[anchor] = atom }
            try append(atom)
        case YAML_SCALAR_EVENT:
            try use(1)
            let scalar = event.data.scalar
            guard let value = String(bytes: UnsafeBufferPointer(start: scalar.value, count: scalar.length), encoding: .utf8) else {
                throw YAMLFailure.syntax
            }
            let tag: Tag
            if scalar.quoted_implicit == 1 { tag = Tag(.str) }
            else { tag = string(scalar.tag).map { Tag(.init(rawValue: $0)) } ?? .implicit }
            let style = Node.Scalar.Style(rawValue: scalar.style.rawValue) ?? .any
            let node = Node.scalar(.init(value, tag, style))
            let model: StructuredValue
            switch node.tag.rawValue {
            case Tag.Name.null.rawValue: model = .null
            case Tag.Name.bool.rawValue:
                guard let boolean = node.bool else { throw YAMLFailure.syntax }
                model = .boolean(boolean)
            case Tag.Name.int.rawValue, Tag.Name.float.rawValue: model = .number(value)
            default: model = .string(value)
            }
            let atom = YAMLAtom(value: model, scalarKey: value, cost: 1, height: 0)
            if let anchor = string(scalar.anchor) { anchors[anchor] = atom }
            try append(atom)
        case YAML_ALIAS_EVENT:
            guard let name = string(event.data.alias.anchor),
                  !frames.contains(where: { $0.anchor == name }), let atom = anchors[name] else {
                throw YAMLFailure.syntax
            }
            try use(atom.cost)
            guard frames.count + atom.height <= limits.maximumDepth else { throw YAMLFailure.limit }
            try append(atom)
        default: break
        }
    }

    /// Attaches a scalar/container to the current frame and requires mapping keys to be scalar and unique.
    private mutating func append(_ atom: YAMLAtom) throws {
        guard !frames.isEmpty else {
            guard root == nil else { throw YAMLFailure.syntax }
            root = atom.value
            return
        }
        let index = frames.count - 1
        frames[index].cost += atom.cost
        frames[index].height = max(frames[index].height, atom.height + 1)
        if frames[index].mapping {
            if let key = frames[index].pendingKey {
                frames[index].members.append(.init(key: key, value: atom.value))
                frames[index].pendingKey = nil
            } else {
                guard let key = atom.scalarKey else { throw YAMLFailure.unsupportedKey }
                guard frames[index].keys.insert(key).inserted else { throw YAMLFailure.syntax }
                frames[index].pendingKey = key
            }
        } else {
            frames[index].values.append(atom.value)
        }
    }

    /// Copies a libyaml-owned null-terminated scalar pointer without retaining temporary storage.
    private func string(_ pointer: UnsafeMutablePointer<UInt8>?) -> String? {
        pointer.map { String(cString: $0) }
    }
}
