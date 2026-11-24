import AppKit
import Foundation
import InspectorCore
import XCTest

final class XMLPlistPreviewTests: XCTestCase {
    @MainActor
    func testStructuredTreeHeadersUseSemanticTextColorInLightAndDarkAppearance() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let controller = makeSizedPreviewController()
        controller.display(PreviewPreparation.prepare(bytes: Data("{\"name\":\"Glimt\"}".utf8),
                                                      fileSize: 16, fileName: "config.json", systemUTI: "public.json"))
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            controller.configuration = RenderConfiguration(appearance: name == .darkAqua ? .dark : .light)
            controller.view.appearance = appearance
            window.contentView?.layoutSubtreeIfNeeded()

            let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            let headerView = try XCTUnwrap(outline.headerView)
            XCTAssertEqual(headerView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)

            for column in outline.tableColumns {
                let headerCell = try XCTUnwrap(column.headerCell as? StructuredTreeHeaderCell)
                XCTAssertEqual(headerCell.stringValue, column.title)
                let columnIndex = try XCTUnwrap(outline.tableColumns.firstIndex { $0 === column })
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                            pixelsWide: max(1, Int(headerView.bounds.width)),
                                                            pixelsHigh: max(1, Int(headerView.bounds.height)),
                                                            bitsPerSample: 8,
                                                            samplesPerPixel: 4,
                                                            hasAlpha: true,
                                                            isPlanar: false,
                                                            colorSpaceName: .deviceRGB,
                                                            bytesPerRow: 0,
                                                            bitsPerPixel: 0))
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                headerView.effectiveAppearance.performAsCurrentDrawingAppearance {
                    headerCell.draw(withFrame: headerView.headerRect(ofColumn: columnIndex), in: headerView)
                }
                let drawnColor = try XCTUnwrap(headerCell.attributedStringValue.attribute(.foregroundColor,
                                                                                           at: 0,
                                                                                           effectiveRange: nil) as? NSColor)
                let actual = try XCTUnwrap(drawnColor.usingColorSpace(.deviceRGB))
                let luminance = 0.2126 * actual.redComponent + 0.7152 * actual.greenComponent + 0.0722 * actual.blueComponent
                if name == .darkAqua {
                    XCTAssertGreaterThan(luminance, 0.5, "\(column.title) header must remain legible in Dark Aqua")
                } else {
                    XCTAssertLessThan(luminance, 0.5, "\(column.title) header must remain legible in Aqua")
                }
            }
        }
    }

    @MainActor
    func testFractionalPlistDateHasUnderstandableLosslessFallback() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1.25)
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["date": date], format: .binary, options: 0)
        let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "date.plist", systemUTI: nil)
        let controller = makeSizedPreviewController()
        controller.display(preparation)
        let views = descendants(controller.view)
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        XCTAssertEqual((0..<modes.segmentCount).compactMap(modes.label(forSegment:)), ["Tree", "Raw"],
                       "Unavailable Pretty is hidden, not disabled")
        XCTAssertEqual(modes.selectedSegment, 0)
        let diagnostic = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        XCTAssertTrue(preparation.structuredDiagnostics.contains { $0.message.contains("fractional dates") })
        XCTAssertTrue((diagnostic.accessibilityLabel() ?? diagnostic.stringValue).contains("Pretty unavailable"))
        XCTAssertTrue(preparation.structuredDiagnostics.contains { $0.message.contains("Tree and Raw remain available") })
        XCTAssertFalse(diagnostic.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse((diagnostic.accessibilityLabel() ?? "").isEmpty)
    }

    @MainActor
    func testXMLFixturesTreePrettyRawAndMalformedFallback() throws {
        for name in ["simple", "attributes", "namespaces", "mixed-content", "comments"] {
            let url = try fixtureURL(name == "attributes" ? "Showcase/xml/xml.xml" : "Cases/xml/valid/\(name).xml")
            let preparation = try PreviewPreparation.read(at: url)
            let inspection = try XCTUnwrap(preparation.xmlInspection, name)
            XCTAssertNil(preparation.plistInspection)
            XCTAssertNil(preparation.sourceDocument)
            XCTAssertNil(preparation.markdownDocument)
            XCTAssertNotNil(inspection.root)
            let controller = makeSizedPreviewController()
            controller.display(preparation)
            let modes = try modeControl(controller)
            XCTAssertEqual((0..<modes.segmentCount).compactMap(modes.label(forSegment:)), ["Tree", "Pretty", "Raw"])
            XCTAssertEqual(modes.selectedSegment, 0)
            let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertEqual(outline.accessibilityLabel(), "XML structure")
            XCTAssertGreaterThan(outline.numberOfRows, 1)
            select(1, modes)
            XCTAssertEqual(try textView(controller).string, inspection.prettyText)
            select(2, modes)
            XCTAssertEqual(try textView(controller).string, inspection.rawText)
            if name == "namespaces" { try snapshots(controller, format: "XML") }
        }
        for name in ["malformed", "truncated"] {
            let url = try fixtureURL("Cases/xml/invalid/\(name).xml")
            let preparation = try PreviewPreparation.read(at: url)
            let controller = makeSizedPreviewController()
            controller.display(preparation)
            let modes = try modeControl(controller)
            XCTAssertEqual((0..<modes.segmentCount).compactMap(modes.label(forSegment:)), ["Raw"])
            XCTAssertEqual(modes.selectedSegment, 0)
            XCTAssertEqual(try textView(controller).string, String(decoding: try Data(contentsOf: url), as: UTF8.self))
            XCTAssertTrue(preparation.structuredDiagnostics.first?.message.contains("Line") ?? false)
        }
    }

    @MainActor
    func testKMLAndGPXUseGeospatialTreeWithSharedXMLPrettyAndRawViews() throws {
        for (path, expectedID, label) in [
            ("Showcase/geospatial/places.kml", FormatID.kml, "KML structure"),
            ("Showcase/geospatial/route.gpx", FormatID.gpx, "GPX structure")
        ] {
            let preparation = try PreviewPreparation.read(at: fixtureURL(path))
            XCTAssertEqual(preparation.formatDefinition?.id, expectedID)
            XCTAssertNotNil(preparation.xmlInspection?.domainSummary)
            let controller = makeSizedPreviewController()
            controller.display(preparation)
            let modes = try modeControl(controller)
            XCTAssertEqual((0..<modes.segmentCount).compactMap(modes.label(forSegment:)), ["Tree", "Pretty", "Raw"])
            let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertEqual(outline.accessibilityLabel(), label)
            XCTAssertGreaterThan(outline.numberOfRows, 1)
            select(1, modes)
            XCTAssertEqual(try textView(controller).string, preparation.xmlInspection?.prettyText)
            select(2, modes)
            XCTAssertEqual(try textView(controller).string, preparation.xmlInspection?.rawText)
        }
    }

    @MainActor
    func testPropertyListXMLAndBinaryUseTypedModes() throws {
        for path in ["Cases/plist/xml/simple.plist", "Showcase/plist/plist.plist", "Cases/plist/xml/all-types.plist", "Showcase/plist/binary.plist"] {
            let url = try fixtureURL(path)
            let preparation = try PreviewPreparation.read(at: url)
            let plist = try XCTUnwrap(preparation.plistInspection, path)
            XCTAssertNotNil(plist.content)
            XCTAssertNil(preparation.xmlInspection)
            let controller = makeSizedPreviewController()
            controller.display(preparation)
            let modes = try modeControl(controller)
            XCTAssertEqual((0..<modes.segmentCount).compactMap(modes.label(forSegment:)), ["Tree", "Pretty", "Raw"], path)
            XCTAssertEqual(modes.selectedSegment, 0)
            let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertEqual(outline.accessibilityLabel(), "Property list structure")
            XCTAssertGreaterThan(outline.numberOfRows, 1)
            select(1, modes)
            XCTAssertEqual(try textView(controller).string, plist.prettyText)
            select(2, modes)
            let raw = try textView(controller).string
            if plist.isBinary {
                XCTAssertTrue(raw.hasPrefix("00000000  62 70 6c 69 73 74 30 30"))
                XCTAssertFalse(raw.contains("Binary property list"))
                XCTAssertTrue(raw.contains("|bplist00"))
                XCTAssertFalse(raw.contains("<?xml"))
            } else { XCTAssertEqual(raw, plist.rawText) }
            if path.hasSuffix("all-types.plist") {
                let root = try XCTUnwrap(outline.item(atRow: 0))
                let count = outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: root) ?? 0
                let typeColumn = try XCTUnwrap(outline.tableColumns.first { $0.identifier.rawValue == "Type" })
                let valueColumn = try XCTUnwrap(outline.tableColumns.first { $0.identifier.rawValue == "Value" })
                var foundData = false
                for index in 0..<count {
                    let child = try XCTUnwrap(outline.dataSource?.outlineView?(outline, child: index, ofItem: root))
                    let type = outline.delegate?.outlineView?(outline, viewFor: typeColumn, item: child) as? NSTextField
                    if type?.stringValue == "Data" {
                        let value = outline.delegate?.outlineView?(outline, viewFor: valueColumn, item: child) as? NSTextField
                        XCTAssertLessThan(try XCTUnwrap(value).stringValue.count, 32)
                        XCTAssertFalse(try XCTUnwrap(value).stringValue.contains("AAEC/w=="))
                        foundData = true
                    }
                }
                XCTAssertTrue(foundData)
                try snapshots(controller, format: "Plist")
            }
        }
    }

    @MainActor
    func testContentRoutingMalformedAndBoundedBinaryRaw() throws {
        let binary = try Data(contentsOf: fixtureURL("Showcase/plist/binary.plist"))
        XCTAssertNotNil(PreviewPreparation.prepare(bytes: binary, fileSize: binary.count, fileName: "unknown.bin", systemUTI: nil).plistInspection?.content)
        let xml = try Data(contentsOf: fixtureURL("Cases/plist/xml/simple.plist"))
        let asXML = PreviewPreparation.prepare(bytes: xml, fileSize: xml.count, fileName: "misleading.xml", systemUTI: "public.xml")
        XCTAssertNotNil(asXML.plistInspection?.content)
        XCTAssertNil(asXML.xmlInspection)
        let malformed = try Data(contentsOf: fixtureURL("Cases/plist/invalid/malformed.plist"))
        let controller = makeSizedPreviewController()
        controller.display(PreviewPreparation.prepare(bytes: malformed, fileSize: malformed.count, fileName: "broken.plist", systemUTI: "public.xml"))
        XCTAssertEqual(try modeControl(controller).selectedSegment, 0)
        XCTAssertEqual(try textView(controller).string, String(decoding: malformed, as: UTF8.self))
        let large = Data("bplist00".utf8) + Data(repeating: 0, count: 512)
        let incomplete = PreviewPreparation.prepare(bytes: large, fileSize: 2_000_000, fileName: "large.plist", systemUTI: nil)
        controller.display(incomplete)
        XCTAssertEqual(try modeControl(controller).selectedSegment, 0)
        XCTAssertLessThan(try textView(controller).string.count, 4_096)
        XCTAssertEqual(try textView(controller).string.split(separator: "\n").count, 33)
        let status = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        XCTAssertTrue(status.accessibilityLabel()?.contains("520 bytes shown of 2000000 bytes") == true)
        XCTAssertTrue(status.accessibilityLabel()?.contains("2.0 MB total") == true)
    }

    @MainActor
    func testTreeKeySortingIsStableAndPreservesJSONYAMLAndPlistRaw() throws {
        for (name, source) in [("JSON", "{\"z\":0,\"a\":1,\"a\":2}"),
                               ("YAML", "z: 0\na: 1\nb: 2\n")] {
            let bytes = Data(source.utf8)
            let value: StructuredValue?
            if name == "JSON" {
                let inspection = try JSONInspector.inspect(bytes: bytes)
                value = inspection.content
                XCTAssertEqual(inspection.rawText, source)
                XCTAssertEqual(inspection.rawBytes, bytes)
            } else {
                let inspection = try YAMLInspector.inspect(bytes: bytes)
                value = inspection.documents?.first
                XCTAssertEqual(inspection.rawText, source)
                XCTAssertEqual(inspection.rawBytes, bytes)
            }
            let tree = StructuredTreeView()
            tree.configure(sortKeys: true, expandDepth: 1)
            tree.display(value, formatName: name)
            let outline = try XCTUnwrap(descendants(tree).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertEqual(try cellTexts(outline, column: "Key"), name == "JSON" ? ["$", "a", "a", "z"] : ["$", "a", "b", "z"])
            if name == "JSON" { XCTAssertEqual(try cellTexts(outline, column: "Value").suffix(3), ["1", "2", "0"]) }
            tree.configure(sortKeys: false, expandDepth: 1)
            tree.display(value, formatName: name)
            XCTAssertEqual(try cellTexts(outline, column: "Key")[1], "z")
        }
        let source = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>z</key><integer>0</integer><key>a</key><integer>1</integer></dict></plist>"
        let bytes = Data(source.utf8)
        let inspection = try PlistInspector.inspect(bytes: bytes)
        let tree = StructuredTreeView()
        tree.configure(sortKeys: true, expandDepth: 1)
        tree.displayPlist(inspection.content)
        let outline = try XCTUnwrap(descendants(tree).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertEqual(try cellTexts(outline, column: "Key"), ["$", "a", "z"])
        XCTAssertEqual(inspection.rawText, source)
        XCTAssertEqual(inspection.rawBytes, bytes)
    }

    @MainActor
    func testTreeExpansionDepthDefaultsAndClampsWithoutChangingXMLOrder() throws {
        let inspection = try JSONInspector.inspect(bytes: Data("{\"z\":{\"y\":{\"x\":{\"leaf\":1}}},\"a\":0}".utf8))
        let tree = StructuredTreeView()
        tree.display(inspection.content)
        let outline = try XCTUnwrap(descendants(tree).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertEqual(try cellTexts(outline, column: "Key"), ["$", "z", "a"])
        for (depth, keys) in [(Int.min, ["$", "a", "z"]), (1, ["$", "a", "z"]),
                              (2, ["$", "a", "z", "y"]), (3, ["$", "a", "z", "y", "x"]),
                              (Int.max, ["$", "a", "z", "y", "x"])] {
            tree.configure(sortKeys: true, expandDepth: depth)
            tree.display(inspection.content)
            XCTAssertEqual(try cellTexts(outline, column: "Key"), keys)
        }
        let array = try JSONInspector.inspect(bytes: Data("{\"z\":[{\"b\":1,\"a\":2},{\"d\":3,\"c\":4}],\"a\":0}".utf8))
        tree.display(array.content)
        XCTAssertEqual(try cellTexts(outline, column: "Key"), ["$", "a", "z", "[0]", "a", "b", "[1]", "c", "d"])
        let xml = try XMLInspector.inspect(bytes: Data("<root><z><y><x><leaf/></x></y></z><a/></root>".utf8))
        tree.configure(sortKeys: true, expandDepth: 3)
        tree.displayXML(xml.root)
        XCTAssertEqual(try cellTexts(outline, column: "Key"), ["root", "z", "y", "x", "a"])
    }

    @MainActor
    private func cellTexts(_ outline: NSOutlineView, column name: String) throws -> [String] {
        let column = try XCTUnwrap(outline.tableColumns.first { $0.identifier.rawValue == name })
        return try (0..<outline.numberOfRows).map { row in
            let item = try XCTUnwrap(outline.item(atRow: row))
            let label = outline.delegate?.outlineView?(outline, viewFor: column, item: item) as? NSTextField
            return try XCTUnwrap(label).stringValue
        }
    }

    @MainActor
    private func snapshots(_ controller: SharedPreviewViewController, format: String) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 640, height: 480))
        defer { window.contentViewController = nil; window.close() }
        let modes = try modeControl(controller)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            controller.view.appearance = appearance
            window.appearance = appearance
            for mode in 0...2 {
                select(mode, modes)
                controller.view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                appearance.performAsCurrentDrawingAppearance { controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap) }
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "\(format)-\(name.rawValue)-\(mode)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    @MainActor private func modeControl(_ controller: SharedPreviewViewController) throws -> PreviewTabStrip { try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewTabStrip }.first) }
    @MainActor private func textView(_ controller: SharedPreviewViewController) throws -> NSTextView { try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first) }
    @MainActor private func select(_ mode: Int, _ control: PreviewTabStrip) { control.selectedSegment = mode; _ = control.sendAction(control.action, to: control.target) }
}
