import Foundation
import XCTest
@testable import InspectorCore

final class SecurityFormatInspectorTests: XCTestCase {
    func testOpenSSHPublicKeyShowsMetadataAndFingerprintWithoutTrustClaims() throws {
        let url = try fixtureURL("Showcase/security/sample.pub")
        let bytes = try Data(contentsOf: url)
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .sshPublicKey)

        XCTAssertEqual(result.formatID, .sshPublicKey)
        XCTAssertTrue(result.summary.contains("fingerprint"))
        let content = String(describing: try XCTUnwrap(result.content))
        XCTAssertTrue(content.contains("ssh-ed25519"))
        XCTAssertTrue(content.contains("SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8"))
        XCTAssertTrue(content.contains("build@glimt.test"))
        XCTAssertFalse(result.summary.localizedCaseInsensitiveContains("verified"))

        let preview = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(preview.formatDefinition?.id, .sshPublicKey)
        XCTAssertTrue(preview.additionalInspection?.securityInspection?.content != nil)
    }

    func testMalformedAndTruncatedOpenSSHPublicKeysKeepNoPartialMetadata() throws {
        for filename in ["malformed.pub", "truncated.pub"] {
            let bytes = try Data(contentsOf: fixtureURL("Cases/security/invalid/\(filename)"))
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .sshPublicKey)
            XCTAssertNil(result.content, filename)
            XCTAssertFalse(result.diagnostics.isEmpty, filename)
        }

        let prefix = Data("ssh-ed25519 AAAA".utf8)
        let result = try SecurityFormatInspector.inspect(data: prefix, fileSize: prefix.count + 12, formatID: .sshPublicKey)
        XCTAssertNil(result.content)
        XCTAssertEqual(result.diagnostics.first?.code, .truncated)
    }

    func testPublicKeyExtensionDoesNotMislabelPEMTextAsSSH() {
        let bytes = Data("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n".utf8)
        let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "certificate.pub", systemUTI: nil)
        XCTAssertEqual(result.formatDefinition?.id, .pemPublicKey)
        XCTAssertNil(result.additionalInspection?.securityInspection?.content)
        XCTAssertTrue(result.additionalInspection?.securityInspection?.diagnostics.isEmpty == false)
        XCTAssertEqual(result.analysis.text, String(decoding: bytes, as: UTF8.self))
    }

    func testInfoPlistAndEntitlementsUseBoundedPlistInspectionAndDistinctIdentity() throws {
        for (path, filename, expectedID) in [
            ("Showcase/apple/Info.plist", "Info.plist", FormatID.infoPlist),
            ("Showcase/apple/Glimt.entitlements", "Glimt.entitlements", FormatID.entitlements)
        ] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, expectedID, filename)
            XCTAssertEqual(result.formatDefinition?.id, expectedID, filename)
            XCTAssertNotNil(result.plistInspection?.content, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
            XCTAssertEqual(result.formatDefinition?.availableRepresentations, [.tree, .pretty, .raw], filename)
        }

        let malformed = try PreviewInspectionResult.read(
            at: fixtureURL("Cases/requested-formats/invalid/app.entitlements"), contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(malformed.formatDefinition?.id, .entitlements)
        XCTAssertFalse(malformed.plistInspection?.diagnostics.isEmpty ?? true)
        XCTAssertEqual(malformed.originalBytes, try Data(contentsOf: fixtureURL("Cases/requested-formats/invalid/app.entitlements")))

        let invalidInfo = try PreviewInspectionResult.read(
            at: fixtureURL("Cases/catalog/invalid/Info.plist"), contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(invalidInfo.formatDefinition?.id, .infoPlist)
        XCTAssertFalse(invalidInfo.plistInspection?.diagnostics.isEmpty ?? true)

        let prefix = try Data(contentsOf: fixtureURL("Showcase/apple/Info.plist"))
        let truncatedInfo = PreviewInspectionResult.prepare(bytes: prefix, fileSize: prefix.count + 10,
            fileName: "Info.plist", systemUTI: nil)
        XCTAssertEqual(truncatedInfo.formatDefinition?.id, .infoPlist)
        XCTAssertTrue(truncatedInfo.plistInspection?.diagnostics.contains { $0.code == .truncated } == true)
    }

    func testMobileProvisionExtractsProfileMetadataWithoutClaimingSignatureVerification() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/security/synthetic.mobileprovision"))
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .mobileprovision)

        XCTAssertEqual(result.formatID, .mobileprovision)
        XCTAssertEqual(result.summary, "Provisioning profile metadata · signature not checked")
        let content = try XCTUnwrap(result.content)
        let description = String(describing: content)
        XCTAssertTrue(description.contains("Synthetic Development Profile"))
        XCTAssertTrue(description.contains("CMS signature verification"))
        XCTAssertFalse(description.contains("DeveloperCertificates"))
    }

    func testJWTShowsDecodedJWSHeaderAndClaimsAsUnverified() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/security/token.jwt"))
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .jwt)

        XCTAssertEqual(result.formatID, .jwt)
        XCTAssertTrue(result.summary.contains("unverified"))
        let description = String(describing: try XCTUnwrap(result.content))
        XCTAssertTrue(description.contains("glimt-fixture"))
        XCTAssertTrue(description.contains("Verification"))
    }

    func testMalformedAndEncryptedJWTsDoNotProducePartialStructuredContent() throws {
        for token in ["header.payload", "a.b.c.d.e", "@@.e30.AA",
                      "eyJhbGciOiJub25lIn0.eyJzdWIiOiJvayIsInN1YiI6ImFsdGVyZWQifQ."] {
            let bytes = Data(token.utf8)
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .jwt)
            XCTAssertNil(result.content, token)
            XCTAssertFalse(result.diagnostics.isEmpty, token)
        }
    }

    func testJWKPrivateComponentsAreRedactedFromStructuredTree() throws {
        let bytes = Data(#"{"kty":"RSA","kid":"sample-public","n":"public-modulus","e":"AQAB","d":"never-show-this-secret"}"#.utf8)
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .jwk)

        let description = String(describing: try XCTUnwrap(result.content))
        XCTAssertTrue(description.contains("sample-public"))
        XCTAssertTrue(description.contains("redacted"))
        XCTAssertFalse(description.contains("never-show-this-secret"))
    }

    func testJWKRejectsDuplicateSecurityCriticalMembers() throws {
        let bytes = Data(#"{"kty":"RSA","n":"first","n":"second","e":"AQAB"}"#.utf8)
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .jwk)
        XCTAssertNil(result.content)
        XCTAssertEqual(result.diagnostics.first?.code, .parseError)
    }

    func testJWKSRequiresAKeySetAndRedactsPrivateValuesInEveryKey() throws {
        let bytes = Data(#"{"keys":[{"kty":"oct","kid":"one","k":"hidden-key"},{"kty":"RSA","kid":"two","n":"N","e":"AQAB"}]}"#.utf8)
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .jwks)

        let description = String(describing: try XCTUnwrap(result.content))
        XCTAssertTrue(description.contains("two"))
        XCTAssertFalse(description.contains("hidden-key"))
        XCTAssertTrue(description.contains("redacted"))
    }

    func testCycloneDXAndSPDXJSONAreRecognizedAndSummarized() throws {
        let cyclonedx = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":[{"type":"library","name":"demo","version":"1.0"}]}"#.utf8)
        let cycloneResult = try SecurityFormatInspector.inspect(data: cyclonedx, fileSize: cyclonedx.count, formatID: .cyclonedxSBOM)
        XCTAssertTrue(cycloneResult.summary.contains("1 component"))
        XCTAssertTrue(String(describing: try XCTUnwrap(cycloneResult.content)).contains("CycloneDX"))

        let spdx = Data(#"{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"fixture","documentNamespace":"https://example.invalid/spdx","creationInfo":{"creators":["Tool: fixture"]},"packages":[{"name":"demo","SPDXID":"SPDXRef-Package-demo"}]}"#.utf8)
        let spdxResult = try SecurityFormatInspector.inspect(data: spdx, fileSize: spdx.count, formatID: .spdxSBOM)
        XCTAssertTrue(spdxResult.summary.contains("1 package"))
        XCTAssertTrue(String(describing: try XCTUnwrap(spdxResult.content)).contains("SPDX-2.3"))
    }

    func testUnsupportedSBOMVersionsKeepRawFallbackWithoutPartialContent() throws {
        let bytes = Data(#"{"bomFormat":"CycloneDX","specVersion":"2.0","components":[]}"#.utf8)
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .cyclonedxSBOM)
        XCTAssertNil(result.content)
        XCTAssertEqual(result.diagnostics.first?.code, .unsupported)
    }

    func testCycloneDXXMLIsVersionGatedAndSummarized() throws {
        let xml = Data(#"<bom xmlns="http://cyclonedx.org/schema/bom/1.6" serialNumber="urn:uuid:00000000-0000-0000-0000-000000000001" version="1"><components><component type="library" bom-ref="pkg"><name>fixture-lib</name><version>1.0</version></component></components></bom>"#.utf8)
        let result = try SecurityFormatInspector.inspect(data: xml, fileSize: xml.count, formatID: .cyclonedxSBOMXML)
        XCTAssertTrue(result.summary.contains("CycloneDX 1.6"))
        XCTAssertTrue(result.summary.contains("1 component"))
        XCTAssertTrue(String(describing: try XCTUnwrap(result.content)).contains("fixture-lib"))

        let prefixed = Data(#"<c:bom xmlns:c="http://cyclonedx.org/schema/bom/1.6" version="1"><c:components><c:component type="library"/></c:components></c:bom>"#.utf8)
        let prefixedResult = try SecurityFormatInspector.inspect(data: prefixed, fileSize: prefixed.count,
                                                                  formatID: .cyclonedxSBOMXML)
        XCTAssertTrue(prefixedResult.summary.contains("1 component"))
    }

    func testCycloneDXXMLRejectsUnsupportedVersionsAndExternalEntities() throws {
        let unsupported = Data(#"<bom xmlns="http://cyclonedx.org/schema/bom/1.3" version="1"/>"#.utf8)
        let versionResult = try SecurityFormatInspector.inspect(data: unsupported, fileSize: unsupported.count,
                                                                 formatID: .cyclonedxSBOMXML)
        XCTAssertNil(versionResult.content)
        XCTAssertEqual(versionResult.diagnostics.first?.code, .unsupported)
        let external = Data(#"<!DOCTYPE bom [<!ENTITY x SYSTEM "file:///etc/passwd">]><bom xmlns="http://cyclonedx.org/schema/bom/1.6" version="1"><metadata>&x;</metadata></bom>"#.utf8)
        let externalResult = try SecurityFormatInspector.inspect(data: external, fileSize: external.count,
                                                                  formatID: .cyclonedxSBOMXML)
        XCTAssertNil(externalResult.content)
        XCTAssertFalse(externalResult.diagnostics.isEmpty)
    }

    func testSPDXTagValuePreservesRepeatedTagsAndContinuationLines() throws {
        let source = """
        SPDXVersion: SPDX-2.3
        DataLicense: CC0-1.0
        SPDXID: SPDXRef-DOCUMENT
        DocumentName: Fixture BOM
        DocumentNamespace: https://example.invalid/spdx
        Creator: Tool: Glimt
        Created: 2026-01-01T00:00:00Z
        PackageName: first-package
        PackageSPDXID: SPDXRef-Package-first
        PackageComment: first line
         continued detail
        PackageName: second-package
        PackageSPDXID: SPDXRef-Package-second
        """
        let bytes = Data(source.utf8)
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .spdxTagValue)
        XCTAssertTrue(result.summary.contains("SPDX-2.3"))
        XCTAssertTrue(result.summary.contains("2 packages"))
        guard case .array(let records) = try XCTUnwrap(result.content),
              let comment = records.first(where: { memberValue("Tag", in: $0) == .string("PackageComment") }) else {
            return XCTFail("Expected preserved SPDX package comment")
        }
        XCTAssertEqual(memberValue("Value", in: comment), .string("first line\ncontinued detail"))
        XCTAssertTrue(String(describing: result.content).contains("second-package"))
    }

    func testSPDXYAMLUsesBoundedStructureAndCountOnlySummary() throws {
        let source = """
        spdxVersion: SPDX-2.3
        dataLicense: CC0-1.0
        SPDXID: SPDXRef-DOCUMENT
        name: private-document-name
        documentNamespace: https://example.invalid/private-namespace
        packages:
          - SPDXID: SPDXRef-Package-a
            name: private-package-name
        """
        let bytes = Data(source.utf8)
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .spdxYAML)
        XCTAssertNotNil(result.content)
        XCTAssertTrue(result.summary.contains("1 package"))
        XCTAssertFalse(result.summary.contains("private"))
    }

    func testSPDXYAMLRejectsWrongVersionAndMalformedInput() throws {
        for source in [
            "spdxVersion: SPDX-3.0\ndataLicense: CC0-1.0\nSPDXID: SPDXRef-DOCUMENT\nname: sample\npackages: []\n",
            "spdxVersion: SPDX-2.3\nspdxVersion: SPDX-2.2\n"
        ] {
            let bytes = Data(source.utf8)
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .spdxYAML)
            XCTAssertNil(result.content)
            XCTAssertFalse(result.diagnostics.isEmpty)
        }
    }

    func testSPDXTagValueRejectsMalformedAndUnsupportedDocumentsWithoutPartialContent() throws {
        for source in [
            "SPDXVersion: SPDX-3.0\nDataLicense: CC0-1.0\nSPDXID: SPDXRef-DOCUMENT\nDocumentName: fixture\nDocumentNamespace: urn:example\n",
            "SPDXVersion: SPDX-2.3\nSPDXVersion: SPDX-2.2\n",
            "SPDXVersion: SPDX-2.3\nMalformed record without colon\n"
        ] {
            let bytes = Data(source.utf8)
            let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .spdxTagValue)
            XCTAssertNil(result.content, source)
            XCTAssertFalse(result.diagnostics.isEmpty, source)
        }
    }

    func testSBOMAdversarialFixturesDoNotProducePartialContent() throws {
        let cases: [(String, FormatID)] = [
            ("Cases/sbom/invalid/cyclonedx-unsupported-version.cdx.xml", .cyclonedxSBOMXML),
            ("Cases/sbom/invalid/cyclonedx-external-entity.cdx.xml", .cyclonedxSBOMXML),
            ("Cases/sbom/invalid/spdx-duplicate-version.spdx", .spdxTagValue),
            ("Cases/sbom/invalid/spdx-malformed-record.spdx", .spdxTagValue)
        ]
        for (path, id) in cases {
            let data = try Data(contentsOf: fixtureURL(path))
            let result = try SecurityFormatInspector.inspect(data: data, fileSize: data.count, formatID: id)
            XCTAssertNil(result.content, path)
            XCTAssertFalse(result.diagnostics.isEmpty, path)
        }
    }

    func testMalformedMobileProvisionDoesNotReturnProfileFacts() throws {
        let bytes = Data([0x30, 0x00])
        let result = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: .mobileprovision)
        XCTAssertNil(result.content)
        XCTAssertFalse(result.diagnostics.isEmpty)

        // EnvelopedData is refused before the CMS decoder can be asked to process encrypted content.
        let enveloped = Data([0x30, 0x0b, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x03])
        let encryptedResult = try SecurityFormatInspector.inspect(data: enveloped, fileSize: enveloped.count,
                                                                    formatID: .mobileprovision)
        XCTAssertNil(encryptedResult.content)
        XCTAssertEqual(encryptedResult.diagnostics.first?.code, .unsupported)
    }

    func testSecurityFormatsHaveSuffixOnlyCatalogRoutingIncludingSBOMCompoundExtensions() {
        XCTAssertEqual(FormatCatalog.match(fileName: "profile.mobileprovision")?.id, .mobileprovision)
        XCTAssertEqual(FormatCatalog.match(fileName: "embedded.provisionprofile")?.id, .mobileprovision)
        XCTAssertEqual(FormatCatalog.match(fileName: "CycloneDX.cdx.pb")?.id, .cyclonedxSBOMProtobuf)
        XCTAssertEqual(FormatCatalog.match(fileName: "token.jwt")?.id, .jwt)
        XCTAssertEqual(FormatCatalog.match(fileName: "key.jwk")?.id, .jwk)
        XCTAssertEqual(FormatCatalog.match(fileName: "keys.jwks")?.id, .jwks)
        XCTAssertEqual(FormatCatalog.match(fileName: "package.cdx.json")?.id, .cyclonedxSBOM)
        XCTAssertEqual(FormatCatalog.match(fileName: "inventory.CDX.JSON")?.id, .cyclonedxSBOM)
        XCTAssertEqual(FormatCatalog.match(fileName: "bom.json")?.id, .cyclonedxSBOM)
        XCTAssertEqual(FormatCatalog.match(fileName: "audit.spdx.json")?.id, .spdxSBOM)
        XCTAssertEqual(FormatCatalog.match(fileName: "report.json")?.id, .json)
    }

    func testCycloneDXProtobufProjectsComponentNameAndVersionAndRejectsMalformedWireData() throws {
        let url = try fixtureURL("Showcase/security/cyclonedx.cdx.pb")
        let bytes = try Data(contentsOf: url)
        let preview = try PreviewInspectionResult.read(at: url)
        XCTAssertEqual(preview.formatDefinition?.id, .cyclonedxSBOMProtobuf)
        XCTAssertEqual(preview.originalBytes, bytes)
        let result = try XCTUnwrap(preview.additionalInspection?.securityInspection)
        XCTAssertTrue(result.summary.contains("CycloneDX protobuf 1.5"))
        XCTAssertTrue(String(describing: result.content).contains("SQLite3"))
        XCTAssertTrue(String(describing: result.content).contains("3.46"))

        let malformed = try Data(contentsOf: fixtureURL("Cases/sbom/invalid/malformed.cdx.pb"))
        let rejected = try SecurityFormatInspector.inspect(data: malformed, fileSize: malformed.count,
            formatID: .cyclonedxSBOMProtobuf)
        XCTAssertNil(rejected.content)
        XCTAssertFalse(rejected.diagnostics.isEmpty)
    }

    func testFourNextFormatsHaveSupportedCatalogRoutes() throws {
        let cases: [(String, FormatID, InspectorID)] = [
            ("Catalog.xcstrings", .xcstrings, .json),
            ("Build.xcscheme", .xcscheme, .xml),
            ("package.cdx.xml", .cyclonedxSBOMXML, .security),
            ("package.spdx", .spdxTagValue, .security)
        ]
        for (fileName, id, inspectorID) in cases {
            let definition = try XCTUnwrap(FormatCatalog.definition(for: id), fileName)
            XCTAssertEqual(definition.status, .supported, fileName)
            XCTAssertEqual(definition.effectiveInspectorID, inspectorID, fileName)
            XCTAssertEqual(FormatCatalog.match(fileName: fileName)?.id, id, fileName)
        }
        XCTAssertEqual(FormatCatalog.match(fileName: "bom.xml")?.id, .cyclonedxSBOMXML)
        XCTAssertEqual(FormatCatalog.match(fileName: "ordinary.xml")?.id, .xml)
    }

    func testExplicitSecurityFormatMappingCanRouteAUserSelectedAlias() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/security/synthetic.mobileprovision"))
        let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "custom.profile", systemUTI: nil, formatOverride: .security(.mobileprovision))
        XCTAssertEqual(result.formatDefinition?.id, .mobileprovision)
        XCTAssertNotNil(result.additionalInspection?.securityInspection?.content)
    }

    private func memberValue(_ name: String, in value: StructuredValue) -> StructuredValue? {
        guard case .object(let members) = value else { return nil }
        return members.first { $0.key == name }?.value
    }
}
