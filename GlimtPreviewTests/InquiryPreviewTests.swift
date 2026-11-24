import AppKit
import Foundation
import InspectorCore
import XCTest

final class InquiryPreviewTests: XCTestCase {
    @MainActor
    func testQuickLookDiagnosticsOpensAsInquirySheet() throws {
        let controller = InquiryViewController(configuration: .init())
        let parent = NSWindow(contentViewController: controller)
        controller.loadViewIfNeeded()

        let diagnostics = try button("InquiryQuickLookDiagnostics", in: controller.view)
        XCTAssertEqual(diagnostics.title, "Quick Look Diagnostics…")
        _ = diagnostics.sendAction(diagnostics.action, to: diagnostics.target)

        XCTAssertNotNil(parent.attachedSheet)
        XCTAssertTrue((parent.attachedSheet?.contentViewController as? GlimtQuickLookDiagnosticsViewController) != nil)
        if let sheet = parent.attachedSheet { parent.endSheet(sheet) }
    }

    @MainActor
    func testSettingsExamplesAreCanonicalValidFilesUsingNormalPipeline() async throws {
        for section in ["general", "text", "source", "sourceThemes", "markdown", "structured"] {
            for example in PreviewSamples.examples(for: section) {
                let selected = try XCTUnwrap(PreviewSamples.url(for: example, bundle: productShowcaseBundle()), example.path)
                let canonical = try fixtureURL(example.path)
                let isTextBundle = URL(fileURLWithPath: example.path).pathExtension == "textbundle"
                if isTextBundle {
                    let selectedMarkdown = try Data(contentsOf: selected.appendingPathComponent("text.md"))
                    let canonicalMarkdown = try Data(contentsOf: canonical.appendingPathComponent("text.md"))
                    XCTAssertEqual(selectedMarkdown, canonicalMarkdown, "\(example.path) package Markdown payload")
                } else {
                    XCTAssertEqual(try Data(contentsOf: selected), try Data(contentsOf: canonical), example.path)
                }
                let preview = try await SharedPreviewPipeline.preview(for: selected, configuration: .init())
                let inspection = preview.inspection
                XCTAssertFalse(inspection.analysis.isBinary && inspection.plistInspection == nil && inspection.additionalInspection == nil,
                               "\(example.path): \(inspection.inspectionDiagnostics)")
                XCTAssertTrue(inspection.structuredDiagnostics.isEmpty, example.path)
                if isTextBundle {
                    let canonicalMarkdown = try Data(contentsOf: canonical.appendingPathComponent("text.md"))
                    XCTAssertEqual(inspection.originalBytes, canonicalMarkdown,
                                   "\(example.path) retains its exact inspected Markdown payload")
                }
                if section == "source" || section == "sourceThemes" {
                    XCTAssertNotNil(inspection.sourceDocument, example.path)
                }
                if section == "markdown" { XCTAssertNotNil(inspection.markdownDocument, example.path) }
                if section == "structured" { XCTAssertTrue(inspection.isStructured, example.path) }
            }
        }
    }

    @MainActor
    func testInquiryUsesNormalPipelineAndTogglesReadOnlyDetailsAndPreviewCallback() async throws {
        let url = try fixtureURL("Cases/source/Example.swift")
        var settings = GlimtSettings.factoryDefaults
        settings.general.maximumPreviewSize = .small
        settings.source.languageOverrides["swift"] = SourceLanguageOverride(fontSize: 15, showLineNumbers: false, wordWrap: true, tabWidth: 7)
        let configuration = RenderConfiguration(settings: settings)
        let normal = try await SharedPreviewPipeline.preview(for: url, configuration: configuration)
        let controller = InquiryViewController(configuration: configuration)
        await controller.loadFile(at: url)
        let report = try XCTUnwrap(controller.report)
        XCTAssertEqual(report.formatName, normal.inspection.formatName)
        XCTAssertEqual(controller.inspection?.detectionReason, normal.inspection.detectionReason)
        XCTAssertEqual(controller.currentFileURL, url)
        let values = descendants(controller.view).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "InquiryValue" }
        XCTAssertFalse(values.isEmpty)
        XCTAssertTrue(values.allSatisfy { !$0.isEditable && $0.isSelectable })
        XCTAssertTrue(reportFields(controller).contains(report.formatName))
        XCTAssertFalse(reportFields(controller).contains(url.path))
        XCTAssertTrue(reportFields(controller).contains("Filename extension (.swift)"))
        assertNoRowRepeatsItsSection(controller)
        let standardTitles = descendants(controller.view).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "InquirySection" }.map(\.stringValue)
        XCTAssertEqual(standardTitles, ["Detected format", "Preview in Glimt", "Finder preview"])
        XCTAssertTrue(reportFields(controller).contains("Format: " + report.formatName))
        let advanced = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == "InquiryMode" })
        XCTAssertEqual((0..<advanced.segmentCount).map { advanced.label(forSegment: $0) }, ["Standard", "Advanced"])
        advanced.selectedSegment = 1; _ = advanced.sendAction(advanced.action, to: advanced.target)
        XCTAssertTrue(reportFields(controller).contains(url.path))
        let titles = descendants(controller.view).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "InquirySection" }.map(\.stringValue)
        XCTAssertEqual(titles, ["File identity", "Content", "Detection", "Glimt support and routing", "Resolved rendering settings"])
        XCTAssertTrue(reportFields(controller).contains("Preview byte limit: \(configuration.maximumPreviewBytes) bytes"))
        assertNoRowRepeatsItsSection(controller)
        let language = try XCTUnwrap(normal.inspection.sourceDocument?.language)
        let resolved = configuration.source(for: language)
        XCTAssertTrue(reportFields(controller).contains("Source language: " + language.displayName))
        XCTAssertTrue(reportFields(controller).contains("Source font: \(resolved.fontFamily), \(resolved.fontSize) pt"))
        XCTAssertTrue(reportFields(controller).contains("Source visual tab width: \(resolved.tabWidth) spaces"))
        XCTAssertTrue(reportFields(controller).contains("Source word wrap: on"))
        XCTAssertTrue(reportFields(controller).contains("Source line numbers: off"))
        advanced.selectedSegment = 0; _ = advanced.sendAction(advanced.action, to: advanced.target)
        XCTAssertFalse(reportFields(controller).contains(url.path))
        XCTAssertFalse(reportFields(controller).contains("Resolved rendering settings"))
        var selectedURL: URL?
        controller.onPreview = { selectedURL = $0 }
        let preview = try button("InquiryPreview", in: controller.view)
        XCTAssertTrue(preview.isEnabled)
        _ = preview.sendAction(preview.action, to: preview.target)
        XCTAssertEqual(selectedURL, url)
        try snapshots(controller, advanced: advanced)
    }

    @MainActor
    func testInquiryExplainsActualUserMappingAndAutomaticAlternative() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("example.foo")
        try Data("hello world\n".utf8).write(to: file)
        var settings = GlimtSettings()
        settings.fileAssociations = [.init(kind: .fileExtension, value: "foo", target: .yaml)]
        let configuration = RenderConfiguration(settings: settings)
        let preview = try await SharedPreviewPipeline.preview(for: file, configuration: configuration)
        let inquiry = InquiryViewController(configuration: configuration)
        await inquiry.loadFile(at: file)
        XCTAssertEqual(preview.inspection.formatName, "YAML")
        XCTAssertEqual(inquiry.inspection?.formatName, preview.inspection.formatName)
        XCTAssertTrue(inquiry.report?.summary.contains("*.foo") == true)
        XCTAssertTrue(inquiry.report?.summary.contains("Plain text") == true)
    }

    @MainActor
    func testInquiryMalformedXMLAndUnavailableFileHaveHonestFallback() async throws {
        let controller = InquiryViewController(configuration: RenderConfiguration())
        await controller.loadFile(at: try fixtureURL("Cases/xml/invalid/malformed.xml"))
        XCTAssertEqual(controller.report?.availableRepresentations, ["Raw"])
        XCTAssertTrue(controller.report?.summary.contains("Partial support") == true)
        await controller.loadFile(at: URL(fileURLWithPath: "/does-not-exist/glimt-inquiry-file"))
        XCTAssertNil(controller.report)
        XCTAssertNil(controller.currentFileURL)
        XCTAssertFalse(try button("InquiryPreview", in: controller.view).isEnabled)
        XCTAssertTrue(reportFields(controller).contains("could not be read"))
    }

    @MainActor
    private func snapshots(_ controller: InquiryViewController, advanced: NSSegmentedControl) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 640, height: 480))
        defer { window.contentViewController = nil; window.close() }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            window.appearance = appearance; controller.view.appearance = appearance
            for state in [0, 1] {
                advanced.selectedSegment = state; _ = advanced.sendAction(advanced.action, to: advanced.target)
                controller.view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                appearance.performAsCurrentDrawingAppearance { controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap) }
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "Inquiry-\(name.rawValue)-\(state == 1 ? "Advanced" : "Standard")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    /// A row label never repeats its section heading; the heading carries the group, the row the fact (D40).
    @MainActor private func assertNoRowRepeatsItsSection(_ controller: InquiryViewController, file: StaticString = #filePath, line: UInt = #line) {
        let groups = descendants(controller.view).compactMap { $0 as? NSStackView }.filter { group in
            group.arrangedSubviews.first.map { ($0 as? NSTextField)?.identifier?.rawValue == "InquirySection" } ?? false
        }
        XCTAssertFalse(groups.isEmpty, file: file, line: line)
        for group in groups {
            let heading = (group.arrangedSubviews[0] as? NSTextField)?.stringValue ?? ""
            let rowLabels = descendants(group).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "InquiryLabel" }.map(\.stringValue)
            XCTAssertFalse(rowLabels.isEmpty, heading, file: file, line: line)
            XCTAssertFalse(rowLabels.contains(heading), "Row label repeats section \(heading)", file: file, line: line)
        }
    }

    @MainActor private func reportFields(_ controller: InquiryViewController) -> String {
        descendants(controller.view).compactMap { $0 as? NSTextField }.compactMap { field in
            field.identifier?.rawValue == "InquiryValue" ? field.accessibilityLabel() : nil
        }.joined(separator: "\n")
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func button(_ identifier: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier })
    }
}
