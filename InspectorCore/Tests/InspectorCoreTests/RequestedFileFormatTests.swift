import Foundation
import XCTest
@testable import InspectorCore

final class RequestedFileFormatTests: XCTestCase {
    func testRequestedFixturesUseSemanticInspectorsOrFaithfulRawText() throws {
        let cases: [(String, FormatID)] = [
            ("Cases/idl-jupyter/idl/source.pro", .text),
            ("Cases/idl-jupyter/inf/setup.inf", .text),
            ("Cases/idl-jupyter/ini/settings.ini", .ini),
            ("Cases/idl-jupyter/ini/service.cfg", .ini),
            ("Cases/idl-jupyter/inno/installer.iss", FormatID(rawValue: "inno-setup")),
            ("Cases/idl-jupyter/ino/blink.ino", .cpp),
            ("Cases/idl-jupyter/idea/module.iml", .xml),
            ("Cases/idl-jupyter/interface/Main.storybard", .xml),
            ("Cases/idl-jupyter/interface/Main.storyboard", .storyboard),
            ("Cases/idl-jupyter/interface/Main.xib", .xib),
            ("Cases/idl-jupyter/properties/app.properties", .properties),
            ("Cases/idl-jupyter/jsp/page.jsp", FormatID(rawValue: "jsp")),
            ("Cases/idl-jupyter/java/Main.java", .java),
            ("Cases/idl-jupyter/java/Compat.jav", .java),
            ("Cases/idl-jupyter/java/app.jnlp", .xml),
            ("Cases/idl-jupyter/javafx/View.fxml", .xml),
            ("Cases/idl-jupyter/javascript/app.js", .javascript),
            ("Cases/idl-jupyter/javascript/app.jscript", .javascript),
            ("Cases/idl-jupyter/javascript/app.javascript", .javascript),
            ("Cases/idl-jupyter/javascript/module.mjs", .javascript),
            ("Cases/idl-jupyter/javascript/module.jsm", .javascript),
            ("Cases/idl-jupyter/json/document.json", .json),
            ("Cases/idl-jupyter/json/document.jsonc", .json),
            ("Cases/idl-jupyter/json/document.json5", .json),
            ("Cases/idl-jupyter/json/board.canvas", .json),
            ("Cases/idl-jupyter/json/events.jsonl", .jsonl),
            ("Cases/idl-jupyter/julia/analysis.jl", .julia)
        ]

        for (path, expectedID) in cases {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(FormatCatalog.match(fileName: url.lastPathComponent)?.id, expectedID, path)
            XCTAssertEqual(result.formatDefinition?.id, expectedID, path)
            XCTAssertEqual(result.originalBytes, bytes, path)

            switch expectedID {
            case .xml, .storyboard, .xib:
                XCTAssertNotNil(result.xmlInspection?.root, path)
                XCTAssertNil(result.sourceDocument, path)
            case .json:
                XCTAssertNotNil(result.jsonInspection?.content, path)
                XCTAssertEqual(result.jsonInspection?.rawBytes, bytes, path)
            case .ini, .properties, .java, .javascript, .cpp, .julia, FormatID(rawValue: "inno-setup"):
                XCTAssertEqual(result.sourceDocument?.language.rawValue, expectedID.rawValue, path)
                XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, path)
            case FormatID(rawValue: "jsp"):
                XCTAssertEqual(result.sourceDocument?.language, .jsp, path)
                XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, path)
            case .jsonl:
                XCTAssertNotNil(result.additionalStructuredContent, path)
                XCTAssertTrue(result.inspectionDiagnostics.contains { $0.code == .parseError }, path)
            default:
                XCTAssertNil(result.sourceDocument, path)
                XCTAssertEqual(result.analysis.text, String(decoding: bytes, as: UTF8.self), path)
            }
        }
    }

    func testMalformedStructuredAndBinaryFixturesRetainSafeFallbacks() throws {
        for path in ["Cases/idl-jupyter/interface/malformed.xib",
                     "Cases/idl-jupyter/json/malformed.jsonc",
                     "Cases/idl-jupyter/json/unsupported.json5"] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.originalBytes, bytes, path)
            XCTAssertFalse(result.inspectionDiagnostics.isEmpty, path)
            XCTAssertEqual(result.analysis.text, String(decoding: bytes, as: UTF8.self), path)
        }

        let classURL = try fixtureURL("Cases/idl-jupyter/java/Example.class")
        let classBytes = try Data(contentsOf: classURL)
        let classResult = try PreviewInspectionResult.read(at: classURL, contentTypeIdentifier: { _ in nil })
        XCTAssertTrue(classResult.analysis.isBinary)
        XCTAssertEqual(classResult.originalBytes, classBytes)
        XCTAssertNil(classResult.formatDefinition)
        XCTAssertNil(FormatCatalog.match(fileName: classURL.lastPathComponent))
    }
}
