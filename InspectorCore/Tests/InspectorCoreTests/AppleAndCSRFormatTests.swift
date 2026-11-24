import Foundation
import CryptoKit
import XCTest
@testable import InspectorCore

final class AppleAndCSRFormatTests: XCTestCase {
    func testAppleCatalogFormatsKeepDistinctIdentityAndUseBoundedSharedInspectors() throws {
        let cases: [(String, String, String)] = [
            ("Showcase/apple/Localizable.strings", "Localizable.strings", "strings"),
            ("Showcase/apple/Localizable.stringsdict", "Localizable.stringsdict", "stringsdict"),
            ("Showcase/apple/Localizable.xcstrings", "Localizable.xcstrings", "xcstrings"),
            ("Showcase/apple/Glimt.xcscheme", "Glimt.xcscheme", "xcscheme")
        ]

        for (path, filename, expectedID) in cases {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            let format = try XCTUnwrap(FormatCatalog.definition(for: FormatID(rawValue: expectedID)))

            XCTAssertEqual(format.status, .supported, filename)
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, format.id, filename)
            XCTAssertEqual(result.formatDefinition?.id, format.id, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
            XCTAssertFalse(result.analysis.isBinary, filename)
            XCTAssertFalse(result.statusSummary.items.contains { $0.kind == .warning }, filename)

            switch expectedID {
            case "strings", "stringsdict": XCTAssertNotNil(result.plistInspection?.content, filename)
            case "xcstrings": XCTAssertNotNil(result.jsonInspection?.content, filename)
            case "xcscheme": XCTAssertNotNil(result.xmlInspection?.root, filename)
            default: XCTFail("Unexpected fixture ID: \(expectedID)")
            }
        }
    }

    func testMalformedAppleFormatFixturesKeepIdentityAndOriginalText() throws {
        for (path, filename, expectedID) in [
            ("Cases/requested-formats/invalid/localizable.strings", "Localizable.strings", "strings"),
            ("Cases/requested-formats/invalid/localizable.stringsdict", "Localizable.stringsdict", "stringsdict"),
            ("Cases/catalog/invalid/Localizable.xcstrings", "Localizable.xcstrings", "xcstrings"),
            ("Cases/requested-formats/invalid/sample.xcscheme", "sample.xcscheme", "xcscheme")
        ] {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: filename, systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id.rawValue, expectedID, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
            XCTAssertTrue(result.statusSummary.items.contains { $0.kind == .warning }, path)
        }
    }

    func testCSRShowsOnlyBoundedRequestMetadataWithoutVerifyingOrImportingKey() throws {
        let url = try fixtureURL("Showcase/security/request.csr")
        let bytes = try Data(contentsOf: url)
        let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
        let inspection = try XCTUnwrap(result.additionalInspection?.securityInspection)
        let content = try XCTUnwrap(inspection.content)
        let description = String(describing: content)

        XCTAssertEqual(FormatCatalog.match(fileName: "request.csr")?.id.rawValue, "csr")
        XCTAssertEqual(result.formatDefinition?.id.rawValue, "csr")
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertTrue(description.contains("Public key algorithm"))
        XCTAssertTrue(description.contains("Public key size"))
        XCTAssertTrue(description.contains("Signature verification"))
        XCTAssertTrue(description.contains("Not performed"))
        XCTAssertFalse(inspection.summary.localizedCaseInsensitiveContains("verified"))

        let pem = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        let encoded = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: encoded))
        let derInspection = try SecurityFormatInspector.inspect(data: der, fileSize: der.count, formatID: .csr)
        XCTAssertNotNil(derInspection.content)
    }

    func testMalformedTruncatedAndOversizedCSRRetainRawWithoutPartialFacts() throws {
        for filename in ["malformed.csr", "truncated.csr"] {
            let bytes = try Data(contentsOf: fixtureURL("Cases/security/invalid/\(filename)"))
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .csr)
            XCTAssertNil(result.content, filename)
            XCTAssertFalse(result.diagnostics.isEmpty, filename)
        }

        let complete = try Data(contentsOf: fixtureURL("Showcase/security/request.csr"))
        let truncated = try SecurityFormatInspector.inspect(data: complete, fileSize: complete.count + 1, formatID: .csr)
        XCTAssertNil(truncated.content)
        XCTAssertEqual(truncated.diagnostics.first?.code, .truncated)

        let oversized = Data(repeating: 0x41, count: SecurityFormatInspector.maximumInputBytes + 1)
        let limited = try SecurityFormatInspector.inspect(data: oversized, fileSize: oversized.count, formatID: .csr)
        XCTAssertNil(limited.content)
        XCTAssertEqual(limited.diagnostics.first?.code, .limitExceeded)

        let malformedDER = Data([0x30, 0x82, 0xFF])
        let invalid = try SecurityFormatInspector.inspect(data: malformedDER, fileSize: malformedDER.count, formatID: .csr)
        XCTAssertNil(invalid.content)
        XCTAssertEqual(invalid.diagnostics.first?.code, .parseError)
    }

    func testPKCS12CertificateOnlyFixtureAndEnvelopeFacts() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/security/certificate-only.p12"))
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count,
                                                          formatID: FormatID(rawValue: "pkcs12"))
        let content = try XCTUnwrap(result.content)
        XCTAssertEqual(result.summary, "1 envelope")
        XCTAssertEqual(result.formatID.rawValue, "pkcs12")
        XCTAssertEqual(content, .object([
            .init(key: "Version", value: .number("3")),
            .init(key: "Envelope count", value: .number("1")),
            .init(key: "Envelope kinds", value: .array([.string("encryptedData")])),
            .init(key: "MacData present", value: .boolean(true))
        ]))

        let showcase = try XCTUnwrap(FormatCatalog.definition(for: FormatID(rawValue: "pkcs12"))?.showcaseFixture)
        XCTAssertEqual(try Data(contentsOf: fixtureURL(showcase)), bytes)
    }

    func testPKCS12RealReferenceOracle() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repositoryRoot.deleteLastPathComponent() }
        let url = repositoryRoot.appendingPathComponent("docs/plans/.runs/2026-11-23-pkcs12/real-certificate-only.pfx")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Stage the independent PKCS#12 export in the run directory to check the reference oracle")
        }
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 1_115)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "66804c9cccf04dbaf60f3932f57e7972da425b32c454d184e9e7405217d92de4")
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .pkcs12)
        XCTAssertEqual(result.summary, "1 envelope")
        XCTAssertEqual(result.content, .object([
            .init(key: "Version", value: .number("3")),
            .init(key: "Envelope count", value: .number("1")),
            .init(key: "Envelope kinds", value: .array([.string("encryptedData")])),
            .init(key: "MacData present", value: .boolean(true))
        ]))
    }

    func testPKCS12EnvelopeOrderDuplicatesAndOpaquePayloads() throws {
        let bytes = pfx(envelopes: [(.data, Data()), (.encryptedData, Data([0x00, 0xFF])),
                                    (.data, Data("opaque".utf8)), (.data, Data("opaque".utf8))], macData: false)
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count,
                                                          formatID: FormatID(rawValue: "pkcs12"))
        XCTAssertEqual(result.summary, "4 envelopes")
        XCTAssertEqual(result.content, .object([
            .init(key: "Version", value: .number("3")),
            .init(key: "Envelope count", value: .number("4")),
            .init(key: "Envelope kinds", value: .array([.string("data"), .string("encryptedData"),
                                                          .string("data"), .string("data")])),
            .init(key: "MacData present", value: .boolean(false))
        ]))
    }

    func testPKCS12AllowsZeroThroughSixteenEntriesAndLimitsSeventeenthBeforeReadingIt() throws {
        for count in [0, 1, 16] {
            let bytes = pfx(envelopes: Array(repeating: (.data, Data()), count: count), macData: false)
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .pkcs12)
            XCTAssertEqual(result.content == nil, false, "\(count) entries")
            XCTAssertEqual(result.summary, count == 1 ? "1 envelope" : "\(count) envelopes")
        }
        let seventeen = pfx(envelopes: Array(repeating: (.data, Data()), count: 17), macData: false)
        var accepted: [Int] = []
        let limited = try SecurityFormatInspector.inspectPKCS12(data: seventeen, fileSize: seventeen.count,
            isCancelled: { false }, onAcceptedEntry: { accepted.append($0) })
        XCTAssertEqual(accepted, Array(1...16))
        XCTAssertNil(limited.content)
        XCTAssertEqual(limited.diagnostics.first?.code, .limitExceeded)
    }

    func testPKCS12CancellationOrdering() throws {
        let bytes = pfx(envelopes: [(.data, Data()), (.data, Data())], macData: true)
        var cancelled = false
        var accepted: [Int] = []
        XCTAssertThrowsError(try SecurityFormatInspector.inspectPKCS12(data: bytes, fileSize: bytes.count,
            isCancelled: { cancelled }, onAcceptedEntry: { count in
                accepted.append(count)
                cancelled = true
            }))
        XCTAssertEqual(accepted, [1])
        XCTAssertThrowsError(try SecurityFormatInspector.inspectPKCS12(data: bytes, fileSize: bytes.count,
            isCancelled: { true }, onAcceptedEntry: { _ in }))

        let seventeen = pfx(envelopes: Array(repeating: (.data, Data()), count: 17), macData: false)
        cancelled = false
        accepted.removeAll()
        XCTAssertThrowsError(try SecurityFormatInspector.inspectPKCS12(data: seventeen, fileSize: seventeen.count,
            isCancelled: { cancelled }, onAcceptedEntry: { count in
                accepted.append(count)
                if count == 16 { cancelled = true }
            }))
        XCTAssertEqual(accepted, Array(1...16))
    }

    func testPKCS12MacDataIterationCanonicalityAndLargeValues() throws {
        for iteration in [Data([0x01]), Data([0x00]), Data([0x80]), Data([0x00, 0x01])] {
            let bytes = pfx(envelopes: [], macData: true, macIteration: iteration)
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .pkcs12)
            XCTAssertNil(result.content, iteration.map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(result.diagnostics.first?.code, .parseError)
        }
        for iteration in [nil, Data([0x02]), Data([0x00, 0x80]), Data([0x00] + Array(repeating: 0xFF, count: 16))] {
            let bytes = pfx(envelopes: [], macData: true, macIteration: iteration)
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .pkcs12)
            XCTAssertNotNil(result.content, iteration?.description ?? "omitted")
        }
    }

    func testPKCS12PEMMarkerAndSlicedDataClassification() throws {
        for prefix in ["-----BEGIN ", " \t\r\n-----BEGIN ", "\u{FEFF}-----BEGIN "] {
            let bytes = Data((prefix + "anything\nnot parsed").utf8)
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .pkcs12)
            XCTAssertEqual(result.diagnostics.first?.code, .unsupported)
        }
        for prefix in ["-----END ", "pem ", "x"] {
            let bytes = Data((prefix + "-----BEGIN X-----").utf8)
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .pkcs12)
            XCTAssertEqual(result.diagnostics.first?.code, .parseError)
        }
        let valid = pfx(envelopes: [(.data, Data())], macData: false)
        var storage = Data([0x55, 0x66]) + valid + Data([0x77])
        let slice = storage[2..<(2 + valid.count)]
        let result = try SecurityFormatInspector.inspect(data: slice, fileSize: valid.count, formatID: .pkcs12)
        XCTAssertNotNil(result.content)
        storage.removeAll()
    }

    func testPKCS12RejectsMalformedAndUnsupportedStructuresWithoutPartialFacts() throws {
        let valid = pfx(envelopes: [(.data, Data())], macData: true)
        let malformed = [Data(valid.dropLast()), Data([0x30, 0x80, 0x00, 0x00]),
                         pfx(version: 2, envelopes: [(.data, Data())], macData: false),
                         pfx(envelopes: [(.unknown, Data())], macData: false)]
        for input in malformed {
            let result = try SecurityFormatInspector.inspect(data: input, fileSize: input.count,
                                                              formatID: FormatID(rawValue: "pkcs12"))
            XCTAssertNil(result.content)
            XCTAssertFalse(result.diagnostics.isEmpty)
        }
        let alternateVersion = pfx(version: 4, envelopes: [(.data, Data())], macData: false)
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: alternateVersion, fileSize: alternateVersion.count,
            formatID: FormatID(rawValue: "pkcs12")).diagnostics.first?.code, .unsupported)
        let malformedEOC = Data([0x30, 0x05, 0x02, 0x01, 0x03, 0x00, 0x80])
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: malformedEOC, fileSize: malformedEOC.count,
            formatID: .pkcs12).diagnostics.first?.code, .parseError)
        let trailing = valid + Data([0x05, 0x00])
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: trailing, fileSize: trailing.count,
            formatID: .pkcs12).diagnostics.first?.code, .parseError)
        let truncated = try SecurityFormatInspector.inspect(data: valid, fileSize: valid.count + 1,
            formatID: FormatID(rawValue: "pkcs12"))
        XCTAssertEqual(truncated.diagnostics.first?.code, .truncated)
    }

    func testPKCS12CatalogSuffixRoutingAndUTIRejection() throws {
        let formatID = FormatID(rawValue: "pkcs12")
        let definition = try XCTUnwrap(FormatCatalog.definition(for: formatID))
        XCTAssertEqual(definition.status, .supported)
        XCTAssertEqual(definition.extensions, ["p12", "pfx"])
        XCTAssertEqual(definition.contentTypeIdentifiers, ["com.rsa.pkcs-12"])
        XCTAssertEqual(definition.effectiveInspectorID, .security)
        XCTAssertEqual(definition.effectiveSettingsProfile, .structured)
        XCTAssertEqual(definition.availableRepresentations, [.tree, .hex])
        XCTAssertEqual(definition.defaultViews, [.tree])

        let bytes = pfx(envelopes: [(.data, Data())], macData: false)
        for name in ["sample.p12", "sample.P12", "sample.pfx", "sample.PFX"] {
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: name, systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id, formatID, name)
            XCTAssertEqual(result.additionalInspection?.securityInspection?.summary, "1 envelope", name)
        }
        for name in ["sample", "sample.bin"] {
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: name, systemUTI: "com.rsa.pkcs-12")
            XCTAssertNotEqual(result.formatDefinition?.id, formatID, name)
        }

        for name in ["sample.p12", "sample.PFX"] {
            let matchingOverride = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: name, systemUTI: nil, formatOverride: .security(.pkcs12))
            XCTAssertEqual(matchingOverride.selectedFormatID, .pkcs12)
            XCTAssertEqual(matchingOverride.detectionReason, "userOverride")
        }
        let unrelatedTextOverride = PreviewInspectionResult.prepare(bytes: Data("ordinary text".utf8), fileSize: 13,
            fileName: "notes.txt", systemUTI: nil, formatOverride: .security(.pkcs12))
        XCTAssertNil(unrelatedTextOverride.selectedFormatID)
        XCTAssertEqual(unrelatedTextOverride.detectionReason, "invalidOverride")
        XCTAssertEqual(unrelatedTextOverride.formatName, "Binary data")
        let unrelatedBinaryOverride = PreviewInspectionResult.prepare(bytes: Data([0, 0xFF]), fileSize: 2,
            fileName: "blob.bin", systemUTI: nil, formatOverride: .security(.pkcs12))
        XCTAssertNil(unrelatedBinaryOverride.selectedFormatID)
        XCTAssertEqual(unrelatedBinaryOverride.detectionReason, "userOverride")
        XCTAssertEqual(unrelatedBinaryOverride.formatName, "Binary data")

        let sqlite = Data("SQLite format 3\0".utf8)
        let conflictingSQLite = PreviewInspectionResult.prepare(bytes: sqlite, fileSize: sqlite.count,
            fileName: "store.p12", systemUTI: nil)
        XCTAssertEqual(conflictingSQLite.selectedFormatID, .pkcs12)
        XCTAssertEqual(conflictingSQLite.detectionReason, "fileExtension")
        let tar = Data(repeating: 0, count: 512)
        let conflictingTAR = PreviewInspectionResult.prepare(bytes: tar, fileSize: tar.count,
            fileName: "archive.pfx", systemUTI: nil)
        XCTAssertEqual(conflictingTAR.selectedFormatID, .pkcs12)
        XCTAssertEqual(conflictingTAR.detectionReason, "fileExtension")

        let pkcs7Bytes = try Data(contentsOf: fixtureURL("Cases/security/bundle.p7b"))
        let pkcs7Override = PreviewInspectionResult.prepare(bytes: pkcs7Bytes, fileSize: pkcs7Bytes.count,
            fileName: "bundle.data", systemUTI: nil, formatOverride: .security(.pkcs7))
        XCTAssertEqual(pkcs7Override.selectedFormatID, .pkcs7)
    }

    private enum PFXEnvelopeKind { case data, encryptedData, unknown }

    private func pfx(version: UInt8 = 3, envelopes: [(PFXEnvelopeKind, Data)], macData: Bool,
                     macIteration: Data? = Data([0x02])) -> Data {
        let safe = testTLV(0x30, envelopes.reduce(into: Data()) { output, item in
            let oid: Data
            let payloadTag: UInt8
            switch item.0 {
            case .data:
                oid = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]); payloadTag = 0x04
            case .encryptedData:
                oid = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x06]); payloadTag = 0x30
            case .unknown:
                oid = Data([0x2A, 0x03]); payloadTag = 0x04
            }
            let contentInfo = testTLV(0x30, testTLV(0x06, oid) + testTLV(0xA0, testTLV(payloadTag, item.1)))
            output.append(contentInfo)
        })
        let dataContentInfo = testTLV(0x30, testTLV(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]))
            + testTLV(0xA0, testTLV(0x04, safe)))
        var fields = testTLV(0x02, Data([version])) + dataContentInfo
        if macData {
            let algorithm = testTLV(0x30, testTLV(0x06, Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]))
                + Data([0x05, 0x00]))
            let digestInfo = testTLV(0x30, algorithm + testTLV(0x04, Data(repeating: 0xA5, count: 32)))
            var macFields = digestInfo + testTLV(0x04, Data([0x01, 0x02, 0x03]))
            if let macIteration { macFields.append(testTLV(0x02, macIteration)) }
            fields.append(testTLV(0x30, macFields))
        }
        return testTLV(0x30, fields)
    }

    func testPKCS7CertificateOnlyBundleAndStrictPEMAdmission() throws {
        let certificate = try Data(contentsOf: fixtureURL("Cases/security/certificate.der"))
        let bundle = pkcs7([certificate])
        let result = try SecurityFormatInspector.inspect(data: bundle, fileSize: bundle.count, formatID: .pkcs7)
        let content = try XCTUnwrap(result.content)
        XCTAssertEqual(result.summary, "1 certificate")
        XCTAssertTrue(String(describing: content).contains("Trust and signatures were not checked."))
        XCTAssertTrue(String(describing: content).contains("SHA-256 fingerprint"))
        XCTAssertEqual(try Data(contentsOf: fixtureURL(try XCTUnwrap(FormatCatalog.definition(for: .pkcs7)?.showcaseFixture))),
                       try Data(contentsOf: fixtureURL("Cases/security/bundle.p7b")))

        let encoded = bundle.base64EncodedString()
        let pem = Data("  -----BEGIN PKCS7-----\r\n\t\(encoded.prefix(40)) \t\(encoded.dropFirst(40))\r\n-----END PKCS7-----  \n".utf8)
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: pem, fileSize: pem.count, formatID: .pkcs7).summary,
                       "1 certificate")
        for invalid in [Data(), Data("-----BEGIN PKCS7-----\n\(encoded)\n-----END PKCS7----\n".utf8),
                        Data("\u{FEFF}-----BEGIN PKCS7-----\n\(encoded)\n-----END PKCS7-----".utf8)] {
            let rejected = try SecurityFormatInspector.inspect(data: invalid, fileSize: invalid.count, formatID: .pkcs7)
            XCTAssertNil(rejected.content)
            XCTAssertEqual(rejected.diagnostics.first?.code, .parseError)
        }
    }

    func testPKCS7WireOrderDuplicatesMemberCeilingAndAllOrNothingFacts() throws {
        let first = try Data(contentsOf: fixtureURL("Cases/security/certificate.der"))
        let second = try Data(contentsOf: fixtureURL("Cases/security/pkcs7/certificate-2.der"))
        let firstFingerprint = "0B14835CC5FCE61FB8B7AD9F4C09E9861571B4F02329B8D657C678AD681E2780"
        let secondFingerprint = "063E4AFAC491DFD332F3089B8542E94617D893D7FE944E10A7937EE29D9693C0"

        let forward = try SecurityFormatInspector.inspect(data: pkcs7([first, second]),
            fileSize: pkcs7([first, second]).count, formatID: .pkcs7)
        let forwardText = String(describing: try XCTUnwrap(forward.content))
        XCTAssertEqual(forward.summary, "2 certificates")
        XCTAssertLessThan(try XCTUnwrap(forwardText.range(of: firstFingerprint)?.lowerBound),
                          try XCTUnwrap(forwardText.range(of: secondFingerprint)?.lowerBound))
        let reverseBytes = pkcs7([second, first])
        let reverse = try SecurityFormatInspector.inspect(data: reverseBytes, fileSize: reverseBytes.count, formatID: .pkcs7)
        let reverseText = String(describing: try XCTUnwrap(reverse.content))
        XCTAssertLessThan(try XCTUnwrap(reverseText.range(of: secondFingerprint)?.lowerBound),
                          try XCTUnwrap(reverseText.range(of: firstFingerprint)?.lowerBound))

        let duplicateBytes = pkcs7([first, first])
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: duplicateBytes, fileSize: duplicateBytes.count,
            formatID: .pkcs7).summary, "2 certificates")
        let sixteenBytes = pkcs7(Array(repeating: first, count: 16))
        let sixteen = try SecurityFormatInspector.inspect(data: sixteenBytes, fileSize: sixteenBytes.count, formatID: .pkcs7)
        XCTAssertEqual(sixteen.summary, "16 certificates")
        let seventeenBytes = pkcs7(Array(repeating: first, count: 16) + [Data([0x30, 0x82])])
        let seventeen = try SecurityFormatInspector.inspect(data: seventeenBytes, fileSize: seventeenBytes.count, formatID: .pkcs7)
        XCTAssertNil(seventeen.content)
        XCTAssertEqual(seventeen.diagnostics.first?.code, .limitExceeded)

        let invalidMemberBytes = pkcs7([first, second, Data([0x30, 0x00])])
        let invalidMember = try SecurityFormatInspector.inspect(data: invalidMemberBytes,
            fileSize: invalidMemberBytes.count, formatID: .pkcs7)
        XCTAssertNil(invalidMember.content)
        XCTAssertEqual(invalidMember.diagnostics.first?.code, .parseError)
    }

    func testPKCS7RejectsMalformedFieldsAndPreservesSizePrecedence() throws {
        let certificate = try Data(contentsOf: fixtureURL("Cases/security/certificate.der"))
        let valid = pkcs7([certificate])
        let malformed = [Data([0x30, 0x82, 0xFF]),
                         replacingFirst(valid, from: Data([0x02, 0x01, 0x01]), with: Data([0x02, 0x81, 0x01, 0x01])),
                         Data(valid.dropLast())]
        for bytes in malformed {
            let rejected = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .pkcs7)
            XCTAssertNil(rejected.content)
            XCTAssertEqual(rejected.diagnostics.first?.code, .parseError)
        }
        let truncated = try SecurityFormatInspector.inspect(data: valid, fileSize: valid.count + 1, formatID: .pkcs7)
        XCTAssertNil(truncated.content)
        XCTAssertEqual(truncated.diagnostics.first?.code, .truncated)
        let oversized = try SecurityFormatInspector.inspect(data: Data(), fileSize: SecurityFormatInspector.maximumInputBytes + 1,
                                                              formatID: .pkcs7)
        XCTAssertEqual(oversized.diagnostics.first?.code, .limitExceeded)
        let retainedOversize = Data(repeating: 0x41, count: SecurityFormatInspector.maximumInputBytes + 1)
        let retainedLimit = try SecurityFormatInspector.inspect(data: retainedOversize, fileSize: -1, formatID: .pkcs7)
        XCTAssertEqual(retainedLimit.diagnostics.first?.code, .limitExceeded)
        let negativeSize = try SecurityFormatInspector.inspect(data: Data([0x30]), fileSize: -1, formatID: .pkcs7)
        XCTAssertNil(negativeSize.content)
        XCTAssertEqual(negativeSize.diagnostics.first?.code, .truncated)
    }

    func testPKCS7WellFormedAlternateStructuresAreUnsupportedAndBrokenFieldsAreMalformed() throws {
        let certificate = try Data(contentsOf: fixtureURL("Cases/security/certificate.der"))
        let dataOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])
        let alternatives = [
            pkcs7(signedDataFields: Data([0x02, 0x02, 0x00, 0x80, 0x31, 0x00])
                + testTLV(0x30, dataOID) + testTLV(0xA0, certificate) + Data([0x31, 0x00])),
            pkcs7(signedDataFields: Data([0x02, 0x01, 0x02, 0x31, 0x00]) + testTLV(0x30, dataOID)
                + testTLV(0xA0, certificate) + Data([0x31, 0x00])),
            pkcs7(signedDataFields: Data([0x02, 0x01, 0x01]) + testTLV(0x31, Data([0x30, 0x00]))
                + testTLV(0x30, dataOID) + testTLV(0xA0, certificate) + Data([0x31, 0x00])),
            pkcs7(signedDataFields: Data([0x02, 0x01, 0x01, 0x31, 0x00])
                + testTLV(0x30, dataOID + Data([0xA0, 0x00])) + testTLV(0xA0, certificate) + Data([0x31, 0x00])),
            pkcs7(signedDataFields: Data([0x02, 0x01, 0x01, 0x31, 0x00]) + testTLV(0x30, dataOID)
                + testTLV(0xA0, testTLV(0xA1, Data([0x01]))) + Data([0x31, 0x00])),
            pkcs7(signedDataFields: Data([0x02, 0x01, 0x01, 0x31, 0x00]) + testTLV(0x30, dataOID)
                + testTLV(0xA0, certificate) + testTLV(0x31, Data([0x30, 0x00])))
            , pkcs7(signedDataFields: Data([0x02, 0x01, 0x01, 0x31, 0x00]) + testTLV(0x30, dataOID)
                + testTLV(0xA0, certificate) + testTLV(0xA1, Data([0x30, 0x00])) + Data([0x31, 0x00]))
        ]
        for bytes in alternatives {
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .pkcs7)
            XCTAssertNil(result.content)
            XCTAssertEqual(result.diagnostics.first?.code, .unsupported)
        }
        let alternateOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x03])
        let alternateType = pkcs7(signedDataFields: Data([0x02, 0x01, 0x01, 0x31, 0x00])
            + testTLV(0x30, dataOID) + testTLV(0xA0, certificate) + Data([0x31, 0x00]),
            contentTypeOID: alternateOID)
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: alternateType, fileSize: alternateType.count,
            formatID: .pkcs7).diagnostics.first?.code, .unsupported)
        let invalidOID = pkcs7(signedDataFields: Data([0x02, 0x01, 0x01, 0x31, 0x00])
            + testTLV(0x30, dataOID) + testTLV(0xA0, certificate) + Data([0x31, 0x00]),
            contentTypeOID: Data([0x06, 0x01, 0x80]))
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: invalidOID, fileSize: invalidOID.count,
            formatID: .pkcs7).diagnostics.first?.code, .parseError)
        let nonMinimalInteger = pkcs7(signedDataFields: Data([0x02, 0x02, 0x00, 0x01, 0x31, 0x00])
            + testTLV(0x30, dataOID) + testTLV(0xA0, certificate) + Data([0x31, 0x00]))
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: nonMinimalInteger, fileSize: nonMinimalInteger.count,
            formatID: .pkcs7).diagnostics.first?.code, .parseError)
        let brokenEncapsulatedField = Data([0x02, 0x01, 0x01, 0x31, 0x00])
            + testTLV(0x30, dataOID + Data([0xA0, 0x82, 0xFF]))
            + testTLV(0xA0, certificate) + Data([0x31, 0x00])
        let malformed = pkcs7(signedDataFields: brokenEncapsulatedField)
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: malformed, fileSize: malformed.count,
            formatID: .pkcs7).diagnostics.first?.code, .parseError)
        let indefinite = Data([0x30, 0x80, 0x00, 0x00])
        XCTAssertEqual(try SecurityFormatInspector.inspect(data: indefinite, fileSize: indefinite.count,
            formatID: .pkcs7).diagnostics.first?.code, .unsupported)
    }

    func testPKCS7CancellationStopsBeforeSecondMember() throws {
        let certificate = try Data(contentsOf: fixtureURL("Cases/security/certificate.der"))
        let bundle = pkcs7([certificate, certificate])
        var cancelled = false
        var accepted: [Int] = []
        XCTAssertThrowsError(try SecurityFormatInspector.inspectPKCS7(data: bundle, fileSize: bundle.count,
            isCancelled: { cancelled }, onAcceptedMember: { count in
                accepted.append(count)
                cancelled = true
            }))
        XCTAssertEqual(accepted, [1])
        XCTAssertThrowsError(try SecurityFormatInspector.inspectPKCS7(data: bundle, fileSize: bundle.count,
            isCancelled: { true }, onAcceptedMember: { _ in }))
    }

    func testPKCS7CatalogSuffixRoutingAndGenericSecurityOverride() throws {
        let definition = try XCTUnwrap(FormatCatalog.definition(for: .pkcs7))
        XCTAssertEqual(definition.status, .supported)
        XCTAssertEqual(definition.extensions, ["p7b", "p7c"])
        XCTAssertEqual(definition.contentTypeIdentifiers, ["com.glimt.pkcs7-certificate-bundle"])
        XCTAssertEqual(definition.effectiveInspectorID, .security)
        XCTAssertEqual(definition.effectiveSettingsProfile, .structured)
        XCTAssertEqual(definition.availableRepresentations, [.tree, .raw, .hex])
        XCTAssertEqual(definition.defaultViews, [.tree, .raw])
        XCTAssertFalse(try XCTUnwrap(definition.detectionRules?.first).usesCatalogUTIs)

        let der = try Data(contentsOf: fixtureURL("Cases/security/bundle.p7b"))
        let pem = Data("-----BEGIN PKCS7-----\n\(der.base64EncodedString())\n-----END PKCS7-----\n".utf8)
        for suffix in ["p7b", "p7c"] {
            for (bytes, encoding) in [(der, "DER"), (pem, "PEM")] {
                for uti in [nil, "com.glimt.pkcs7-certificate-bundle"] as [String?] {
                    let name = "archive.\(suffix.uppercased())"
                    let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                        fileName: name, systemUTI: uti)
                    XCTAssertEqual(result.formatDefinition?.id, .pkcs7, "\(name), \(encoding), \(uti ?? "nil")")
                    XCTAssertEqual(result.additionalInspection?.securityInspection?.summary, "1 certificate",
                                   "\(name), \(encoding), \(uti ?? "nil")")
                }
            }
        }
        for name in ["unknown", "other.bin"] {
            let result = PreviewInspectionResult.prepare(bytes: der, fileSize: der.count, fileName: name,
                systemUTI: "com.glimt.pkcs7-certificate-bundle")
            XCTAssertNotEqual(result.formatDefinition?.id, .pkcs7, name)
        }
        let failed = PreviewInspectionResult.prepare(bytes: Data([0x30, 0x82, 0xFF]), fileSize: 3,
            fileName: "bad.p7b", systemUTI: nil)
        XCTAssertEqual(failed.formatDefinition?.id, .pkcs7)
        XCTAssertNil(failed.additionalInspection?.securityInspection?.content)

        let overridden = PreviewInspectionResult.prepare(bytes: der, fileSize: der.count, fileName: "bundle.data",
            systemUTI: nil, formatOverride: .security(.pkcs7))
        XCTAssertEqual(overridden.formatDefinition?.id, .pkcs7)
        XCTAssertEqual(overridden.additionalInspection?.securityInspection?.summary, "1 certificate")
    }

    private func pkcs7(_ certificates: [Data]) -> Data {
        let dataOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])
        let fields = Data([0x02, 0x01, 0x01, 0x31, 0x00]) + testTLV(0x30, dataOID)
            + testTLV(0xA0, certificates.reduce(into: Data(), { $0.append($1) })) + Data([0x31, 0x00])
        return pkcs7(signedDataFields: fields)
    }

    private func pkcs7(signedDataFields: Data, contentTypeOID: Data? = nil) -> Data {
        let signedDataOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
        return testTLV(0x30, (contentTypeOID ?? signedDataOID) + testTLV(0xA0, testTLV(0x30, signedDataFields)))
    }

    private func testTLV(_ tag: UInt8, _ contents: Data) -> Data {
        var length = Data()
        if contents.count < 128 { length.append(UInt8(contents.count)) }
        else {
            var value = contents.count
            var octets: [UInt8] = []
            while value > 0 { octets.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
            length.append(0x80 | UInt8(octets.count)); length.append(contentsOf: octets)
        }
        return Data([tag]) + length + contents
    }

    private func replacingFirst(_ data: Data, from needle: Data, with replacement: Data) -> Data {
        guard let range = data.range(of: needle) else { return data }
        var result = data
        result.replaceSubrange(range, with: replacement)
        return result
    }
}
