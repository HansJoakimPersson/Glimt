import Foundation
import XCTest
import UniformTypeIdentifiers
@testable import InspectorCore

final class InquiryReportTests: XCTestCase {
    func testReportUsesActualPipelineResultsAcrossSupportedAndFallbackInputs() throws {
        let cases: [(String, Data, String?)] = [
            ("example.swift", try Data(contentsOf: fixtureURL("Cases/source/Example.swift")), "public.swift-source"),
            ("example.ts", try Data(contentsOf: fixtureURL("Showcase/source/typescript.ts")), "public.mpeg-2-transport-stream"),
            ("script", try Data(contentsOf: fixtureURL("Cases/ambiguous/extensionless-python")), nil),
            ("example.yaml", try Data(contentsOf: fixtureURL("Showcase/yaml/yaml.yaml")), "public.yaml"),
            ("example.plist", try Data(contentsOf: fixtureURL("Showcase/plist/binary.plist")), "com.apple.binary-property-list"),
            ("example.md", try Data(contentsOf: fixtureURL("Cases/markdown/headings.md")), "net.daringfireball.markdown"),
            ("broken.xml", try Data(contentsOf: fixtureURL("Cases/xml/invalid/malformed.xml")), "public.xml"),
            ("unknown", try Data(contentsOf: fixtureURL("Cases/text/unknown.txt")), nil),
            ("binary", try Data(contentsOf: fixtureURL("Cases/binary/extensionless")), "public.data")
        ]
        for (name, bytes, uti) in cases {
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: name, systemUTI: uti)
            let report = InquiryReport.make(url: URL(fileURLWithPath: "/tmp/" + name), inspection: result)
            XCTAssertEqual(report.formatName, result.formatName, name)
            XCTAssertTrue(report.summary.contains(result.formatName), name)
            XCTAssertFalse(report.summary.contains("%"), name)
            XCTAssertTrue(report.summary.contains("macOS or another provider may win"), name)
            XCTAssertTrue(report.details.contains("Observed UTType: " + (uti ?? "unavailable")), name)
            XCTAssertTrue(report.details.contains("Size: \(bytes.count) bytes"), name)
            if result.jsonInspection?.content != nil || result.yamlInspection?.documents != nil || result.plistInspection?.content != nil {
                XCTAssertTrue(report.availableRepresentations.contains("Tree"), name)
            }
            if name == "broken.xml" {
                XCTAssertEqual(report.availableRepresentations, ["Raw"])
                XCTAssertTrue(report.summary.contains("Partial support"))
            }
            if name == "binary" { XCTAssertEqual(report.availableRepresentations, ["Hex"]) }
            if name == "script" { XCTAssertTrue(report.details.contains("Shebang (bounded, never executed): #!/usr/bin/env python3")) }
            if name == "example.ts" {
                XCTAssertEqual(report.formatName, "TypeScript")
                XCTAssertTrue(report.summary.contains("Conflicting evidence"))
                XCTAssertTrue(report.summary.contains("readable TypeScript"))
                XCTAssertTrue(report.summary.contains("MPEG video"))
                XCTAssertFalse(report.summary.contains("public.mpeg-2-transport-stream"))
                XCTAssertTrue(report.details.contains("public.mpeg-2-transport-stream"))
            }
            if name == "example.plist" {
                XCTAssertTrue(report.details.contains("File signature: recognized · bplist00"))
                XCTAssertFalse(report.details.contains("magicSignature"))
                XCTAssertFalse(report.details.contains("noMatch"))
                XCTAssertTrue(report.availableRepresentations.contains("Raw (bounded hex)"))
            }
        }
    }

    func testDeclarationsAreEligibilityOnlyAndCanBeUnavailable() {
        let bytes = Data("let answer = 42".utf8)
        let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: "file.swift", systemUTI: "public.swift-source")
        let url = URL(fileURLWithPath: "/tmp/file.swift")
        let matched = InquiryReport.make(url: url, inspection: result, declaredTypeIDs: ["public.swift-source"])
        XCTAssertTrue(matched.details.contains("Embedded preview declarations match: public.swift-source"))
        XCTAssertTrue(matched.details.contains("does not prove provider selection"))
        // LaunchServices may return no hierarchy in a sandboxed test host; never invent it.
        for parent in UTType("public.swift-source")?.supertypes ?? [] {
            XCTAssertTrue(matched.details.contains(parent.identifier))
        }
        let missing = InquiryReport.make(url: url, inspection: result)
        XCTAssertTrue(missing.details.contains("eligibility not assessed"))
        let unmatched = InquiryReport.make(url: url, inspection: result, declaredTypeIDs: ["public.image"])
        XCTAssertTrue(unmatched.details.contains("no match for the observed UTType"))
    }

    func testStandaloneMermaidInquiryReportsRenderedView() throws {
        let url = try fixtureURL("Cases/mermaid/xy-chart.mmd")
        let inspection = try PreviewInspectionResult.read(at: url)
        let report = InquiryReport.make(url: url, inspection: inspection)

        XCTAssertEqual(inspection.formatDefinition?.id, .mermaid)
        XCTAssertEqual(report.availableRepresentations, ["Rendered", "Raw"])
        XCTAssertTrue(report.details.contains("MermaidKit native diagram renderer"))

        let wrappedURL = try fixtureURL("Cases/mermaid/wrapped-02.md")
        let wrappedInspection = try PreviewInspectionResult.read(at: wrappedURL)
        let wrappedReport = InquiryReport.make(url: wrappedURL, inspection: wrappedInspection)
        XCTAssertEqual(wrappedReport.availableRepresentations, ["Rendered", "Source"])
        XCTAssertTrue(wrappedReport.details.contains("native text and Mermaid rendering"))
    }

    func testUserMappingRetainsAutomaticResultAndObservedType() {
        let bytes = Data("{}".utf8)
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "file.custom", systemUTI: "public.data", formatOverride: .json,
            overrideDescription: "Extension .custom → JSON")
        let report = InquiryReport.make(url: URL(fileURLWithPath: "/tmp/file.custom"), inspection: inspection)
        XCTAssertEqual(report.formatName, "JSON")
        XCTAssertTrue(report.summary.contains("Why: an explicit user mapping"))
        XCTAssertTrue(report.summary.contains("User mapping: Extension .custom → JSON"))
        XCTAssertTrue(report.summary.contains("Automatic result: " + (inspection.automaticFormatName ?? "missing")))
        XCTAssertTrue(report.details.contains("Observed UTType: public.data"))
        XCTAssertEqual(report.availableRepresentations, ["Tree", "Pretty", "Raw", "Hex"])
    }

    func testAdvancedTextIsBoundedAndDoesNotInjectNewFields() throws {
        let source = "#!/" + String(repeating: "a", count: 2_000) + "\nplain text"
        let bytes = Data(source.utf8)
        let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count + 20, fileName: "unknown", systemUTI: nil)
        let url = URL(fileURLWithPath: "/tmp/name\nInjected: value")
        let report = InquiryReport.make(url: url, inspection: result)
        XCTAssertTrue(report.summary.contains("bounded prefix"))
        XCTAssertFalse(report.details.contains("\nInjected:"))
        XCTAssertLessThanOrEqual(report.summary.count, 8_192)
        XCTAssertLessThanOrEqual(report.details.count, 32_768)
        let line = report.details.split(separator: "\n").first { $0.hasPrefix("Shebang") }
        XCTAssertLessThan(try XCTUnwrap(line).count, 600)
    }
}
