import AppKit
import CryptoKit
import Darwin
import Foundation
import InspectorCore
import XCTest
import UniformTypeIdentifiers

final class PreviewViewControllerTests: XCTestCase {
    @MainActor
    func testLogSeverityColorsUseSemanticSystemColors() {
        XCTAssertEqual(StructuredTreeView.logLevelColor(for: "ERROR"), .systemRed)
        XCTAssertEqual(StructuredTreeView.logLevelColor(for: "WARN"), .systemOrange)
        XCTAssertEqual(StructuredTreeView.logLevelColor(for: "INFO"), .controlAccentColor)
        XCTAssertEqual(StructuredTreeView.logLevelColor(for: "DEBUG"), .secondaryLabelColor)
        XCTAssertNil(StructuredTreeView.logLevelColor(for: "unknown"))
    }

    @MainActor
    func testLogTableHeadersSortAndFilterTheirColumns() throws {
        let table = CSVTablePreviewView(frame: .zero)
        table.display(headers: ["Line", "Severity", "Message"], rows: [
            ["10", "INFO", "connected"],
            ["2", "ERROR", "request failed"],
            ["3", "DEBUG", "retrying"]
        ], interactiveHeaders: true)
        let nativeTable = try XCTUnwrap(allViews(beneath: table).compactMap { $0 as? NSTableView }.first)

        XCTAssertNotNil(nativeTable.tableColumns[1].headerCell.menu?.item(withTitle: "Filter…"))
        table.tableView(nativeTable, didClick: nativeTable.tableColumns[0])
        XCTAssertEqual(table.tableView(nativeTable, objectValueFor: nativeTable.tableColumns[0], row: 0) as? String, "2")

        table.applyFilter("error", to: 1)
        table.applyFilter("failed", to: 2)
        XCTAssertEqual(table.numberOfRows(in: nativeTable), 1)
        XCTAssertEqual(table.tableView(nativeTable, objectValueFor: nativeTable.tableColumns[2], row: 0) as? String, "request failed")

        table.applyFilter("", to: 1)
        XCTAssertEqual(table.numberOfRows(in: nativeTable), 1)
        table.applyFilter("", to: 2)
        XCTAssertEqual(table.numberOfRows(in: nativeTable), 3)
    }

    @MainActor
    func testMarkdownLastDocumentPixelCanScrollFullyAboveFooter() throws {
        let controller = makeSizedPreviewController()
        controller.view.setFrameSize(.init(width: 640, height: 480))
        controller.display(try PreviewPreparation.read(at: fixtureURL("Showcase/markdown/markdown.md")))
        controller.view.layoutSubtreeIfNeeded()
        let views = allViews(beneath: controller.view)
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { !$0.isHiddenOrHasHiddenAncestor })
        let container = try XCTUnwrap(text.textContainer)
        let layout = try XCTUnwrap(text.layoutManager)
        layout.ensureLayout(for: container)
        text.scrollToEndOfDocument(nil)
        controller.view.layoutSubtreeIfNeeded()
        let glyph = try XCTUnwrap(layout.numberOfGlyphs > 0 ? layout.numberOfGlyphs - 1 : nil)
        let last = layout.boundingRect(forGlyphRange: .init(location: glyph, length: 1), in: container)
            .offsetBy(dx: text.textContainerInset.width, dy: text.textContainerInset.height)
        let lastOnScreen = text.convert(last, to: controller.view)
        let footer = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewFooter" })
        let footerFrame = footer.convert(footer.bounds, to: controller.view)
        if controller.view.isFlipped { XCTAssertLessThanOrEqual(lastOnScreen.maxY, footerFrame.minY) }
        else { XCTAssertGreaterThanOrEqual(lastOnScreen.minY, footerFrame.maxY) }
    }

    @MainActor
    func testEveryRepresentationClipsAndInsetsItsViewportAboveFooter() throws {
        for size in [NSSize(width: 640, height: 480), NSSize(width: 360, height: 480)] {
            for path in ["Showcase/markdown/markdown.md", "Showcase/source/swift.swift", "Showcase/json/json.json", "Showcase/plist/binary.plist"] {
                let controller = makeSizedPreviewController()
                controller.view.setFrameSize(size)
                controller.display(try PreviewPreparation.read(at: fixtureURL(path)))
                let views = allViews(beneath: controller.view)
                let content = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewContent" })
                let footer = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewFooter" })
                let tabs = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
                for mode in 0..<max(1, tabs.segmentCount) {
                    if tabs.segmentCount > 0 && tabs.isEnabled(forSegment: mode) {
                        tabs.selectedSegment = mode; _ = tabs.sendAction(tabs.action, to: tabs.target)
                    }
                    controller.view.layoutSubtreeIfNeeded()
                    XCTAssertTrue(content.clipsToBounds, path)
                    let footerRect = footer.convert(footer.bounds, to: controller.view)
                    let contentRect = content.convert(content.bounds, to: controller.view)
                    XCTAssertFalse(footerRect.intersects(contentRect), path)
                    for scroll in allViews(beneath: content).compactMap({ $0 as? NSScrollView }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
                        XCTAssertGreaterThanOrEqual(scroll.contentInsets.bottom, footer.bounds.height, path)
                        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: controller.view)
                        XCTAssertFalse(viewport.intersects(footerRect), path)
                    }
                }
            }
        }
    }

    @MainActor
    func testSwiftAndCSVRepresentationsUseCatalogTabsAndSharedHex() throws {
        let swift = Data("let answer = 42\n".utf8)
        let swiftController = makeSizedPreviewController()
        swiftController.display(.prepare(bytes: swift, fileSize: swift.count, fileName: "Example.swift", systemUTI: nil))
        let swiftTabs = try XCTUnwrap(allViews(beneath: swiftController.view).compactMap { $0 as? PreviewTabStrip }.first)
        XCTAssertEqual((0..<swiftTabs.segmentCount).compactMap(swiftTabs.label(forSegment:)), ["Source", "Raw"], "Hex is supported but not in the Source Code profile")
        XCTAssertNotNil(try XCTUnwrap(FormatCatalog.definition(for: .swift)).defaultRepresentation)

        let csv = Data("name,kind\nGlimt,document\n".utf8)
        let csvController = makeSizedPreviewController()
        csvController.display(.prepare(bytes: csv, fileSize: csv.count, fileName: "items.csv", systemUTI: nil))
        let views = allViews(beneath: csvController.view)
        let tabs = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        XCTAssertEqual((0..<tabs.segmentCount).compactMap(tabs.label(forSegment:)), ["Table", "Raw"])
        XCTAssertFalse(try XCTUnwrap(views.first { $0 is CSVTablePreviewView }).isHiddenOrHasHiddenAncestor)
        tabs.selectedSegment = 1
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertFalse(try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first).string.isEmpty)
    }

    @MainActor
    func testRefinedChromeUsesTabsStatusViewsAndStableFooterGeometry() throws {
        let controller = makeSizedPreviewController()
        controller.view.setFrameSize(.init(width: 900, height: 600))
        let bytes = Data("name: Glimt\nenabled: true\nitems: [one, two]\n".utf8)
        controller.display(.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.yaml", systemUTI: nil))
        let views = allViews(beneath: controller.view)
        XCTAssertFalse(views.contains { $0 is NSSegmentedControl })
        let tabs = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        let status = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first)
        let footer = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewFooter" })
        for index in 0..<3 {
            tabs.selectedSegment = index
            _ = tabs.sendAction(tabs.action, to: tabs.target)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(footer.frame.height, 28)
            XCTAssertEqual(tabs.frame.minX, PreviewRepresentationTabStrip.tabLeadingInset)
            XCTAssertEqual(tabs.frame.height, 28)
        }
        XCTAssertFalse(status.stringValue.contains("|"))
        XCTAssertTrue(allViews(beneath: status).contains { $0.identifier?.rawValue == "PreviewStatusSeparator" })
        let full = status.accessibilityLabel()
        controller.view.setFrameSize(.init(width: 300, height: 600))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(status.accessibilityLabel(), full)
        XCTAssertLessThan(status.visibleItemCount, status.items.count)
    }

    @MainActor
    func testSelectedBottomTabConnectsToContentAndBreaksFooterSeparator() throws {
        let controller = makeSizedPreviewController()
        controller.view.setFrameSize(.init(width: 900, height: 600))
        let bytes = Data("{\"name\":\"Glimt\"}".utf8)
        controller.display(.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.json", systemUTI: nil))
        controller.view.layoutSubtreeIfNeeded()
        let views = allViews(beneath: controller.view)
        let footer = try XCTUnwrap(views.compactMap { $0 as? PreviewRepresentationTabStrip }.first)
        let tabs = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        let content = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewContent" })
        let contentFrame = content.convert(content.bounds, to: controller.view)
        let footerFrame = footer.convert(footer.bounds, to: controller.view)

        for index in 0..<tabs.segmentCount {
            tabs.selectedSegment = index
            controller.view.layoutSubtreeIfNeeded()
            tabs.layoutSubtreeIfNeeded()
            let selectedInFooter = try XCTUnwrap(footer.selectedTabFrame)
            XCTAssertEqual(selectedInFooter.maxY, footer.bounds.maxY)
            XCTAssertEqual(selectedInFooter.minY, PreviewTabGeometry.selectedTabBottomInset)
            XCTAssertEqual(selectedInFooter.height, PreviewTabStrip.tabHeight - PreviewTabGeometry.selectedTabBottomInset)
            XCTAssertEqual(selectedInFooter.minX,
                           PreviewRepresentationTabStrip.tabLeadingInset + CGFloat(index) * tabs.itemWidth)
            XCTAssertGreaterThan(selectedInFooter.minY, footer.bounds.minY)
            XCTAssertTrue(footer.topSeparatorSegments.allSatisfy { !$0.intersects(selectedInFooter) })
            XCTAssertTrue(footer.topSeparatorSegments.contains { $0.maxX == selectedInFooter.minX })
            XCTAssertTrue(footer.topSeparatorSegments.contains { $0.minX == selectedInFooter.maxX })
            XCTAssertEqual(footer.selectedTabOutlineSegments.count, 3)
            XCTAssertTrue(footer.selectedTabOutlineSegments.contains { $0.minY == selectedInFooter.minY })
            XCTAssertTrue(footer.selectedTabBackgroundColor.isEqual(NSColor.textBackgroundColor))
            XCTAssertFalse(footer.selectedTabBackgroundColor.isEqual(footer.footerBackgroundColor))
            XCTAssertFalse(tabs.subviews.compactMap { $0 as? NSButton }.contains(where: \.isBordered))
            XCTAssertEqual(content.convert(content.bounds, to: controller.view), contentFrame)
            XCTAssertEqual(footer.convert(footer.bounds, to: controller.view), footerFrame)
        }
    }

    @MainActor
    func testClickMovesSelectedTabOutlineAndSeparatorGap() throws {
        let controller = makeSizedPreviewController()
        controller.view.setFrameSize(.init(width: 900, height: 600))
        let raw = "{\"name\":\"Glimt\",\"version\":1}"
        let prepared = PreviewPreparation.prepare(bytes: Data(raw.utf8), fileSize: raw.utf8.count,
                                                 fileName: "sample.json", systemUTI: nil)
        controller.display(prepared)
        controller.view.layoutSubtreeIfNeeded()

        let views = allViews(beneath: controller.view)
        let footer = try XCTUnwrap(views.compactMap { $0 as? PreviewRepresentationTabStrip }.first)
        let tabs = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        let tree = try XCTUnwrap(views.compactMap { $0 as? StructuredTreeView }.first)
        let text = try XCTUnwrap(views.compactMap { $0 as? StructuredTextPreview }.first)
        let buttons = tabs.subviews.compactMap { $0 as? NSButton }
        XCTAssertTrue(buttons.allSatisfy { $0.focusRingType == .none },
                      "A focus ring on a previously focused tab can look like a stale selection")
        for index in buttons.indices {
            try XCTUnwrap(buttons.indices.contains(index) ? buttons[index] : nil).performClick(nil)
            controller.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(tabs.selectedSegment, index)
            let selectedFrame = try XCTUnwrap(footer.selectedTabFrame)
            XCTAssertEqual(selectedFrame.minX,
                           PreviewRepresentationTabStrip.tabLeadingInset + CGFloat(index) * tabs.itemWidth)
            XCTAssertTrue(footer.selectedTabOutlineSegments.contains { $0.minX == selectedFrame.minX })
            XCTAssertTrue(footer.topSeparatorSegments.contains { $0.maxX == selectedFrame.minX })

            switch index {
            case 0:
                XCTAssertFalse(tree.isHidden, "Tree must own the document while its tab is selected")
            case 1:
                XCTAssertTrue(tree.isHidden, "Pretty must own the document while its tab is selected")
                XCTAssertEqual(text.textView.string, prepared.structuredPrettyText)
            case 2:
                XCTAssertTrue(tree.isHidden, "Raw must own the document while its tab is selected")
                XCTAssertEqual(text.textView.string, prepared.structuredRawText)
            default:
                XCTFail("Unexpected representation tab at index \(index)")
            }
        }
    }

    func testHexPresentationHasOffsetsASCIIAndBoundedRows() {
        let text = HexPreview.format(Data("bplist00".utf8))
        XCTAssertTrue(text.hasPrefix("00000000  62 70 6c 69 73 74 30 30"))
        XCTAssertTrue(text.contains("|bplist00|"))
        XCTAssertEqual(HexPreview.format(Data(repeating: 0, count: 100_000)).split(separator: "\n").count, HexPreview.maximumBytes / 16)
    }

    @MainActor
    func testStructuredTextGutterAndHighlightingPreserveOriginalAcrossFormats() throws {
        let samples: [(String, String)] = [
            ("yaml", "name: \"Glimt\"\r\nenabled: true\r\nitems: [one, 42]\r\n"),
            ("json", "{\"name\":\"Glimt\",\"enabled\":true,\"count\":42}"),
            ("xml", "<root enabled=\"true\"><!-- comment -->text</root>"),
            ("plist", "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>name</key><string>Glimt</string></dict></plist>")
        ]
        for (ext, original) in samples {
            let controller = makeSizedPreviewController()
            controller.view.setFrameSize(.init(width: 640, height: 480))
            let bytes = Data(original.utf8)
            let prepared = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample." + ext, systemUTI: nil)
            controller.display(prepared)
            let surface = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? StructuredTextPreview }.first)
            XCTAssertEqual(surface.textView.string, original)
            XCTAssertTrue(surface.rulersVisible)
            var colors = Set<String>()
            surface.textView.textStorage?.enumerateAttribute(.foregroundColor, in: .init(location: 0, length: original.utf16.count)) { value, _, _ in
                if let color = value as? NSColor { colors.insert(color.description) }
            }
            XCTAssertGreaterThan(colors.count, 1, ext)
            let tabs = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? PreviewTabStrip }.first)
            tabs.selectedSegment = 1
            _ = tabs.sendAction(tabs.action, to: tabs.target)
            XCTAssertEqual(surface.textView.string, prepared.structuredPrettyText)
            XCTAssertTrue(surface.rulersVisible)
        }
    }

    @MainActor
    func testTabsSkipDisabledRepresentationsAndExposeSelectedTabState() throws {
        let controller = makeSizedPreviewController()
        let bytes = Data("items: [broken".utf8)
        controller.display(.prepare(bytes: bytes, fileSize: bytes.count, fileName: "broken.yaml", systemUTI: nil))
        let tabs = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? PreviewTabStrip }.first)
        let buttons = tabs.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual((0..<tabs.segmentCount).compactMap(tabs.label(forSegment:)), ["Raw"], "Unavailable views are hidden; Raw is the recovery view")
        XCTAssertEqual(buttons.map(\.isEnabled), [true])
        XCTAssertEqual(buttons.first?.accessibilityRole(), .radioButton)
        XCTAssertEqual(buttons.first?.accessibilitySubrole(), NSAccessibility.Subrole.tabButtonSubrole)
        XCTAssertEqual(tabs.accessibilityRole(), .tabGroup)
        XCTAssertEqual(tabs.accessibilitySelectedChildren()?.count, 1)
        XCTAssertEqual(tabs.selectedSegment, 0)
        tabs.moveSelection(by: 1)
        XCTAssertEqual(tabs.selectedSegment, 0)
        XCTAssertEqual(tabs.accessibilitySelectedChildren()?.count, 1)
        XCTAssertEqual(tabs.accessibilitySelectedChildren()?.first as? NSButton, buttons.first)
    }

    func testRepresentationTabHairlinesAreOnePhysicalPixelAtOneAndTwoTimes() {
        for scale: CGFloat in [1, 2] {
            let thickness = PreviewTabGeometry.hairlineThickness(backingScaleFactor: scale)
            XCTAssertEqual(thickness * scale, 1, accuracy: 0.001)
            let tab = NSRect(x: 76, y: PreviewTabGeometry.selectedTabBottomInset,
                             width: 76, height: 28 - PreviewTabGeometry.selectedTabBottomInset)
            let top = PreviewTabGeometry.separatorSegments(width: 400, height: 28, selectedTab: tab, scale: scale)
            let outline = PreviewTabGeometry.selectedOutlineSegments(tab: tab, scale: scale)
            XCTAssertEqual(top.count, 2)
            XCTAssertEqual(outline.count, 3)
            XCTAssertTrue((top + outline).allSatisfy { abs($0.minX * scale - ($0.minX * scale).rounded()) < 0.001 })
            XCTAssertTrue((top + outline).allSatisfy { abs($0.minY * scale - ($0.minY * scale).rounded()) < 0.001 })
            XCTAssertTrue((top + outline).allSatisfy {
                abs($0.width * scale - ($0.width * scale).rounded()) < 0.001
                    && abs($0.height * scale - ($0.height * scale).rounded()) < 0.001
            })
            XCTAssertTrue(top.allSatisfy { $0.height == thickness })
            XCTAssertTrue(outline.allSatisfy { $0.width == thickness || $0.height == thickness })
            XCTAssertTrue(outline.contains { $0.minY > 0 && $0.minY == tab.minY })
        }
    }

    @MainActor
    func testCanonicalYAMLAndJSONShowDifferentRealRawAndPrettyRepresentations() throws {
        for path in ["Showcase/yaml/yaml.yaml", "Showcase/json/json.json"] {
            let prepared = try PreviewPreparation.read(at: fixtureURL(path))
            XCTAssertNotNil(prepared.structuredPrettyText)
            XCTAssertNotEqual(prepared.structuredRawText, prepared.structuredPrettyText)
            let controller = makeSizedPreviewController()
            controller.view.setFrameSize(.init(width: 640, height: 480))
            controller.display(prepared)
            let tabs = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? PreviewTabStrip }.first)
            tabs.selectedSegment = 0
            tabs.moveSelection(by: 1)
            XCTAssertEqual(tabs.selectedSegment, 1)
        }
    }

    private var temporaryDirectoryURL: URL?
    private var oversizedFixtureURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlimtPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        temporaryDirectoryURL = directoryURL
        oversizedFixtureURL = directoryURL.appendingPathComponent("oversized.json")
        try Data(repeating: 0x61, count: 1_048_577).write(to: try XCTUnwrap(oversizedFixtureURL))
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testSharedFooterContainsRepresentationNavigationAndSingleStatus() throws {
        let controller = makeSizedPreviewController()
        let bytes = Data("{\"value\":1}".utf8)
        controller.display(PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.json", systemUTI: nil))
        let views = allViews(beneath: controller.view)
        let footer = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewFooter" })
        let status = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first { $0.identifier?.rawValue == "PreviewModeControl" })
        XCTAssertEqual((0..<modes.segmentCount).map { modes.label(forSegment: $0) }, ["Tree", "Pretty", "Raw"])
        XCTAssertTrue(status.isDescendant(of: footer))
        XCTAssertTrue(modes.isDescendant(of: footer))
        XCTAssertEqual(views.filter { $0.identifier?.rawValue == "PreviewStatus" }.count, 1)
        XCTAssertFalse(status.stringValue.contains("Rendered by Glimt"))
        XCTAssertTrue((status.accessibilityLabel() ?? status.stringValue).contains("Valid JSON"))
        XCTAssertFalse((status.accessibilityLabel() ?? "").isEmpty)
        XCTAssertEqual(status.toolTip, status.accessibilityLabel())
        let text = Data("ordinary text".utf8)
        controller.display(PreviewPreparation.prepare(bytes: text, fileSize: text.count, fileName: "notes", systemUTI: nil))
        XCTAssertFalse(footer.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(status.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(modes.isHiddenOrHasHiddenAncestor)
    }

    @MainActor
    func testFooterStatusRemainsVisibleAcrossPreviewStates() throws {
        let cases: [(String, Data, Int)] = [
            ("config", Data("---\na: 1\nb: 2\n".utf8), 14),
            ("unknown", Data(), 0),
            ("sample.json", Data("{\"items\":[1,true]}".utf8), 18),
            ("sample.json", Data("{bad".utf8), 4),
            ("sample.json", Data("{}".utf8), 20),
            ("sample.json", Data([0x00, 0x01]), 2)
        ]
        let controller = makeSizedPreviewController()
        for (name, bytes, size) in cases {
            controller.display(PreviewPreparation.prepare(bytes: bytes, fileSize: size, fileName: name, systemUTI: nil))
            controller.view.setFrameSize(NSSize(width: 640, height: 480))
            controller.view.layoutSubtreeIfNeeded()
            let views = allViews(beneath: controller.view)
            let footer = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewFooter" })
            let status = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
            XCTAssertFalse(status.stringValue.isEmpty)
            XCTAssertFalse((status.accessibilityLabel() ?? "").isEmpty)
            XCTAssertEqual(status.toolTip, status.accessibilityLabel())
            XCTAssertFalse(footer.isHiddenOrHasHiddenAncestor)
            let footerFrame = footer.convert(footer.bounds, to: controller.view)
            let body = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
            let bodyFrame = body.convert(body.bounds, to: controller.view)
            XCTAssertEqual(footer.bounds.height, 28, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(footerFrame.minY, controller.view.bounds.minY)
            if controller.view.isFlipped { XCTAssertGreaterThanOrEqual(footerFrame.minY, bodyFrame.maxY) }
            else { XCTAssertLessThanOrEqual(footerFrame.maxY, bodyFrame.minY) }
            XCTAssertGreaterThan(bodyFrame.height, 0)
        }
    }

    @MainActor
    func testDisplaysDecodedUTF8AndFooterStatus() async throws {
        let url = try fixtureURL("Cases/json/valid/unicode.json")
        let preview = await render(at: url)

        XCTAssertEqual(preview.text, "{\"text\":\"åäö 🙂\\tTabbed\"}\n")
        assertStatus(preview.header, contains: "JSON | UTF-8 | LF")
    }

    @MainActor
    func testDisplaysWindows1252FallbackWithoutMojibake() async throws {
        let url = try fixtureURL("Cases/json/invalid/invalid-utf8.json")
        let preview = await render(at: url)

        XCTAssertEqual(preview.text, "Ã(ÿ")
        assertStatus(preview.header, contains: "JSON | Windows-1252")
    }

    @MainActor
    func testFR005PresentationCheckpoint() throws {
        let cases: [(name: String, source: String, expectedHeader: String)] = [
            (
                "config",
                "---\na: 1\nb: 2\n",
                "YAML | UTF-8 | LF"
            ),
            (
                "script",
                "#!/usr/bin/env python3\nprint(1)\n",
                "Python | UTF-8 | LF"
            )
        ]

        for testCase in cases {
            let bytes = Data(testCase.source.utf8)
            let preparation = PreviewPreparation.prepare(
                bytes: bytes,
                fileSize: bytes.count,
                fileName: testCase.name,
                systemUTI: nil
            )
            let controller = makeSizedPreviewController()
            controller.display(preparation)

            let descendants = allViews(beneath: controller.view)
            guard
                let header = descendants.compactMap({ $0 as? PreviewStatusView }).first(where: {
                    $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
                }),
                let scrollView = descendants.compactMap({ $0 as? NSScrollView }).first,
                let textView = scrollView.documentView as? NSTextView
            else {
                XCTFail("Preview controller did not create its text view", file: #filePath, line: #line)
                continue
            }

            assertStatus(header.accessibilityLabel() ?? header.stringValue, contains: testCase.expectedHeader, message: testCase.name)
            XCTAssertEqual(textView.string, testCase.source, testCase.name)
        }
    }

    @MainActor
    func testDeterministicFooterStatusesDescribeDisplayedContent() throws {
        let cases: [(name: String, source: String, uti: String?, expectedType: String, expectedHeader: String)] = [
            ("sample.ts", "const x: number = 1;\n", nil, "typescript", "TypeScript | UTF-8 | LF"),
            ("sample.d.ts", "declare const x: string;\n", nil, "typescript-declaration", "TypeScript | UTF-8 | LF"),
            ("app.local", "KEY=value\n", nil, "generic-local", "Generic Local | UTF-8 | LF"),
            ("Makefile", "all:\n", nil, "make", "Makefile | UTF-8 | LF"),
            ("Dockerfile", "FROM scratch\n", nil, "dockerfile", "Dockerfile | UTF-8 | LF"),
            ("settings.local", "value\n", nil, "generic-local", "Generic Local | UTF-8 | LF"),
            ("script.py", "print(1)\n", nil, "python", "Python | UTF-8 | LF"),
            ("config", "---\na: 1\nb: 2\n", nil, "yaml", "YAML | UTF-8 | LF"),
            ("script", "plain words\n", nil, "unknown", "Plain text | UTF-8 | LF"),
            ("script", "", nil, "unknown", "Plain text | UTF-8"),
            ("script", "print(1)\n", "public.python-script", "python", "Python | UTF-8 | LF"),
            ("script", "#!/usr/bin/env python3\nprint(1)\n", nil, "python", "Python | UTF-8 | LF"),
            ("sample.ts", "const x: number = 1;\n", "public.mpeg-2-transport-stream", "typescript", "TypeScript | UTF-8 | LF")
        ]

        for testCase in cases {
            let bytes = Data(testCase.source.utf8)
            let preparation = PreviewPreparation.prepare(
                bytes: bytes,
                fileSize: bytes.count,
                fileName: testCase.name,
                systemUTI: testCase.uti
            )
            XCTAssertEqual(preparation.resolution.typeID, testCase.expectedType, testCase.name)
            let controller = makeSizedPreviewController()
            controller.display(preparation)
            let views = allViews(beneath: controller.view)
            let header = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first {
                $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
            })
            assertStatus(header.accessibilityLabel() ?? header.stringValue, contains: testCase.expectedHeader, message: testCase.name)
            XCTAssertFalse((header.accessibilityLabel() ?? "").isEmpty, testCase.name)
            XCTAssertFalse(header.stringValue.contains("Tentative"), testCase.name)
            XCTAssertFalse(header.stringValue.contains("Confidence"), testCase.name)
            let textView = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTextView)
            XCTAssertEqual(textView.string, testCase.source, testCase.name)
        }
    }

    @MainActor
    func testYAMLDocumentsBlockScalarsAndModes() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/yaml/valid/multi-document.yaml"))
        let source = String(decoding: bytes, as: UTF8.self)
        let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.yaml", systemUTI: "public.yaml")
        XCTAssertEqual(preparation.yamlInspection?.documents?.count, 3)
        let controller = makeSizedPreviewController()
        controller.display(preparation)
        let views = allViews(beneath: controller.view)
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        let outline = try XCTUnwrap(views.compactMap { $0 as? NSOutlineView }.first)
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        let header = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        assertStatus(header.accessibilityLabel() ?? header.stringValue, contains: "Valid YAML | 3 documents")
        XCTAssertFalse(header.stringValue.contains("Confidence"))
        XCTAssertEqual(modes.selectedSegment, 0, "Tree is the first view of the Structured Data profile")
        let root = try XCTUnwrap(outline.item(atRow: 0))
        XCTAssertEqual(outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: root), 3)
        let first = try XCTUnwrap(outline.dataSource?.outlineView?(outline, child: 0, ofItem: root))
        outline.expandItem(first)
        let body = try XCTUnwrap(outline.dataSource?.outlineView?(outline, child: 1, ofItem: first))
        let valueColumn = try XCTUnwrap(outline.tableColumns.first { $0.identifier.rawValue == "Value" })
        let value = outline.delegate?.outlineView?(outline, viewFor: valueColumn, item: body) as? NSTextField
        XCTAssertEqual(value?.stringValue, "line one\nline two\n")
        XCTAssertGreaterThan(try XCTUnwrap(outline.delegate?.outlineView?(outline, heightOfRowByItem: body)), outline.rowHeight)
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertEqual(text.string, preparation.yamlInspection?.prettyText)
        XCTAssertEqual(try YAMLInspector.inspect(bytes: Data(text.string.utf8)).documents, preparation.yamlInspection?.documents)
        modes.selectedSegment = 2
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertEqual(text.string, source)
        try attachStructuredSnapshots(controller, format: "YAML")
    }

    @MainActor
    func testYAMLLimitsAndMalformedInputKeepRaw() throws {
        let nested = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        for (index, source) in ["a: [broken\n", nested, "base: &base [x, x]\nb: &b [*base, *base]\nc: &c [*b, *b]\n"].enumerated() {
            let bytes = Data(source.utf8)
            let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.yml", systemUTI: nil)
            let controller = makeSizedPreviewController()
            controller.display(preparation)
            let views = allViews(beneath: controller.view)
            let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
            let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
            XCTAssertFalse(modes.isHidden)
            if index < 2 {
                XCTAssertNil(preparation.yamlInspection?.documents)
                XCTAssertEqual(modes.segmentCount, 1, "Only the Raw recovery view is offered")
                XCTAssertEqual(modes.label(forSegment: 0), "Raw")
                XCTAssertEqual(modes.selectedSegment, 0)
                let diagnostic = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
                XCTAssertFalse(diagnostic.isHidden)
            }
            else { XCTAssertNotNil(preparation.yamlInspection?.documents) }
            modes.selectedSegment = modes.segmentCount - 1
            _ = modes.sendAction(modes.action, to: modes.target)
            XCTAssertEqual(text.string, source)
        }
    }

    @MainActor
    func testGenuineYAMLPreview() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["FR009_REAL_INPUT"] else {
            if environment["FR009_REQUIRE_REAL_INPUT"] == "1" { return XCTFail("Required genuine YAML is missing") }
            throw XCTSkip("Genuine YAML is not configured")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let preparation = try PreviewPreparation.read(at: URL(fileURLWithPath: path))
        XCTAssertEqual(preparation.yamlInspection?.documents?.count, 1)
        let controller = makeSizedPreviewController()
        controller.display(preparation)
        let views = allViews(beneath: controller.view)
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(modes.selectedSegment, 0)
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertEqual(try YAMLInspector.inspect(bytes: Data(text.string.utf8)).documents, preparation.yamlInspection?.documents)
        modes.selectedSegment = 2
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertEqual(text.string, String(data: bytes, encoding: .utf8))
    }

    @MainActor
    func testJSONModesPreserveOriginalAndExposeTypedCollapsibleTree() throws {
        let source = " {\"items\": [true, null, 42], \"name\": \"å\\n🙂\"}\r\n"
        let bytes = Data(source.utf8)
        let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.json", systemUTI: "public.json")
        XCTAssertEqual(preparation.resolution.typeID, "json")
        let controller = makeSizedPreviewController()
        controller.display(preparation)
        let views = allViews(beneath: controller.view)
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        let outline = try XCTUnwrap(views.compactMap { $0 as? NSOutlineView }.first)
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        XCTAssertFalse(modes.isHidden)
        XCTAssertEqual(modes.selectedSegment, 0)
        XCTAssertEqual(outline.numberOfRows, 3, "Root plus two object members")
        let root = try XCTUnwrap(outline.item(atRow: 0))
        let items = try XCTUnwrap(outline.dataSource?.outlineView?(outline, child: 0, ofItem: root))
        XCTAssertEqual(outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: items), 3)
        outline.expandItem(items)
        XCTAssertEqual(outline.numberOfRows, 6)
        let typeColumn = try XCTUnwrap(outline.tableColumns.first { $0.identifier.rawValue == "Type" })
        let firstValue = try XCTUnwrap(outline.dataSource?.outlineView?(outline, child: 0, ofItem: items))
        let typeLabel = outline.delegate?.outlineView?(outline, viewFor: typeColumn, item: firstValue) as? NSTextField
        XCTAssertEqual(typeLabel?.stringValue, "Boolean")
        outline.collapseItem(items)
        XCTAssertEqual(outline.numberOfRows, 3)
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertEqual(text.string, preparation.jsonInspection?.prettyText)
        XCTAssertNotEqual(text.string, source)
        modes.selectedSegment = 2
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertEqual(text.string, source)
        XCTAssertTrue(text.isSelectable)
        XCTAssertEqual(text.font, NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))

        try attachStructuredSnapshots(controller, format: "JSON")
    }

    @MainActor
    func testInvalidDeepAndTruncatedJSONKeepRawAvailable() throws {
        let deep = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        for (source, extraSize) in [("{bad", 0), (deep, 0), ("{}", 20)] {
            let bytes = Data(source.utf8)
            let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count + extraSize, fileName: "sample.json", systemUTI: nil)
            let controller = makeSizedPreviewController()
            controller.display(preparation)
            let views = allViews(beneath: controller.view)
            let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
            let diagnostic = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
            let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
            XCTAssertEqual(modes.segmentCount, 1, "Unavailable Tree and Pretty are hidden, not disabled")
            XCTAssertEqual(modes.label(forSegment: 0), "Raw")
            XCTAssertEqual(modes.selectedSegment, 0)
            XCTAssertTrue(modes.isEnabled(forSegment: 0))
            XCTAssertFalse(diagnostic.isHidden)
            XCTAssertFalse(diagnostic.stringValue.isEmpty)
            let fullStatus = diagnostic.accessibilityLabel() ?? diagnostic.stringValue
            if source == "{bad" { XCTAssertTrue(fullStatus.contains("Invalid JSON")) }
            else {
                XCTAssertFalse(fullStatus.contains("Invalid"), "A resource limit does not prove syntax is invalid")
                XCTAssertTrue(fullStatus.lowercased().contains("truncated") || fullStatus.lowercased().contains("limit"))
            }
            XCTAssertEqual(text.string, source)
        }
    }

    @MainActor
    func testGenuineJSONModes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["FR008_REAL_INPUT"] else {
            if environment["FR008_REQUIRE_REAL_INPUT"] == "1" {
                return XCTFail("Required genuine JSON input is missing")
            }
            throw XCTSkip("Genuine JSON input is not configured")
        }
        let url = URL(fileURLWithPath: path)
        let bytes = try Data(contentsOf: url)
        let preparation = try PreviewPreparation.read(at: url)
        XCTAssertEqual(preparation.resolution.typeID, "json")
        XCTAssertEqual(preparation.jsonInspection?.rawBytes, bytes)
        XCTAssertTrue(preparation.jsonInspection?.diagnostics.isEmpty == true)
        let controller = makeSizedPreviewController()
        controller.display(preparation)
        let views = allViews(beneath: controller.view)
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(modes.selectedSegment, 0)
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        let original = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
        let pretty = try JSONSerialization.jsonObject(with: Data(text.string.utf8)) as? NSDictionary
        XCTAssertNotNil(original)
        XCTAssertEqual(original, pretty)
        modes.selectedSegment = 2
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertEqual(text.string, String(data: bytes, encoding: .utf8))
    }

    @MainActor
    func testUnknownUTIDisplaysReadablePlainTextWithoutInventedClassification() throws {
        let bytes = Data("ordinary words\n".utf8)
        let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "unknown", systemUTI: "com.example.private-content")
        let controller = makeSizedPreviewController()
        controller.display(preparation)
        let header = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        assertStatus(header.accessibilityLabel() ?? header.stringValue, contains: "Plain text | UTF-8 | LF")
        XCTAssertFalse((header.accessibilityLabel() ?? "").isEmpty)
        XCTAssertFalse(header.stringValue.contains("Confidence"))
        XCTAssertFalse(header.stringValue.contains("Tentative"))
    }

    @MainActor
    func testFooterKeepsTabsBeforeTruncatingItsSingleLineStatus() throws {
        let bytes = Data("{\"message\":\"hello\"}".utf8)
        let controller = makeSizedPreviewController()
        controller.display(PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.json", systemUTI: nil))
        let views = allViews(beneath: controller.view)
        let status = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        let footer = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewFooter" })
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first { $0.identifier?.rawValue == "PreviewModeControl" })
        XCTAssertFalse((status.accessibilityLabel() ?? "").isEmpty)
        XCTAssertEqual(status.toolTip, status.accessibilityLabel())
        for size in [NSSize(width: 640, height: 480), NSSize(width: 1_200, height: 900), NSSize(width: 240, height: 480)] {
            controller.view.setFrameSize(size)
            controller.view.layoutSubtreeIfNeeded()
            let footerFrame = footer.convert(footer.bounds, to: controller.view)
            let modeFrame = modes.convert(modes.bounds, to: controller.view)
            let statusFrame = status.convert(status.bounds, to: controller.view)
            XCTAssertTrue(status.isDescendant(of: footer), "No status banner belongs above content")
            XCTAssertGreaterThanOrEqual(modeFrame.minX, footerFrame.minX)
            XCTAssertLessThanOrEqual(modeFrame.maxX, statusFrame.minX)
            XCTAssertLessThanOrEqual(statusFrame.maxX, footerFrame.maxX)
            XCTAssertGreaterThanOrEqual(modeFrame.width, modes.intrinsicContentSize.width - 1)
        }
    }

    @MainActor
    func testMarkdownTOCTracksRenderedGeometryAndNavigatesWithoutChangingTextSelection() throws {
        let body = String(repeating: "Reading line with enough words to span the preview.\n", count: 30)
        let raw = "# Start\n\n\(body)\n## Repeated\n\n\(body)\n## Repeated\n\n\(body)\n### Café **Formatted**\n\n\(body)\n"
        let bytes = Data(raw.utf8)
        let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                                                     fileName: "toc.md", systemUTI: "net.daringfireball.markdown")
        let controller = makeSizedPreviewController(size: .init(width: 960, height: 620))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.display(preparation)
        controller.view.layoutSubtreeIfNeeded()

        let views = allViews(beneath: controller.view)
        let hud = try XCTUnwrap(views.first { $0.identifier?.rawValue == "MarkdownTOCHUD" })
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "MarkdownTOCToggle" })
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { !$0.isHiddenOrHasHiddenAncestor })
        let previewScroll = try XCTUnwrap(views.compactMap { $0 as? StructuredTextPreview }.first)
        XCTAssertTrue(controller.markdownTOCIsAvailable)
        XCTAssertFalse(hud.isHidden)
        XCTAssertEqual(preparation.markdownDocument?.headings.map(\.title), ["Start", "Repeated", "Repeated", "Café Formatted"])
        XCTAssertEqual(preparation.markdownDocument?.headings.map(\.level), [1, 2, 2, 3])
        XCTAssertEqual(Set(preparation.markdownDocument?.headings.map(\.anchor) ?? []).count, 4,
                       "Repeated titles resolve through distinct stable heading anchors")

        let contentView = try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewContent" })
        let hudFrame = hud.convert(hud.bounds, to: contentView)
        XCTAssertLessThan(hudFrame.width, 320, "The HUD is a compact control, not a full-width bar")
        XCTAssertLessThanOrEqual(hudFrame.height, 30)
        XCTAssertEqual(contentView.bounds.maxX - hudFrame.maxX, 24, accuracy: 1,
                       "The HUD keeps clear of the overlay scroller")
        let previewFrame = previewScroll.frame
        XCTAssertEqual(previewFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(previewFrame.minY, 0, accuracy: 1, "The HUD must not reserve document layout space")
        XCTAssertEqual(previewFrame.width, contentView.bounds.width, accuracy: 1)

        let initialScrollOrigin = previewScroll.contentView.bounds.minY
        let oldSelection = textView.selectedRange()
        var presentedAnchor: NSView?
        var presentedPositioning: NSMenuItem?
        controller.markdownTOCMenuPresenter = { menu, positioning, _, anchor in
            presentedAnchor = anchor
            presentedPositioning = positioning
            XCTAssertTrue(controller.markdownTOCIsOpen)
            XCTAssertTrue(controller.markdownTOCMenuIsShown)
            XCTAssertEqual(button.accessibilityValue() as? String, "Menu shown")
            XCTAssertEqual(previewScroll.contentView.bounds.minY, initialScrollOrigin,
                           "Opening the menu must not move the reading position")
            let toc = controller.markdownTOCMenuForReview
            XCTAssertEqual(toc?.headingCount, 4)
            XCTAssertEqual(menu.items.first?.isSectionHeader, true)
            XCTAssertEqual(menu.items.dropFirst().map(\.indentationLevel), [0, 1, 1, 2])
            XCTAssertEqual(menu.items.dropFirst().map(\.title), ["Start", "Repeated", "Repeated", "Café Formatted"])
            XCTAssertEqual(toc?.checkedIndices, [0], "Only the reading section carries the checkmark")
            menu.performActionForItem(at: 4)
        }
        button.performClick(nil)
        XCTAssertTrue(presentedAnchor === button, "The menu is anchored to the TOC button")
        XCTAssertNil(presentedPositioning, "A short menu drops below the button without scrolling")
        XCTAssertFalse(controller.markdownTOCIsOpen)
        XCTAssertFalse(controller.markdownTOCMenuIsShown, "Choosing a heading ends the transient menu")
        XCTAssertEqual(button.accessibilityValue() as? String, "Menu hidden")
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 3)
        XCTAssertEqual(textView.selectedRange(), oldSelection, "TOC navigation must not move the document insertion point")
        let storage = try XCTUnwrap(textView.textStorage)
        let clipView = previewScroll.contentView
        let navigatedRange = try XCTUnwrap(markdownHeadingRange(3, in: storage))
        let navigatedRect = try XCTUnwrap(markdownHeadingRect(navigatedRange, in: textView))
        let expectedOrigin = min(max(0, textView.frame.height - clipView.bounds.height),
                                 max(0, navigatedRect.minY - min(80, max(36, clipView.bounds.height * 0.16))))
        XCTAssertEqual(clipView.bounds.minY, expectedOrigin, accuracy: 8)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 3,
                       "Programmatic navigation and observed scrolling settle without feedback")

        let activeIndicator = try XCTUnwrap(allViews(beneath: controller.view).first {
            $0.identifier?.rawValue == "MarkdownTOCActiveSection"
        } as? NSTextField)
        let targetRange = try XCTUnwrap(markdownHeadingRange(1, in: storage))
        let targetRect = try XCTUnwrap(markdownHeadingRect(targetRange, in: textView))
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: max(0, targetRect.minY - 54)))
        previewScroll.reflectScrolledClipView(clipView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 1,
                       "The active heading follows rendered geometry, including duplicate titles")
        XCTAssertEqual(activeIndicator.accessibilityValue(), "Repeated",
                       "The current-section label follows manual scrolling while the menu is closed")
        XCTAssertFalse(activeIndicator.isHiddenOrHasHiddenAncestor)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: max(0, targetRect.minY - 70)))
        previewScroll.reflectScrolledClipView(clipView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 1)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: max(0, targetRect.minY - 81)))
        previewScroll.reflectScrolledClipView(clipView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 1, "Small threshold movement does not flicker the active section")
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: max(0, targetRect.minY - 90)))
        previewScroll.reflectScrolledClipView(clipView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 0, "Crossing the hysteresis band while scrolling up changes section")
        XCTAssertEqual(activeIndicator.accessibilityValue(), "Start",
                       "The closed HUD indicator updates when scrolling back across a heading")
        let maximumOrigin = max(0, textView.frame.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: maximumOrigin))
        previewScroll.reflectScrolledClipView(clipView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 3, "The final heading becomes active at the document end")

        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        let sourceView = try XCTUnwrap(views.compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(sourceView.textView.string, raw, "Source must remain the original Markdown source")
        XCTAssertTrue(hud.isHidden)
        XCTAssertFalse(controller.markdownTOCIsOpen)
        modes.selectedSegment = 0
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertFalse(hud.isHidden)
        XCTAssertFalse(controller.markdownTOCIsOpen, "Rendered mode must start with the menu closed after switching through Raw")
        window.orderOut(nil)
        window.contentViewController = nil
    }

    @MainActor
    func testMarkdownTOCMenuKeepsOneCheckmarkThatFollowsScrollingWhileOpen() throws {
        let body = String(repeating: "Reading line with enough words to span the preview.\n", count: 30)
        let raw = (1...5).map { "## Part \($0)\n\n\(body)" }.joined(separator: "\n")
        let bytes = Data(raw.utf8)
        let controller = makeSizedPreviewController(size: .init(width: 900, height: 600))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.display(.prepare(bytes: bytes, fileSize: bytes.count, fileName: "parts.md",
                                    systemUTI: "net.daringfireball.markdown"))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        let views = allViews(beneath: controller.view)
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "MarkdownTOCToggle" })
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { !$0.isHiddenOrHasHiddenAncestor })
        let previewScroll = try XCTUnwrap(views.compactMap { $0 as? StructuredTextPreview }.first)
        let indicator = try XCTUnwrap(views.first { $0.identifier?.rawValue == "MarkdownTOCActiveSection" } as? NSTextField)
        let storage = try XCTUnwrap(textView.textStorage)
        let clipView = previewScroll.contentView

        var observed: [[Int]] = []
        controller.markdownTOCMenuPresenter = { _, _, _, _ in
            guard let toc = controller.markdownTOCMenuForReview else { return XCTFail("Menu model missing while open") }
            observed.append(toc.checkedIndices)
            for index in [2, 4, 1] {
                guard let range = self.markdownHeadingRange(index, in: storage),
                      let rect = self.markdownHeadingRect(range, in: textView) else { return XCTFail("Heading \(index) missing") }
                clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: max(0, rect.minY - 54)))
                previewScroll.reflectScrolledClipView(clipView)
                // NSMenu tracks in the event-tracking run-loop mode; section updates must still arrive.
                RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
                observed.append(toc.checkedIndices)
                XCTAssertEqual(controller.activeMarkdownHeadingIndex, index)
                XCTAssertEqual(indicator.stringValue, "Part \(index + 1)",
                               "Menu checkmark and section label share one active section")
            }
        }
        button.performClick(nil)
        XCTAssertEqual(observed, [[0], [2], [4], [1]], "Exactly one item is checked and it follows the reading position")
        XCTAssertFalse(controller.markdownTOCMenuIsShown)

        var reopened: [Int]?
        controller.markdownTOCMenuPresenter = { _, _, _, _ in reopened = controller.markdownTOCMenuForReview?.checkedIndices }
        button.performClick(nil)
        XCTAssertEqual(reopened, [1], "A reopened menu starts at the current reading section")
        window.orderOut(nil)
        window.contentViewController = nil
    }

    @MainActor
    func testMarkdownTOCLabelYieldsInNarrowPreviewAndIsUnavailableWithoutHeadings() throws {
        let raw = "# Heading with a fairly long title that must truncate inside the compact label\n\n"
            + String(repeating: "Body text for a narrow preview.\n", count: 24)
        let bytes = Data(raw.utf8)
        let controller = makeSizedPreviewController(size: .init(width: 760, height: 520))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.display(.prepare(bytes: bytes, fileSize: bytes.count, fileName: "narrow.md",
                                    systemUTI: "net.daringfireball.markdown"))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        controller.view.layoutSubtreeIfNeeded()
        let views = allViews(beneath: controller.view)
        let hud = try XCTUnwrap(views.first { $0.identifier?.rawValue == "MarkdownTOCHUD" })
        let label = try XCTUnwrap(views.first { $0.identifier?.rawValue == "MarkdownTOCSectionLabel" })
        let indicator = try XCTUnwrap(views.first { $0.identifier?.rawValue == "MarkdownTOCActiveSection" } as? NSTextField)
        XCTAssertTrue(controller.markdownTOCIsAvailable)
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(indicator.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(indicator.maximumNumberOfLines, 1)
        XCTAssertLessThanOrEqual(indicator.alignmentRect(forFrame: indicator.frame).width, 260.5,
                                 "Long section titles truncate inside the label")
        XCTAssertEqual(indicator.toolTip, "Heading with a fairly long title that must truncate inside the compact label")
        XCTAssertLessThan(hud.frame.width, 320)

        window.setContentSize(.init(width: 400, height: 520))
        controller.view.setFrameSize(.init(width: 400, height: 520))
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(label.isHidden, "A narrow preview keeps only the TOC button")
        XCTAssertFalse(hud.isHidden)
        XCTAssertLessThanOrEqual(hud.frame.width, 29)
        XCTAssertEqual(indicator.accessibilityValue(),
                       "Heading with a fairly long title that must truncate inside the compact label")

        let codeOnly = Data("```markdown\n# Not a heading\n```\n".utf8)
        let codeOnlyPreparation = PreviewPreparation.prepare(bytes: codeOnly, fileSize: codeOnly.count,
                                                            fileName: "empty.md", systemUTI: "net.daringfireball.markdown")
        controller.display(codeOnlyPreparation)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.markdownTOCIsAvailable)
        XCTAssertTrue(hud.isHidden)
        XCTAssertEqual(codeOnlyPreparation.markdownDocument?.raw, String(decoding: codeOnly, as: UTF8.self))

        let plainBytes = Data("# This is plain text, not a Markdown heading".utf8)
        controller.display(.prepare(bytes: plainBytes, fileSize: plainBytes.count,
                                    fileName: "plain.txt", systemUTI: "public.plain-text"))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.markdownTOCIsAvailable)
        XCTAssertTrue(hud.isHidden, "Non-Markdown formats never show the Markdown HUD")
        window.contentViewController = nil
    }

    @MainActor
    func testMarkdownTOCMenuTruncatesLongHeadingsAndExposesFullTitles() throws {
        let long = "Section — " + String(repeating: "long heading text ", count: 8)
        let headings = (1...96).map { index in
            "\(String(repeating: "#", count: index % 6 + 1)) \(index) \(long)\n\nBody for section \(index).\n"
        }.joined(separator: "\n")
        let bytes = Data(headings.utf8)
        let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                                                     fileName: "many-headings.md", systemUTI: "net.daringfireball.markdown")
        let titles = try XCTUnwrap(preparation.markdownDocument?.headings)
        let toc = MarkdownTOCMenu(headings: titles, activeIndex: 40)
        XCTAssertEqual(toc.headingCount, 96)
        XCTAssertEqual(toc.checkedIndices, [40])
        let font = NSFont.menuFont(ofSize: 0)
        for (index, heading) in titles.enumerated() {
            let item = try XCTUnwrap(toc.item(forHeading: index))
            XCTAssertEqual(item.indentationLevel, heading.level - 1)
            XCTAssertLessThanOrEqual((item.title as NSString).size(withAttributes: [.font: font]).width,
                                     MarkdownTOCMenu.maximumTitleWidth + 0.5)
            XCTAssertTrue(item.title.hasSuffix("…"), "Long headings truncate with a trailing ellipsis")
            XCTAssertEqual(item.toolTip, heading.title)
            XCTAssertEqual(item.accessibilityLabel(), heading.title, "VoiceOver reads the full heading")
            XCTAssertTrue(item.isEnabled)
        }
        XCTAssertLessThanOrEqual(toc.menu.size.width, MarkdownTOCMenu.maximumTitleWidth + 120,
                                 "Long headings never widen the menu beyond the bounded label width")
        toc.setActiveIndex(41)
        toc.setActiveIndex(95)
        XCTAssertEqual(toc.checkedIndices, [95])
        toc.setActiveIndex(nil)
        XCTAssertEqual(toc.checkedIndices, [])
        XCTAssertEqual(MarkdownTOCMenu.truncatedTitle("Short", font: font, maximumWidth: 200), "Short")

        XCTAssertNil(MarkdownTOCMenu.positioningIndex(activeIndex: 40, itemCount: 96, menuHeight: 600, availableHeight: 800),
                     "A menu that fits opens below the button")
        XCTAssertNil(MarkdownTOCMenu.positioningIndex(activeIndex: 3, itemCount: 96, menuHeight: 2_100, availableHeight: 700),
                     "No scrolling when the active heading is already visible")
        XCTAssertEqual(MarkdownTOCMenu.positioningIndex(activeIndex: 80, itemCount: 96, menuHeight: 2_100, availableHeight: 700), 80,
                       "The menu scrolls to an active heading that would otherwise be out of view")
        XCTAssertNil(MarkdownTOCMenu.positioningIndex(activeIndex: nil, itemCount: 96, menuHeight: 2_100, availableHeight: 700))
    }

    @MainActor
    func testMarkdownTOCButtonAndSectionLabelAreAccessible() throws {
        let firstBody = String(repeating: "Introductory reading line.\n", count: 16)
        let raw = "# Café **Overview**\n\n\(firstBody)\n## Second section\n\nBody.\n"
        let bytes = Data(raw.utf8)
        let controller = makeSizedPreviewController(size: .init(width: 640, height: 480))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.display(.prepare(bytes: bytes, fileSize: bytes.count, fileName: "accessible.md",
                                    systemUTI: "net.daringfireball.markdown"))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))

        let views = allViews(beneath: controller.view)
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "MarkdownTOCToggle"
        })
        let indicator = try XCTUnwrap(views.first {
            $0.identifier?.rawValue == "MarkdownTOCActiveSection"
        } as? NSTextField)
        XCTAssertEqual(button.accessibilityLabel(), "Table of contents")
        XCTAssertFalse((button.accessibilityHelp() ?? "").isEmpty)
        XCTAssertNotNil(button.image, "The button uses an SF Symbol")
        XCTAssertEqual(indicator.accessibilityLabel(), "Current section")
        XCTAssertEqual(indicator.accessibilityValue(), "Café Overview")

        var opened = 0
        controller.markdownTOCMenuPresenter = { menu, _, _, _ in
            opened += 1
            let item = menu.items[2]
            XCTAssertNotNil(item.action)
            XCTAssertTrue(item.isEnabled, "Menu items are reachable with arrow keys and Return")
        }
        let label = try XCTUnwrap(views.first { $0.identifier?.rawValue == "MarkdownTOCSectionLabel" })
        let click = try XCTUnwrap(label.gestureRecognizers.first as? NSClickGestureRecognizer)
        _ = (click.target as? NSObject)?.perform(click.action, with: click)
        button.performClick(nil)
        XCTAssertEqual(opened, 2, "Both the button and its section label open the menu")
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 0, "Dismissing without a choice keeps the reading section")
        window.contentViewController = nil
    }

    @MainActor
    func testMarkdownTOCCreatesLightDarkResponsiveContactSheet() throws {
        let sectionBody = String(repeating: "A readable preview paragraph that wraps naturally at the current window width.\n", count: 24)
        let raw = (1...6).map { index in
            "\(String(repeating: "#", count: index.isMultiple(of: 2) ? 2 : 1)) Section \(index)\n\n\(sectionBody)"
        }.joined(separator: "\n")
        let bytes = Data(raw.utf8)
        let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                                                     fileName: "toc-contact-sheet.md", systemUTI: "net.daringfireball.markdown")
        let size = NSSize(width: 1_040, height: 720)
        let controller = makeSizedPreviewController(size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.configuration = RenderConfiguration(appearance: .light)
        controller.display(preparation)
        controller.view.layoutSubtreeIfNeeded()
        var captures: [(String, NSBitmapImageRep)] = []
        func capture(_ label: String) throws {
            controller.view.layoutSubtreeIfNeeded()
            captures.append((label, try snapshotForReview(controller.view)))
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 0)
        XCTAssertTrue(controller.markdownTOCIsAvailable)
        try capture("Wide • Light • Section 1")

        let textView = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? NSTextView }.first { !$0.isHiddenOrHasHiddenAncestor })
        let sectionRange = try XCTUnwrap(markdownHeadingRange(5, in: try XCTUnwrap(textView.textStorage)))
        let sectionRect = try XCTUnwrap(markdownHeadingRect(sectionRange, in: textView))
        let scroll = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? StructuredTextPreview }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, sectionRect.minY - 54)))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 5)
        try capture("Wide • Light • Section 6")

        controller.configuration = RenderConfiguration(appearance: .dark)
        controller.view.layoutSubtreeIfNeeded()
        let secondRange = try XCTUnwrap(markdownHeadingRange(1, in: try XCTUnwrap(textView.textStorage)))
        let secondRect = try XCTUnwrap(markdownHeadingRect(secondRange, in: textView))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, secondRect.minY - 54)))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.activeMarkdownHeadingIndex, 1)
        try capture("Wide • Dark • Section 2")

        window.setContentSize(.init(width: 400, height: 600))
        controller.view.setFrameSize(.init(width: 400, height: 600))
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        try capture("Narrow • Dark • Button only")
        controller.configuration = RenderConfiguration(appearance: .light)
        try capture("Narrow • Light • Button only")
        window.setContentSize(.init(width: 560, height: 600))
        controller.view.setFrameSize(.init(width: 560, height: 600))
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        try capture("Medium • Light • Truncating label")

        let padding: CGFloat = 16
        let tileWidth: CGFloat = 500
        let imageHeight: CGFloat = 260
        let captionHeight: CGFloat = 24
        let tileHeight = imageHeight + captionHeight + padding
        let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(2 * tileWidth + 3 * padding), pixelsHigh: Int(3 * tileHeight + padding),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let sheet = try XCTUnwrap(canvas)
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: sheet))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 2 * tileWidth + 3 * padding, height: 3 * tileHeight + padding).fill()
        let captionAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        for (index, item) in captures.enumerated() {
            let column = index % 2
            let row = index / 2
            let x = padding + CGFloat(column) * (tileWidth + padding)
            let y = 3 * tileHeight - padding - CGFloat(row + 1) * tileHeight + captionHeight
            let imageScale = min(tileWidth / CGFloat(item.1.pixelsWide), imageHeight / CGFloat(item.1.pixelsHigh))
            let imageSize = NSSize(width: CGFloat(item.1.pixelsWide) * imageScale,
                                   height: CGFloat(item.1.pixelsHigh) * imageScale)
            item.1.draw(in: NSRect(x: x + (tileWidth - imageSize.width) / 2, y: y + (imageHeight - imageSize.height) / 2,
                                   width: imageSize.width, height: imageSize.height))
            (item.0 as NSString).draw(at: NSPoint(x: x, y: y - captionHeight + 5), withAttributes: captionAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let evidenceDirectory = root.appendingPathComponent("artifacts/markdown-toc-hud", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try XCTUnwrap(sheet.representation(using: .png, properties: [:]))
            .write(to: evidenceDirectory.appendingPathComponent("contact-sheet.png"), options: .atomic)
        let receipt = "Glimt Markdown TOC contact sheet\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nScenarios: \(captures.map(\.0).joined(separator: "; "))\n"
        try Data(receipt.utf8).write(to: evidenceDirectory.appendingPathComponent("capture-receipt.txt"), options: .atomic)
        window.orderOut(nil)
        window.contentViewController = nil
    }

    /// Opt-in live evidence: real windows and a real tracking `NSMenu`, captured in-process with
    /// `cacheDisplay`. Set `GLIMT_TOC_CAPTURE_DIR` (via `TEST_RUNNER_GLIMT_TOC_CAPTURE_DIR`) to run.
    @MainActor
    func testMarkdownTOCLiveMenuEvidence() throws {
        guard let output = ProcessInfo.processInfo.environment["GLIMT_TOC_CAPTURE_DIR"] else {
            throw XCTSkip("Set GLIMT_TOC_CAPTURE_DIR to write live Markdown TOC evidence")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runbook = try Data(contentsOf: root.appendingPathComponent("docs/07-runbook.md"))
        let body = String(repeating: "A short document still needs enough text to scroll past each heading.\n", count: 18)
        let short = Data("# Release notes\n\n\(body)\n## Install\n\n\(body)\n## Known issues\n\n\(body)".utf8)
        var receipt = ["Glimt Markdown TOC live evidence", "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        var frameNumber = 0

        func png(_ rep: NSBitmapImageRep, _ url: URL) throws {
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
        }
        func snapshot(_ window: NSWindow) throws -> NSBitmapImageRep {
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                // The window background comes from the compositor; paint it before the views.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            return rep
        }
        /// Draws the document window and, when open, the menu window at their screen positions.
        func composite(_ window: NSWindow, menu: NSWindow?) throws -> NSBitmapImageRep {
            let content = window.convertToScreen(try XCTUnwrap(window.contentView).frame)
            let bounds = menu.map { content.union($0.frame) } ?? content
            let scale = window.backingScaleFactor
            let canvas = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            canvas.size = bounds.size
            let windowImage = try snapshot(window)
            let menuImage = try menu.map(snapshot)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
            windowImage.draw(in: content.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
            if let menu, let menuImage {
                let frame = menu.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                let path = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
                path.addClip()
                menuImage.draw(in: frame)
                NSColor.separatorColor.setStroke()
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            return canvas
        }
        func scrollTo(heading index: Int, in controller: SharedPreviewViewController) throws {
            let views = allViews(beneath: controller.view)
            let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { !$0.isHiddenOrHasHiddenAncestor })
            let scroll = try XCTUnwrap(views.compactMap { $0 as? StructuredTextPreview }.first)
            let range = try XCTUnwrap(markdownHeadingRange(index, in: try XCTUnwrap(textView.textStorage)))
            let rect = try XCTUnwrap(markdownHeadingRect(range, in: textView))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 54)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func scrollBy(_ delta: CGFloat, in controller: SharedPreviewViewController) throws {
            let scroll = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? StructuredTextPreview }.first)
            let clip = scroll.contentView
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, clip.bounds.minY + delta))))
            scroll.reflectScrolledClipView(clip)
        }
        func open(_ data: Data, name: String, size: NSSize, appearance: PreviewAppearance)
            throws -> (SharedPreviewViewController, NSWindow, NSButton) {
            let controller = makeSizedPreviewController(size: size)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            window.contentViewController = controller
            window.setContentSize(size)
            window.center()
            window.makeKeyAndOrderFront(nil)
            controller.configuration = RenderConfiguration(appearance: appearance)
            controller.display(.prepare(bytes: data, fileSize: data.count, fileName: name,
                                        systemUTI: "net.daringfireball.markdown"))
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let button = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "MarkdownTOCToggle"
            })
            return (controller, window, button)
        }
        /// Runs `body` while the real menu tracks, then dismisses it as Escape would.
        func whileMenuOpen(_ controller: SharedPreviewViewController, _ window: NSWindow, _ button: NSButton,
                           _ body: @escaping @MainActor (NSWindow?) throws -> Void) throws {
            var failure: Error?
            let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let menuWindow = NSApp.windows.first { $0 !== window && $0.isVisible && $0.level.rawValue > window.level.rawValue }
                    do { try body(menuWindow) } catch { failure = error }
                    controller.markdownTOCMenuForReview?.menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            button.performClick(nil)
            if let failure { throw failure }
            XCTAssertFalse(controller.markdownTOCMenuIsShown)
        }
        func frame(_ window: NSWindow, menu: NSWindow?) throws {
            frameNumber += 1
            try png(try composite(window, menu: menu), frames.appendingPathComponent(String(format: "frame-%03d.png", frameNumber)))
        }

        for appearance in [PreviewAppearance.light, .dark] {
            let tag = appearance == .light ? "light" : "dark"
            for (width, label) in [(CGFloat(1_100), "wide"), (CGFloat(520), "narrow"), (CGFloat(400), "very-narrow")] {
                let (controller, window, button) = try open(runbook, name: "07-runbook.md",
                                                            size: .init(width: width, height: 760), appearance: appearance)
                try scrollTo(heading: 12, in: controller)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                try png(try composite(window, menu: nil), directory.appendingPathComponent("after-\(label)-\(tag)-closed.png"))
                try whileMenuOpen(controller, window, button) { menuWindow in
                    XCTAssertNotNil(menuWindow, "The real NSMenu window is on screen while tracking")
                    XCTAssertEqual(controller.markdownTOCMenuForReview?.checkedIndices, [controller.activeMarkdownHeadingIndex ?? -1])
                    try png(try composite(window, menu: menuWindow),
                            directory.appendingPathComponent("after-\(label)-\(tag)-menu.png"))
                }
                receipt.append("\(label) \(tag): active=\(controller.activeMarkdownHeadingIndex ?? -1) width=\(Int(width))")
                window.orderOut(nil)
                window.contentViewController = nil
            }
            let (controller, window, button) = try open(short, name: "short.md", size: .init(width: 900, height: 640),
                                                        appearance: appearance)
            try scrollTo(heading: 1, in: controller)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try whileMenuOpen(controller, window, button) { menuWindow in
                try png(try composite(window, menu: menuWindow), directory.appendingPathComponent("after-short-toc-\(tag)-menu.png"))
            }
            window.orderOut(nil)
            window.contentViewController = nil
        }

        // Recording frames: the closed HUD while scrolling, then the open menu following the same scroll.
        let (controller, window, button) = try open(runbook, name: "07-runbook.md", size: .init(width: 1_000, height: 720),
                                                    appearance: .light)
        var closedSections: [Int] = []
        for _ in 0..<36 {
            try scrollBy(120, in: controller)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            closedSections.append(controller.activeMarkdownHeadingIndex ?? -1)
            try frame(window, menu: nil)
        }
        var openSections: [[Int]] = []
        try whileMenuOpen(controller, window, button) { menuWindow in
            for _ in 0..<36 {
                try scrollBy(-120, in: controller)
                RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.03))
                openSections.append(controller.markdownTOCMenuForReview?.checkedIndices ?? [])
                try frame(window, menu: menuWindow)
            }
        }
        XCTAssertGreaterThan(Set(closedSections).count, 3, "The label changes section while scrolling with the menu closed")
        XCTAssertTrue(openSections.allSatisfy { $0.count == 1 }, "The open menu always shows exactly one checkmark")
        XCTAssertGreaterThan(Set(openSections).count, 3, "The checkmark follows scrolling while the menu is open")
        receipt.append("closed scroll sections: \(closedSections)")
        receipt.append("open scroll checkmarks: \(openSections.map { $0.first ?? -1 })")
        window.orderOut(nil)
        window.contentViewController = nil
        try Data((receipt.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("receipt.txt"))
    }

    @MainActor
    private func snapshotForReview(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func markdownHeadingRange(_ index: Int, in storage: NSTextStorage) -> NSRange? {
        var result: NSRange?
        storage.enumerateAttribute(MarkdownRenderer.headingIndexAttribute,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard (value as? Int) == index else { return }
            result = result.map { NSUnionRange($0, range) } ?? range
        }
        return result
    }

    @MainActor
    private func markdownHeadingRect(_ range: NSRange, in textView: NSTextView) -> NSRect? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        layout.ensureLayout(forCharacterRange: range)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(
            dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y
        )
    }

    @MainActor
    func testDisplaysBoundedPrefixAndLowerBoundForOversizedFile() async throws {
        let preview = await render(at: try XCTUnwrap(oversizedFixtureURL))

        XCTAssertEqual(preview.text, String(repeating: "a", count: 1_048_576))
        assertStatus(preview.header, contains: "JSON | UTF-8")
    }

    @MainActor
    func testDisplaysBOMMarkedUTF16JSON() async throws {
        let text = "{\"text\":\"café\"}\n"
        let payload = text.utf16.flatMap { [UInt8($0 & 0x00FF), UInt8($0 >> 8)] }
        let bytes = Data([0xFF, 0xFE] + payload)
        let preview = await render(at: try writeJSONFixture(bytes))

        XCTAssertEqual(preview.text, text)
        assertStatus(preview.header, contains: "JSON | UTF-16 LE | LF")
    }

    @MainActor
    func testDisplaysWindows1252JSONWithCRLFMetadata() async throws {
        let bytes = Data([0x7B, 0x22, 0x74, 0x65, 0x78, 0x74, 0x22, 0x3A, 0x22, 0x63, 0x61, 0x66, 0xE9, 0x22, 0x7D, 0x0D, 0x0A])
        let preview = await render(at: try writeJSONFixture(bytes))

        XCTAssertEqual(preview.text, "{\"text\":\"café\"}\r\n")
        assertStatus(preview.header, contains: "JSON | Windows-1252 | CRLF")
    }

    @MainActor
    func testIdentifiesBinaryJSONWithoutDisplayingPayload() async throws {
        let bytes = Data([0x7B, 0x00, 0x01, 0x7D])
        let url = try writeJSONFixture(bytes)
        let preparation = PreviewPreparation.prepare(
            bytes: bytes,
            fileSize: bytes.count,
            fileName: "Makefile",
            systemUTI: nil
        )
        XCTAssertTrue(preparation.analysis.isBinary)
        XCTAssertEqual(preparation.resolution.typeID, "make")
        let controlledPreview = try present(preparation)
        assertStatus(controlledPreview.header, contains: "Binary")
        XCTAssertEqual(controlledPreview.body, HexPreview.format(bytes))
        let preview = await render(at: url)

        assertStatus(preview.header, contains: "Binary")
        XCTAssertEqual(preview.text, HexPreview.format(bytes))
    }

    func testPreparationReportsResolverResultsAndCompleteEvidence() {
        let cases: [(String, Data, String?, String, Double)] = [
            ("Makefile", Data("all:\n".utf8), nil, "make", 1.0),
            ("foo.d.ts", Data("declare const x: string;\n".utf8), nil, "typescript-declaration", 0.98),
            ("app.local", Data("KEY=value\n".utf8), nil, "generic-local", 0.95),
            ("config", Data("---\na: 1\nb: 2\n".utf8), nil, "yaml", 0.80),
            ("script", Data("#!/usr/bin/env python3\nprint(1)\n".utf8), nil, "python", 0.90),
            ("unknown", Data("plain words\n".utf8), nil, "unknown", 0),
            ("foo.ts", Data("const x: number = 1;\n".utf8), "public.mpeg-2-transport-stream", "typescript", 0.95)
        ]

        for (name, bytes, uti, expectedType, expectedConfidence) in cases {
            let preparation = PreviewPreparation.prepare(
                bytes: bytes,
                fileSize: bytes.count,
                fileName: name,
                systemUTI: uti
            )
            let expected = TypeResolver().resolve(
                fileName: name,
                leadingBytes: Data(bytes.prefix(65_536)),
                systemUTI: uti,
                sampleIsComplete: true
            )
            XCTAssertEqual(preparation.resolution, expected, name)
            XCTAssertEqual(preparation.resolution.typeID, expectedType, name)
            XCTAssertEqual(preparation.resolution.confidence.value, expectedConfidence, accuracy: 0.000_001, name)
            XCTAssertEqual(preparation.resolution.evidence.count, uti == "public.mpeg-2-transport-stream" ? 8 : 7, name)
            XCTAssertEqual(preparation.sampleByteCount, bytes.count, name)
            XCTAssertTrue(preparation.sampleIsComplete, name)
        }
    }

#if DEBUG
    func testPreviewProviderMarkerSerializesValidPrimitiveInput() {
        let scores: [(DetectionEvidence.SignalKind, Double)] = [
            (.filename, 0),
            (.multiExtension, 0),
            (.singleExtension, 0),
            (.shebang, 0),
            (.yamlMapping, 0.75),
            (.yamlDocumentMarker, 0.80),
            (.systemUTI, 0)
        ]

        XCTAssertEqual(
            PreviewProviderMarkerSerializer.serialize(
                token: "01234567-89ab-cdef-0123-456789abcdef",
                provider: "preview",
                phase: "display-prepared",
                typeID: "yaml",
                confidence: 0.80,
                scores: scores,
                sampleByteCount: 917,
                sampleIsComplete: true
            ),
            "FR005_PROVIDER_V1 token=01234567-89ab-cdef-0123-456789abcdef provider=preview phase=display-prepared type=yaml confidence=0.80 scores=0.00,0.00,0.00,0.00,0.75,0.80,0.00 sampleBytes=917 complete=1"
        )
    }

    func testPreviewProviderMarkerRejectsInvalidPrimitiveInputs() {
        let validToken = "01234567-89ab-cdef-0123-456789abcdef"
        let validScores = Self.markerScores
        var token = validToken
        var type = "yaml"
        var confidence = 0.80
        var scores = validScores
        var sampleBytes = 917
        var provider = "preview"
        var phase = "display-prepared"
        func serialize() -> String? {
            PreviewProviderMarkerSerializer.serialize(
                token: token,
                provider: provider,
                phase: phase,
                typeID: type,
                confidence: confidence,
                scores: scores,
                sampleByteCount: sampleBytes,
                sampleIsComplete: true
            )
        }

        for malformed in [
            "01234567-89AB-cdef-0123-456789abcdef",
            "01234567-89ab-cdef-0123-456789abcde ",
            "{01234567-89ab-cdef-0123-456789abcdef}",
            "0123456789abcdef0123456789abcdef"
        ] {
            token = malformed
            XCTAssertNil(serialize())
        }
        token = validToken
        type = "public.mpeg-2-transport-stream"
        XCTAssertNil(serialize())
        type = "yaml"
        provider = "thumbnail"
        XCTAssertNil(serialize())
        provider = "preview"
        phase = "reply-prepared"
        XCTAssertNil(serialize())
        phase = "display-prepared"
        for invalidConfidence in [Double.nan, .infinity, -.infinity, -0.000_001, 1.000_001] {
            confidence = invalidConfidence
            XCTAssertNil(serialize())
        }
        confidence = 0.80
        for invalidSampleBytes in [-1, 65_537] {
            sampleBytes = invalidSampleBytes
            XCTAssertNil(serialize())
        }
        sampleBytes = 917
        scores = Array(validScores.dropLast())
        XCTAssertNil(serialize())
        scores = validScores + [(.filename, 0)]
        XCTAssertNil(serialize())
        scores = validScores.map { ($0.0, $0.0 == .systemUTI ? Double.nan : $0.1) }
        XCTAssertNil(serialize())
        scores = validScores.map { ($0.0, $0.0 == .systemUTI ? 1.01 : $0.1) }
        XCTAssertNil(serialize())
    }

    func testPreviewProviderMarkerRoundsToHundredthsAndUsesFixedSignalOrder() {
        let scores: [(DetectionEvidence.SignalKind, Double)] = [
            (.systemUTI, 1),
            (.yamlDocumentMarker, 0.0151),
            (.yamlMapping, 0.0149),
            (.shebang, 0.005),
            (.singleExtension, -0.0),
            (.multiExtension, 0),
            (.filename, 0)
        ]
        let marker = PreviewProviderMarkerSerializer.serialize(
            token: "01234567-89ab-cdef-0123-456789abcdef",
            provider: "preview",
            phase: "display-prepared",
            typeID: "unknown",
            confidence: 0.125,
            scores: scores + [(.utiConflict, .nan)],
            sampleByteCount: 0,
            sampleIsComplete: false
        )
        XCTAssertEqual(
            marker,
            "FR005_PROVIDER_V1 token=01234567-89ab-cdef-0123-456789abcdef provider=preview phase=display-prepared type=unknown confidence=0.13 scores=0.00,0.00,0.00,0.01,0.01,0.02,1.00 sampleBytes=0 complete=0"
        )
    }

    func testPreviewProviderTokenReaderRequiresAnExactCanonicalAttribute() throws {
        let url = try writeTemporaryFile(Data("content".utf8), named: "token-reader")
        XCTAssertNil(PreviewProviderMarkerSerializer.readToken(from: url))

        try setEvidenceAttribute(Data("01234567-89ab-cdef-0123-456789abcdef".utf8), at: url)
        XCTAssertEqual(PreviewProviderMarkerSerializer.readToken(from: url), "01234567-89ab-cdef-0123-456789abcdef")

        try setEvidenceAttribute(Data("01234567-89AB-cdef-0123-456789abcdef".utf8), at: url)
        XCTAssertNil(PreviewProviderMarkerSerializer.readToken(from: url))
        try setEvidenceAttribute(Data(repeating: 0x61, count: 37), at: url)
        XCTAssertNil(PreviewProviderMarkerSerializer.readToken(from: url))
        try setEvidenceAttribute(Data(repeating: 0x61, count: 38), at: url)
        XCTAssertNil(PreviewProviderMarkerSerializer.readToken(from: url))
        try setEvidenceAttribute(Data([0xFF]), at: url)
        XCTAssertNil(PreviewProviderMarkerSerializer.readToken(from: url))
    }

    @MainActor
    func testPreviewProviderEmitsAfterDisplayBeforeSuccessfulCompletion() async throws {
        let bytes = Data("---\na: 1\nb: 2\n".utf8)
        let url = try writeTemporaryFile(bytes, named: "config")
        let markerRecorder = ProviderMarkerRecorder()
        let provenanceRecorder = ProviderMarkerRecorder()
        let tokenReadCounter = PreviewTokenReadCounter()
        let controllerBox = PreviewControllerWeakBox()
        var events: [String] = []
        let dependencies = PreviewProviderDebugDependencies(
            loadingIndicatorDelay: contentFirstLoadingDelay,
            tokenReader: { _ in
                tokenReadCounter.increment()
                return "01234567-89ab-cdef-0123-456789abcdef"
            },
            contentTypeIdentifier: { _ in nil },
            markerObserver: { marker in
                guard let controller = controllerBox.value else {
                    XCTFail("Controller disappeared before display observation")
                    return
                }
                let views = self.allViews(beneath: controller.view)
                let header = views.compactMap { $0 as? PreviewStatusView }.first {
                    $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
                }
                let textView = views.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTextView
                self.assertStatus(header?.accessibilityLabel() ?? header?.stringValue ?? "", contains: "YAML | UTF-8 | LF")
                XCTAssertEqual(textView?.string, "---\na: 1\nb: 2\n")
                markerRecorder.append(marker)
                events.append("marker")
            },
            provenanceObserver: { marker in
                provenanceRecorder.append(marker)
                events.append("provenance")
            },
            runtimeIdentity: {
                QuickLookProviderRuntimeIdentity(
                    extensionBundleURL: URL(fileURLWithPath: "/Applications/Glimt.app/Contents/PlugIns/GlimtPreview.appex"),
                    extensionBundleIdentifier: "com.glimt.app.preview",
                    appBundleIdentifier: "com.glimt.app",
                    appVersion: "2.4",
                    appBuild: "204"
                )
            }
        )
        let controller = PreviewViewController(debugDependencies: dependencies)
        controllerBox.value = controller
        controller.loadViewIfNeeded()
        let buildMarker = try XCTUnwrap(controller.footerStrip.trailingAccessory as? NSImageView)
        XCTAssertEqual(buildMarker.identifier, NSUserInterfaceItemIdentifier("QuickLookDebugBuildMarker"))
        XCTAssertNotNil(buildMarker.image, "The debug build marker is an icon, not footer text")
        XCTAssertTrue(buildMarker.toolTip?.hasPrefix("Debug build ") == true)
        XCTAssertEqual(buildMarker.accessibilityLabel(), buildMarker.toolTip)
        let completed = expectation(description: "Preview callback completes")
        controller.preparePreviewOfFile(at: url) { error in
            XCTAssertNil(error)
            events.append("completion")
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(markerRecorder.values.count, 1)
        XCTAssertTrue(markerRecorder.values[0].contains("type=yaml confidence=0.80"))
        XCTAssertEqual(tokenReadCounter.value, 1)
        XCTAssertEqual(provenanceRecorder.values.count, 1)
        XCTAssertTrue(provenanceRecorder.values[0].contains("provider=preview phase=request-received"))
        XCTAssertTrue(provenanceRecorder.values[0].contains("extensionID=com.glimt.app.preview"))
        XCTAssertFalse(provenanceRecorder.values[0].contains(url.path))
        XCTAssertEqual(events, ["provenance", "marker", "completion"])
    }

    @MainActor
    func testDebugBuildMarkerFollowsTheBuildMarkerSetting() async throws {
        var settings = GlimtSettingsV3()
        settings.general.debugBuildMarker = false
        let configuration = RenderConfiguration(settings: settings)
        let controller = PreviewViewController(debugDependencies: .init(loadingIndicatorDelay: contentFirstLoadingDelay, contentTypeIdentifier: { _ in nil },
                                                                        configurationLoader: { configuration }))
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.footerStrip.trailingAccessory, "Factory configuration shows the marker")
        let completed = expectation(description: "Preview callback completes")
        controller.preparePreviewOfFile(at: try writeTemporaryFile(Data("a: 1\n".utf8), named: "marker.yaml")) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertNil(controller.footerStrip.trailingAccessory, "Build marker off removes the footer icon")
    }

    @MainActor
    func testFastQuickLookPreviewRepliesOnceWithoutLoadingState() async throws {
        let controller = PreviewViewController(debugDependencies: .init(contentTypeIdentifier: { _ in nil },
                                                                        configurationLoader: { .init() }))
        controller.loadViewIfNeeded()
        let replies = ReplyRecorder()
        let completed = expectation(description: "Preview callback completes")
        controller.preparePreviewOfFile(at: try writeTemporaryFile(Data("a: 1\n".utf8), named: "fast.yaml")) { error in
            MainActor.assumeIsolated { replies.record(error) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        try await Task.sleep(for: SharedPreviewViewController.loadingIndicatorDelay * 2)
        XCTAssertEqual(replies.count, 1)
        XCTAssertNil(controller.loadingStateMessage, "A displayed result must cancel the pending indicator")
    }

    @MainActor
    func testSlowQuickLookPreviewRepliesEarlyThenShowsFailureInTheView() async throws {
        let controller = PreviewViewController(debugDependencies: .init(
            contentTypeIdentifier: { _ in
                while !Task.isCancelled { usleep(1_000) }
                return nil
            },
            configurationLoader: { .init() },
            previewTimeLimit: .milliseconds(600)))
        controller.loadViewIfNeeded()
        let replies = ReplyRecorder()
        let early = expectation(description: "Early reply reveals the loading indicator")
        controller.preparePreviewOfFile(at: try writeTemporaryFile(Data("plain\n".utf8), named: "slow.txt")) { error in
            MainActor.assumeIsolated { replies.record(error) }
            early.fulfill()
        }
        await fulfillment(of: [early], timeout: 5)
        XCTAssertNil(replies.errors.first ?? nil)
        XCTAssertEqual(controller.loadingStateMessage, "Loading preview…")
        for _ in 0..<400 where controller.loadingStateMessage == "Loading preview…" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.loadingStateMessage, "This file could not be previewed.")
        XCTAssertEqual(replies.count, 1, "Quick Look receives exactly one reply per request")
    }

    @MainActor
    func testHostPreviewHidesTheLoadingStateWhenContentIsDisplayed() async throws {
        let controller = SharedPreviewViewController()
        controller.loadViewIfNeeded()
        controller.scheduleLoadingIndicator(after: .zero)
        for _ in 0..<100 where controller.loadingStateMessage == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.loadingStateMessage, "Loading preview…")
        let url = try writeTemporaryFile(Data("a: 1\n".utf8), named: "host.yaml")
        try await controller.preview(for: url, configuration: .init())
        XCTAssertNil(controller.loadingStateMessage)
    }

    @MainActor
    func testQuickLookAdapterRunsVCSInspectionAfterDisplayingContent() async throws {
        var settings = GlimtSettingsV3()
        settings.general.vcsSupportEnabled = true
        let configuration = RenderConfiguration(settings: settings)
        let gate = QuickLookVCSInspectionGate()
        let diff = try VCSLineDiff.compare(baseline: Data("before\n".utf8), working: Data("after\n".utf8))
        let result = VCSInspectionResult(repositoryType: .svn, fileStatus: .modified,
                                         comparison: .init(base: .svnBase, lineDiff: diff))
        let controller = PreviewViewController(
            debugDependencies: .init(loadingIndicatorDelay: contentFirstLoadingDelay, configurationLoader: { configuration }),
            vcsProviders: [QuickLookVCSProvider(gate: gate, result: result)]
        )
        controller.loadViewIfNeeded()
        let completed = expectation(description: "Quick Look content callback completes")
        controller.preparePreviewOfFile(at: try fixtureURL("Cases/source/Example.swift")) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)

        let code = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? SourceCodeView }.first)
        let ruler = try XCTUnwrap(code.scrollView.verticalRulerView as? SourceLineNumberRuler)
        for _ in 0..<100 where !(await gate.hasEntered()) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(code.textView.string.isEmpty, "Quick Look must present content before repository work")
        XCTAssertNil(ruler.lineDiff)
        await gate.release()
        for _ in 0..<100 where ruler.lineDiff == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(ruler.lineDiff, diff)
        let status = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? PreviewStatusView }.first {
            $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
        })
        XCTAssertTrue(status.stringValue.contains("SVN: Modified"))
    }

    @MainActor
    func testQuickLookKeepsContentWhenVCSMetadataIsUnavailable() async throws {
        var settings = GlimtSettingsV3()
        settings.general.vcsSupportEnabled = true
        let configuration = RenderConfiguration(settings: settings)
        let result = VCSInspectionResult(
            repositoryType: .git,
            fileStatus: .unavailable,
            comparison: nil,
            diagnostics: [.repositoryNotReadable]
        )
        let gate = QuickLookVCSInspectionGate()
        let controller = PreviewViewController(
            debugDependencies: .init(loadingIndicatorDelay: contentFirstLoadingDelay, configurationLoader: { configuration }),
            vcsProviders: [QuickLookVCSProvider(gate: gate, result: result)]
        )
        controller.loadViewIfNeeded()
        let completed = expectation(description: "Quick Look content callback completes")
        controller.preparePreviewOfFile(at: try fixtureURL("Cases/source/Example.swift")) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        await gate.release()

        let code = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? SourceCodeView }.first)
        let ruler = try XCTUnwrap(code.scrollView.verticalRulerView as? SourceLineNumberRuler)
        XCTAssertFalse(code.textView.string.isEmpty)
        XCTAssertNil(ruler.lineDiff)
        let status = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? PreviewStatusView }.first {
            $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
        })
        for _ in 0..<100 where !status.stringValue.contains("Git: Status unavailable") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(status.stringValue.contains("Git: Status unavailable"))
        XCTAssertFalse(code.textView.string.isEmpty)
    }

    @MainActor
    func testStatusBarNamesTheCommitThatLastChangedTheFile() async throws {
        var settings = GlimtSettingsV3()
        settings.general.vcsSupportEnabled = true
        let configuration = RenderConfiguration(settings: settings)
        let authorDate = Date(timeIntervalSince1970: 1_795_000_000)
        let result = VCSInspectionResult(
            repositoryType: .git, fileStatus: .clean, comparison: nil,
            lastCommit: .init(id: "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d", summary: "Fix parser", authorDate: authorDate)
        )
        let gate = QuickLookVCSInspectionGate()
        let controller = PreviewViewController(
            debugDependencies: .init(configurationLoader: { configuration }),
            vcsProviders: [QuickLookVCSProvider(gate: gate, result: result)]
        )
        controller.loadViewIfNeeded()
        let completed = expectation(description: "Quick Look content callback completes")
        controller.preparePreviewOfFile(at: try fixtureURL("Cases/source/Example.swift")) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        await gate.release()

        let status = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? PreviewStatusView }.first {
            $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
        })
        let expected = "Commit 1a2b3c4 · \(authorDate.formatted(date: .abbreviated, time: .omitted))"
        for _ in 0..<100 where !status.stringValue.contains(expected) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(status.stringValue.contains("Git: Clean"), status.stringValue)
        XCTAssertTrue(status.stringValue.contains(expected), status.stringValue)
    }

    @MainActor
    func testQuickLookControllerCapturesActualSharedPreviewForReview() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }

        let jsonController = PreviewViewController(debugDependencies: PreviewProviderDebugDependencies(
            loadingIndicatorDelay: contentFirstLoadingDelay,
            contentTypeIdentifier: { _ in "public.json" }
        ))
        window.contentViewController = jsonController
        window.setContentSize(NSSize(width: 800, height: 600))
        let jsonCompletion = expectation(description: "Quick Look JSON request completes")
        var jsonError: Error?
        jsonController.preparePreviewOfFile(at: try fixtureURL("Showcase/json/json.json")) { error in
            jsonError = error
            jsonCompletion.fulfill()
        }
        await fulfillment(of: [jsonCompletion], timeout: 5)
        XCTAssertNil(jsonError)
        try attachQuickLookControllerSnapshots(jsonController, format: "JSON", modes: [0, 1, 2])

        let markdownController = PreviewViewController(debugDependencies: PreviewProviderDebugDependencies(
            loadingIndicatorDelay: contentFirstLoadingDelay,
            contentTypeIdentifier: { _ in "net.daringfireball.markdown" }
        ))
        window.contentViewController = markdownController
        window.setContentSize(NSSize(width: 800, height: 600))
        let markdownCompletion = expectation(description: "Quick Look Markdown request completes")
        var markdownError: Error?
        markdownController.preparePreviewOfFile(at: try fixtureURL("Showcase/markdown/markdown.md")) { error in
            markdownError = error
            markdownCompletion.fulfill()
        }
        await fulfillment(of: [markdownCompletion], timeout: 5)
        XCTAssertNil(markdownError)
        try attachQuickLookControllerSnapshots(markdownController, format: "Markdown", modes: [0, 1])
    }

    @MainActor
    private func attachQuickLookControllerSnapshots(
        _ controller: PreviewViewController,
        format: String,
        modes: [Int]
    ) throws {
        let views = allViews(beneath: controller.view)
        let tabs = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            controller.configuration = RenderConfiguration(
                appearance: appearanceName == .darkAqua ? .dark : .light
            )
            controller.view.appearance = appearance
            for mode in modes {
                XCTAssertTrue(tabs.isEnabled(forSegment: mode), "\(format) mode \(mode) is enabled")
                tabs.selectedSegment = mode
                _ = tabs.sendAction(tabs.action, to: tabs.target)
                controller.view.layoutSubtreeIfNeeded()

                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                appearance.performAsCurrentDrawingAppearance {
                    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                }
                let attachment = XCTAttachment(
                    data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                    uniformTypeIdentifier: "public.png"
                )
                attachment.name = "QuickLookController-\(format)-\(appearanceName.rawValue)-\(tabs.label(forSegment: mode) ?? "mode-\(mode)")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testPreviewProviderFailureAndInvalidTokenSuppressOnlyMarker() async throws {
        let missingURL = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("missing")
        let failedMarkerRecorder = ProviderMarkerRecorder()
        let failedTokenCalls = ProviderCallCounter()
        let failedController = PreviewViewController(debugDependencies: PreviewProviderDebugDependencies(
            loadingIndicatorDelay: contentFirstLoadingDelay,
            tokenReader: { _ in failedTokenCalls.increment(); return "01234567-89ab-cdef-0123-456789abcdef" },
            markerObserver: { marker in failedMarkerRecorder.append(marker) }
        ))
        let failed = expectation(description: "Missing-file preparation fails")
        failedController.preparePreviewOfFile(at: missingURL) { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(failedTokenCalls.value, 1)
        XCTAssertTrue(failedMarkerRecorder.values.isEmpty)

        let url = try writeTemporaryFile(Data("plain words\n".utf8), named: "unknown")
        let invalidMarkerRecorder = ProviderMarkerRecorder()
        let invalidController = PreviewViewController(debugDependencies: PreviewProviderDebugDependencies(
            loadingIndicatorDelay: contentFirstLoadingDelay,
            tokenReader: { _ in "01234567-89AB-cdef-0123-456789abcdef" },
            contentTypeIdentifier: { _ in nil },
            markerObserver: { marker in invalidMarkerRecorder.append(marker) }
        ))
        let completed = expectation(description: "Invalid token does not change successful preview")
        invalidController.preparePreviewOfFile(at: url) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(invalidMarkerRecorder.values.isEmpty)
    }

    @MainActor
    func testPreviewControllerDeallocationReportsCancellationWithoutMarker() async throws {
        let url = try writeTemporaryFile(Data("plain words\n".utf8), named: "unknown")
        let gate = ProviderPreparationGate()
        defer { gate.release.signal() }
        let recorder = ProviderMarkerRecorder()
        let dependencies = PreviewProviderDebugDependencies(
            loadingIndicatorDelay: contentFirstLoadingDelay,
            contentTypeIdentifier: { _ in
                gate.entered.fulfill()
                _ = gate.release.wait(timeout: .now() + 5)
                return nil
            },
            markerObserver: { marker in recorder.append(marker) }
        )
        var controller: PreviewViewController? = PreviewViewController(debugDependencies: dependencies)
        let controllerBox = PreviewControllerWeakBox()
        controllerBox.value = controller
        let completed = expectation(description: "Released controller reports cancellation")
        controller?.preparePreviewOfFile(at: url) { error in
            XCTAssertTrue(error is CancellationError)
            completed.fulfill()
        }

        await fulfillment(of: [gate.entered], timeout: 5)
        controller = nil
        XCTAssertNil(controllerBox.value)
        gate.release.signal()
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(recorder.values.isEmpty)
    }

    private static var markerScores: [(DetectionEvidence.SignalKind, Double)] {
        [(.filename, 0), (.multiExtension, 0), (.singleExtension, 0), (.shebang, 0),
         (.yamlMapping, 0.75), (.yamlDocumentMarker, 0.80), (.systemUTI, 0)]
    }
#endif

    func testPreparationCompletenessAndConfirmedEOFVectors() {
        let boundaryVectors: [(Data, Int, Int, Bool)] = [
            (Data(), 0, 0, true),
            (Data(repeating: 0x61, count: 65_536), 65_536, 65_536, true),
            (Data(repeating: 0x61, count: 65_537), 65_537, 65_536, false),
            (Data(repeating: 0x61, count: 10), 11, 10, false),
            (Data(repeating: 0x61, count: 11), 10, 11, false)
        ]
        for (bytes, fileSize, sampleCount, complete) in boundaryVectors {
            let result = PreviewPreparation.prepare(bytes: bytes, fileSize: fileSize, fileName: "unknown", systemUTI: nil)
            XCTAssertEqual(result.sampleByteCount, sampleCount)
            XCTAssertEqual(result.sampleIsComplete, complete)
            XCTAssertEqual(result.resolution.typeID, "unknown")
        }

        let shebang = Data("#!/usr/bin/env python3".utf8)
        let padded = shebang + Data(repeating: 0x20, count: 65_536 - shebang.count)
        XCTAssertEqual(PreviewPreparation.prepare(bytes: padded, fileSize: padded.count, fileName: "script", systemUTI: nil).resolution.confidence.value, 0.90)
        XCTAssertEqual(PreviewPreparation.prepare(bytes: padded, fileSize: padded.count + 1, fileName: "script", systemUTI: nil).resolution.typeID, "unknown")
        let terminatedIncomplete = Data("#!/usr/bin/env python3\n".utf8) + Data(repeating: 0x61, count: 10)
        XCTAssertEqual(PreviewPreparation.prepare(
            bytes: terminatedIncomplete,
            fileSize: terminatedIncomplete.count + 1,
            fileName: "script",
            systemUTI: nil
        ).resolution.typeID, "python")

        var lastByteLF = Data("#!/usr/bin/env python3".utf8)
        lastByteLF.append(Data(repeating: 0x20, count: 65_535 - lastByteLF.count))
        lastByteLF.append(0x0A)
        XCTAssertEqual(lastByteLF.count, 65_536)
        XCTAssertEqual(PreviewPreparation.prepare(bytes: lastByteLF, fileSize: lastByteLF.count, fileName: "script", systemUTI: nil).resolution.typeID, "python")

        let beyondSampleLF = Data("#!/usr/bin/env python3".utf8)
            + Data(repeating: 0x20, count: 65_536 - shebang.count)
            + Data([0x0A])
        XCTAssertEqual(PreviewPreparation.prepare(bytes: beyondSampleLF, fileSize: beyondSampleLF.count, fileName: "script", systemUTI: nil).resolution.typeID, "unknown")
    }

    func testReadFallsBackWhenUTIMetadataIsUnavailableAndThrowsForMissingFile() throws {
        let url = try writeJSONFixture(Data("plain words\n".utf8))
        let nilUTI = try PreviewPreparation.read(at: url) { _ in nil }
        let throwingUTI = try PreviewPreparation.read(at: url) { _ in throw CocoaError(.fileReadUnknown) }
        XCTAssertEqual(nilUTI.resolution.typeID, "json")
        XCTAssertEqual(throwingUTI.resolution.typeID, "json")
        XCTAssertEqual(nilUTI.resolution, TypeResolver().resolve(
            fileName: url.lastPathComponent,
            leadingBytes: Data("plain words\n".utf8),
            systemUTI: nil,
            sampleIsComplete: true
        ))
        XCTAssertThrowsError(try PreviewPreparation.read(at: url.appendingPathComponent("missing")))
    }

    func testReadKeepsAnalysisBoundedAtPreviewCeiling() throws {
        for (count, truncated) in [(1_048_576, false), (1_048_577, true)] {
            let bytes = Data(repeating: 0x61, count: count)
            let url = try writeTemporaryFile(bytes, named: "unknown-\(count)")
            let preparation = try PreviewPreparation.read(at: url) { _ in nil }
            XCTAssertEqual(preparation.analysis.text.utf8.count, 1_048_576)
            XCTAssertEqual(preparation.analysis.truncated, truncated)
            XCTAssertEqual(preparation.sampleByteCount, 65_536)
            XCTAssertFalse(preparation.sampleIsComplete)
        }
    }

    @MainActor
    func testFR005RealInputs() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FR005_REQUIRE_REAL_INPUT"] != nil || environment["FR005_REAL_INPUT_DIR"] != nil else {
            throw XCTSkip("Real adapter inputs are not configured")
        }
        guard environment["FR005_REQUIRE_REAL_INPUT"] == "1",
              let directoryPath = environment["FR005_REAL_INPUT_DIR"],
              directoryPath.hasPrefix("/") else {
            XCTFail("Supplied real-input mode requires FR005_REQUIRE_REAL_INPUT=1 and an absolute FR005_REAL_INPUT_DIR")
            return
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let yaml = try Data(contentsOf: directory.appendingPathComponent("fr005b-tapioca.yml"), options: .mappedIfSafe)
        let python = try Data(contentsOf: directory.appendingPathComponent("glib-mkenums"), options: .mappedIfSafe)
        try requireRealInput(yaml.count == 917, "Tapioca YAML byte count changed; do not process it until revalidated")
        try requireRealInput(
            Self.sha256(yaml) == "0cca808009e7f0b76c4667cd211f0b196aa97b25e489cbb8a09aa472f5b68adb",
            "Tapioca YAML SHA-256 changed; do not process it until revalidated"
        )
        try requireRealInput(python.count == 32_278, "glib-mkenums byte count changed; do not process it until revalidated")
        try requireRealInput(
            Self.sha256(python) == "6b144d7044beeddcde563f4588cd7e3aed74f4dbc9198af1223b2993de9a9ea5",
            "glib-mkenums SHA-256 changed; do not process it until revalidated"
        )

        let configURL = try writeTemporaryFile(yaml, named: "config")
        let scriptURL = try writeTemporaryFile(python, named: "script")
        let tsURL = try writeTemporaryFile(yaml, named: "foo.ts")
        let makefileURL = try writeTemporaryFile(yaml, named: "Makefile")
        let config = try PreviewPreparation.read(at: configURL) { _ in nil }
        let script = try PreviewPreparation.read(at: scriptURL) { _ in nil }
        let typescript = try PreviewPreparation.read(at: tsURL) { _ in nil }
        try assertRealResult(config, type: "yaml", confidence: 0.80, scores: [0, 0, 0, 0, 0.75, 0.80, 0])
        try assertRealResult(script, type: "python", confidence: 0.90, scores: [0, 0, 0, 0.90, 0, 0, 0])
        try assertRealResult(typescript, type: "typescript", confidence: 0.95, scores: [0, 0, 0.95, 0, 0.75, 0.80, 0])
        let makefile = try PreviewPreparation.read(at: makefileURL) { _ in "public.make-source" }
        try assertRealResult(makefile, type: "makefile", confidence: 1.0, scores: [1, 0, 0, 0, 0.75, 0.80, 0])
        try requireRealInput(
            !makefile.resolution.evidence.contains { $0.signalKind == .utiConflict },
            "Makefile resolution unexpectedly reports a UTI conflict"
        )

        let defaultPreparation = try PreviewPreparation.read(at: configURL)
        let actualUTI = try configURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        try requireRealInput(defaultPreparation.resolution == TypeResolver().resolve(
            fileName: configURL.lastPathComponent,
            leadingBytes: Data(yaml.prefix(65_536)),
            systemUTI: actualUTI,
            sampleIsComplete: true
        ), "Default UTI metadata differs from direct resolver output")

        let configPresentation = try present(config)
        try requireRealInput(
            statusContains(configPresentation.header, expected: expectedHeader(type: "YAML", analysis: config.analysis)),
            "Genuine extensionless YAML header did not retain resolver and analysis metadata"
        )
        try requireRealInput(
            configPresentation.body == String(decoding: yaml, as: UTF8.self),
            "Genuine extensionless YAML body changed during preview presentation"
        )

        let scriptPresentation = try present(script)
        try requireRealInput(
            statusContains(scriptPresentation.header, expected: expectedHeader(type: "Python", analysis: script.analysis)),
            "Genuine extensionless Python header did not retain resolver and analysis metadata"
        )
        try requireRealInput(
            scriptPresentation.body == String(decoding: python, as: UTF8.self),
            "Genuine extensionless Python body changed during preview presentation"
        )

#if DEBUG
        let yamlToken = UUID().uuidString.lowercased()
        let pythonToken = UUID().uuidString.lowercased()
        try setEvidenceAttribute(Data(yamlToken.utf8), at: configURL)
        try setEvidenceAttribute(Data(pythonToken.utf8), at: scriptURL)
        XCTAssertEqual(PreviewProviderMarkerSerializer.readToken(from: configURL), yamlToken)
        XCTAssertEqual(PreviewProviderMarkerSerializer.readToken(from: scriptURL), pythonToken)

        let yamlProviderResult = try await inspectPreviewProvider(at: configURL, systemUTI: "public.yaml")
        assertStatus(yamlProviderResult.header, contains: "YAML | UTF-8 | LF")
        XCTAssertEqual(yamlProviderResult.markers, [
            "FR005_PROVIDER_V1 token=\(yamlToken) provider=preview phase=display-prepared type=yaml confidence=0.80 scores=0.00,0.00,0.00,0.00,0.75,0.80,0.60 sampleBytes=917 complete=1"
        ])
        let pythonProviderResult = try await inspectPreviewProvider(at: scriptURL, systemUTI: "public.python-script")
        XCTAssertEqual(pythonProviderResult.markers, [
            "FR005_PROVIDER_V1 token=\(pythonToken) provider=preview phase=display-prepared type=python confidence=0.90 scores=0.00,0.00,0.00,0.90,0.00,0.00,0.60 sampleBytes=32278 complete=1"
        ])
        XCTAssertEqual(Self.sha256(try Data(contentsOf: configURL)), "0cca808009e7f0b76c4667cd211f0b196aa97b25e489cbb8a09aa472f5b68adb")
        XCTAssertEqual(Self.sha256(try Data(contentsOf: scriptURL)), "6b144d7044beeddcde563f4588cd7e3aed74f4dbc9198af1223b2993de9a9ea5")
#endif
        let receipt = XCTAttachment(string: "Preview adapter received required FR-005 real-input vectors and fingerprints.")
        receipt.name = "Preview adapter FR005_REQUIRE_REAL_INPUT=1 receipt"
        add(receipt)
    }

    @MainActor
    private func attachStructuredSnapshots(_ controller: SharedPreviewViewController, format: String) throws {
        let views = allViews(beneath: controller.view)
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        // Capture only this synthetic fixture, never the user's desktop or genuine file contents.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 640, height: 480))
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            controller.view.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            window.appearance = controller.view.appearance
            for mode in 0...2 {
                modes.selectedSegment = mode
                _ = modes.sendAction(modes.action, to: modes.target)
                controller.view.layoutSubtreeIfNeeded()
                let header = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first {
                    $0.identifier?.rawValue == "PreviewStatus"
                })
                let headerFrame = header.convert(header.bounds, to: controller.view)
                XCTAssertGreaterThanOrEqual(headerFrame.minY, controller.view.bounds.minY)
                XCTAssertLessThanOrEqual(headerFrame.maxY, controller.view.bounds.maxY)
                XCTAssertTrue(header.isDescendant(of: try XCTUnwrap(views.first { $0.identifier?.rawValue == "PreviewFooter" })))
                let modeFrame = modes.convert(modes.bounds, to: controller.view)
                XCTAssertGreaterThanOrEqual(modeFrame.minX, controller.view.bounds.minX)
                XCTAssertLessThanOrEqual(modeFrame.maxX, controller.view.bounds.maxX)
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                try XCTUnwrap(window.appearance).performAsCurrentDrawingAppearance {
                    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                }
                let body = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
                let bodyFrame = body.convert(body.bounds, to: controller.view)
                let scale = CGFloat(bitmap.pixelsHigh) / controller.view.bounds.height
                let firstRow = max(0, Int((controller.view.bounds.maxY - bodyFrame.maxY) * scale) + 2)
                let lastRow = min(bitmap.pixelsHigh, firstRow + 80)
                let background = bitmap.colorAt(x: 2, y: firstRow)
                let hasVisibleContent = stride(from: firstRow, to: lastRow, by: 2).contains { y in
                    stride(from: 2, to: bitmap.pixelsWide - 2, by: 2).contains { x in
                        bitmap.colorAt(x: x, y: y) != background
                    }
                }
                XCTAssertTrue(hasVisibleContent, "Footer background must not paint over the JSON content")
                let image = NSImage(size: controller.view.bounds.size)
                image.lockFocus()
                try XCTUnwrap(window.appearance).performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    controller.view.bounds.fill()
                    bitmap.draw(in: controller.view.bounds)
                }
                image.unlockFocus()
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(format)-\(appearance.rawValue)-\(mode)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func writeJSONFixture(_ contents: Data) throws -> URL {
        let url = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("\(UUID().uuidString).json")
        try contents.write(to: url)
        return url
    }

    private func writeTemporaryFile(_ contents: Data, named name: String) throws -> URL {
        let url = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func setEvidenceAttribute(_ value: Data, at url: URL) throws {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { (path: UnsafePointer<Int8>?) -> Int32 in
            guard let path else { return -1 }
            return "com.glimt.fr005-evidence".withCString { (name: UnsafePointer<Int8>) -> Int32 in
                value.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
                    setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

#if DEBUG
    @MainActor
    private func inspectPreviewProvider(at url: URL, systemUTI: String) async throws -> (header: String, markers: [String]) {
        let recorder = ProviderMarkerRecorder()
        let controller = PreviewViewController(debugDependencies: PreviewProviderDebugDependencies(
            loadingIndicatorDelay: contentFirstLoadingDelay,
            contentTypeIdentifier: { _ in systemUTI },
            markerObserver: { marker in recorder.append(marker) }
        ))
        controller.loadViewIfNeeded()
        let completed = expectation(description: "Genuine preview provider request completes")
        var completionError: Error?
        controller.preparePreviewOfFile(at: url) { error in
            completionError = error
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertNil(completionError)
        let header = allViews(beneath: controller.view).compactMap { $0 as? PreviewStatusView }.first {
            $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
        }.map { $0.accessibilityLabel() ?? $0.stringValue } ?? ""
        return (header, recorder.values)
    }
#endif

    private func assertRealResult(
        _ preparation: PreviewPreparation,
        type: String,
        confidence: Double,
        scores: [Double]
    ) throws {
        try requireRealInput(preparation.resolution.typeID == type, "Real input resolved as \(preparation.resolution.typeID); expected \(type)")
        try requireRealInput(
            abs(preparation.resolution.confidence.value - confidence) <= 0.000_001,
            "Real input confidence \(preparation.resolution.confidence.value) did not match \(confidence)"
        )
        try requireRealInput(
            preparation.resolution.evidence.prefix(7).map(\.score.value) == scores,
            "Real input detector score vector changed"
        )
        try requireRealInput(
            preparation.sampleByteCount == min(preparation.analysis.fileSize, 65_536),
            "Real input resolver sample count changed"
        )
        try requireRealInput(preparation.sampleIsComplete, "Real input was not read as complete")
    }

    private func requireRealInput(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            XCTFail(message, file: #filePath, line: #line)
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func expectedHeader(type: String, analysis: TextAnalysis) -> String {
        [type, analysis.encoding?.displayName ?? "UTF-8", analysis.lineEnding.rawValue].joined(separator: " | ")
    }

    private func statusContains(_ actual: String, expected: String) -> Bool {
        expected.components(separatedBy: " | ").filter { !$0.isEmpty && $0 != "none" }.allSatisfy {
            actual.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    private func assertStatus(_ actual: String, contains expected: String, message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(statusContains(actual, expected: expected), "Status \(actual) lacks \(expected). \(message)", file: file, line: line)
    }

    @MainActor
    private func present(_ preparation: PreviewPreparation) throws -> (header: String, body: String) {
        let controller = makeSizedPreviewController()
        controller.display(preparation)
        let descendants = allViews(beneath: controller.view)
        let header = try XCTUnwrap(descendants.compactMap { $0 as? PreviewStatusView }.first {
            $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
        })
        let scrollView = try XCTUnwrap(descendants.compactMap { $0 as? NSScrollView }.first)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        return (header.accessibilityLabel() ?? header.stringValue, textView.string)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func render(at url: URL) async -> (header: String, text: String) {
        let controller = makeSizedPreviewController()
        controller.loadViewIfNeeded()

        do { try await controller.preview(for: url, configuration: .init()) }
        catch { XCTFail("Shared preview failed: \(error)") }

        let descendants = allViews(beneath: controller.view)
        guard
            let header = descendants.compactMap({ $0 as? PreviewStatusView }).first(where: {
                $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
            }),
            let scrollView = descendants.compactMap({ $0 as? NSScrollView }).first,
            let textView = scrollView.documentView as? NSTextView
        else {
            XCTFail("Preview controller did not create its text view")
            return ("", "")
        }

        return (header.accessibilityLabel() ?? header.stringValue, textView.string)
    }

    @MainActor
    private func allViews(beneath view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(beneath: $0) }
    }
}

private final class ProviderMarkerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class PreviewTokenReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class ProviderCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class ProviderPreparationGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Detached UTI lookup entered")
    let release = DispatchSemaphore(value: 0)
}

private struct QuickLookVCSProvider: VCSProvider {
    let gate: QuickLookVCSInspectionGate
    let result: VCSInspectionResult
    var repositoryType: VCSRepositoryType { result.repositoryType }

    func inspect(fileURL: URL) async -> VCSProviderInspection {
        await gate.suspend()
        return .inspected(result)
    }
}

private actor QuickLookVCSInspectionGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private final class PreviewControllerWeakBox {
    weak var value: PreviewViewController?
}

/// Records Quick Look replies so tests can assert exactly-once completion.
@MainActor
private final class ReplyRecorder {
    private(set) var errors: [Error?] = []
    var count: Int { errors.count }
    func record(_ error: Error?) { errors.append(error) }
}

/// Loading delay for adapter tests that read the displayed content as soon as Quick Look's reply
/// arrives. It keeps the reply content-first, since an early reply for the loading indicator
/// (ADR-040) would let a loaded test machine assert before the document is displayed.
let contentFirstLoadingDelay: Duration = .seconds(3_600)
