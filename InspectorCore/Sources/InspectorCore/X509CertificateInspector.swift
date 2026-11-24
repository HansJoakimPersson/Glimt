import CryptoKit
import Foundation
import Security

/// The encoding family used for an X.509 certificate input.
public enum X509CertificateEncoding: Equatable, Sendable {
    case pem
    case der
}

/// Display facts parsed locally by Security. These facts do not assert certificate trust or validity.
public struct X509CertificateFacts: Equatable, Sendable {
    public let subjectSummary: String
    public let issuerSummary: String?
    public let serialNumberHex: String
    public let notBefore: Date?
    public let notAfter: Date?
    public let sha256Fingerprint: String
    public let publicKeyAlgorithm: String?
    public let publicKeySize: Int?
}

/// One or more parsed certificates from a PEM bundle, or one DER certificate.
public struct X509CertificateInspection: Equatable, Sendable {
    public let certificates: [X509CertificateFacts]

    init(certificates: [X509CertificateFacts]) { self.certificates = certificates }
}

/// Typed rejection reasons for bounded, local X.509 parsing.
public enum X509CertificateError: Error, Equatable, Sendable {
    case invalidFileSize
    case incompleteInput
    case inputLimitExceeded
    case malformedPEM
    case malformedDER
    case certificateCountLimitExceeded
    case cancelled
}

/// Inspects certificate metadata with Apple's Security framework without evaluating trust.
public enum X509CertificateInspector {
    public static let maximumInputBytes = 1_048_576
    public static let maximumCertificates = 16

    /// Parses complete PEM or DER input into certificate facts. Private-key PEM labels are rejected.
    public static func inspect(data: Data, fileSize: Int, encoding: X509CertificateEncoding,
                               isCancelled: @escaping () -> Bool = { false }) throws(X509CertificateError) -> X509CertificateInspection {
        func checkpoint() throws(X509CertificateError) {
            if Task.isCancelled || isCancelled() { throw .cancelled }
        }
        try checkpoint()
        guard fileSize >= 0, data.count <= fileSize else { throw .invalidFileSize }
        guard data.count <= maximumInputBytes, fileSize <= maximumInputBytes else { throw .inputLimitExceeded }
        guard data.count == fileSize else { throw .incompleteInput }
        guard !data.isEmpty else {
            throw encoding == .pem ? .malformedPEM : .malformedDER
        }

        let derCertificates: [Data]
        switch encoding {
        case .der:
            derCertificates = [data]
        case .pem:
            derCertificates = try pemCertificates(data, checkpoint: checkpoint)
        }
        guard !derCertificates.isEmpty, derCertificates.count <= maximumCertificates else {
            throw .certificateCountLimitExceeded
        }

        var facts: [X509CertificateFacts] = []
        facts.reserveCapacity(derCertificates.count)
        for der in derCertificates {
            try checkpoint()
            guard hasSingleDERSequence(der),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw encoding == .pem ? .malformedPEM : .malformedDER
            }
            facts.append(certificateFacts(certificate, der: der))
            try checkpoint()
        }
        try checkpoint()
        return X509CertificateInspection(certificates: facts)
    }

    private static func pemCertificates(_ data: Data,
                                        checkpoint: () throws(X509CertificateError) -> Void) throws(X509CertificateError) -> [Data] {
        guard let text = String(data: data, encoding: .ascii) else { throw .malformedPEM }
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var cursor = text.startIndex
        var result: [Data] = []

        func skipWhitespace() {
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
        }

        skipWhitespace()
        while cursor < text.endIndex {
            try checkpoint()
            guard text[cursor...].hasPrefix(begin) else { throw .malformedPEM }
            cursor = text.index(cursor, offsetBy: begin.count)
            guard let endRange = text.range(of: end, range: cursor..<text.endIndex) else { throw .malformedPEM }
            let body = text[cursor..<endRange.lowerBound]
            var base64 = String()
            base64.reserveCapacity(body.utf8.count)
            var scalarCount = 0
            for scalar in body.unicodeScalars {
                scalarCount += 1
                if scalarCount.isMultiple(of: 1_024) { try checkpoint() }
                if scalar.properties.isWhitespace { continue }
                guard scalar.isASCII,
                      (scalar.value >= 65 && scalar.value <= 90)
                        || (scalar.value >= 97 && scalar.value <= 122)
                        || (scalar.value >= 48 && scalar.value <= 57)
                        || scalar == "+" || scalar == "/" || scalar == "=" else {
                    throw .malformedPEM
                }
                base64.append(String(scalar))
            }
            guard !base64.isEmpty, let der = Data(base64Encoded: base64) else { throw .malformedPEM }
            result.append(der)
            guard result.count <= maximumCertificates else { throw .certificateCountLimitExceeded }
            cursor = endRange.upperBound
            skipWhitespace()
        }
        return result
    }

    private static func hasSingleDERSequence(_ data: Data) -> Bool {
        guard data.count >= 2, data[data.startIndex] == 0x30 else { return false }
        let firstLength = data[data.index(after: data.startIndex)]
        if firstLength < 0x80 { return Int(firstLength) == data.count - 2 }
        let lengthByteCount = Int(firstLength & 0x7F)
        guard (1...4).contains(lengthByteCount), data.count >= 2 + lengthByteCount else { return false }
        let lengthStart = data.index(data.startIndex, offsetBy: 2)
        guard data[lengthStart] != 0 else { return false }
        var contentLength = 0
        for index in 0..<lengthByteCount {
            let byte = data[data.index(lengthStart, offsetBy: index)]
            let (shifted, overflow) = contentLength.multipliedReportingOverflow(by: 256)
            guard !overflow else { return false }
            let (combined, addOverflow) = shifted.addingReportingOverflow(Int(byte))
            guard !addOverflow else { return false }
            contentLength = combined
        }
        guard contentLength >= 128 else { return false }
        let headerLength = 2 + lengthByteCount
        let (totalLength, overflow) = headerLength.addingReportingOverflow(contentLength)
        return !overflow && totalLength == data.count
    }

    private static func certificateFacts(_ certificate: SecCertificate, der: Data) -> X509CertificateFacts {
        let summary = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "X.509 certificate"
        let issuerName = certificateName(certificate, oid: kSecOIDX509V1IssuerName)
        let serialData = SecCertificateCopySerialNumberData(certificate, nil) as Data?
        let serial = serialData.map(hexString) ?? ""
        let notBefore = SecCertificateCopyNotValidBeforeDate(certificate) as Date?
        let notAfter = SecCertificateCopyNotValidAfterDate(certificate) as Date?
        let digest = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        let key = SecCertificateCopyKey(certificate)
        let keyAttributes = key.flatMap { SecKeyCopyAttributes($0) as? [String: Any] }
        let keyType = keyAttributes?[kSecAttrKeyType as String] as? String
        let algorithm: String?
        if keyType == (kSecAttrKeyTypeRSA as String) { algorithm = "RSA" }
        else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) { algorithm = "EC" }
        else { algorithm = keyType }
        let keySize = keyAttributes?[kSecAttrKeySizeInBits as String] as? Int
        return X509CertificateFacts(subjectSummary: summary, issuerSummary: issuerName,
                                    serialNumberHex: serial, notBefore: notBefore, notAfter: notAfter,
                                    sha256Fingerprint: digest, publicKeyAlgorithm: algorithm,
                                    publicKeySize: keySize)
    }

    private static func certificateName(_ certificate: SecCertificate, oid: CFString) -> String? {
        var error: Unmanaged<CFError>?
        let keys = [oid] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, &error) as? [String: Any],
              let property = values[oid as String] as? [String: Any],
              let value = property[kSecPropertyKeyValue as String] else { return nil }
        return displayValue(value)
    }

    private static func displayValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let rows = value as? [[String: Any]] {
            let parts = rows.compactMap { row -> String? in
                let label = row[kSecPropertyKeyLabel as String] as? String
                let nested = row[kSecPropertyKeyValue as String].flatMap(displayValue)
                guard let nested else { return nil }
                return label.map { "\($0)=\(nested)" } ?? nested
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        return nil
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
