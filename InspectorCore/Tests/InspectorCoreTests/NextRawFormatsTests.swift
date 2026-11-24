import Foundation
import XCTest
@testable import InspectorCore

final class NextRawFormatsTests: XCTestCase {
    func testAllFiveFormatsRouteToDedicatedSourceViews() throws {
        let cases: [(String, FormatID, SourceLanguage, String, SyntaxTokenKind)] = [
            ("Makefile", FormatID.make, .makefile, "all", .type),
            ("catalog.dtd", .dtd, .dtd, "<!ENTITY", .directive),
            ("query.xquery", .xquery, .xquery, "$items", .variable),
            ("page.jsp", .jsp, .jsp, "<%@", .directive),
            ("home.haml", .haml, .haml, "%main", .type)
        ]

        for (filename, formatID, language, marker, kind) in cases {
            let source = switch formatID.rawValue {
            case "make": "all: build\n\t@echo $(NAME)\n"
            case "dtd": "<!ELEMENT note (#PCDATA)>\n<!ENTITY company \"Glimt\">\n"
            case "xquery": "for $items in doc('items.xml') return $items/item\n"
            case "jsp": "<%@ page contentType=\"text/html\" %><h1><%= title %></h1>"
            default: "%main.container\n  = @title\n"
            }
            let bytes = Data(source.utf8)
            let result = PreviewInspectionResult.prepare(
                bytes: bytes, fileSize: bytes.count, fileName: filename, systemUTI: nil
            )
            XCTAssertEqual(result.formatDefinition?.id, formatID, filename)
            XCTAssertEqual(result.formatDefinition?.inspectionKind, .source, filename)
            XCTAssertEqual(result.sourceDocument?.language, language, filename)
            XCTAssertEqual(result.sourceDocument?.source, source, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
            let document = try XCTUnwrap(result.sourceDocument, filename)
            let tokens = document.highlighting.runs.map {
                ((document.source as NSString).substring(with: $0.range), $0.kind)
            }
            XCTAssertTrue(tokens.contains { $0.0 == marker && $0.1 == kind }, filename)
        }
    }

    func testAllFiveFormatDefinitionsExposeSourceRawAndHex() throws {
        for id in [FormatID.make, .dtd, .xquery, .jsp, .haml] {
            let definition = try XCTUnwrap(FormatCatalog.definition(for: id), id.rawValue)
            XCTAssertEqual(definition.status, .supported, id.rawValue)
            XCTAssertEqual(definition.availableRepresentations, [.source, .raw, .hex], id.rawValue)
            XCTAssertNotNil(definition.showcaseFixture, id.rawValue)
        }
    }
}
