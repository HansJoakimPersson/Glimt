import Foundation
import XCTest
@testable import InspectorCore

final class XMLInspectorTests: XCTestCase {
    private func inspect(_ source: String, limits: StructuredInspectionLimits = .init()) throws -> XMLInspectionResult {
        try XMLInspector.inspect(bytes: Data(source.utf8), limits: limits)
    }

    func testCanonicalElementsAttributesNamespacesAndComments() throws {
        for name in ["simple", "attributes", "namespaces", "comments"] {
            let bytes = try Data(contentsOf: fixtureURL(name == "attributes" ? "Showcase/xml/xml.xml" : "Cases/xml/valid/\(name).xml"))
            let result = try XMLInspector.inspect(bytes: bytes)
            XCTAssertTrue(result.diagnostics.isEmpty, name)
            XCTAssertNotNil(result.root, name)
            XCTAssertNotNil(result.prettyText, name)
            XCTAssertEqual(result.rawBytes, bytes)
            XCTAssertEqual(result.rawText, String(data: bytes, encoding: .utf8))
        }
        let namespaced = try XMLInspector.inspect(bytes: Data(contentsOf: fixtureURL("Cases/xml/valid/namespaces.xml")))
        guard case .element(let root) = namespaced.root else { return XCTFail("Expected element") }
        XCTAssertEqual(root.name, "lib:catalog")
        XCTAssertTrue(root.attributes.contains { $0.name == "xmlns:lib" && $0.value == "urn:glimt:library" })
        let attributes = try inspect("<book id=\"1\" language=\"sv\"><title>Example</title><!-- note --></book>")
        guard case .element(let book) = attributes.root else { return XCTFail("Expected book") }
        XCTAssertEqual(book.attributes.map(\.name), ["id", "language"])
        XCTAssertEqual(book.children.last, .comment(" note "))
    }

    func testMixedContentCDATAAndPreservedWhitespaceUseConservativePretty() throws {
        for source in ["<p><em>Hello</em>\n<b>world</b></p>", "<p>Hello <em>Glimt</em> &amp; friends.</p>", "<p><em>Hello</em> <b>world</b></p>", "<root xml:space=\"preserve\"><x/>  <y/></root>", "<?instruction value?><root><x/></root>"] {
            let result = try inspect(source)
            XCTAssertEqual(result.prettyText, source)
            XCTAssertTrue(result.diagnostics.isEmpty)
        }
        let cdata = try inspect("<root><![CDATA[a < b & c]]></root>")
        guard case .element(let root) = cdata.root else { return XCTFail("Expected root") }
        XCTAssertEqual(root.children, [.text("a < b & c")])
        let pretty = try inspect("<catalog><book id=\"1\"><title>A &amp; B</title></book></catalog>")
        XCTAssertTrue(try XCTUnwrap(pretty.prettyText).contains("\n  <book"))
        XCTAssertTrue(try XCTUnwrap(pretty.prettyText).contains("A &amp; B"))
        XCTAssertNotNil(try inspect(try XCTUnwrap(pretty.prettyText)).root)
    }

    func testMalformedTruncatedAndIncompleteKeepRaw() throws {
        for name in ["malformed", "truncated"] {
            let bytes = try Data(contentsOf: fixtureURL("Cases/xml/invalid/\(name).xml"))
            let result = try XMLInspector.inspect(bytes: bytes)
            XCTAssertNil(result.root)
            XCTAssertNil(result.prettyText)
            XCTAssertEqual(result.rawBytes, bytes)
            XCTAssertEqual(result.diagnostics.first?.code, .parseError)
            XCTAssertTrue(result.diagnostics.first?.message.contains("Line") ?? false)
        }
        let partial = try XMLInspector.inspect(bytes: Data("<root/>".utf8), fileSize: 100)
        XCTAssertFalse(partial.rawIsComplete)
        XCTAssertNil(partial.root)
        XCTAssertEqual(partial.diagnostics.first?.code, .truncated)
        XCTAssertNil(try inspect("<a/><b/>").root)
    }

    func testDTDAndEntitiesAreRejectedBeforeNativeParser() throws {
        for source in [
            "<!DOCTYPE x SYSTEM \"https://example.invalid/remote.dtd\"><x/>",
            "<!DOCTYPE x [<!ENTITY secret SYSTEM \"file:///etc/passwd\">]><x>&secret;</x>",
            "<!DOCTYPE x [<!ENTITY a \"boom\"><!ENTITY b \"&a;&a;\">]><x>&b;</x>"
        ] {
            let result = try inspect(source)
            XCTAssertNil(result.root)
            XCTAssertEqual(result.diagnostics.first?.code, .unsupported)
            XCTAssertEqual(result.rawText, source)
        }
        let utf16DTD = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE x SYSTEM \"https://example.invalid/remote.dtd\"><x/>"
        let utf16Bytes = Data([0xFF, 0xFE]) + (try XCTUnwrap(utf16DTD.data(using: .utf16LittleEndian)))
        XCTAssertEqual(try XMLInspector.inspect(bytes: utf16Bytes).diagnostics.first?.code, .unsupported)
        XCTAssertNil(try inspect("<x>&missing;</x>").root)
        XCTAssertNotNil(try inspect("<x>&amp;&lt;&gt;&quot;&apos;</x>").root)
        XCTAssertNotNil(try inspect("<x><!-- <!DOCTYPE harmless> --><![CDATA[<!ENTITY literal>]]></x>").root)
    }

    func testUnicodeAndEncodingDeclarationAgreement() throws {
        let source = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><root>Glimt å🙂</root>"
        let bytes = Data([0xFF, 0xFE]) + (try XCTUnwrap(source.data(using: .utf16LittleEndian)))
        let result = try XMLInspector.inspect(bytes: bytes)
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, source)
        guard case .element(let root) = result.root else { return XCTFail("Expected Unicode XML") }
        XCTAssertEqual(root.children, [.text("Glimt å🙂")])
        XCTAssertFalse(try XCTUnwrap(result.prettyText).contains("encoding=\"UTF-16\""))
        XCTAssertNil(try inspect("<?xml version=\"1.0\" encoding=\"UTF-16\"?><x>å</x>").root)
    }

    func testDepthNodeTextOutputAndByteLimits() throws {
        for (source, limits) in [
            (String(repeating: "<x>", count: 65) + String(repeating: "</x>", count: 65), StructuredInspectionLimits()),
            ("<r><a/><b/></r>", .init(maximumValues: 2)),
            ("<r>long</r>", .init(maximumOutputBytes: 2)),
            ("<r/>", .init(maximumDepth: 0)),
            ("<r/>", .init(maximumBytes: 2))
        ] {
            let result = try inspect(source, limits: limits)
            XCTAssertNil(result.root)
            XCTAssertNil(result.prettyText)
            XCTAssertTrue(result.diagnostics.contains { $0.code == .limitExceeded })
        }
    }

    func testCancellationStopsInspection() async {
        let bytes = Data("<root/>".utf8)
        let result = await runCancelled { try XMLInspector.inspect(bytes: bytes) }
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }
}
