import Foundation
import XCTest
@testable import InspectorCore

final class AppleMetadataFormatTests: XCTestCase {
    func testPrivacyManifestUsesBoundedPlistAndCountOnlySummary() throws {
        let bytes = try fixture("Showcase/apple/PrivacyInfo.xcprivacy")
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "PrivacyInfo.xcprivacy", systemUTI: nil)

        XCTAssertEqual(inspection.formatDefinition?.id, .privacyManifest)
        let content = try XCTUnwrap(inspection.plistInspection?.content)
        let summary = try XCTUnwrap(ApplePrivacyManifestSummary.make(from: content))
        XCTAssertFalse(summary.contains("tracker.example"))
        XCTAssertTrue(summary.contains("1 tracking domain"))
    }

    func testPrivacyManifestRejectsWrongKnownKeyShapeAndKeepsRaw() throws {
        let bytes = try fixture("Cases/apple/invalid/wrong-shape.xcprivacy")
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "PrivacyInfo.xcprivacy", systemUTI: nil)

        XCTAssertEqual(inspection.formatDefinition?.id, .privacyManifest)
        XCTAssertNil(inspection.plistInspection?.content)
        XCTAssertEqual(inspection.plistInspection?.diagnostics.first?.code, .unsupported)
        XCTAssertEqual(inspection.plistInspection?.rawBytes, bytes)
    }

    func testXcodeTestPlanRequiresRecognizedRootAndKeepsRawOnFailure() throws {
        let bytes = try fixture("Showcase/apple/UnitTests.xctestplan")
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "UnitTests.xctestplan", systemUTI: nil)

        XCTAssertEqual(inspection.formatDefinition?.id, .xcodeTestPlan)
        let content = try XCTUnwrap(inspection.jsonInspection?.content)
        let summary = try XCTUnwrap(XcodeTestPlanSummary.make(from: content))
        XCTAssertTrue(summary.contains("1 test target"))
        XCTAssertTrue(summary.contains("1 configuration"))

        let malformed = Data("{\"version\":2,\"testTargets\":[]}".utf8)
        let rejected = PreviewInspectionResult.prepare(bytes: malformed, fileSize: malformed.count,
            fileName: "Broken.xctestplan", systemUTI: nil)
        XCTAssertNil(rejected.jsonInspection?.content)
        XCTAssertEqual(rejected.jsonInspection?.diagnostics.first?.code, .unsupported)
        XCTAssertEqual(rejected.jsonInspection?.rawBytes, malformed)
    }

    func testCodeResourcesUsesPlistTreeAndDoesNotClaimSignatureVerification() throws {
        let bytes = try fixture("Showcase/apple/CodeResources")
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "CodeResources", systemUTI: nil)

        XCTAssertEqual(inspection.formatDefinition?.id, .codeResources)
        let content = try XCTUnwrap(inspection.plistInspection?.content)
        let summary = try XCTUnwrap(AppleCodeResourcesSummary.make(from: content))
        XCTAssertTrue(summary.contains("1 sealed resource entry"))
        XCTAssertTrue(summary.contains("signature not checked"))

        let malformed = try fixture("Cases/apple/invalid/CodeResources")
        let rejected = PreviewInspectionResult.prepare(bytes: malformed, fileSize: malformed.count,
            fileName: "CodeResources", systemUTI: nil)
        XCTAssertEqual(rejected.formatDefinition?.id, .codeResources)
        XCTAssertNil(rejected.plistInspection?.content)
        XCTAssertEqual(rejected.plistInspection?.rawBytes, malformed)
    }

    func testEmbeddedProvisionProfileUsesExistingBoundedSecurityInspector() throws {
        let bytes = try fixture("Showcase/security/synthetic.mobileprovision")
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "embedded.provisionprofile", systemUTI: nil)
        XCTAssertEqual(inspection.formatDefinition?.id, .mobileprovision)
        XCTAssertNotNil(inspection.additionalInspection?.securityInspection?.content)
        XCTAssertTrue(inspection.additionalInspection?.securityInspection?.summary.contains("signature not checked") == true)
    }

    private func fixture(_ path: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Fixtures/\(path)"))
    }

    func testStringCatalogRequiresSupportedJSONShapeAndPreservesRawOnFailure() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Cases/apple/invalid/unsupported-version.xcstrings"))
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "Unsupported.xcstrings", systemUTI: nil)

        XCTAssertEqual(inspection.formatDefinition?.id, .xcstrings)
        XCTAssertNil(inspection.jsonInspection?.content)
        XCTAssertEqual(inspection.jsonInspection?.diagnostics.first?.code, .unsupported)
        XCTAssertEqual(inspection.jsonInspection?.rawBytes, bytes)
        XCTAssertEqual(inspection.originalBytes, bytes)
    }

    func testXcodeSchemeRequiresSchemeRootAndKeepsRawOnFailure() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Cases/apple/invalid/wrong-root.xcscheme"))
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "Unsupported.xcscheme", systemUTI: nil)

        XCTAssertEqual(inspection.formatDefinition?.id, .xcscheme)
        XCTAssertNil(inspection.xmlInspection?.root)
        XCTAssertEqual(inspection.xmlInspection?.diagnostics.first?.code, .unsupported)
        XCTAssertEqual(inspection.xmlInspection?.rawBytes, bytes)
        XCTAssertEqual(inspection.originalBytes, bytes)
    }
}
