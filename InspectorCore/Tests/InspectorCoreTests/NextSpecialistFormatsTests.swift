import Foundation
import XCTest
@testable import InspectorCore

final class NextSpecialistFormatsTests: XCTestCase {
    func testAppleAndXMLFormatsKeepDistinctIdentitiesOnTheBoundedXMLInspector() throws {
        let fixtures: [(String, String)] = [
            ("Cases/catalog/View.xib", "xib"),
            ("Cases/catalog/Main.storyboard", "storyboard"),
            ("Cases/requested-formats/schema.xsd", "xsd"),
            ("Cases/catalog/transform.xslt", "xslt")
        ]

        for (path, id) in fixtures {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(FormatCatalog.match(fileName: url.lastPathComponent)?.id.rawValue, id, path)
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, path)
            XCTAssertNotNil(result.xmlInspection?.root, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
            XCTAssertEqual(result.formatDefinition?.availableRepresentations, [.tree, .pretty, .raw, .hex], path)
        }

        for (filename, id) in [("layout.xib", "xib"), ("Main.storyboard", "storyboard"),
                                ("schema.xsd", "xsd"), ("transform.xsl", "xslt")] {
            let bytes = Data("<root><value/></root>".utf8)
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: filename, systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, filename)
            XCTAssertNotNil(result.xmlInspection?.root, filename)
        }
    }

    func testMalformedXMLAliasesKeepOriginalBytesAndDiagnostics() {
        let bytes = Data("<document><broken></document>".utf8)
        for filename in ["layout.xib", "Main.storyboard", "schema.xsd", "transform.xslt"] {
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: filename, systemUTI: nil)
            XCTAssertEqual(result.originalBytes, bytes, filename)
            XCTAssertNotNil(result.xmlInspection, filename)
            XCTAssertFalse(result.xmlInspection?.diagnostics.isEmpty ?? true, filename)
        }
    }

    func testDocumentationFormatsUseInertSourceViews() throws {
        let fixtures: [(String, String)] = [
            ("Showcase/fileformats/guide.rst", "rst"),
            ("Showcase/fileformats/report.qmd", "quarto"),
            ("Showcase/fileformats/page.mdx", "mdx")
        ]

        for (path, id) in fixtures {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, path)
            XCTAssertEqual(result.formatDefinition?.availableRepresentations, [.source, .raw, .hex], path)
            XCTAssertNotNil(result.sourceDocument, path)
            XCTAssertNil(result.markdownDocument, "Specialized renderers and embedded code must not run: \(path)")
            XCTAssertEqual(result.sourceDocument?.source, result.analysis.text, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, path)
            if id == "rst" {
                XCTAssertTrue(result.sourceDocument?.highlighting.runs.contains { $0.kind == .directive } == true)
                XCTAssertTrue(result.sourceDocument?.highlighting.runs.contains { $0.kind == .keyword } == true)
            }
        }
        XCTAssertEqual(SourceLanguage(rawValue: "rst")?.displayName, "reStructuredText")
    }

    func testPEMPublicKeyMetadataIsBoundedAndDoesNotImportOrVerifyKey() throws {
        let url = try fixtureURL("Showcase/security/pem-public-key.pub")
        let bytes = try Data(contentsOf: url)
        let id = FormatID(rawValue: "pem-public-key")
        let inspection = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count, formatID: id)
        XCTAssertEqual(inspection.formatID, id)
        let content = try XCTUnwrap(inspection.content)
        XCTAssertTrue(String(describing: content).contains("RSA"))
        XCTAssertTrue(String(describing: content).contains("2048"))
        XCTAssertTrue(String(describing: content).contains("Not performed"))
        XCTAssertFalse(String(describing: content).contains("private"))

        let preview = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(preview.formatDefinition?.id, id)
        XCTAssertEqual(preview.additionalInspection?.securityInspection?.content, content)

        let malformed = Data("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n".utf8)
        let failed = try SecurityFormatInspector.inspect(data: malformed, fileSize: malformed.count, formatID: id)
        XCTAssertNil(failed.content)
        XCTAssertFalse(failed.diagnostics.isEmpty)

        let truncated = try SecurityFormatInspector.inspect(data: bytes, fileSize: bytes.count + 1, formatID: id)
        XCTAssertNil(truncated.content)
        XCTAssertEqual(truncated.diagnostics.first?.code, .truncated)
        let oversizedBytes = Data(repeating: 0, count: SecurityFormatInspector.maximumInputBytes + 1)
        let oversized = try SecurityFormatInspector.inspect(data: oversizedBytes, fileSize: oversizedBytes.count, formatID: id)
        XCTAssertNil(oversized.content)
        XCTAssertEqual(oversized.diagnostics.first?.code, .limitExceeded)

        let sshBytes = try Data(contentsOf: fixtureURL("Showcase/security/sample.pub"))
        let ssh = PreviewInspectionResult.prepare(bytes: sshBytes, fileSize: sshBytes.count,
            fileName: "id_ed25519.pub", systemUTI: nil)
        XCTAssertEqual(ssh.formatDefinition?.id, .sshPublicKey)
        XCTAssertEqual(ssh.additionalInspection?.securityInspection?.formatID, .sshPublicKey)
    }
}
