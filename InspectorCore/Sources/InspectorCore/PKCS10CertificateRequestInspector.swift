import Foundation

/// Extracts bounded PKCS#10 public metadata without validating the signature or using the key.
enum PKCS10CertificateRequestInspector {
    static func inspectPublicKey(_ input: Data) throws -> SecurityFormatInspection {
        let der = try decodePublicKeyInput(input)
        var cursor = 0
        let subjectPublicKeyInfo = try DERReader.read(der, cursor: &cursor, limit: der.count)
        guard subjectPublicKeyInfo.tag == 0x30, cursor == der.count else { throw PKCS10Failure.malformed }
        let (algorithm, keySize) = try publicKeyFacts(der, element: subjectPublicKeyInfo)
        let facts: [StructuredMember] = [
            .init(key: "Public key algorithm", value: .string(algorithm)),
            .init(key: "Public key size", value: .number(String(keySize))),
            .init(key: "Key import or use", value: .string("Not performed")),
            .init(key: "Trust evaluation", value: .string("Not performed"))
        ]
        return .init(formatID: .pemPublicKey, content: .object(facts),
                     summary: "PEM public-key metadata · trust evaluation not performed", diagnostics: [])
    }

    static func inspect(_ input: Data) throws -> SecurityFormatInspection {
        let der = try decodeInput(input)
        var cursor = 0
        let request = try DERReader.read(der, cursor: &cursor, limit: der.count)
        guard request.tag == 0x30, cursor == der.count else { throw PKCS10Failure.malformed }

        var requestCursor = request.contentStart
        let info = try DERReader.read(der, cursor: &requestCursor, limit: request.end)
        let signatureAlgorithm = try DERReader.read(der, cursor: &requestCursor, limit: request.end)
        let signature = try DERReader.read(der, cursor: &requestCursor, limit: request.end)
        guard info.tag == 0x30, signatureAlgorithm.tag == 0x30,
              signature.tag == 0x03, requestCursor == request.end,
              signature.length >= 2, der[signature.contentStart] == 0 else {
            throw PKCS10Failure.malformed
        }

        var infoCursor = info.contentStart
        let version = try DERReader.read(der, cursor: &infoCursor, limit: info.end)
        let subject = try DERReader.read(der, cursor: &infoCursor, limit: info.end)
        let subjectPublicKeyInfo = try DERReader.read(der, cursor: &infoCursor, limit: info.end)
        guard version.tag == 0x02, version.length == 1, der[version.contentStart] == 0,
              subject.tag == 0x30, subjectPublicKeyInfo.tag == 0x30 else {
            throw PKCS10Failure.malformed
        }
        if infoCursor < info.end {
            let attributes = try DERReader.read(der, cursor: &infoCursor, limit: info.end)
            guard attributes.tag == 0xA0 else { throw PKCS10Failure.malformed }
            var elementCount = 0
            try DERReader.validateChildren(der, start: attributes.contentStart, end: attributes.end,
                                           depth: 0, elementCount: &elementCount)
        }
        guard infoCursor == info.end else { throw PKCS10Failure.malformed }

        let (keyAlgorithm, keySize) = try publicKeyFacts(der, element: subjectPublicKeyInfo)
        let signatureOID = try algorithmOID(der, element: signatureAlgorithm)
        let signatureName = signatureNameForOID[signatureOID] ?? signatureOID
        let subjectText = try subjectSummary(der, element: subject)

        let facts: [StructuredMember] = [
            .init(key: "Subject", value: .string(subjectText.isEmpty ? "Not specified" : subjectText)),
            .init(key: "Public key algorithm", value: .string(keyAlgorithm)),
            .init(key: "Public key size", value: .number(String(keySize))),
            .init(key: "Signature algorithm", value: .string(signatureName)),
            .init(key: "Signature verification", value: .string("Not performed")),
            .init(key: "Key import or use", value: .string("Not performed"))
        ]
        return .init(formatID: .csr, content: .object(facts),
                     summary: "PKCS#10 request metadata · signature verification not performed", diagnostics: [])
    }

    private static func decodePublicKeyInput(_ data: Data) throws -> Data {
        guard data.count <= SecurityFormatInspector.maximumInputBytes,
              let source = String(data: data, encoding: .utf8) else { throw PKCS10Failure.malformed }
        let lines = source.components(separatedBy: .newlines)
        let nonempty = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard nonempty.count >= 3, nonempty.first == "-----BEGIN PUBLIC KEY-----",
              nonempty.last == "-----END PUBLIC KEY-----" else { throw PKCS10Failure.malformed }
        let encoded = nonempty.dropFirst().dropLast().joined()
        guard !encoded.isEmpty,
              encoded.utf8.allSatisfy({
                  (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                      || (0x30...0x39).contains($0) || $0 == 0x2B || $0 == 0x2F || $0 == 0x3D
              }),
              let der = Data(base64Encoded: encoded), !der.isEmpty else { throw PKCS10Failure.malformed }
        return der
    }

    private static func decodeInput(_ data: Data) throws -> Data {
        guard data.count <= SecurityFormatInspector.maximumInputBytes else { throw PKCS10Failure.malformed }
        guard let source = String(data: data, encoding: .utf8),
              source.contains("-----BEGIN") else { return data }
        let lines = source.components(separatedBy: .newlines)
        let nonempty = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard nonempty.count >= 3,
              ["-----BEGIN CERTIFICATE REQUEST-----", "-----BEGIN NEW CERTIFICATE REQUEST-----"].contains(nonempty.first),
              let begin = nonempty.first,
              nonempty.last == begin.replacingOccurrences(of: "BEGIN", with: "END") else {
            throw PKCS10Failure.malformed
        }
        let encoded = nonempty.dropFirst().dropLast().joined()
        guard !encoded.isEmpty,
              encoded.utf8.allSatisfy({
                  (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                      || (0x30...0x39).contains($0) || $0 == 0x2B || $0 == 0x2F || $0 == 0x3D
              }),
              let der = Data(base64Encoded: encoded), !der.isEmpty else {
            throw PKCS10Failure.malformed
        }
        return der
    }

    private static func publicKeyFacts(_ bytes: Data, element: DERElement) throws -> (String, Int) {
        var cursor = element.contentStart
        let algorithm = try DERReader.read(bytes, cursor: &cursor, limit: element.end)
        let key = try DERReader.read(bytes, cursor: &cursor, limit: element.end)
        guard algorithm.tag == 0x30, key.tag == 0x03, key.length >= 2,
              bytes[key.contentStart] == 0, cursor == element.end else {
            throw PKCS10Failure.malformed
        }
        let (oid, parameters) = try algorithmParts(bytes, element: algorithm)
        switch oid {
        case "1.2.840.113549.1.1.1":
            guard parameters?.tag == 0x05, parameters?.length == 0 else { throw PKCS10Failure.malformed }
            let rsa = Data(bytes[(key.contentStart + 1)..<key.end])
            var rsaCursor = 0
            let rsaSequence = try DERReader.read(rsa, cursor: &rsaCursor, limit: rsa.count)
            guard rsaSequence.tag == 0x30, rsaCursor == rsa.count else { throw PKCS10Failure.malformed }
            var fieldsCursor = rsaSequence.contentStart
            let modulus = try DERReader.read(rsa, cursor: &fieldsCursor, limit: rsaSequence.end)
            let exponent = try DERReader.read(rsa, cursor: &fieldsCursor, limit: rsaSequence.end)
            try validatePositiveInteger(rsa, element: modulus)
            try validatePositiveInteger(rsa, element: exponent)
            guard fieldsCursor == rsaSequence.end else { throw PKCS10Failure.malformed }
            var start = modulus.contentStart
            while start < modulus.end - 1, rsa[start] == 0 { start += 1 }
            let first = rsa[start]
            let significantBits = (modulus.end - start - 1) * 8 + (8 - first.leadingZeroBitCount)
            guard (2_048...16_384).contains(significantBits) else { throw PKCS10Failure.unsupported }
            return ("RSA", significantBits)
        case "1.2.840.10045.2.1":
            guard let parameters, parameters.tag == 0x06 else { throw PKCS10Failure.malformed }
            let curve = try decodeOID(bytes, element: parameters)
            guard let bits = curveBitSize[curve] else { throw PKCS10Failure.unsupported }
            let pointLength = key.length - 1
            guard pointLength == ((bits + 7) / 8) * 2 + 1, bytes[key.contentStart + 1] == 0x04 else {
                throw PKCS10Failure.malformed
            }
            return ("ECDSA", bits)
        case "1.3.101.112":
            guard parameters == nil, key.length == 33 else { throw PKCS10Failure.malformed }
            return ("Ed25519", 256)
        default:
            throw PKCS10Failure.unsupported
        }
    }

    private static func subjectSummary(_ bytes: Data, element: DERElement) throws -> String {
        var cursor = element.contentStart
        var fields: [String] = []
        var attributeCount = 0
        while cursor < element.end {
            try Task.checkCancellation()
            let set = try DERReader.read(bytes, cursor: &cursor, limit: element.end)
            guard set.tag == 0x31 else { throw PKCS10Failure.malformed }
            var setCursor = set.contentStart
            while setCursor < set.end {
                attributeCount += 1
                guard attributeCount <= 128 else { throw PKCS10Failure.unsupported }
                let attribute = try DERReader.read(bytes, cursor: &setCursor, limit: set.end)
                guard attribute.tag == 0x30 else { throw PKCS10Failure.malformed }
                var attributeCursor = attribute.contentStart
                let oid = try DERReader.read(bytes, cursor: &attributeCursor, limit: attribute.end)
                let value = try DERReader.read(bytes, cursor: &attributeCursor, limit: attribute.end)
                guard oid.tag == 0x06, attributeCursor == attribute.end,
                      let decoded = decodeDirectoryString(bytes, element: value) else {
                    throw PKCS10Failure.malformed
                }
                if let label = subjectLabels[try decodeOID(bytes, element: oid)], !decoded.isEmpty {
                    fields.append("\(label)=\(decoded)")
                }
                guard fields.count <= 32 else { throw PKCS10Failure.unsupported }
            }
        }
        return fields.joined(separator: ", ")
    }

    private static func decodeDirectoryString(_ bytes: Data, element: DERElement) -> String? {
        guard element.length <= 1_024 else { return nil }
        let value = bytes[element.contentStart..<element.end]
        let decoded: String?
        switch element.tag {
        case 0x0C: decoded = String(data: Data(value), encoding: .utf8)
        case 0x13, 0x16: decoded = String(bytes: value, encoding: .ascii)
        case 0x1E:
            guard element.length.isMultiple(of: 2) else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(element.length / 2)
            var index = element.contentStart
            while index < element.end {
                units.append((UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]))
                index += 2
            }
            decoded = String(decoding: units, as: UTF16.self)
        default: decoded = nil
        }
        guard let decoded, !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return decoded
    }

    private static func algorithmOID(_ bytes: Data, element: DERElement) throws -> String {
        try algorithmParts(bytes, element: element).oid
    }

    private static func algorithmParts(_ bytes: Data, element: DERElement) throws -> (oid: String, parameters: DERElement?) {
        var cursor = element.contentStart
        let oid = try DERReader.read(bytes, cursor: &cursor, limit: element.end)
        guard element.tag == 0x30, oid.tag == 0x06 else { throw PKCS10Failure.malformed }
        var parameters: DERElement?
        if cursor < element.end {
            parameters = try DERReader.read(bytes, cursor: &cursor, limit: element.end)
        }
        guard cursor == element.end else { throw PKCS10Failure.malformed }
        return (try decodeOID(bytes, element: oid), parameters)
    }

    private static func validatePositiveInteger(_ bytes: Data, element: DERElement) throws {
        guard element.tag == 0x02, element.length > 0, bytes[element.contentStart] & 0x80 == 0 else {
            throw PKCS10Failure.malformed
        }
        if element.length > 1, bytes[element.contentStart] == 0,
           bytes[element.contentStart + 1] & 0x80 == 0 {
            throw PKCS10Failure.malformed
        }
    }

    private static func decodeOID(_ bytes: Data, element: DERElement) throws -> String {
        guard element.tag == 0x06, element.length > 0, element.length <= 128 else { throw PKCS10Failure.malformed }
        var arcs: [UInt64] = []
        var value: UInt64 = 0
        var pending = false
        var atStart = true
        var byteCount = 0
        for byte in bytes[element.contentStart..<element.end] {
            byteCount += 1
            if byteCount.isMultiple(of: 256) { try Task.checkCancellation() }
            guard !(atStart && byte == 0x80) else { throw PKCS10Failure.malformed }
            guard value <= (UInt64.max >> 7) else { throw PKCS10Failure.malformed }
            value = (value << 7) | UInt64(byte & 0x7F)
            pending = byte & 0x80 != 0
            if !pending {
                arcs.append(value)
                value = 0
                guard arcs.count <= 64 else { throw PKCS10Failure.malformed }
                atStart = true
            } else {
                atStart = false
            }
        }
        guard !pending, let first = arcs.first else { throw PKCS10Failure.malformed }
        let firstArc: UInt64 = first < 40 ? 0 : first < 80 ? 1 : 2
        let secondArc = first - firstArc * 40
        return ([String(firstArc), String(secondArc)] + arcs.dropFirst().map(String.init)).joined(separator: ".")
    }

    private static let subjectLabels: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L",
        "2.5.4.8": "ST", "2.5.4.10": "O", "2.5.4.11": "OU",
        "1.2.840.113549.1.9.1": "email"
    ]

    private static let curveBitSize: [String: Int] = [
        "1.2.840.10045.3.1.7": 256,
        "1.3.132.0.34": 384,
        "1.3.132.0.35": 521
    ]

    private static let signatureNameForOID: [String: String] = [
        "1.2.840.113549.1.1.5": "sha1WithRSAEncryption",
        "1.2.840.113549.1.1.11": "sha256WithRSAEncryption",
        "1.2.840.113549.1.1.12": "sha384WithRSAEncryption",
        "1.2.840.113549.1.1.13": "sha512WithRSAEncryption",
        "1.2.840.10045.4.3.2": "ecdsa-with-SHA256",
        "1.2.840.10045.4.3.3": "ecdsa-with-SHA384",
        "1.2.840.10045.4.3.4": "ecdsa-with-SHA512",
        "1.3.101.112": "Ed25519"
    ]
}

enum PKCS10Failure: Error { case malformed, unsupported }

private struct DERElement {
    let tag: UInt8
    let contentStart: Int
    let length: Int
    var end: Int { contentStart + length }
}

private enum DERReader {
    static func validateChildren(_ bytes: Data, start: Int, end: Int,
                                 depth: Int, elementCount: inout Int) throws {
        guard depth <= 32 else { throw PKCS10Failure.unsupported }
        var cursor = start
        while cursor < end {
            elementCount += 1
            guard elementCount <= 10_000 else { throw PKCS10Failure.unsupported }
            if elementCount.isMultiple(of: 128) { try Task.checkCancellation() }
            let element = try read(bytes, cursor: &cursor, limit: end)
            if element.tag & 0x20 != 0 {
                try validateChildren(bytes, start: element.contentStart, end: element.end,
                                     depth: depth + 1, elementCount: &elementCount)
            }
        }
    }

    static func read(_ bytes: Data, cursor: inout Int, limit: Int) throws -> DERElement {
        guard cursor >= 0, limit <= bytes.count, cursor < limit else { throw PKCS10Failure.malformed }
        let tag = bytes[cursor]
        guard tag & 0x1F != 0x1F else { throw PKCS10Failure.unsupported }
        cursor += 1
        guard cursor < limit else { throw PKCS10Failure.malformed }
        let firstLength = bytes[cursor]
        cursor += 1
        let length: Int
        if firstLength < 0x80 {
            length = Int(firstLength)
        } else {
            let octetCount = Int(firstLength & 0x7F)
            guard (1...4).contains(octetCount), octetCount <= limit - cursor,
                  bytes[cursor] != 0 else { throw PKCS10Failure.malformed }
            var decoded = 0
            for _ in 0..<octetCount {
                guard decoded <= Int.max >> 8 else { throw PKCS10Failure.malformed }
                decoded = (decoded << 8) | Int(bytes[cursor])
                cursor += 1
            }
            guard decoded >= 128 else { throw PKCS10Failure.malformed }
            length = decoded
        }
        guard length <= limit - cursor else { throw PKCS10Failure.malformed }
        let element = DERElement(tag: tag, contentStart: cursor, length: length)
        cursor = element.end
        return element
    }
}
