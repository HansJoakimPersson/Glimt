import Foundation
import CoreFoundation
import Security
import CryptoKit

/// Redacted, local security-document facts. A nil content value means the caller should keep Raw/Hex recovery.
public struct SecurityFormatInspection: Sendable {
    public let formatID: FormatID
    public let content: StructuredValue?
    public let summary: String
    public let diagnostics: [InspectionDiagnostic]
}

/// Bounded parsers for security metadata formats. None of these parsers verifies trust or executes content.
public enum SecurityFormatInspector {
    public static let maximumInputBytes = 1_048_576
    private static let maximumJWTEncodedSegmentBytes = 524_288
    private static let privateJWKMembers: Set<String> = ["d", "p", "q", "dp", "dq", "qi", "oth", "k"]
    private static let maximumSSHCommentBytes = 1_024

    /// Distinguishes OpenSSH text keys from PEM files that share the `.pub` suffix.
    static func recognizesOpenSSHPublicKey(_ data: Data) -> Bool {
        guard data.count <= maximumInputBytes,
              let source = String(data: data.prefix(4_096), encoding: .utf8),
              let firstLine = source.split(whereSeparator: \.isNewline).first,
              let algorithm = firstLine.split(whereSeparator: \.isWhitespace).first else { return false }
        return algorithm.hasPrefix("ssh-") || algorithm.hasPrefix("ecdsa-sha2-")
    }

    /// Distinguishes a generic SubjectPublicKeyInfo PEM block from OpenSSH's single-line key form.
    static func recognizesPEMPublicKey(_ data: Data) -> Bool {
        guard data.count <= maximumInputBytes,
              let source = String(data: data.prefix(256), encoding: .utf8) else { return false }
        return source.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
            == "-----BEGIN PUBLIC KEY-----"
    }

    /// Dispatches only catalog-selected security formats and retains no source paths or file metadata.
    public static func inspect(data: Data, fileSize: Int, formatID: FormatID,
                               fileURL: URL? = nil) throws -> SecurityFormatInspection {
        if formatID == .pkcs7 {
            return try inspectPKCS7(data: data, fileSize: fileSize,
                                    isCancelled: { Task.isCancelled }, onAcceptedMember: { _ in })
        }
        if formatID == .pkcs12 {
            return try inspectPKCS12(data: data, fileSize: fileSize,
                                     isCancelled: { Task.isCancelled }, onAcceptedEntry: { _ in })
        }
        try Task.checkCancellation()
        if formatID == .sqlite {
            guard let fileURL else {
                return fallback(formatID, .unsupported, "SQLite inspection needs a local file handle.")
            }
            do {
                return try SQLiteDatabaseInspector.inspect(fileAt: fileURL, fileSize: fileSize)
            } catch SQLiteDatabaseError.cancelled {
                throw CancellationError()
            } catch SQLiteDatabaseError.incompleteInput {
                return fallback(formatID, .truncated, "SQLite database is incomplete.")
            } catch SQLiteDatabaseError.objectLimitExceeded, SQLiteDatabaseError.outputLimitExceeded {
                return fallback(formatID, .limitExceeded, "SQLite inspection limit reached.")
            } catch {
                return fallback(formatID, .parseError, "SQLite schema could not be inspected.")
            }
        }
        guard data.count <= maximumInputBytes, fileSize <= maximumInputBytes else {
            return fallback(formatID, .limitExceeded, "Security document exceeds the inspection limit.")
        }
        guard fileSize >= 0, fileSize == data.count else {
            return fallback(formatID, .truncated, "Security document is incomplete.")
        }

        do {
            switch formatID {
            case .mobileprovision: return try inspectMobileProvision(data)
            case .cyclonedxSBOMProtobuf: return try inspectCycloneDXProtobuf(data)
            case .sshPublicKey: return try inspectOpenSSHPublicKey(data)
            case .pemPublicKey: return try PKCS10CertificateRequestInspector.inspectPublicKey(data)
            case .csr: return try PKCS10CertificateRequestInspector.inspect(data)
            case .jwt: return try inspectJWT(data)
            case .jwk: return try inspectJWK(data, isSet: false)
            case .jwks: return try inspectJWK(data, isSet: true)
            case .cyclonedxSBOM: return try inspectSBOM(data, formatID: formatID)
            case .spdxSBOM: return try inspectSBOM(data, formatID: formatID)
            case .cyclonedxSBOMXML: return try inspectCycloneDXXML(data, fileSize: fileSize)
            case .spdxTagValue: return try inspectSPDXTagValue(data, fileSize: fileSize)
            case .spdxYAML: return try inspectSPDXYAML(data, fileSize: fileSize)
            default: return fallback(formatID, .unsupported, "Unsupported security document.")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch SecurityDocumentFailure.unsupported {
            return fallback(formatID, .unsupported, "Security document format or version is unsupported.")
        } catch PKCS10Failure.unsupported {
            let message = formatID == .csr
                ? "Certificate request algorithm or structure is unsupported."
                : "Public key algorithm or structure is unsupported."
            return fallback(formatID, .unsupported, message)
        } catch PKCS10Failure.malformed {
            let message = formatID == .csr
                ? "Certificate signing request could not be parsed."
                : "PEM public key could not be parsed."
            return fallback(formatID, .parseError, message)
        } catch {
            return fallback(formatID, .parseError, "Security document could not be parsed.")
        }
    }

    /// Parses a certificate-only CMS SignedData bundle without evaluating trust or signatures.
    static func inspectPKCS7(data: Data, fileSize: Int, isCancelled: @escaping () -> Bool,
                             onAcceptedMember: (Int) -> Void) throws -> SecurityFormatInspection {
        func checkpoint() throws {
            if Task.isCancelled || isCancelled() { throw CancellationError() }
        }
        try Task.checkCancellation()
        if isCancelled() { throw CancellationError() }
        guard data.count <= maximumInputBytes, fileSize <= maximumInputBytes else {
            return fallback(.pkcs7, .limitExceeded, "PKCS#7 bundle exceeds the inspection limit.")
        }
        guard fileSize >= 0, fileSize == data.count else {
            return fallback(.pkcs7, .truncated, "PKCS#7 bundle is incomplete.")
        }
        do {
            try checkpoint()
            let der: Data
            if data.first == 0x30 {
                der = data
            } else {
                der = try decodePKCS7PEM(data, checkpoint: { try checkpoint() })
            }
            try checkpoint()
            let slices = try PKCS7Envelope.certificates(in: der, checkpoint: { try checkpoint() })
            var facts: [X509CertificateFacts] = []
            facts.reserveCapacity(slices.count)
            for (index, slice) in slices.enumerated() {
                try checkpoint()
                let inspection: X509CertificateInspection
                do {
                    inspection = try X509CertificateInspector.inspect(data: slice, fileSize: slice.count,
                        encoding: .der, isCancelled: { Task.isCancelled || isCancelled() })
                } catch X509CertificateError.cancelled { throw CancellationError() }
                catch X509CertificateError.inputLimitExceeded,
                      X509CertificateError.certificateCountLimitExceeded { throw PKCS7Failure.limit }
                catch X509CertificateError.incompleteInput { throw PKCS7Failure.truncated }
                catch { throw PKCS7Failure.malformed }
                guard inspection.certificates.count == 1 else { throw PKCS7Failure.malformed }
                let member = inspection.certificates[0]
                onAcceptedMember(index + 1)
                try checkpoint()
                facts.append(member)
            }
            try checkpoint()
            let certificates = facts.map { fact -> StructuredValue in
                let subject = fact.subjectSummary.utf8.count > 4_096
                    ? "Subject summary exceeds display limit" : fact.subjectSummary
                return .object([
                    .init(key: "Subject", value: .string(subject)),
                    .init(key: "SHA-256 fingerprint", value: .string(fact.sha256Fingerprint))
                ])
            }
            let countText = facts.count == 1 ? "1 certificate" : "\(facts.count) certificates"
            let content = StructuredValue.object([
                .init(key: "Certificate count", value: .number(String(facts.count))),
                .init(key: "Verification", value: .string("Trust and signatures were not checked.")),
                .init(key: "Certificates", value: .array(certificates))
            ])
            try checkpoint()
            return .init(formatID: .pkcs7, content: content, summary: countText, diagnostics: [])
        } catch is CancellationError { throw CancellationError() }
        catch let failure as PKCS7Failure {
            switch failure {
            case .unsupported: return fallback(.pkcs7, .unsupported, "PKCS#7 bundle structure is unsupported.")
            case .limit: return fallback(.pkcs7, .limitExceeded, "PKCS#7 bundle inspection limit reached.")
            case .truncated: return fallback(.pkcs7, .truncated, "PKCS#7 bundle is incomplete.")
            case .malformed: return fallback(.pkcs7, .parseError, "PKCS#7 bundle could not be parsed.")
            }
        }
    }

    /// Reads only the bounded PFX envelope and publishes no values derived from opaque payloads.
    static func inspectPKCS12(data: Data, fileSize: Int, isCancelled: @escaping () -> Bool,
                              onAcceptedEntry: (Int) -> Void) throws -> SecurityFormatInspection {
        func checkpoint() throws {
            if Task.isCancelled || isCancelled() { throw CancellationError() }
        }
        try checkpoint()
        guard data.count <= maximumInputBytes, fileSize <= maximumInputBytes else {
            return fallback(.pkcs12, .limitExceeded, "PKCS#12 file exceeds the inspection limit.")
        }
        guard fileSize >= 0, fileSize == data.count else {
            return fallback(.pkcs12, .truncated, "PKCS#12 file is incomplete.")
        }

        do {
            if hasPKCS12PEMMarker(data) { throw PKCS12Failure.unsupported }
            // A normalized copy makes integer offsets safe for Data slices without changing DER bytes.
            let bytes = Data(Array(data))
            var cursor = 0
            let outer = try pkcs12Read(bytes, cursor: &cursor, limit: bytes.count)
            guard outer.tag == 0x30, cursor == bytes.count else { throw PKCS12Failure.malformed }

            var outerCursor = outer.contentStart
            let version = try pkcs12Read(bytes, cursor: &outerCursor, limit: outer.end)
            guard version.tag == 0x02, DERReader.isMinimalInteger(bytes, version) else {
                throw PKCS12Failure.malformed
            }
            let versionBytes = Data((version.contentStart..<version.end).map { DERReader.byte(bytes, at: $0) })
            guard versionBytes == Data([0x03]) else { throw PKCS12Failure.unsupported }

            try checkpoint()
            let contentInfo = try pkcs12Read(bytes, cursor: &outerCursor, limit: outer.end)
            guard contentInfo.tag == 0x30 else { throw PKCS12Failure.malformed }
            let authSafe = try pkcs12AuthenticatedSafe(bytes, contentInfo, checkpoint: checkpoint)
            var envelopeKinds: [StructuredValue] = []
            envelopeKinds.reserveCapacity(16)
            var memberCursor = authSafe.contentStart
            while memberCursor < authSafe.end {
                try checkpoint()
                guard envelopeKinds.count < 16 else { throw PKCS12Failure.entryLimit }
                let kind = try pkcs12EnvelopeEntry(bytes, cursor: &memberCursor, limit: authSafe.end)
                envelopeKinds.append(.string(kind))
                onAcceptedEntry(envelopeKinds.count)
            }
            guard memberCursor == authSafe.end else { throw PKCS12Failure.malformed }

            var macDataPresent = false
            if outerCursor < outer.end {
                try checkpoint()
                let macData = try pkcs12Read(bytes, cursor: &outerCursor, limit: outer.end)
                guard macData.tag == 0x30 else { throw PKCS12Failure.malformed }
                try pkcs12MacData(bytes, macData)
                macDataPresent = true
            }
            guard outerCursor == outer.end else { throw PKCS12Failure.malformed }
            try checkpoint()
            let count = envelopeKinds.count
            let content = StructuredValue.object([
                .init(key: "Version", value: .number("3")),
                .init(key: "Envelope count", value: .number(String(count))),
                .init(key: "Envelope kinds", value: .array(envelopeKinds)),
                .init(key: "MacData present", value: .boolean(macDataPresent))
            ])
            return .init(formatID: .pkcs12, content: content,
                         summary: count == 1 ? "1 envelope" : "\(count) envelopes", diagnostics: [])
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PKCS12Failure {
            switch failure {
            case .unsupported:
                return fallback(.pkcs12, .unsupported, "PKCS#12 structure is unsupported.")
            case .entryLimit:
                return fallback(.pkcs12, .limitExceeded, "PKCS#12 envelope count limit reached.")
            case .malformed:
                return fallback(.pkcs12, .parseError, "PKCS#12 structure could not be parsed.")
            }
        }
    }

    private static func hasPKCS12PEMMarker(_ data: Data) -> Bool {
        let bytes = Array(data)
        var cursor = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { cursor = 3 }
        while cursor < bytes.count, [0x20, 0x09, 0x0D, 0x0A].contains(bytes[cursor]) { cursor += 1 }
        return bytes[cursor...].starts(with: Array("-----BEGIN ".utf8))
    }

    private static func pkcs12Read(_ bytes: Data, cursor: inout Int, limit: Int) throws -> DERTLV {
        let initialCursor = cursor
        do {
            let item = try DERReader.read(bytes, cursor: &cursor, limit: limit)
            guard !(item.tag & 0xC0 == 0 && item.tag & 0x1F == 0) else { throw PKCS12Failure.malformed }
            return item
        } catch DERReadFailure.indefiniteLength {
            let tag = DERReader.byte(bytes, at: initialCursor)
            guard !(tag & 0xC0 == 0 && tag & 0x1F == 0) else { throw PKCS12Failure.malformed }
            throw PKCS12Failure.unsupported
        } catch let failure as PKCS12Failure {
            throw failure
        } catch {
            throw PKCS12Failure.malformed
        }
    }

    private static func pkcs12AuthenticatedSafe(_ bytes: Data, _ contentInfo: DERTLV,
                                                checkpoint: () throws -> Void) throws -> DERTLV {
        var cursor = contentInfo.contentStart
        let contentType = try pkcs12Read(bytes, cursor: &cursor, limit: contentInfo.end)
        guard contentType.tag == 0x06, DERReader.isValidOID(bytes, contentType) else {
            throw PKCS12Failure.malformed
        }
        guard DERReader.encoded(bytes, contentType) == PKCS12Envelope.dataOID else {
            try pkcs12ConsumeAlternativeContentInfo(bytes, contentInfo, firstOID: contentType, cursor: cursor)
            throw PKCS12Failure.unsupported
        }
        try checkpoint()
        let wrapper = try pkcs12Read(bytes, cursor: &cursor, limit: contentInfo.end)
        guard wrapper.tag == 0xA0, cursor == contentInfo.end else { throw PKCS12Failure.malformed }
        var wrappedCursor = wrapper.contentStart
        let octets = try pkcs12Read(bytes, cursor: &wrappedCursor, limit: wrapper.end)
        guard octets.tag == 0x04, wrappedCursor == wrapper.end else { throw PKCS12Failure.malformed }
        var safeCursor = octets.contentStart
        let safe = try pkcs12Read(bytes, cursor: &safeCursor, limit: octets.end)
        guard safe.tag == 0x30, safeCursor == octets.end else { throw PKCS12Failure.malformed }
        return safe
    }

    private static func pkcs12ConsumeAlternativeContentInfo(_ bytes: Data, _ contentInfo: DERTLV,
                                                             firstOID: DERTLV, cursor initialCursor: Int) throws {
        var cursor = initialCursor
        guard firstOID.tag == 0x06, DERReader.isValidOID(bytes, firstOID) else { throw PKCS12Failure.malformed }
        if cursor < contentInfo.end {
            let wrapper = try pkcs12Read(bytes, cursor: &cursor, limit: contentInfo.end)
            guard wrapper.tag == 0xA0 else { throw PKCS12Failure.malformed }
            var innerCursor = wrapper.contentStart
            _ = try pkcs12Read(bytes, cursor: &innerCursor, limit: wrapper.end)
            guard innerCursor == wrapper.end else { throw PKCS12Failure.malformed }
        }
        guard cursor == contentInfo.end else { throw PKCS12Failure.malformed }
    }

    private static func pkcs12EnvelopeEntry(_ bytes: Data, cursor: inout Int, limit: Int) throws -> String {
        let entry = try pkcs12Read(bytes, cursor: &cursor, limit: limit)
        guard entry.tag == 0x30 else { throw PKCS12Failure.malformed }
        var fieldCursor = entry.contentStart
        let oid = try pkcs12Read(bytes, cursor: &fieldCursor, limit: entry.end)
        guard oid.tag == 0x06, DERReader.isValidOID(bytes, oid) else { throw PKCS12Failure.malformed }
        let kind: String
        let payloadTag: UInt8
        switch DERReader.encoded(bytes, oid) {
        case PKCS12Envelope.dataOID: kind = "data"; payloadTag = 0x04
        case PKCS12Envelope.encryptedDataOID: kind = "encryptedData"; payloadTag = 0x30
        default:
            try pkcs12ConsumeAlternativeContentInfo(bytes, entry, firstOID: oid, cursor: fieldCursor)
            throw PKCS12Failure.unsupported
        }
        let wrapper = try pkcs12Read(bytes, cursor: &fieldCursor, limit: entry.end)
        guard wrapper.tag == 0xA0, fieldCursor == entry.end else { throw PKCS12Failure.malformed }
        var wrappedCursor = wrapper.contentStart
        let payload = try pkcs12Read(bytes, cursor: &wrappedCursor, limit: wrapper.end)
        guard payload.tag == payloadTag, wrappedCursor == wrapper.end else { throw PKCS12Failure.malformed }
        return kind
    }

    private static func pkcs12MacData(_ bytes: Data, _ macData: DERTLV) throws {
        var cursor = macData.contentStart
        let digestInfo = try pkcs12Read(bytes, cursor: &cursor, limit: macData.end)
        guard digestInfo.tag == 0x30 else { throw PKCS12Failure.malformed }
        var digestCursor = digestInfo.contentStart
        let algorithm = try pkcs12Read(bytes, cursor: &digestCursor, limit: digestInfo.end)
        guard algorithm.tag == 0x30 else { throw PKCS12Failure.malformed }
        var algorithmCursor = algorithm.contentStart
        let oid = try pkcs12Read(bytes, cursor: &algorithmCursor, limit: algorithm.end)
        guard oid.tag == 0x06, DERReader.isValidOID(bytes, oid) else { throw PKCS12Failure.malformed }
        if algorithmCursor < algorithm.end { _ = try pkcs12Read(bytes, cursor: &algorithmCursor, limit: algorithm.end) }
        guard algorithmCursor == algorithm.end, digestCursor < digestInfo.end else { throw PKCS12Failure.malformed }
        let digest = try pkcs12Read(bytes, cursor: &digestCursor, limit: digestInfo.end)
        guard digest.tag == 0x04, digest.contentStart < digest.end, digestCursor == digestInfo.end else {
            throw PKCS12Failure.malformed
        }
        guard cursor < macData.end else { throw PKCS12Failure.malformed }
        let salt = try pkcs12Read(bytes, cursor: &cursor, limit: macData.end)
        guard salt.tag == 0x04, salt.contentStart < salt.end else { throw PKCS12Failure.malformed }
        if cursor < macData.end {
            let iterations = try pkcs12Read(bytes, cursor: &cursor, limit: macData.end)
            guard iterations.tag == 0x02, DERReader.isMinimalInteger(bytes, iterations),
                  pkcs12IntegerIsPositiveGreaterThanOne(bytes, iterations) else { throw PKCS12Failure.malformed }
        }
        guard cursor == macData.end else { throw PKCS12Failure.malformed }
    }

    private static func pkcs12IntegerIsPositiveGreaterThanOne(_ bytes: Data, _ item: DERTLV) -> Bool {
        let content = (item.contentStart..<item.end).map { DERReader.byte(bytes, at: $0) }
        guard let first = content.first, first & 0x80 == 0 else { return false }
        let magnitude = first == 0 && content.count > 1 ? Array(content.dropFirst()) : content
        guard !magnitude.isEmpty else { return false }
        return magnitude.count > 1 || magnitude[0] > 1
    }

    private static func inspectOpenSSHPublicKey(_ data: Data) throws -> SecurityFormatInspection {
        guard let source = String(data: data, encoding: .utf8) else { throw SecurityDocumentFailure.malformed }
        let lines = source.split(whereSeparator: \.isNewline)
        guard lines.count == 1, let line = lines.first else { throw SecurityDocumentFailure.malformed }
        let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { throw SecurityDocumentFailure.malformed }
        let algorithm = String(fields[0])
        let encodedBlob = String(fields[1])
        let comment = fields.count == 3 ? String(fields[2]) : nil
        guard (comment?.utf8.count ?? 0) <= maximumSSHCommentBytes,
              comment?.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) ?? true,
              encodedBlob.utf8.allSatisfy({
                  (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || (0x30...0x39).contains($0)
                      || $0 == 0x2B || $0 == 0x2F || $0 == 0x3D
              }),
              let blob = Data(base64Encoded: encodedBlob), blob.count <= maximumInputBytes else {
            throw SecurityDocumentFailure.malformed
        }

        var reader = SSHWireReader(bytes: Array(blob))
        guard let encodedAlgorithm = String(bytes: try reader.readString(), encoding: .ascii),
              encodedAlgorithm == algorithm else { throw SecurityDocumentFailure.malformed }
        let keySize: Int
        switch algorithm {
        case "ssh-ed25519":
            guard try reader.readString().count == 32, reader.isAtEnd else { throw SecurityDocumentFailure.malformed }
            keySize = 256
        case "ssh-rsa":
            let exponent = try reader.readString()
            let modulus = try reader.readString()
            guard !exponent.isEmpty, !modulus.isEmpty, modulus.count <= 8_192, reader.isAtEnd else {
                throw SecurityDocumentFailure.malformed
            }
            let significant = modulus.drop(while: { $0 == 0 })
            guard let first = significant.first else { throw SecurityDocumentFailure.malformed }
            keySize = (significant.count - 1) * 8 + (8 - first.leadingZeroBitCount)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = String(bytes: try reader.readString(), encoding: .ascii)
            let point = try reader.readString()
            let expected: (name: String, pointBytes: Int, bits: Int)
            switch algorithm {
            case "ecdsa-sha2-nistp256": expected = ("nistp256", 65, 256)
            case "ecdsa-sha2-nistp384": expected = ("nistp384", 97, 384)
            default: expected = ("nistp521", 133, 521)
            }
            guard curve == expected.name, point.count == expected.pointBytes, point.first == 0x04, reader.isAtEnd else {
                throw SecurityDocumentFailure.malformed
            }
            keySize = expected.bits
        default:
            throw SecurityDocumentFailure.unsupported
        }

        let encodedFingerprint = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        var facts: [StructuredMember] = [
            .init(key: "Algorithm", value: .string(algorithm)),
            .init(key: "Public key size", value: .number(String(keySize))),
            .init(key: "SHA-256 fingerprint", value: .string("SHA256:\(encodedFingerprint)")),
            .init(key: "Trust evaluation", value: .string("Not performed"))
        ]
        if let comment, !comment.isEmpty { facts.append(.init(key: "Comment", value: .string(comment))) }
        return .init(formatID: .sshPublicKey, content: .object(facts),
                     summary: "SSH public-key metadata · SHA-256 fingerprint · trust not evaluated", diagnostics: [])
    }

    private static func inspectMobileProvision(_ data: Data) throws -> SecurityFormatInspection {
        try requireSignedDataCMS(data)
        // CMSDecoderCopyContent extracts encapsulated bytes. Signature-status and trust APIs are never called.
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { throw SecurityDocumentFailure.malformed }
        let updateStatus = data.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return errSecDecode }
            return CMSDecoderUpdateMessage(decoder, baseAddress, rawBuffer.count)
        }
        guard updateStatus == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw SecurityDocumentFailure.malformed
        }
        var cmsContent: CFData?
        guard CMSDecoderCopyContent(decoder, &cmsContent) == errSecSuccess,
              let cmsContent, CFDataGetLength(cmsContent) <= maximumInputBytes else {
            throw SecurityDocumentFailure.malformed
        }
        let plistData = cmsContent as Data
        let plist = try PlistInspector.inspect(bytes: plistData, fileSize: plistData.count)
        guard plist.diagnostics.isEmpty, let root = plist.content, case .dictionary(let members) = root else {
            throw SecurityDocumentFailure.malformed
        }
        let source = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) })
        var facts: [StructuredMember] = []

        for key in ["Name", "AppIDName", "UUID", "Version"] {
            if let value = source[key], let display = boundedScalar(value) {
                facts.append(.init(key: key, value: display))
            }
        }
        for key in ["CreationDate", "ExpirationDate"] {
            if let value = source[key], let display = boundedScalar(value) {
                facts.append(.init(key: key, value: display))
            }
        }
        for key in ["TeamIdentifier", "ApplicationIdentifierPrefix", "Platform"] {
            if let value = source[key], let display = boundedStringArray(value) {
                facts.append(.init(key: key, value: .array(display)))
            }
        }
        if let devices = source["ProvisionedDevices"], case .array(let values) = devices {
            facts.append(.init(key: "Provisioned device count", value: .number(String(min(values.count, 10_000)))))
        }
        if let value = source["ProvisionsAllDevices"], let display = boundedScalar(value) {
            facts.append(.init(key: "Provisions all devices", value: display))
        }
        if let entitlements = source["Entitlements"], let filtered = filteredEntitlements(entitlements) {
            facts.append(.init(key: "Selected entitlements", value: filtered))
        }
        if source["DeveloperCertificates"] != nil {
            facts.append(.init(key: "Developer certificates", value: .string("Certificate data omitted")))
        }
        facts.append(.init(key: "CMS signature verification", value: .string("Not performed")))
        let content = StructuredValue.object(facts)
        return .init(formatID: .mobileprovision, content: content,
                     summary: "Provisioning profile metadata · signature not checked", diagnostics: [])
    }

    private static func inspectJWT(_ data: Data) throws -> SecurityFormatInspection {
        guard data.count <= maximumJWTEncodedSegmentBytes * 2,
              let source = String(data: data, encoding: .ascii) else {
            throw SecurityDocumentFailure.malformed
        }
        let token = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("=") else { throw SecurityDocumentFailure.malformed }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, !segments[0].isEmpty, !segments[1].isEmpty,
              segments.allSatisfy({ $0.utf8.count <= maximumJWTEncodedSegmentBytes }) else {
            throw SecurityDocumentFailure.malformed
        }
        guard let headerData = decodeBase64URL(String(segments[0])),
              let payloadData = decodeBase64URL(String(segments[1])),
              let header = try jsonObject(headerData), let payload = try jsonObject(payloadData),
              segments[2].isEmpty || decodeBase64URL(String(segments[2])) != nil else {
            throw SecurityDocumentFailure.malformed
        }
        let algorithm = objectMember("alg", in: header).flatMap(stringValue) ?? "unspecified"
        let signatureState = segments[2].isEmpty ? "Empty signature segment" : "Present; not verified"
        let content = StructuredValue.object([
            .init(key: "Header", value: header),
            .init(key: "Payload", value: payload),
            .init(key: "Signature", value: .object([
                .init(key: "Algorithm", value: .string(algorithm)),
                .init(key: "Status", value: .string(signatureState)),
                .init(key: "Verification", value: .string("Not performed"))
            ]))
        ])
        return .init(formatID: .jwt, content: content,
                     summary: "JWT · \(algorithm) · unverified", diagnostics: [])
    }

    private static func inspectJWK(_ data: Data, isSet: Bool) throws -> SecurityFormatInspection {
        let parsed = try JSONInspector.inspect(bytes: data, fileSize: data.count)
        guard parsed.diagnostics.isEmpty, let root = parsed.content, !containsDuplicateObjectKeys(root) else {
            throw SecurityDocumentFailure.malformed
        }
        let redacted: StructuredValue
        let keyCount: Int
        if isSet {
            guard let keys = objectMember("keys", in: root), case .array(let values) = keys,
                  !values.isEmpty, values.count <= 256, values.allSatisfy(validJWKKey) else {
                throw SecurityDocumentFailure.unsupported
            }
            redacted = redactJWKTree(root)
            keyCount = values.count
        } else {
            guard case .object = root, validJWKKey(root) else { throw SecurityDocumentFailure.unsupported }
            redacted = redactJWKTree(root)
            keyCount = 1
        }
        let hasPrivateMembers = containsPrivateJWKMember(root)
        let typeSummary: String
        if isSet { typeSummary = "\(keyCount) \(keyCount == 1 ? "key" : "keys")" }
        else { typeSummary = "JWK · \(objectMember("kty", in: root).flatMap(stringValue) ?? "unknown")" }
        let note = hasPrivateMembers ? "Private key members are redacted in Tree" : "Public key metadata"
        return .init(formatID: isSet ? .jwks : .jwk,
                     content: redacted,
                     summary: "\(typeSummary) · \(note)", diagnostics: [])
    }

    private static func inspectSBOM(_ data: Data, formatID: FormatID) throws -> SecurityFormatInspection {
        let parsed = try JSONInspector.inspect(bytes: data, fileSize: data.count)
        guard parsed.diagnostics.isEmpty, let root = parsed.content,
              case .object = root, !containsDuplicateObjectKeys(root) else { throw SecurityDocumentFailure.malformed }
        let summary: String
        switch formatID {
        case .cyclonedxSBOM:
            guard stringValue(objectMember("bomFormat", in: root)) == "CycloneDX",
                  let version = stringValue(objectMember("specVersion", in: root)),
                  ["1.4", "1.5", "1.6", "1.7"].contains(version) else { throw SecurityDocumentFailure.unsupported }
            let components = arrayCount(objectMember("components", in: root))
            summary = "CycloneDX \(version) · \(components) \(components == 1 ? "component" : "components")"
        case .spdxSBOM:
            guard let version = stringValue(objectMember("spdxVersion", in: root)),
                  ["SPDX-2.2", "SPDX-2.3"].contains(version),
                  stringValue(objectMember("SPDXID", in: root)) != nil,
                  stringValue(objectMember("name", in: root)) != nil else { throw SecurityDocumentFailure.unsupported }
            let packages = arrayCount(objectMember("packages", in: root))
            summary = "\(version) · \(packages) \(packages == 1 ? "package" : "packages")"
        default: throw SecurityDocumentFailure.unsupported
        }
        return .init(formatID: formatID, content: root, summary: summary, diagnostics: [])
    }

    private static func inspectCycloneDXXML(_ data: Data, fileSize: Int) throws -> SecurityFormatInspection {
        let parsed = try XMLInspector.inspect(bytes: data, fileSize: fileSize)
        guard parsed.diagnostics.isEmpty, let root = parsed.root,
              case .element(let bom) = root, localXMLName(bom.name) == "bom" else {
            throw SecurityDocumentFailure.malformed
        }
        let namespaceAttribute: String
        if let prefix = bom.name.split(separator: ":").dropLast().last {
            namespaceAttribute = "xmlns:\(prefix)"
        } else {
            namespaceAttribute = "xmlns"
        }
        guard let namespace = bom.attributes.first(where: { $0.name == namespaceAttribute })?.value,
              namespace.hasPrefix("http://cyclonedx.org/schema/bom/"),
              let version = namespace.split(separator: "/").last.map(String.init),
              ["1.4", "1.5", "1.6", "1.7"].contains(version),
              bom.attributes.contains(where: { $0.name == "version" && Int($0.value) != nil }) else {
            throw SecurityDocumentFailure.unsupported
        }
        var components = 0
        for child in bom.children {
            guard case .element(let container) = child, localXMLName(container.name) == "components" else { continue }
            components += container.children.reduce(into: 0) { count, nested in
                if case .element(let component) = nested, localXMLName(component.name) == "component" { count += 1 }
            }
        }
        var budget = 10_000
        guard let content = structuredXML(root, depth: 0, budget: &budget) else {
            throw SecurityDocumentFailure.malformed
        }
        return .init(formatID: .cyclonedxSBOMXML, content: content,
                     summary: "CycloneDX \(version) · \(components) \(components == 1 ? "component" : "components")",
                     diagnostics: [])
    }

    private static func inspectCycloneDXProtobuf(_ data: Data) throws -> SecurityFormatInspection {
        guard let result = CycloneDXProtobufInspector.inspect(data) else {
            throw SecurityDocumentFailure.malformed
        }
        return result
    }

    private static func inspectSPDXTagValue(_ data: Data, fileSize: Int) throws -> SecurityFormatInspection {
        guard fileSize == data.count, fileSize <= maximumInputBytes,
              let source = String(data: data, encoding: .utf8), !source.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SecurityDocumentFailure.malformed
        }
        var records: [(tag: String, value: String)] = []
        for (lineIndex, rawLine) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if lineIndex >= 10_000 { throw SecurityDocumentFailure.unsupported }
            if lineIndex.isMultiple(of: 128) { try Task.checkCancellation() }
            let line = String(rawLine)
            if line.isEmpty || line.first == "#" { continue }
            if line.first == " " || line.first == "\t" {
                guard let prior = records.indices.last else { throw SecurityDocumentFailure.malformed }
                let continuation = String(line.dropFirst())
                guard continuation.utf8.count < maximumInputBytes,
                      records[prior].value.utf8.count <= maximumInputBytes - continuation.utf8.count - 1 else {
                    throw SecurityDocumentFailure.unsupported
                }
                records[prior].value += "\n" + continuation
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw SecurityDocumentFailure.malformed }
            let tag = String(line[..<colon])
            guard isValidSPDXTag(tag) else { throw SecurityDocumentFailure.malformed }
            var valueStart = line.index(after: colon)
            if valueStart < line.endIndex, line[valueStart] == " " { valueStart = line.index(after: valueStart) }
            records.append((tag, String(line[valueStart...])))
            guard records.count <= 3_000 else { throw SecurityDocumentFailure.unsupported }
        }
        guard records.first?.tag == "SPDXVersion",
              let version = records.first(where: { $0.tag == "SPDXVersion" })?.value,
              ["SPDX-2.2", "SPDX-2.3"].contains(version) else { throw SecurityDocumentFailure.unsupported }
        for required in ["DataLicense", "SPDXID", "DocumentName", "DocumentNamespace", "Creator", "Created"] {
            guard records.contains(where: { $0.tag == required && !$0.value.isEmpty }) else {
                throw SecurityDocumentFailure.malformed
            }
        }
        guard records.filter({ $0.tag == "SPDXVersion" }).count == 1 else { throw SecurityDocumentFailure.malformed }
        let packages = records.filter { $0.tag == "PackageName" }.count
        let content = StructuredValue.array(records.map { record in
            .object([
                .init(key: "Tag", value: .string(record.tag)),
                .init(key: "Value", value: .string(record.value))
            ])
        })
        return .init(formatID: .spdxTagValue, content: content,
                     summary: "\(version) Tag-Value · \(packages) \(packages == 1 ? "package" : "packages")",
                     diagnostics: [])
    }

    private static func inspectSPDXYAML(_ data: Data, fileSize: Int) throws -> SecurityFormatInspection {
        let parsed = try YAMLInspector.inspect(bytes: data, fileSize: fileSize, maximumDocuments: 1)
        guard parsed.diagnostics.isEmpty, let documents = parsed.documents, documents.count == 1,
              case .object(let root) = documents[0], uniqueKeys(root),
              let version = stringValue(objectMember("spdxVersion", in: documents[0])),
              ["SPDX-2.2", "SPDX-2.3"].contains(version),
              stringValue(objectMember("dataLicense", in: documents[0])) == "CC0-1.0",
              stringValue(objectMember("SPDXID", in: documents[0])) == "SPDXRef-DOCUMENT",
              nonemptyString(objectMember("name", in: documents[0])),
              nonemptyString(objectMember("documentNamespace", in: documents[0])),
              case .array(let packages)? = objectMember("packages", in: documents[0]),
              packages.allSatisfy({
                  guard case .object(let fields) = $0, uniqueKeys(fields),
                        nonemptyString(objectMember("SPDXID", in: $0)),
                        nonemptyString(objectMember("name", in: $0)) else { return false }
                  return true
              }) else {
            let diagnostic = parsed.diagnostics.first ?? .init(code: .unsupported,
                message: "Unsupported SPDX YAML structure or version. Raw remains available.")
            return .init(formatID: .spdxYAML, content: nil,
                         summary: "Security document metadata unavailable", diagnostics: [diagnostic])
        }
        let packageCount = packages.count
        return .init(formatID: .spdxYAML, content: .object(root),
                     summary: "\(version) YAML · \(packageCount) \(packageCount == 1 ? "package" : "packages")",
                     diagnostics: [])
    }

    private static func nonemptyString(_ value: StructuredValue?) -> Bool {
        guard case .string(let string)? = value else { return false }
        return !string.isEmpty && string.utf8.count <= maximumInputBytes
    }

    private static func uniqueKeys(_ members: [StructuredMember]) -> Bool {
        Set(members.map(\.key)).count == members.count
    }

    private static func isValidSPDXTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.utf8.count <= 128 else { return false }
        for byte in tag.utf8 {
            let valid = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45
            if !valid { return false }
        }
        return true
    }

    private static func localXMLName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name))
    }

    private static func structuredXML(_ node: XMLNode, depth: Int, budget: inout Int) -> StructuredValue? {
        guard depth <= 64, budget > 0 else { return nil }
        budget -= 1
        switch node {
        case .comment: return nil
        case .text(let text):
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : .string(value)
        case .element(let element):
            let attributes = element.attributes.map { StructuredMember(key: $0.name, value: .string($0.value)) }
            var children: [StructuredValue] = []
            for child in element.children {
                guard let value = structuredXML(child, depth: depth + 1, budget: &budget) else {
                    if budget <= 0 { return nil }
                    continue
                }
                children.append(value)
            }
            return .object([
                .init(key: "element", value: .string(element.name)),
                .init(key: "attributes", value: .object(attributes)),
                .init(key: "children", value: .array(children))
            ])
        }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard value.utf8.allSatisfy({
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func jsonObject(_ data: Data) throws -> StructuredValue? {
        let parsed = try JSONInspector.inspect(bytes: data, fileSize: data.count)
        guard parsed.diagnostics.isEmpty, let content = parsed.content,
              case .object = content, !containsDuplicateObjectKeys(content) else { return nil }
        return content
    }

    /// Accepts only a canonical, complete CMS ContentInfo envelope carrying SignedData.
    /// This rejects EnvelopedData before Security.framework could attempt to decrypt it.
    private static func requireSignedDataCMS(_ data: Data) throws {
        guard data.count >= 13, data[data.startIndex] == 0x30 else { throw SecurityDocumentFailure.malformed }
        var cursor = data.startIndex + 1
        let firstLength = data[cursor]
        cursor += 1
        let contentLength: Int
        if firstLength < 0x80 {
            contentLength = Int(firstLength)
        } else {
            let count = Int(firstLength & 0x7f)
            guard count > 0, count <= 4, data.count - cursor >= count, data[cursor] != 0 else {
                throw SecurityDocumentFailure.malformed
            }
            var length = 0
            for _ in 0..<count {
                guard length <= (Int.max >> 8) else { throw SecurityDocumentFailure.malformed }
                length = (length << 8) | Int(data[cursor])
                cursor += 1
            }
            guard length >= 128 else { throw SecurityDocumentFailure.malformed }
            contentLength = length
        }
        guard contentLength == data.count - cursor, data.count - cursor >= 11,
              data[cursor] == 0x06, data[cursor + 1] == 0x09 else { throw SecurityDocumentFailure.malformed }
        let signedDataOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]
        guard Array(data[(cursor + 2)..<(cursor + 11)]) == signedDataOID else {
            throw SecurityDocumentFailure.unsupported
        }
    }

    private static func containsDuplicateObjectKeys(_ value: StructuredValue) -> Bool {
        switch value {
        case .object(let members):
            var keys = Set<String>()
            for member in members where !keys.insert(member.key).inserted || containsDuplicateObjectKeys(member.value) {
                return true
            }
            return false
        case .array(let values): return values.contains(where: containsDuplicateObjectKeys)
        default: return false
        }
    }

    private static func validJWKKey(_ value: StructuredValue) -> Bool {
        guard let type = stringValue(objectMember("kty", in: value)),
              ["RSA", "EC", "OKP", "oct"].contains(type) else { return false }
        if type == "RSA" {
            return stringValue(objectMember("n", in: value)) != nil && stringValue(objectMember("e", in: value)) != nil
        }
        if type == "EC" { return ["crv", "x", "y"].allSatisfy { stringValue(objectMember($0, in: value)) != nil } }
        if type == "OKP" { return ["crv", "x"].allSatisfy { stringValue(objectMember($0, in: value)) != nil } }
        return stringValue(objectMember("k", in: value)) != nil
    }

    private static func redactJWKTree(_ value: StructuredValue, memberName: String? = nil) -> StructuredValue {
        if let memberName, privateJWKMembers.contains(memberName) { return .string("[redacted]") }
        switch value {
        case .object(let members):
            return .object(members.map { .init(key: $0.key, value: redactJWKTree($0.value, memberName: $0.key)) })
        case .array(let values): return .array(values.map { redactJWKTree($0) })
        default: return value
        }
    }

    private static func containsPrivateJWKMember(_ source: StructuredValue) -> Bool {
        func contains(_ value: StructuredValue) -> Bool {
            switch value {
            case .object(let members):
                return members.contains { privateJWKMembers.contains($0.key) || contains($0.value) }
            case .array(let values): return values.contains(where: contains)
            default: return false
            }
        }
        return contains(source)
    }

    private static func objectMember(_ name: String, in value: StructuredValue?) -> StructuredValue? {
        guard case .object(let members) = value else { return nil }
        return members.first { $0.key == name }?.value
    }

    private static func stringValue(_ value: StructuredValue?) -> String? {
        guard case .string(let result) = value else { return nil }
        return result
    }

    private static func arrayCount(_ value: StructuredValue?) -> Int {
        guard case .array(let values) = value else { return 0 }
        return values.count
    }

    private static func boundedScalar(_ value: PlistValue) -> StructuredValue? {
        switch value {
        case .string(let text) where text.utf8.count <= 4_096: return .string(text)
        case .integer(let text) where text.utf8.count <= 64: return .number(text)
        case .real(let number) where number.isFinite: return .number(String(number))
        case .boolean(let flag): return .boolean(flag)
        case .date(let date): return .string(ISO8601DateFormatter().string(from: date))
        default: return nil
        }
    }

    private static func boundedStringArray(_ value: PlistValue) -> [StructuredValue]? {
        guard case .array(let values) = value, values.count <= 64 else { return nil }
        let strings = values.compactMap { boundedScalar($0) }
        guard strings.count == values.count else { return nil }
        return strings
    }

    private static func filteredEntitlements(_ value: PlistValue) -> StructuredValue? {
        guard case .dictionary(let members) = value else { return nil }
        let allowed: Set<String> = [
            "application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups",
            "get-task-allow", "aps-environment", "com.apple.developer.icloud-container-identifiers"
        ]
        let selected = members.filter { allowed.contains($0.key) }.prefix(16).compactMap { member -> StructuredMember? in
            if let scalar = boundedScalar(member.value) { return .init(key: member.key, value: scalar) }
            if let array = boundedStringArray(member.value) { return .init(key: member.key, value: .array(array)) }
            return nil
        }
        return selected.isEmpty ? nil : .object(Array(selected))
    }

    private static func fallback(_ formatID: FormatID, _ code: InspectionDiagnostic.Code,
                                 _ message: String) -> SecurityFormatInspection {
        .init(formatID: formatID, content: nil, summary: "Security document metadata unavailable",
              diagnostics: [.init(code: code, message: message)])
    }
}

private enum SecurityDocumentFailure: Error { case malformed, unsupported }

private enum PKCS7Failure: Error { case malformed, unsupported, truncated, limit }
private enum PKCS12Failure: Error { case malformed, unsupported, entryLimit }

private enum PKCS12Envelope {
    static let dataOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])
    static let encryptedDataOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x06])
}

private struct DERTLV {
    let tag: UInt8
    let start: Int
    let contentStart: Int
    let end: Int
}

private enum DERReadFailure: Error { case malformed, indefiniteLength }

/// Offset-safe definite-length DER framing and canonical primitive checks shared by CMS and PFX.
private enum DERReader {
    static func byte(_ bytes: Data, at offset: Int) -> UInt8 {
        bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
    }

    static func read(_ bytes: Data, cursor: inout Int, limit: Int) throws -> DERTLV {
        guard cursor >= 0, limit <= bytes.count, cursor < limit else { throw DERReadFailure.malformed }
        let start = cursor
        let tag = byte(bytes, at: cursor)
        guard tag & 0x1F != 0x1F else { throw DERReadFailure.malformed }
        cursor += 1
        guard cursor < limit else { throw DERReadFailure.malformed }
        let firstLength = byte(bytes, at: cursor)
        cursor += 1
        if firstLength == 0x80 { throw DERReadFailure.indefiniteLength }
        let length: Int
        if firstLength < 0x80 {
            length = Int(firstLength)
        } else {
            let octets = Int(firstLength & 0x7F)
            guard (1...4).contains(octets), octets <= limit - cursor,
                  byte(bytes, at: cursor) != 0 else { throw DERReadFailure.malformed }
            var decoded = 0
            for _ in 0..<octets {
                guard decoded <= Int.max >> 8 else { throw DERReadFailure.malformed }
                decoded = (decoded << 8) | Int(byte(bytes, at: cursor))
                cursor += 1
            }
            guard decoded >= 128 else { throw DERReadFailure.malformed }
            length = decoded
        }
        guard length <= limit - cursor else { throw DERReadFailure.malformed }
        let contentStart = cursor
        cursor += length
        return DERTLV(tag: tag, start: start, contentStart: contentStart, end: cursor)
    }

    static func encoded(_ bytes: Data, _ tlv: DERTLV) -> Data {
        Data(bytes[bytes.index(bytes.startIndex, offsetBy: tlv.start)..<bytes.index(bytes.startIndex, offsetBy: tlv.end)])
    }

    static func isMinimalInteger(_ bytes: Data, _ tlv: DERTLV) -> Bool {
        let count = tlv.end - tlv.contentStart
        guard count > 0 else { return false }
        guard count > 1 else { return true }
        let first = byte(bytes, at: tlv.contentStart)
        let second = byte(bytes, at: tlv.contentStart + 1)
        if first == 0, second & 0x80 == 0 { return false }
        if first == 0xFF, second & 0x80 != 0 { return false }
        return true
    }

    static func isValidOID(_ bytes: Data, _ tlv: DERTLV) -> Bool {
        guard tlv.contentStart < tlv.end else { return false }
        var atSubidentifierStart = true
        for offset in tlv.contentStart..<tlv.end {
            let value = byte(bytes, at: offset)
            if atSubidentifierStart, value == 0x80 { return false }
            atSubidentifierStart = value & 0x80 == 0
        }
        return atSubidentifierStart
    }
}

private enum PKCS7Envelope {
    static let signedDataOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
    static let dataOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])

    static func certificates(in input: Data, checkpoint: () throws -> Void) throws -> [Data] {
        let bytes = Data(Array(input))
        var cursor = 0
        let outer = try read(bytes, cursor: &cursor, limit: bytes.count)
        guard outer.tag == 0x30 else { throw PKCS7Failure.malformed }
        guard cursor == bytes.count else { throw PKCS7Failure.malformed }
        var outerCursor = outer.contentStart
        try checkpoint()
        let contentType = try read(bytes, cursor: &outerCursor, limit: outer.end)
        guard contentType.tag == 0x06, isValidOID(bytes, contentType) else { throw PKCS7Failure.malformed }
        guard encoded(bytes, contentType) == signedDataOID else { throw PKCS7Failure.unsupported }
        try checkpoint()
        let explicit = try read(bytes, cursor: &outerCursor, limit: outer.end)
        guard explicit.tag == 0xA0 else { throw PKCS7Failure.malformed }
        guard outerCursor == outer.end else { throw PKCS7Failure.malformed }
        var explicitCursor = explicit.contentStart
        try checkpoint()
        let signedData = try read(bytes, cursor: &explicitCursor, limit: explicit.end)
        guard signedData.tag == 0x30, explicitCursor == explicit.end else { throw PKCS7Failure.malformed }
        var cursorInSignedData = signedData.contentStart

        try checkpoint()
        let version = try read(bytes, cursor: &cursorInSignedData, limit: signedData.end)
        guard version.tag == 0x02, version.end - version.contentStart == 1,
              bytes[version.contentStart] == 0x01 else {
            guard version.tag == 0x02, isMinimalInteger(bytes, version) else { throw PKCS7Failure.malformed }
            throw PKCS7Failure.unsupported
        }
        try checkpoint()
        let digestAlgorithms = try read(bytes, cursor: &cursorInSignedData, limit: signedData.end)
        guard digestAlgorithms.tag == 0x31 else { throw PKCS7Failure.malformed }
        if digestAlgorithms.contentStart != digestAlgorithms.end {
            try validateChildren(bytes, start: digestAlgorithms.contentStart, end: digestAlgorithms.end, checkpoint: checkpoint)
            throw PKCS7Failure.unsupported
        }
        try checkpoint()
        let encapsulated = try read(bytes, cursor: &cursorInSignedData, limit: signedData.end)
        guard encapsulated.tag == 0x30 else { throw PKCS7Failure.malformed }
        var encapsulatedCursor = encapsulated.contentStart
        try checkpoint()
        let encapsulatedType = try read(bytes, cursor: &encapsulatedCursor, limit: encapsulated.end)
        guard encapsulatedType.tag == 0x06, isValidOID(bytes, encapsulatedType) else { throw PKCS7Failure.malformed }
        guard encoded(bytes, encapsulatedType) == dataOID else { throw PKCS7Failure.unsupported }
        if encapsulatedCursor != encapsulated.end {
            try validateChildren(bytes, start: encapsulatedCursor, end: encapsulated.end, checkpoint: checkpoint)
            throw PKCS7Failure.unsupported
        }

        try checkpoint()
        let certificateField = try read(bytes, cursor: &cursorInSignedData, limit: signedData.end)
        guard certificateField.tag == 0xA0 else { throw PKCS7Failure.malformed }
        guard certificateField.contentStart != certificateField.end else { throw PKCS7Failure.malformed }
        var memberCursor = certificateField.contentStart
        var certificates: [Data] = []
        certificates.reserveCapacity(16)
        while memberCursor < certificateField.end {
            try checkpoint()
            if certificates.count == 16 { throw PKCS7Failure.limit }
            let start = memberCursor
            let member = try read(bytes, cursor: &memberCursor, limit: certificateField.end)
            guard member.tag == 0x30 else {
                if [0xA0, 0xA1, 0xA2, 0xA3, 0xA4].contains(member.tag) { throw PKCS7Failure.unsupported }
                throw PKCS7Failure.malformed
            }
            certificates.append(bytes.subdata(in: start..<memberCursor))
        }

        try checkpoint()
        let signerInfos = try read(bytes, cursor: &cursorInSignedData, limit: signedData.end)
        if signerInfos.tag == 0xA1 {
            try validateChildren(bytes, start: signerInfos.contentStart, end: signerInfos.end, checkpoint: checkpoint)
            throw PKCS7Failure.unsupported
        }
        guard signerInfos.tag == 0x31 else { throw PKCS7Failure.malformed }
        if signerInfos.contentStart != signerInfos.end {
            try validateChildren(bytes, start: signerInfos.contentStart, end: signerInfos.end, checkpoint: checkpoint)
            throw PKCS7Failure.unsupported
        }
        guard cursorInSignedData == signedData.end else { throw PKCS7Failure.malformed }
        return certificates
    }

    private static func encoded(_ bytes: Data, _ tlv: DERTLV) -> Data { DERReader.encoded(bytes, tlv) }

    private static func isMinimalInteger(_ bytes: Data, _ tlv: DERTLV) -> Bool { DERReader.isMinimalInteger(bytes, tlv) }

    private static func isValidOID(_ bytes: Data, _ tlv: DERTLV) -> Bool { DERReader.isValidOID(bytes, tlv) }

    private static func validateChildren(_ bytes: Data, start: Int, end: Int,
                                         checkpoint: () throws -> Void) throws {
        var cursor = start
        while cursor < end {
            try checkpoint()
            _ = try read(bytes, cursor: &cursor, limit: end)
        }
        guard cursor == end else { throw PKCS7Failure.malformed }
    }

    private static func read(_ bytes: Data, cursor: inout Int, limit: Int) throws -> DERTLV {
        do { return try DERReader.read(bytes, cursor: &cursor, limit: limit) }
        catch DERReadFailure.indefiniteLength { throw PKCS7Failure.unsupported }
        catch { throw PKCS7Failure.malformed }
    }
}

private func decodePKCS7PEM(_ data: Data, checkpoint: () throws -> Void) throws -> Data {
    let bytes = Array(data)
    var lines: [[UInt8]] = []
    var line: [UInt8] = []
    var index = 0
    while index < bytes.count {
        if index.isMultiple(of: 4_096) { try checkpoint() }
        let byte = bytes[index]
        guard byte < 0x80 else { throw PKCS7Failure.malformed }
        if byte == 0x0D {
            guard index + 1 < bytes.count, bytes[index + 1] == 0x0A else { throw PKCS7Failure.malformed }
            lines.append(line); line.removeAll(keepingCapacity: true); index += 2
        } else if byte == 0x0A {
            lines.append(line); line.removeAll(keepingCapacity: true); index += 1
        } else {
            line.append(byte); index += 1
        }
    }
    if !line.isEmpty || data.last != 0x0A { lines.append(line) }

    func horizontalTrim(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        var start = 0, end = bytes.count
        while start < end && (bytes[start] == 0x20 || bytes[start] == 0x09) { start += 1 }
        while end > start && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09) { end -= 1 }
        return bytes[start..<end]
    }
    let begin = Array("-----BEGIN PKCS7-----".utf8)
    let end = Array("-----END PKCS7-----".utf8)
    var beginIndex: Int?
    var endIndex: Int?
    for (lineIndex, bytes) in lines.enumerated() {
        try checkpoint()
        let trimmed = horizontalTrim(bytes)
        if trimmed.elementsEqual(begin) {
            guard beginIndex == nil else { throw PKCS7Failure.malformed }
            beginIndex = lineIndex
        } else if trimmed.elementsEqual(end) {
            guard endIndex == nil else { throw PKCS7Failure.malformed }
            endIndex = lineIndex
        }
    }
    guard let beginIndex, let endIndex, beginIndex < endIndex else { throw PKCS7Failure.malformed }
    for lineIndex in lines.indices where lineIndex < beginIndex || lineIndex > endIndex {
        guard horizontalTrim(lines[lineIndex]).isEmpty else { throw PKCS7Failure.malformed }
    }
    var body: [UInt8] = []
    var bodyScanned = 0
    for bodyLine in lines[(beginIndex + 1)..<endIndex] {
        for byte in bodyLine {
            bodyScanned += 1
            if bodyScanned.isMultiple(of: 4_096) { try checkpoint() }
            if byte == 0x20 || byte == 0x09 { continue }
            guard (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || (0x30...0x39).contains(byte) || byte == 0x2B || byte == 0x2F || byte == 0x3D else {
                throw PKCS7Failure.malformed
            }
            body.append(byte)
        }
    }
    try checkpoint()
    guard !body.isEmpty, let decoded = Data(base64Encoded: String(decoding: body, as: UTF8.self)),
          decoded.base64EncodedString().utf8.elementsEqual(body) else { throw PKCS7Failure.malformed }
    try checkpoint()
    return decoded
}

/// Reads SSH wire-format strings using their bounded, network-order length prefix.
private struct SSHWireReader {
    private let bytes: [UInt8]
    private(set) var cursor = 0

    var isAtEnd: Bool { cursor == bytes.count }

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func readString() throws -> [UInt8] {
        guard cursor <= bytes.count - 4 else { throw SecurityDocumentFailure.malformed }
        let length = Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16
            | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
        cursor += 4
        guard length <= bytes.count - cursor else { throw SecurityDocumentFailure.malformed }
        defer { cursor += length }
        return Array(bytes[cursor..<(cursor + length)])
    }
}
