import Foundation

/// Reads bounded CycloneDX Protocol Buffer envelopes and projects component names and versions.
enum CycloneDXProtobufInspector {
    private static let maximumInputBytes = 1_048_576
    private static let maximumFields = 16_384
    private static let maximumComponents = 512
    fileprivate static let maximumStringBytes = 4_096
    private static let versions: Set<String> = ["1.5", "1.6", "1.7"]

    static func inspect(_ data: Data) -> SecurityFormatInspection? {
        guard data.count <= maximumInputBytes,
              let fields = parseMessage(Array(data), maximumFields: maximumFields) else { return nil }
        let versionFields = fields.filter { $0.number == 1 }
        guard versionFields.count == 1,
              let version = versionFields[0].stringValue,
              versions.contains(version) else { return nil }

        let encodedComponents = fields.filter { $0.number == 5 }
        guard encodedComponents.count <= maximumComponents,
              encodedComponents.allSatisfy({ $0.wireType == 2 }) else { return nil }
        var components: [StructuredValue] = []
        for field in encodedComponents {
            guard let bytes = field.bytes,
                  let parsed = parseMessage(bytes, maximumFields: 128),
                  let component = makeComponent(from: parsed) else { return nil }
            components.append(component)
        }

        let content = StructuredValue.object([
            .init(key: "Specification", value: .string("CycloneDX \(version) Protocol Buffers")),
            .init(key: "Components", value: .array(components))
        ])
        let count = components.count
        let label = count == 1 ? "component" : "components"
        return .init(formatID: .cyclonedxSBOMProtobuf, content: content,
                     summary: "CycloneDX protobuf \(version) · \(count) \(label)", diagnostics: [])
    }

    private static func makeComponent(from fields: [ProtobufField]) -> StructuredValue? {
        let names = fields.filter { $0.number == 8 }
        let versions = fields.filter { $0.number == 9 }
        guard names.count == 1, names[0].wireType == 2,
              versions.count <= 1, versions.allSatisfy({ $0.wireType == 2 }),
              let rawName = names[0].stringValue, !rawName.isEmpty,
              rawName.utf8.count <= maximumStringBytes else { return nil }
        var members = [StructuredMember(key: "Name", value: .string(escape(rawName)))]
        if let rawVersion = versions.first?.stringValue {
            guard rawVersion.utf8.count <= maximumStringBytes else { return nil }
            members.append(.init(key: "Version", value: .string(escape(rawVersion))))
        }
        return .object(members)
    }

    private static func parseMessage(_ bytes: [UInt8], maximumFields: Int) -> [ProtobufField]? {
        var reader = ProtobufReader(bytes: bytes)
        var fields: [ProtobufField] = []
        while !reader.isAtEnd {
            guard fields.count < maximumFields,
                  let tag = reader.readVarint(), tag > 0 else { return nil }
            let number = Int(tag >> 3)
            let wireType = UInt8(tag & 0x07)
            guard number > 0, number <= 536_870_911,
                  let field = reader.readField(number: number, wireType: wireType) else { return nil }
            fields.append(field)
        }
        return fields
    }

    private static func escape(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            if scalar.value == 0x5C { return "\\\\" }
            if CharacterSet.controlCharacters.contains(scalar)
                || [0x202A...0x202E, 0x2066...0x2069].contains(where: { $0.contains(scalar.value) }) {
                return String(format: "\\u{%X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
}

private struct ProtobufField {
    let number: Int
    let wireType: UInt8
    let varint: UInt64?
    let bytes: [UInt8]?

    var stringValue: String? {
        guard wireType == 2, let bytes, bytes.count <= CycloneDXProtobufInspector.maximumStringBytes,
              let value = String(bytes: bytes, encoding: .utf8), !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        return value
    }
}

private struct ProtobufReader {
    private let bytes: [UInt8]
    private var offset = 0
    var isAtEnd: Bool { offset == bytes.count }

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            if index == 9, byte > 1 { return nil }
            value |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    mutating func readField(number: Int, wireType: UInt8) -> ProtobufField? {
        switch wireType {
        case 0:
            guard let value = readVarint() else { return nil }
            return .init(number: number, wireType: wireType, varint: value, bytes: nil)
        case 1:
            guard skip(8) else { return nil }
        case 2:
            guard let length = readVarint(), length <= UInt64(bytes.count - offset),
                  length <= UInt64(Int.max) else { return nil }
            let count = Int(length)
            let payload = Array(bytes[offset..<(offset + count)])
            offset += count
            return .init(number: number, wireType: wireType, varint: nil, bytes: payload)
        case 5:
            guard skip(4) else { return nil }
        default:
            return nil
        }
        return .init(number: number, wireType: wireType, varint: nil, bytes: nil)
    }

    private mutating func skip(_ count: Int) -> Bool {
        guard count <= bytes.count - offset else { return false }
        offset += count
        return true
    }
}
