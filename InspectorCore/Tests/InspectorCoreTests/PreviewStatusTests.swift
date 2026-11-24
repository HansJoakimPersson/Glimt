import Foundation
import XCTest
@testable import InspectorCore

final class PreviewStatusTests: XCTestCase {
    func testStatusReflectsActualValidationAndFormatMetadata() throws {
        let yaml = try inspect("Showcase/yaml/yaml.yaml")
        XCTAssertTrue(yaml.statusSummary.items.contains { $0.kind == .valid && $0.text == "Valid YAML" })
        XCTAssertTrue(yaml.statusSummary.items.map(\.text).contains("1 document"))
        XCTAssertTrue(yaml.statusSummary.items.map(\.text).contains("UTF-8"))
        XCTAssertTrue(yaml.statusSummary.items.map(\.text).contains("LF"))
        for (path, name) in [("Cases/json/valid/simple.json", "JSON"), ("Cases/xml/valid/simple.xml", "XML"), ("Cases/plist/xml/simple.plist", "plist")] {
            let result = try inspect(path)
            XCTAssertTrue(result.statusSummary.items.contains { $0.kind == .valid && $0.text == "Valid " + name })
        }
        let binary = try inspect("Showcase/plist/binary.plist")
        XCTAssertTrue(binary.statusSummary.items.map(\.text).contains("Binary"))
        XCTAssertFalse(binary.statusSummary.items.contains { $0.text.contains("UTF") || $0.text == "LF" || $0.text.contains("lines") })
        for path in ["Cases/source/Example.swift", "Cases/markdown/basic.md", "Showcase/text/plain.txt"] {
            XCTAssertFalse(try inspect(path).statusSummary.items.contains { $0.kind == .valid })
        }
    }

    func testMalformedAndBoundedStatusesDoNotClaimFalseValidation() throws {
        let invalid = try inspect("Cases/yaml/invalid/malformed.yaml")
        XCTAssertTrue(invalid.statusSummary.items.contains { $0.kind == .warning && $0.text == "Invalid YAML" })
        XCTAssertFalse(invalid.statusSummary.items.contains { $0.kind == .valid })
        let data = Data("name: Glimt\n".utf8)
        let truncated = PreviewInspectionResult.prepare(bytes: data, fileSize: data.count + 100, fileName: "partial.yaml", systemUTI: "public.yaml")
        XCTAssertEqual(truncated.statusSummary.items.first?.text, "Truncated")
        XCTAssertFalse(truncated.statusSummary.items.contains { $0.text.hasPrefix("Invalid") || $0.kind == .valid })
        XCTAssertTrue(truncated.statusSummary.items.last?.text.hasSuffix("total") == true)
    }

    private func inspect(_ path: String) throws -> PreviewInspectionResult {
        try PreviewInspectionResult.read(at: fixtureURL(path))
    }
}
