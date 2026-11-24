import CryptoKit
import Foundation
import XCTest
@testable import InspectorCore

final class X509CertificateInspectorTests: XCTestCase {
    func testPublicCertificateFixturesProduceMatchingPEMAndDERFacts() throws {
        let pemURL = try fixtureURL("Cases/security/certificate.pem")
        let derURL = try fixtureURL("Cases/security/certificate.der")
        let pem = try Data(contentsOf: pemURL)
        let der = try Data(contentsOf: derURL)
        let pemResult = try X509CertificateInspector.inspect(data: pem, fileSize: pem.count, encoding: .pem)
        let derResult = try X509CertificateInspector.inspect(data: der, fileSize: der.count, encoding: .der)

        XCTAssertEqual(pemResult.certificates.count, 1)
        XCTAssertEqual(derResult.certificates.count, 1)
        XCTAssertEqual(pemResult.certificates.first?.subjectSummary, "Glimt Test Fixture")
        XCTAssertEqual(pemResult.certificates.first?.serialNumberHex, derResult.certificates.first?.serialNumberHex)
        XCTAssertEqual(pemResult.certificates.first?.sha256Fingerprint, derResult.certificates.first?.sha256Fingerprint)
        XCTAssertEqual(pemResult.certificates.first?.sha256Fingerprint,
                       SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined())
        XCTAssertNotNil(pemResult.certificates.first?.issuerSummary)
        XCTAssertNotNil(pemResult.certificates.first?.notBefore)
        XCTAssertNotNil(pemResult.certificates.first?.notAfter)
    }

    func testPEMBundleRetainsOrderAndRejectsPrivateKeyBlocks() throws {
        let pem = try Data(contentsOf: fixtureURL("Cases/security/certificate.pem"))
        let bundled = pem + Data("\n".utf8) + pem
        let result = try X509CertificateInspector.inspect(data: bundled, fileSize: bundled.count, encoding: .pem)
        XCTAssertEqual(result.certificates.count, 2)
        let privateKey = Data("-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n".utf8)
        XCTAssertThrowsError(try X509CertificateInspector.inspect(
            data: privateKey, fileSize: privateKey.count, encoding: .pem)) {
                XCTAssertEqual($0 as? X509CertificateError, .malformedPEM)
            }
    }

    func testRejectsMalformedAndIncompleteInputsWithTypedErrors() throws {
        let malformedPEM = Data("-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----".utf8)
        XCTAssertThrowsError(try X509CertificateInspector.inspect(data: malformedPEM, fileSize: malformedPEM.count, encoding: .pem)) {
            XCTAssertEqual($0 as? X509CertificateError, .malformedPEM)
        }
        let malformedDER = Data([0x30, 0x03, 0x01, 0x01, 0x00])
        XCTAssertThrowsError(try X509CertificateInspector.inspect(data: malformedDER, fileSize: malformedDER.count, encoding: .der)) {
            XCTAssertEqual($0 as? X509CertificateError, .malformedDER)
        }
        var trailingDER = try Data(contentsOf: fixtureURL("Cases/security/certificate.der"))
        trailingDER.append(0)
        XCTAssertThrowsError(try X509CertificateInspector.inspect(data: trailingDER, fileSize: trailingDER.count, encoding: .der)) {
            XCTAssertEqual($0 as? X509CertificateError, .malformedDER)
        }
        XCTAssertThrowsError(try X509CertificateInspector.inspect(data: malformedDER, fileSize: malformedDER.count + 1, encoding: .der)) {
            XCTAssertEqual($0 as? X509CertificateError, .incompleteInput)
        }
    }

    func testProbeAndTaskCancellationAreTyped() async throws {
        let der = try Data(contentsOf: fixtureURL("Cases/security/certificate.der"))
        XCTAssertThrowsError(try X509CertificateInspector.inspect(data: der, fileSize: der.count,
            encoding: .der, isCancelled: { true })) {
                XCTAssertEqual($0 as? X509CertificateError, .cancelled)
            }

        let cancelled = await runCancelled {
            try X509CertificateInspector.inspect(data: der, fileSize: der.count, encoding: .der)
        }
        XCTAssertThrowsError(try cancelled.get()) { XCTAssertEqual($0 as? X509CertificateError, .cancelled) }
    }

    func testEnforcesInputAndCertificateCountBoundsBeforePublishing() throws {
        let oversized = Data(repeating: 0, count: X509CertificateInspector.maximumInputBytes + 1)
        XCTAssertThrowsError(try X509CertificateInspector.inspect(data: oversized, fileSize: oversized.count, encoding: .der)) {
            XCTAssertEqual($0 as? X509CertificateError, .inputLimitExceeded)
        }
        let pem = try Data(contentsOf: fixtureURL("Cases/security/certificate.pem"))
        let bundle = (0...X509CertificateInspector.maximumCertificates).reduce(into: Data()) { value, _ in
            value.append(pem)
            value.append(0x0A)
        }
        XCTAssertThrowsError(try X509CertificateInspector.inspect(data: bundle, fileSize: bundle.count, encoding: .pem)) {
            XCTAssertEqual($0 as? X509CertificateError, .certificateCountLimitExceeded)
        }
    }

    func testSharedPreviewRoutesBothCertificateEncodingsAndRetainsBytes() throws {
        for (path, id) in [("Showcase/security/certificate.pem", FormatID.pemCertificate),
                           ("Showcase/security/certificate.der", FormatID.derCertificate)] {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                                                         fileName: (path as NSString).lastPathComponent,
                                                         systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id, id, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
            XCTAssertEqual(result.additionalInspection?.certificateInspection?.certificates.count, 1, path)
            XCTAssertNotNil(result.additionalStructuredContent, path)
        }
    }

}
