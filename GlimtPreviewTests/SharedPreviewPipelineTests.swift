import AppKit
import Darwin
import Foundation
import CryptoKit
import GitInspection
import InspectorCore
import XCTest

final class SharedPreviewPipelineTests: XCTestCase {
    @MainActor
    func testFstabUsesTreeAndRawViews() async throws {
        XCTAssertEqual(ViewCategoryID.category(for: .fstab), .structuredData)
        let sheet = FormatsAndViewsSheet(session: SettingsSession(store: nil, snapshot: nil),
                                         selecting: .format(.fstab))
        sheet.loadViewIfNeeded()
        let structuredItem = try XCTUnwrap(sheet.item(for: .category(.structuredData)))
        XCTAssertTrue(structuredItem.children.contains { $0.scope == .format(.fstab) })
        XCTAssertEqual(sheet.orderedViews, [.tree, .raw])

        let example = try XCTUnwrap(PreviewSamples.examples(for: "text").first { $0.path == "Showcase/config/fstab" })
        let bundle = productShowcaseBundle()
        let resources = try XCTUnwrap(bundle.resourceURL)
        let bundledFixture = resources.appendingPathComponent("Showcase/config/fstab")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledFixture.path))
        let exampleURL = try XCTUnwrap(PreviewSamples.url(for: example, bundle: bundle))
        XCTAssertEqual(exampleURL.standardizedFileURL, bundledFixture.standardizedFileURL)

        let fixtureBytes = try Data(contentsOf: bundledFixture)
        let fixtureText = String(decoding: fixtureBytes, as: UTF8.self)
        let controller = makeSizedPreviewController()
        let inspection = try await controller.preview(for: exampleURL,
            configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertEqual(inspection.formatDefinition?.id, .fstab)
        XCTAssertEqual(PreviewChromeModel(inspection: inspection).representations, [.tree, .raw])
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        XCTAssertEqual(try selectedLabel(controller), "Tree")
        XCTAssertTrue(try header(descendants(controller.view)).contains("fstab"))
        let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertEqual(outline.accessibilityLabel(), "JSON structure")
        outline.expandItem(nil, expandChildren: true)
        controller.view.layoutSubtreeIfNeeded()
        let treeText = (0..<outline.numberOfRows).flatMap { row in
            (0..<outline.numberOfColumns).compactMap { column in
                (outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
            }
        }.joined(separator: "\n")
        XCTAssertTrue(treeText.contains("UUID="))
        XCTAssertTrue(treeText.contains("/boot/efi"))
        XCTAssertTrue(treeText.contains("/tmp"))
        let rawButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        rawButton.performClick(nil)
        XCTAssertEqual(try selectedLabel(controller), "Raw")
        XCTAssertEqual(try XCTUnwrap(visibleText(controller).first), fixtureText)

        for sample in ["", " # comment\r\n\t# another\n"] {
            let bytes = Data(sample.utf8)
            let empty = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "fstab", systemUTI: nil)
            XCTAssertEqual(empty.additionalStructuredContent, .array([]))
            XCTAssertTrue(empty.structuredDiagnostics.isEmpty)
            controller.display(empty)
            XCTAssertEqual(try selectedLabel(controller), "Tree")
            let emptyOutline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertLessThanOrEqual(emptyOutline.numberOfRows, 1)
            let emptyRaw = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
            emptyRaw.performClick(nil)
            XCTAssertEqual(try visibleText(controller), [sample])
        }

        let malformedBytes = try Data(contentsOf: fixtureURL("Cases/config/fstab/invalid/fstab"))
        let malformed = PreviewPreparation.prepare(bytes: malformedBytes, fileSize: malformedBytes.count,
            fileName: "fstab", systemUTI: nil)
        guard case .array(let malformedRows)? = malformed.additionalStructuredContent else {
            return XCTFail("Malformed fstab retains its valid rows in Tree")
        }
        XCTAssertEqual(malformedRows.count, 2)
        XCTAssertEqual(malformed.structuredDiagnostics.map(\.code), [.parseError])
        controller.display(malformed)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try selectedLabel(controller), "Tree")
        let warning = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewStatusView }.first)
        XCTAssertTrue(warning.stringValue.contains("Line 2: field count"))
        let malformedRaw = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        malformedRaw.performClick(nil)
        XCTAssertTrue(warning.stringValue.contains("Line 2: field count"))
        XCTAssertEqual(try visibleText(controller), [String(decoding: malformedBytes, as: UTF8.self)])

        let unrelatedBytes = Data("tmpfs /demo tmpfs defaults 0 0\n".utf8)
        let unrelated = PreviewPreparation.prepare(bytes: unrelatedBytes, fileSize: unrelatedBytes.count,
            fileName: "mount-table", systemUTI: "public.data")
        XCTAssertEqual(unrelated.formatName, "Plain text")
        XCTAssertNil(unrelated.additionalInspection)
        controller.display(unrelated)
        XCTAssertTrue(try mode(controller).isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(try visibleText(controller), [String(decoding: unrelatedBytes, as: UTF8.self)])

        let longText = (1...10_001).map { "tmpfs /row-\($0) tmpfs defaults 0 0" }
            .joined(separator: "\n") + "\nraw-after-parser-stop\n"
        let longBytes = Data(longText.utf8)
        let parserStopped = PreviewPreparation.prepare(bytes: longBytes, fileSize: longBytes.count,
            fileName: "fstab", systemUTI: nil)
        XCTAssertTrue(parserStopped.inspectionDiagnostics.contains { $0.code == .limitExceeded })
        XCTAssertEqual(parserStopped.originalBytes, longBytes)
        controller.display(parserStopped)
        let stopRaw = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        stopRaw.performClick(nil)
        let displayedLongRaw = try XCTUnwrap(visibleText(controller).first)
        XCTAssertEqual(displayedLongRaw, longText)
        XCTAssertTrue(displayedLongRaw.contains("raw-after-parser-stop"))

        let thumbnail = ThumbnailPreparation.prepare(bytes: fixtureBytes, fileSize: fixtureBytes.count,
            fileName: "fstab", systemUTI: nil)
        XCTAssertEqual(thumbnail.formatID, .fstab)
        XCTAssertEqual(FormatCatalog.definition(for: .fstab)?.effectiveThumbnailStrategy, .textLines)
        let thumbnailLines = ThumbnailRenderer.renderedLines(for: thumbnail.analysis,
            maximumSize: CGSize(width: 800, height: 50), scale: 1)
        XCTAssertEqual(thumbnailLines.first, "# <file system> <mount point> <type> <options> <dump> <pass>")
    }

    @MainActor
    func testFstabHostPreviewCapture() throws {
        guard let output = ProcessInfo.processInfo.environment["GLIMT_FSTAB_CAPTURE_DIR"] else {
            throw XCTSkip("Set GLIMT_FSTAB_CAPTURE_DIR to write fstab host preview evidence")
        }
        let outputDirectory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let source = "tmpfs /demo tmpfs defaults 0 0\nbroken\nproc /proc proc defaults 0 0\n"
        let bytes = Data(source.utf8)
        let preparation = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "fstab", systemUTI: nil)
        var settings = GlimtSettingsV3.factoryDefaults
        settings.general.colorScheme = .light
        let configuration = RenderConfiguration(settings: settings, appearance: .light)

        for (size, suffix) in [(NSSize(width: 1100, height: 700), "wide"),
                               (NSSize(width: 480, height: 700), "narrow")] {
            let controller = makeSizedPreviewController(configuration: configuration, size: size)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(size)
            defer { window.contentViewController = nil; window.close(); controller.cancelVCSInspection() }

            controller.display(preparation)
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertEqual(try selectedLabel(controller), "Tree")
            let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            outline.expandItem(nil, expandChildren: true)
            controller.view.layoutSubtreeIfNeeded()
            let treeText = (0..<outline.numberOfRows).flatMap { row in
                (0..<outline.numberOfColumns).compactMap { column in
                    (outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
                }
            }.joined(separator: "\n")
            XCTAssertTrue(treeText.contains("Line"))
            XCTAssertTrue(treeText.contains("1"))
            XCTAssertTrue(treeText.contains("3"))
            XCTAssertTrue(treeText.contains("/demo"))
            XCTAssertTrue(treeText.contains("/proc"))
            let status = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewStatusView }.first)
            XCTAssertTrue(status.stringValue.contains("Line 2: field count"))
            XCTAssertGreaterThan(status.visibleItemCount, 0)
            XCTAssertTrue(descendants(status).compactMap { $0 as? NSTextField }
                .contains { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == "Line 2: field count" })

            func capture(_ name: String) throws {
                let content = try XCTUnwrap(window.contentView)
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            try capture("fstab-tree-\(suffix).png")

            let rawButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
            rawButton.performClick(nil)
            XCTAssertEqual(try selectedLabel(controller), "Raw")
            XCTAssertTrue(status.stringValue.contains("Line 2: field count"))
            XCTAssertTrue(descendants(status).compactMap { $0 as? NSTextField }
                .contains { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == "Line 2: field count" })
            XCTAssertEqual(try XCTUnwrap(visibleText(controller).first), source)
            try capture("fstab-raw-\(suffix).png")
        }
    }

    @MainActor
    func testGeoJSONUsesSemanticTreeAndSharedPrettyRawViews() async throws {
        let url = try fixtureURL("Showcase/geospatial/countries.geojson")
        let preparation = try PreviewPreparation.read(at: url)
        XCTAssertEqual(preparation.formatDefinition?.id, .geojson)
        XCTAssertNotNil(preparation.jsonInspection?.domainSummary)
        XCTAssertEqual(PreviewChromeModel(inspection: preparation).representations, [.tree, .pretty, .raw])

        let controller = makeSizedPreviewController()
        _ = try await controller.preview(for: url,
            configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertEqual(outline.accessibilityLabel(), "GeoJSON structure")
        XCTAssertGreaterThan(outline.numberOfRows, 1)
        let modes = try mode(controller)
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertTrue(try visibleText(controller).joined().contains("FeatureCollection"))
        modes.selectedSegment = 2
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertTrue(try visibleText(controller).joined().contains("Harbor Island"))
    }

    @MainActor
    func testEmailCalendarAndContactFixturesUseSharedStructuredPreview() async throws {
        let cases: [(String, FormatID)] = [
            ("Showcase/mail/message.eml", .email),
            ("Showcase/calendar/events.ics", .icalendar),
            ("Showcase/contacts/contact.vcf", .vcard)
        ]
        let controller = makeSizedPreviewController()
        for (path, formatID) in cases {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let inspection = try PreviewPreparation.read(at: url)
            XCTAssertEqual(inspection.formatDefinition?.id, formatID, path)
            XCTAssertEqual(inspection.originalBytes, bytes, path)
            XCTAssertEqual(PreviewChromeModel(inspection: inspection).representations, [.tree, .raw], path)
            XCTAssertTrue(inspection.isStructured, path)
            XCTAssertNotNil(inspection.additionalStructuredContent, path)

            _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)
            XCTAssertGreaterThan(try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first).numberOfRows, 0, path)
        }

        for path in ["Cases/mail/invalid/malformed.eml", "Cases/calendar/invalid/malformed.ics", "Cases/contacts/invalid/malformed.vcf"] {
            let inspection = try PreviewPreparation.read(at: fixtureURL(path))
            XCTAssertTrue(inspection.inspectionDiagnostics.contains { $0.code == .parseError }, path)
            XCTAssertEqual(inspection.originalBytes, try Data(contentsOf: fixtureURL(path)), path)
        }
    }

    @MainActor
    func testZIPPreviewExposesTableAndHexFromTheSharedListing() async throws {
        let url = try fixtureURL("Showcase/data/inventory.zip")
        let inspection = try PreviewPreparation.read(at: url)
        let chrome = PreviewChromeModel(inspection: inspection, configuredViews: [.table, .hex])

        XCTAssertEqual(inspection.formatDefinition?.id, .zip)
        XCTAssertEqual(chrome.representations, [.table, .hex])
        XCTAssertEqual(inspection.additionalInspection?.archiveListing?.entries.map(\.displayName), ["inventory.txt", "notes.txt"])

        let controller = makeSizedPreviewController()
        _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CSVTablePreviewView }.first)
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        let nativeTable = try XCTUnwrap(descendants(table).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(nativeTable.tableColumns.map(\.title), ["Name", "Kind", "Compressed bytes", "Uncompressed bytes"])
        XCTAssertEqual(nativeTable.numberOfRows, 2)
        let tableDataSource = try XCTUnwrap(nativeTable.dataSource)
        XCTAssertEqual(tableDataSource.tableView?(nativeTable, objectValueFor: nativeTable.tableColumns[1], row: 0) as? String,
                       "File")
    }

    @MainActor
    func testSQLiteUsesSharedTreeAndTARUsesSharedTablePreview() async throws {
        let controller = makeSizedPreviewController()
        let sqliteURL = try fixtureURL("Showcase/data/inventory.sqlite")
        let sqlite = try PreviewPreparation.read(at: sqliteURL)
        XCTAssertEqual(sqlite.formatDefinition?.id, .sqlite)
        XCTAssertEqual(PreviewChromeModel(inspection: sqlite).representations, [.tree, .raw])
        XCTAssertEqual(PreviewChromeModel(inspection: sqlite, configuredViews: [.tree, .raw, .hex]).representations,
                       [.tree, .raw, .hex])
        _ = try await controller.preview(for: sqliteURL,
            configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        XCTAssertGreaterThan(try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first).numberOfRows, 0)

        let tarURL = try fixtureURL("Showcase/data/inventory.tar")
        let tar = try PreviewPreparation.read(at: tarURL)
        XCTAssertEqual(tar.formatDefinition?.id, .tarArchive)
        XCTAssertEqual(PreviewChromeModel(inspection: tar).representations, [.table])
        XCTAssertEqual(PreviewChromeModel(inspection: tar, configuredViews: [.table, .hex]).representations,
                       [.table, .hex])
        _ = try await controller.preview(for: tarURL,
            configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        let tableContainer = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CSVTablePreviewView }.first)
        let table = try XCTUnwrap(descendants(tableContainer).compactMap { $0 as? NSTableView }.first)
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(table.tableColumns.map(\.title), ["Name", "Kind", "Size", "Link target"])
        XCTAssertEqual(table.numberOfRows, 1)

        let compressedURL = try fixtureURL("Showcase/data/inventory.tar.gz")
        let compressedBytes = try Data(contentsOf: compressedURL)
        XCTAssertNoThrow(try TARArchiveInspector.inspect(data: compressedBytes, fileSize: compressedBytes.count))
        let compressedDirect = try PreviewPreparation.read(at: compressedURL)
        XCTAssertNotNil(compressedDirect.additionalInspection?.tarArchiveListing,
                        "\(compressedDirect.inspectionDiagnostics)")
        let compressedShared = try await SharedPreviewPipeline.preview(
            for: compressedURL, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertNotNil(compressedShared.inspection.additionalInspection?.tarArchiveListing,
                        "\(compressedShared.inspection.inspectionDiagnostics)")
    }

    @MainActor
    func testX509PEMAndDERUseStructuredCertificateFacts() async throws {
        let controller = makeSizedPreviewController()
        let cases: [(String, FormatID, [FormatDefinition.RepresentationID], [PreviewRepresentation])] = [
            ("Showcase/security/certificate.pem", .pemCertificate, [.tree, .raw, .hex], [.tree, .raw, .hex]),
            ("Showcase/security/certificate.der", .derCertificate, [.tree, .hex], [.tree, .hex])
        ]
        for (path, id, expectedViews, expectedRepresentations) in cases {
            let url = try fixtureURL(path)
            let inspection = try PreviewPreparation.read(at: url)
            let chrome = PreviewChromeModel(inspection: inspection, configuredViews: expectedViews)
            XCTAssertEqual(inspection.formatDefinition?.id, id, path)
            XCTAssertEqual(chrome.representations, expectedRepresentations, path)
            XCTAssertEqual(inspection.additionalInspection?.certificateInspection?.certificates.count, 1, path)
            XCTAssertNotNil(inspection.additionalStructuredContent, path)

            _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)
            XCTAssertGreaterThan(try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first).numberOfRows, 0, path)
        }
    }

    @MainActor
    func testSecurityFormatsUseStructuredPreviewAndKeepOriginalBytes() async throws {
        let cases: [(String, FormatID, [PreviewRepresentation])] = [
            ("Showcase/security/synthetic.mobileprovision", .mobileprovision, [.tree]),
            ("Showcase/security/demo.jwt", .jwt, [.tree, .raw]),
            ("Showcase/security/public-key.jwk", .jwk, [.tree, .raw]),
            ("Showcase/security/public-keys.jwks", .jwks, [.tree, .raw]),
            ("Showcase/security/cyclonedx.cdx.json", .cyclonedxSBOM, [.tree, .raw]),
            ("Showcase/security/demo.spdx.json", .spdxSBOM, [.tree, .raw]),
            ("Showcase/security/cyclonedx.cdx.pb", .cyclonedxSBOMProtobuf, [.tree, .raw]),
            ("Showcase/security/cyclonedx.cdx.xml", .cyclonedxSBOMXML, [.tree, .raw]),
            ("Showcase/security/demo.spdx", .spdxTagValue, [.tree, .raw])
        ]
        let controller = makeSizedPreviewController()
        for (path, id, expectedViews) in cases {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let inspection = try PreviewPreparation.read(at: url)
            let chrome = PreviewChromeModel(inspection: inspection)

            XCTAssertEqual(inspection.formatDefinition?.id, id, path)
            XCTAssertEqual(chrome.representations, expectedViews, path)
            if id == .cyclonedxSBOMProtobuf {
                XCTAssertEqual(PreviewChromeModel(inspection: inspection, configuredViews: [.tree, .raw, .hex]).representations,
                               [.tree, .raw, .hex], path)
            }
            XCTAssertEqual(inspection.originalBytes, bytes, path)
            XCTAssertNotNil(inspection.additionalInspection?.securityInspection?.content, path)
            XCTAssertTrue(inspection.additionalInspection?.securityInspection?.summary.isEmpty == false, path)

            _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)
            let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertGreaterThan(outline.numberOfRows, 0, path)
        }
    }

    @MainActor
    func testAppleCatalogAndSchemeUseSharedStructuredPreview() async throws {
        let cases: [(String, FormatID)] = [
            ("Showcase/apple/Localizable.xcstrings", .xcstrings),
            ("Showcase/apple/Glimt.xcscheme", .xcscheme),
            ("Showcase/apple/CodeResources", .codeResources)
        ]
        let controller = makeSizedPreviewController()
        for (path, id) in cases {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let inspection = try PreviewPreparation.read(at: url)
            XCTAssertEqual(inspection.formatDefinition?.id, id, path)
            XCTAssertEqual(inspection.originalBytes, bytes, path)
            XCTAssertTrue(inspection.isStructured, path)
            if id == .xcstrings { XCTAssertNotNil(inspection.jsonInspection?.content, path) }
            if id == .xcscheme { XCTAssertNotNil(inspection.xmlInspection?.root, path) }
            _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)
            XCTAssertGreaterThan(try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first).numberOfRows, 0, path)
        }
    }

    @MainActor
    func testEmptyAndMalformedZIPCandidatesHaveExplicitSafePresentations() async throws {
        let empty = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
        let emptyInspection = PreviewPreparation.prepare(bytes: empty, fileSize: empty.count,
            fileName: "empty.zip", systemUTI: nil)
        XCTAssertEqual(emptyInspection.additionalInspection?.archiveListing?.entries.count, 0)
        XCTAssertEqual(PreviewChromeModel(inspection: emptyInspection, configuredViews: [.table]).representations, [.table])
        let controller = makeSizedPreviewController()
        controller.display(emptyInspection)
        controller.view.layoutSubtreeIfNeeded()
        let tableContainer = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CSVTablePreviewView }.first)
        let table = try XCTUnwrap(descendants(tableContainer).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 1)

        let malformed = Data([0x50, 0x4B, 0x03, 0x04])
        let malformedInspection = PreviewPreparation.prepare(bytes: malformed, fileSize: malformed.count,
            fileName: "broken.zip", systemUTI: nil)
        XCTAssertNil(malformedInspection.additionalInspection?.archiveListing)
        XCTAssertEqual(PreviewChromeModel(inspection: malformedInspection).representations, [.hex])
    }

    @MainActor
    func testDiffPatchUsesSharedInspectionAndPreview() async throws {
        let url = try fixtureURL("Showcase/diff/changes.patch")
        let preparation = try PreviewPreparation.read(at: url)
        let chrome = PreviewChromeModel(inspection: preparation)
        XCTAssertEqual(chrome.representations, [.diff, .raw])
        XCTAssertEqual(chrome.enabledRepresentations, [.diff, .raw])
        XCTAssertTrue(preparation.diffInspection?.files.isEmpty == false)

        let controller = makeSizedPreviewController()
        _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        XCTAssertTrue(try visibleText(controller).joined().contains("example.json"))
    }

    @MainActor
    func testJSONLinesAndLogsUseSharedStructuredAndRawViews() async throws {
        let controller = makeSizedPreviewController()
        // Logs lead with their Table view (AC-020-7); the Tree and Raw views stay shared with JSON Lines.
        let cases: [(path: String, expected: String, views: [PreviewRepresentation])] = [
            ("Showcase/jsonl/events.jsonl", "completed", [.tree, .raw]),
            ("Showcase/log/server.log", "service started", [.table, .tree, .raw])
        ]
        for (path, expected, views) in cases {
            let url = try fixtureURL(path)
            let inspection = try PreviewPreparation.read(at: url)
            let chrome = PreviewChromeModel(inspection: inspection)
            XCTAssertEqual(chrome.representations, views, path)
            XCTAssertEqual(chrome.enabledRepresentations, Set(views), path)
            XCTAssertNotNil(inspection.additionalStructuredContent, path)
            _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)

            let tabs = try mode(controller)
            if let treeIndex = views.firstIndex(of: .tree), treeIndex != tabs.selectedSegment {
                tabs.selectedSegment = treeIndex
                _ = tabs.sendAction(tabs.action, to: tabs.target)
            }
            controller.view.layoutSubtreeIfNeeded()
            let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertFalse(outline.isHiddenOrHasHiddenAncestor, path)
            outline.expandItem(nil, expandChildren: true)
            controller.view.layoutSubtreeIfNeeded()
            let treeText = (0..<outline.numberOfRows).flatMap { row in
                (0..<outline.numberOfColumns).compactMap { column in
                    (outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
                }
            }.joined(separator: "\n")
            XCTAssertTrue(treeText.contains(expected), path)

            tabs.selectedSegment = try XCTUnwrap(views.firstIndex(of: .raw), path)
            _ = tabs.sendAction(tabs.action, to: tabs.target)
            XCTAssertTrue(try visibleText(controller).joined().contains(expected), path)
            XCTAssertTrue(try visibleText(controller).contains(inspection.analysis.text), path)
        }
    }

    @MainActor
    func testJSONLinesUsesStructuredTreeAndJSONSyntaxInRaw() async throws {
        let url = try fixtureURL("Showcase/jsonl/events.jsonl")
        let preparation = try PreviewPreparation.read(at: url)
        XCTAssertTrue(preparation.isStructured)
        XCTAssertEqual(preparation.formatDefinition?.id, .jsonl)
        XCTAssertEqual(preparation.originalBytes, try Data(contentsOf: url))

        let controller = makeSizedPreviewController()
        _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        controller.view.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertFalse(outline.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(outline.numberOfRows, 0)

        let modes = try mode(controller)
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        let rawView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(rawView.string, preparation.analysis.text)
        let keyRange = (rawView.string as NSString).range(of: "\"event\"")
        let keyColor = try XCTUnwrap(rawView.textStorage?.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor)
        XCTAssertNotEqual(keyColor, NSColor.textColor)

        let malformedURL = try fixtureURL("Cases/jsonl/invalid/malformed.jsonl")
        let malformed = try PreviewPreparation.read(at: malformedURL)
        XCTAssertTrue(malformed.inspectionDiagnostics.contains { $0.code == .parseError })
        _ = try await controller.preview(for: malformedURL, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        controller.view.layoutSubtreeIfNeeded()
        let malformedModes = try mode(controller)
        XCTAssertEqual(malformedModes.selectedSegment, 0)
        let malformedOutline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertFalse(malformedOutline.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(malformedOutline.numberOfRows, 0)
        malformedModes.selectedSegment = 1
        _ = malformedModes.sendAction(malformedModes.action, to: malformedModes.target)
        let malformedRaw = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(malformedRaw.string, malformed.analysis.text)
        XCTAssertEqual(malformed.originalBytes, try Data(contentsOf: malformedURL))
    }

    @MainActor
    func testStandaloneXYChartFileRendersInSharedPreview() async throws {
        try await assertMermaidPreview("Cases/mermaid/xy-chart.mmd", expectedDiagramCount: 1,
                                       expectedViews: [.rendered, .raw])
    }

    @MainActor
    func testWrappedMarkdownPreviewRendersSixteenMermaidDiagramsOrTheirSource() async throws {
        // Diagram 10 is `usecase-beta`, a family MermaidKit does not render; it stays visible as source.
        try await assertMermaidPreview("Cases/mermaid/wrapped-02.md", expectedDiagramCount: 16,
                                       expectedFallbackDiagrams: [10], expectedViews: [.rendered, .source])
    }

    @MainActor
    private func assertMermaidPreview(_ path: String, expectedDiagramCount: Int, expectedFallbackDiagrams: [Int] = [],
                                     expectedViews: [PreviewRepresentation]) async throws {
        let url = try fixtureURL(path)
        let rendered = expectation(description: "Mermaid preview renders \(path)")
        var renderedBlockCount = 0
        var renderedImageCount = 0
        var renderedWidth = 0.0
        var renderedSources: [String] = []
        var renderingFailures: [String] = []
        let renderConfiguration = RenderConfiguration()
        let controller = makeSizedPreviewController(configuration: renderConfiguration,
                                                    renderMermaidBlocks: { blocks, width in
            renderedBlockCount = blocks.count
            renderedWidth = width
            renderedSources = blocks.map(\.source)
            let invalidBlocks = blocks.enumerated().filter {
                $0.element.source.isEmpty || $0.element.source.utf8.count > MermaidKitRenderer.maximumSourceBytes
            }.map { "\($0.offset): \($0.element.source.utf8.count) bytes" }
            XCTAssertTrue(invalidBlocks.isEmpty, "\(path): \(invalidBlocks.joined(separator: ", "))")
            let images = try await MermaidKitRenderer().render(blocks, maximumWidth: width) { index, error in
                renderingFailures.append("diagram \(index): \(error)")
            }
            renderedImageCount = images.count
            return images
        }, requestedMermaidWidth: { 624 }, mermaidResultObserver: { _, _ in
            rendered.fulfill()
        })
        let inspection = try await controller.preview(for: url, configuration: renderConfiguration)
        XCTAssertEqual(PreviewChromeModel(inspection: inspection).representations, expectedViews, path)
        if path.hasSuffix(".md") {
            let documentBlocks = try XCTUnwrap(inspection.markdownDocument?.mermaidBlocks)
            XCTAssertEqual(documentBlocks.count, expectedDiagramCount, path)
            let direct = try PreviewPreparation.read(at: url,
                                                     markdownOptions: renderConfiguration.markdown.options)
            XCTAssertEqual(documentBlocks.map(\.source), direct.markdownDocument?.mermaidBlocks.map(\.source),
                           "Preview and direct Markdown inspections must retain the same Mermaid sources")
            XCTAssertTrue(documentBlocks.allSatisfy { !$0.source.isEmpty },
                          "Every Mermaid block must retain its source for the shared runtime renderer.")
        }
        await fulfillment(of: [rendered], timeout: 90)
        controller.view.layoutSubtreeIfNeeded()
        let textViews = descendants(controller.view).compactMap { $0 as? NSTextView }
        var attachmentCount = 0
        for textView in textViews {
            let storage = try XCTUnwrap(textView.textStorage)
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if value is NSTextAttachment { attachmentCount += 1 }
            }
        }
        let expectedImageCount = expectedDiagramCount - expectedFallbackDiagrams.count
        XCTAssertEqual(attachmentCount, expectedImageCount, path)
        XCTAssertEqual(renderedBlockCount, expectedDiagramCount, path)
        XCTAssertEqual(renderedImageCount, expectedImageCount,
                       "\(path) at \(renderedWidth) pt; source lengths: \(renderedSources.map(\.utf8.count)); failures: \(renderingFailures.joined(separator: "; "))")
        XCTAssertEqual(renderingFailures, expectedFallbackDiagrams.map { "diagram \($0): unsupportedSource" }, path)
        let visibleText = textViews.map(\.string).joined(separator: "\n")
        for index in expectedFallbackDiagrams where renderedSources.indices.contains(index) {
            XCTAssertTrue(visibleText.contains(renderedSources[index]), "\(path): diagram \(index) keeps its source visible")
        }
    }

    @MainActor
    func testConfigurationFormatsUseHighlightedSourceAndRawViews() async throws {
        let controller = makeSizedPreviewController()
        for (path, expected) in [("Showcase/config/toml.toml", "Glimt"), ("Showcase/config/settings.ini", "limit"),
                                 ("Showcase/config/application.properties", "Glimt"),
                                 ("Showcase/config/.editorconfig", "indent_size"),
                                 ("Showcase/config/.gitignore", ".env.example"),
                                 ("Showcase/config/.dockerignore", "Dockerfile.release"),
                                 ("Showcase/config/.npmrc", "engine-strict"),
                                 ("Showcase/config/.gitattributes", "*.pdf"),
                                 ("Showcase/config/.gitmodules", "vendor/shared-components"),
                                 ("Showcase/config/systemd/worker.service", "ExecStart"),
                                 ("Showcase/config/systemd/worker.socket", "ListenStream"),
                                 ("Showcase/config/systemd/worker.timer", "OnCalendar"),
                                 ("Showcase/config/go/go.mod", "example.com/observatory"),
                                 ("Showcase/config/go/go.sum", "astronomy"),
                                 ("Showcase/config/go/go.work", "toolchain"),
                                 ("Showcase/config/go/go.work.sum", "test/dependency")] {
            let url = try fixtureURL(path)
            let inspection = try PreviewPreparation.read(at: url)
            XCTAssertEqual(inspection.sourceDocument?.language, inspection.formatDefinition?.sourceLanguage, path)
            XCTAssertEqual(PreviewChromeModel(inspection: inspection).enabledRepresentations, [.source, .raw], path)
            _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)
            XCTAssertTrue(try visibleText(controller).joined().contains(expected), path)
        }
    }

    @MainActor
    func testDotenvUsesStructuredTreeAndRawViews() async throws {
        let url = try fixtureURL("Showcase/config/service.env")
        let inspection = try PreviewPreparation.read(at: url)
        XCTAssertNil(inspection.sourceDocument)
        XCTAssertEqual(PreviewChromeModel(inspection: inspection).enabledRepresentations, [.tree, .raw])

        let controller = makeSizedPreviewController()
        _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
    }

    @MainActor
    func testAppleStructuredFormatsAndCSRUseTheirCatalogPreviewViews() async throws {
        let cases: [(String, FormatID, [FormatDefinition.RepresentationID])] = [
            ("Showcase/apple/Localizable.strings", .strings, [.tree, .pretty, .raw]),
            ("Showcase/apple/Localizable.stringsdict", .stringsdict, [.tree, .pretty, .raw]),
            ("Showcase/apple/Localizable.xcstrings", .xcstrings, [.tree, .pretty, .raw]),
            ("Showcase/apple/Glimt.xcscheme", .xcscheme, [.tree, .pretty, .raw]),
            ("Showcase/security/request.csr", .csr, [.tree, .raw])
        ]
        let controller = makeSizedPreviewController()
        for (path, expectedID, views) in cases {
            let url = try fixtureURL(path)
            let inspection = try PreviewPreparation.read(at: url)
            XCTAssertEqual(inspection.formatDefinition?.id, expectedID, path)
            XCTAssertEqual(Set(PreviewChromeModel(inspection: inspection).representations.map(\.rawValue)),
                           Set(views.map { $0.rawValue.capitalized }), path)
            _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)
        }
    }

    @MainActor
    func testNextSpecialistFormatsUseStaticSourceAndBoundedXMLViews() async throws {
        let cases: [(String, String, [String])] = [
            ("Showcase/apple/Main.storyboard", "storyboard", ["Tree", "Pretty", "Raw"]),
            ("Showcase/apple/View.xib", "xib", ["Tree", "Pretty", "Raw"]),
            ("Showcase/xml/schema.xsd", "xsd", ["Tree", "Pretty", "Raw"]),
            ("Showcase/xml/transform.xslt", "xslt", ["Tree", "Pretty", "Raw"]),
            ("Showcase/fileformats/guide.rst", "rst", ["Source", "Raw"]),
            ("Showcase/fileformats/report.qmd", "quarto", ["Source", "Raw"]),
            ("Showcase/fileformats/page.mdx", "mdx", ["Source", "Raw"]),
            ("Showcase/security/pem-public-key.pub", "pem-public-key", ["Tree", "Raw"])
        ]
        let controller = makeSizedPreviewController()
        for (path, expectedID, expectedViews) in cases {
            let url = try fixtureURL(path)
            let inspection = try PreviewPreparation.read(at: url)
            XCTAssertEqual(inspection.formatDefinition?.id.rawValue, expectedID, path)
            XCTAssertEqual(Set(PreviewChromeModel(inspection: inspection).enabledRepresentations.map(\.rawValue.capitalized)),
                           Set(expectedViews), path)
            _ = try await controller.preview(for: url,
                configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)
        }
    }

    @MainActor
    func testUnsupportedConfigurationSyntaxKeepsRawPreview() async throws {
        let url = try fixtureURL("Showcase/config/service.conf")
        let inspection = try PreviewPreparation.read(at: url)
        XCTAssertNil(inspection.sourceDocument)
        XCTAssertEqual(PreviewChromeModel(inspection: inspection).enabledRepresentations, [.raw])

        let controller = makeSizedPreviewController()
        _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertTrue(try visibleText(controller).joined().contains("listen_address = \"127.0.0.1\""))
    }

    @MainActor
    func testUnknownBinaryUsesOnlyBoundedHexView() async throws {
        let url = try fixtureURL("Cases/binary/extensionless")
        let inspection = try PreviewPreparation.read(at: url)
        XCTAssertTrue(inspection.analysis.isBinary)
        XCTAssertNil(inspection.formatDefinition)
        let chrome = PreviewChromeModel(inspection: inspection)
        XCTAssertEqual(chrome.representations, [.hex])
        XCTAssertEqual(chrome.enabledRepresentations, [.hex])
        XCTAssertEqual(InquiryReport.make(url: url, inspection: inspection).availableRepresentations, ["Hex"])
        let clippedHex = HexPreview.format(Data(repeating: 0x41, count: HexPreview.maximumBytes + 1))
        XCTAssertEqual(clippedHex.components(separatedBy: "\n").count, HexPreview.maximumBytes / 16)
        XCTAssertTrue(clippedHex.contains("0000fff0"))

        let controller = makeSizedPreviewController()
        _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults))
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        XCTAssertEqual(try visibleText(controller), [HexPreview.format(inspection.originalBytes)])
    }

    @MainActor
    func testChromeCapabilitiesAndStatusFollowActualInspection() throws {
        for path in ["Showcase/yaml/yaml.yaml", "Cases/json/valid/simple.json", "Cases/xml/valid/simple.xml", "Cases/plist/xml/simple.plist"] {
            let inspection = try PreviewPreparation.read(at: fixtureURL(path))
            let model = PreviewChromeModel(inspection: inspection)
            let expected: [PreviewRepresentation] = [.tree, .pretty, .raw]
            XCTAssertEqual(model.representations, expected)
            XCTAssertEqual(model.enabledRepresentations, Set(expected))
            XCTAssertTrue(model.status.items.contains { $0.kind == .valid })
        }
        let malformed = PreviewChromeModel(inspection: try PreviewPreparation.read(at: fixtureURL("Cases/yaml/invalid/malformed.yaml")))
        XCTAssertEqual(malformed.enabledRepresentations, [.raw])
        XCTAssertTrue(malformed.status.items.contains { $0.kind == .warning })
        let malformedJSON = PreviewChromeModel(inspection: try PreviewPreparation.read(at: fixtureURL("Cases/json/invalid/malformed.json")))
        XCTAssertEqual(malformedJSON.representations, [.raw], "Unavailable views are hidden, not disabled")
        XCTAssertFalse(malformedJSON.isRecovery, "Raw is configured, so it is not a fallback")
        let treeOnly = PreviewChromeModel(inspection: try PreviewPreparation.read(at: fixtureURL("Cases/json/invalid/malformed.json")),
                                          configuredViews: [.tree])
        XCTAssertEqual(treeOnly.representations, [.raw], "With nothing configured available, Raw keeps the document inspectable")
        XCTAssertTrue(treeOnly.isRecovery)
        XCTAssertTrue(treeOnly.statusItems(for: .raw).contains { $0.text == "Fallback view" })
        let source = PreviewChromeModel(inspection: try PreviewPreparation.read(at: fixtureURL("Cases/source/Example.swift")))
        XCTAssertEqual(source.representations, [.source, .raw])
        XCTAssertTrue(source.status.items.contains { $0.text == "Swift" })
        XCTAssertFalse(source.status.items.contains { $0.kind == .valid })
        for (path, language) in [
            ("Showcase/source/swift.swift", "Swift"), ("Showcase/source/java.java", "Java"),
            ("Showcase/source/c.c", "C"), ("Showcase/source/cpp.cpp", "C++"),
            ("Showcase/source/python.py", "Python"), ("Showcase/source/javascript.js", "JavaScript"),
            ("Showcase/source/typescript.ts", "TypeScript"), ("Showcase/source/shell.sh", "Shell")
        ] {
            let url = try fixtureURL(path)
            let format = try PreviewPreparation.read(at: url)
            let model = PreviewChromeModel(inspection: format)
            XCTAssertEqual(model.representations, [.source, .raw], language)
            XCTAssertEqual(model.enabledRepresentations, [.source, .raw], language)
        }
        let markdown = PreviewChromeModel(inspection: try PreviewPreparation.read(at: fixtureURL("Cases/markdown/basic.md")))
        XCTAssertEqual(markdown.representations, [.rendered, .source])
        let binary = PreviewChromeModel(inspection: try PreviewPreparation.read(at: fixtureURL("Showcase/plist/binary.plist")))
        XCTAssertFalse(binary.status.items.contains { $0.text.contains("UTF") || $0.text.contains("lines") || $0.text == "LF" })
    }

    @MainActor
    func testPKCS7SharedPresentationRecoveryAndThumbnailBounds() async throws {
        let definition = try XCTUnwrap(FormatCatalog.definition(for: .pkcs7))
        let example = try XCTUnwrap(PreviewSamples.examples(for: definition.settingsSection)
            .first { $0.path == definition.showcaseFixture })
        let productBundle = productShowcaseBundle()
        let bundledURL = try XCTUnwrap(PreviewSamples.url(for: example, bundle: productBundle))
        let fixture = try Data(contentsOf: bundledURL)
        XCTAssertEqual(fixture, try Data(contentsOf: fixtureURL("Cases/security/bundle.p7b")))

        var factory = GlimtSettingsV3.factoryDefaults
        factory.general.colorScheme = .light
        let controller = makeSizedPreviewController(configuration: RenderConfiguration(settings: factory))
        let inspection = try await controller.preview(for: bundledURL, configuration: RenderConfiguration(settings: factory))
        XCTAssertEqual(inspection.formatDefinition?.id, .pkcs7)
        XCTAssertEqual(PreviewChromeModel(inspection: inspection).representations, [.tree])
        XCTAssertEqual(try selectedLabel(controller), "Tree")
        XCTAssertFalse(descendants(controller.view).compactMap { $0 as? NSButton }.contains { $0.title == "Raw" })
        let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertEqual(outline.accessibilityLabel(), "PKCS#7 structure")
        outline.expandItem(nil, expandChildren: true)
        controller.view.layoutSubtreeIfNeeded()
        let treeText = (0..<outline.numberOfRows).flatMap { row in
            (0..<outline.numberOfColumns).compactMap { column in
                (outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
            }
        }.joined(separator: "\n")
        XCTAssertTrue(treeText.contains("Bundle"))
        XCTAssertTrue(treeText.contains("Certificate count"))
        XCTAssertTrue(treeText.contains("Verification"))
        XCTAssertTrue(treeText.contains("Trust and signatures were not checked."))

        var withHex = factory
        withHex.formatOverrides[FormatID.pkcs7.rawValue] = ["tree", "hex"]
        let hexConfiguration = RenderConfiguration(settings: withHex, appearance: .light)
        _ = try await controller.preview(for: bundledURL, configuration: hexConfiguration)
        XCTAssertEqual(PreviewChromeModel(inspection: inspection,
            configuredViews: [.tree, .hex]).representations, [.tree, .hex])
        let hexButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Hex" })
        hexButton.performClick(nil)
        XCTAssertEqual(try selectedLabel(controller), "Hex")
        XCTAssertEqual(try XCTUnwrap(visibleText(controller).first), HexPreview.format(fixture))

        let pem = Data("-----BEGIN PKCS7-----\r\n\(fixture.base64EncodedString())\r\n-----END PKCS7-----\r\n".utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtPKCS7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); controller.cancelVCSInspection() }
        let pemURL = directory.appendingPathComponent("bundle.p7c")
        try pem.write(to: pemURL, options: .atomic)
        let pemInspection = try await controller.preview(for: pemURL, configuration: RenderConfiguration(settings: factory))
        XCTAssertEqual(PreviewChromeModel(inspection: pemInspection).representations, [.tree, .raw])
        XCTAssertEqual(pemInspection.additionalInspection?.securityInspection?.summary, "1 certificate")
        let rawButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        rawButton.performClick(nil)
        XCTAssertEqual(try visibleText(controller), [String(decoding: pem, as: UTF8.self)])

        let damagedPEM = Data("\u{FEFF}-----BEGIN PKCS7-----\r\nAAAA\r\n-----END PKCS7----\r\n".utf8)
        for (bytes, name) in [(Data(), "empty.p7b"), (damagedPEM, "damaged.p7b"),
                              (Data([0x30, 0x41]), "short.p7b")] {
            let failed = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: name, systemUTI: nil)
            XCTAssertEqual(failed.formatDefinition?.id, .pkcs7)
            XCTAssertNil(failed.additionalInspection?.securityInspection?.content)
            XCTAssertFalse(failed.analysis.isBinary, name)
            XCTAssertEqual(PreviewChromeModel(inspection: failed).representations, [.raw], name)
            controller.display(failed)
            XCTAssertEqual(try selectedLabel(controller), "Raw")
            XCTAssertEqual(try visibleText(controller), [failed.analysis.text], name)
            XCTAssertFalse(failed.analysis.text.hasPrefix("\u{FEFF}"), name)
            let hexOnly = PreviewChromeModel(inspection: failed, configuredViews: [.hex])
            XCTAssertEqual(hexOnly.representations, [.hex], name)
            XCTAssertFalse(hexOnly.isRecovery, name)
        }

        let padded = fixture + Data(repeating: 0, count: ThumbnailPreparation.maximumPrefixBytes + 1 - fixture.count)
        for suffix in ["p7b", "p7c"] {
            let url = directory.appendingPathComponent("padded.\(suffix)")
            try padded.write(to: url, options: .atomic)
            let bounded = try ThumbnailPreparation.read(at: url) { _ in nil }
            XCTAssertEqual(bounded.readByteCount, ThumbnailPreparation.maximumPrefixBytes)
            XCTAssertEqual(bounded.analysis.fileSize, padded.count)
            XCTAssertNil(bounded.thumbnailText)
            XCTAssertEqual(bounded.formatID, .pkcs7)
            let direct = ThumbnailPreparation.prepare(bytes: Data(padded.prefix(ThumbnailPreparation.maximumPrefixBytes)),
                fileSize: padded.count, fileName: url.lastPathComponent, systemUTI: nil)
            XCTAssertEqual(direct.readByteCount, ThumbnailPreparation.maximumPrefixBytes)
            XCTAssertEqual(direct.analysis.fileSize, padded.count)
            XCTAssertNil(direct.thumbnailText)
            XCTAssertEqual(direct.formatID, .pkcs7)
        }
        let thumbnail = ThumbnailPreparation.prepare(bytes: fixture, fileSize: fixture.count,
            fileName: "bundle.p7b", systemUTI: nil)
        XCTAssertEqual(thumbnail.thumbnailText, "1 certificate")
        XCTAssertNotNil(ThumbnailRenderer.render(analysis: thumbnail.analysis, semanticText: thumbnail.thumbnailText,
            appearance: .light, maximumSize: CGSize(width: 480, height: 160), scale: 1))
    }

    /// Builds a valid MacData-free PFX of exactly `size` bytes by padding one opaque `data` envelope.
    private func paddedPKCS12(size: Int) throws -> Data {
        func tlv(_ tag: UInt8, _ content: Data) -> Data {
            var length = Data()
            if content.count < 0x80 {
                length.append(UInt8(content.count))
            } else {
                var value = content.count
                var octets: [UInt8] = []
                while value > 0 { octets.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
                length.append(0x80 | UInt8(octets.count))
                length.append(contentsOf: octets)
            }
            return Data([tag]) + length + content
        }
        let dataOID = tlv(0x06, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]))
        func dataContentInfo(_ octets: Data) -> Data { tlv(0x30, dataOID + tlv(0xA0, tlv(0x04, octets))) }
        func pfx(payload: Int) -> Data {
            let authSafe = tlv(0x30, dataContentInfo(Data(repeating: 0, count: payload)))
            return tlv(0x30, tlv(0x02, Data([0x03])) + dataContentInfo(authSafe))
        }
        var payload = max(0, size - 64)
        while pfx(payload: payload).count > size, payload > 0 { payload -= 1 }
        while pfx(payload: payload).count < size { payload += 1 }
        let bytes = pfx(payload: payload)
        XCTAssertEqual(bytes.count, size, "no padded PFX encodes to exactly \(size) bytes")
        return bytes
    }

    /// Checks the four ordered PFX facts published for a certificate-only export.
    private func assertCertificateOnlyPKCS12Facts(_ content: StructuredValue?, file: StaticString = #filePath,
                                                  line: UInt = #line) throws {
        guard case .object(let members)? = content else { return XCTFail("PKCS#12 facts missing", file: file, line: line) }
        XCTAssertEqual(members.map(\.key), ["Version", "Envelope count", "Envelope kinds", "MacData present"],
                       file: file, line: line)
        XCTAssertEqual(members.map(\.value), [.number("3"), .number("1"), .array([.string("encryptedData")]), .boolean(true)],
                       file: file, line: line)
    }

    @MainActor
    func testPKCS12SharedPresentationRecoveryAndThumbnailBounds() async throws {
        let definition = try XCTUnwrap(FormatCatalog.definition(for: .pkcs12))
        XCTAssertEqual(definition.showcaseFixture, "Showcase/security/certificate-only.p12")
        let example = try XCTUnwrap(PreviewSamples.examples(for: definition.settingsSection)
            .first { $0.path == definition.showcaseFixture })
        let bundledURL = try XCTUnwrap(PreviewSamples.url(for: example, bundle: productShowcaseBundle()))
        let fixture = try Data(contentsOf: bundledURL)
        XCTAssertEqual(fixture, try Data(contentsOf: fixtureURL("Cases/security/certificate-only.p12")))

        var factory = GlimtSettingsV3.factoryDefaults
        factory.general.colorScheme = .light
        let controller = makeSizedPreviewController(configuration: RenderConfiguration(settings: factory))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtPKCS12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); controller.cancelVCSInspection() }

        let inspection = try await controller.preview(for: bundledURL, configuration: RenderConfiguration(settings: factory))
        XCTAssertEqual(inspection.formatDefinition?.id, .pkcs12)
        let security = try XCTUnwrap(inspection.additionalInspection?.securityInspection)
        XCTAssertEqual(security.summary, "1 envelope")
        try assertCertificateOnlyPKCS12Facts(security.content)
        XCTAssertEqual(PreviewChromeModel(inspection: inspection).representations, [.tree])
        XCTAssertEqual(try selectedLabel(controller), "Tree")
        let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
        XCTAssertEqual(outline.accessibilityLabel(), "PKCS#12 structure")
        outline.expandItem(nil, expandChildren: true)
        controller.view.layoutSubtreeIfNeeded()
        let treeText = (0..<outline.numberOfRows).flatMap { row in
            (0..<outline.numberOfColumns).compactMap { column in
                (outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue
            }
        }.joined(separator: "\n")
        for text in ["PFX", "Version", "Envelope count", "Envelope kinds", "encryptedData", "MacData present"] {
            XCTAssertTrue(treeText.contains(text), text)
        }

        var withHex = factory
        withHex.formatOverrides[FormatID.pkcs12.rawValue] = ["tree", "hex"]
        _ = try await controller.preview(for: bundledURL, configuration: RenderConfiguration(settings: withHex, appearance: .light))
        let hexButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Hex" })
        hexButton.performClick(nil)
        XCTAssertEqual(try selectedLabel(controller), "Hex")
        XCTAssertEqual(try XCTUnwrap(visibleText(controller).first), HexPreview.format(fixture))

        let malformed: [(Data, String, Bool)] = [(Data([0x30, 0x03, 0x02, 0x01]), "short.p12", true),
                                                 (Data("not a pfx\n".utf8), "text.pfx", false)]
        for (bytes, name, isBinary) in malformed {
            let failed = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: name, systemUTI: nil)
            XCTAssertEqual(failed.formatDefinition?.id, .pkcs12, name)
            XCTAssertNil(failed.additionalInspection?.securityInspection?.content, name)
            XCTAssertEqual(failed.inspectionDiagnostics.first?.code, .parseError, name)
            XCTAssertEqual(failed.analysis.isBinary, isBinary, name)
            let treeOnly = PreviewChromeModel(inspection: failed)
            XCTAssertEqual(treeOnly.representations, [.hex], name)
            XCTAssertTrue(treeOnly.isRecovery, name)
            XCTAssertTrue(treeOnly.statusItems(for: .hex).contains { $0.text == "Fallback view" }, name)
            let configuredHex = PreviewChromeModel(inspection: failed, configuredViews: [.tree, .hex])
            XCTAssertEqual(configuredHex.representations, [.hex], name)
            XCTAssertFalse(configuredHex.isRecovery, name)
            XCTAssertFalse(configuredHex.statusItems(for: .hex).contains { $0.text == "Fallback view" }, name)
            controller.display(failed)
            XCTAssertEqual(try selectedLabel(controller), "Hex", name)
            XCTAssertEqual(try XCTUnwrap(visibleText(controller).first), HexPreview.format(bytes), name)
        }

        let limits: [(limit: Int, size: Int, code: InspectionDiagnostic.Code?)] = [
            (1_048_576, 1_048_576, nil), (1_048_576, 1_048_577, .limitExceeded),
            (65_536, 65_536, nil), (65_536, 65_537, .truncated)
        ]
        for (limit, size, code) in limits {
            let bytes = try paddedPKCS12(size: size)
            let url = directory.appendingPathComponent("bounded-\(limit)-\(size).p12")
            try bytes.write(to: url, options: .atomic)
            var settings = factory
            settings.general.dataLimitBytes = limit
            let result = try await controller.preview(for: url, configuration: RenderConfiguration(settings: settings))
            XCTAssertEqual(result.originalBytes.count, min(size, limit), "\(limit)/\(size)")
            XCTAssertEqual(result.inspectionDiagnostics.first?.code, code, "\(limit)/\(size)")
            if code == nil {
                XCTAssertEqual(result.additionalInspection?.securityInspection?.summary, "1 envelope", "\(limit)/\(size)")
                XCTAssertEqual(try selectedLabel(controller), "Tree", "\(limit)/\(size)")
            } else {
                XCTAssertNil(result.additionalInspection?.securityInspection?.content, "\(limit)/\(size)")
                XCTAssertEqual(try selectedLabel(controller), "Hex", "\(limit)/\(size)")
                let hex = try XCTUnwrap(visibleText(controller).first)
                XCTAssertEqual(hex, HexPreview.format(Data(bytes.prefix(HexPreview.maximumBytes))), "\(limit)/\(size)")
            }
        }

        let maximum = ThumbnailPreparation.maximumPrefixBytes
        XCTAssertEqual(maximum, 262_144)
        for (size, summary) in [(maximum, "1 envelope" as String?), (maximum + 1, nil)] {
            let bytes = try paddedPKCS12(size: size)
            for suffix in ["p12", "PFX"] {
                let url = directory.appendingPathComponent("thumbnail-\(size).\(suffix)")
                try bytes.write(to: url, options: .atomic)
                let read = try ThumbnailPreparation.read(at: url) { _ in nil }
                XCTAssertEqual(read.readByteCount, maximum, "\(size).\(suffix)")
                XCTAssertEqual(read.analysis.fileSize, size, "\(size).\(suffix)")
                XCTAssertEqual(read.formatID, .pkcs12, "\(size).\(suffix)")
                XCTAssertEqual(read.thumbnailText, summary, "\(size).\(suffix)")
                let direct = ThumbnailPreparation.prepare(bytes: Data(bytes.prefix(maximum)), fileSize: size,
                    fileName: url.lastPathComponent, systemUTI: nil)
                XCTAssertEqual(direct.readByteCount, maximum, "\(size).\(suffix)")
                XCTAssertEqual(direct.thumbnailText, summary, "\(size).\(suffix)")
            }
        }
        let broken = ThumbnailPreparation.prepare(bytes: Data([0x30, 0x03, 0x02, 0x01]), fileSize: 4,
            fileName: "short.p12", systemUTI: nil)
        XCTAssertEqual(broken.formatID, .pkcs12)
        XCTAssertNil(broken.thumbnailText)
        let thumbnail = ThumbnailPreparation.prepare(bytes: fixture, fileSize: fixture.count,
            fileName: "certificate-only.p12", systemUTI: nil)
        XCTAssertEqual(thumbnail.thumbnailText, "1 envelope")
        XCTAssertNotNil(ThumbnailRenderer.render(analysis: thumbnail.analysis, semanticText: thumbnail.thumbnailText,
            appearance: .light, maximumSize: CGSize(width: 480, height: 160), scale: 1))
    }

    @MainActor
    func testPKCS12RealHostPreviewCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let input = environment["GLIMT_PKCS12_REAL_INPUT"] ?? environment["TEST_RUNNER_GLIMT_PKCS12_REAL_INPUT"]
        let output = environment["GLIMT_PKCS12_CAPTURE_DIR"] ?? environment["TEST_RUNNER_GLIMT_PKCS12_CAPTURE_DIR"]
        if input == nil, output == nil {
            throw XCTSkip("Set GLIMT_PKCS12_REAL_INPUT and GLIMT_PKCS12_CAPTURE_DIR to capture PKCS#12 host previews")
        }
        let relativeInput = try XCTUnwrap(input, "GLIMT_PKCS12_REAL_INPUT is required with a capture directory")
        let capturePath = try XCTUnwrap(output, "GLIMT_PKCS12_CAPTURE_DIR is required with a real input")
        XCTAssertTrue(capturePath.hasPrefix("/"), "Capture directory must be absolute")
        let captures = URL(fileURLWithPath: capturePath, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let realURL = repositoryRoot.appendingPathComponent(relativeInput)
        let realBytes = try Data(contentsOf: realURL)
        XCTAssertEqual(realBytes.count, 1_115)
        XCTAssertEqual(SHA256.hash(data: realBytes).map { String(format: "%02x", $0) }.joined(),
                       "66804c9cccf04dbaf60f3932f57e7972da425b32c454d184e9e7405217d92de4")
        let oracle = PreviewPreparation.prepare(bytes: realBytes, fileSize: realBytes.count,
            fileName: realURL.lastPathComponent, systemUTI: nil)
        XCTAssertEqual(oracle.formatDefinition?.id, .pkcs12)
        try assertCertificateOnlyPKCS12Facts(oracle.additionalInspection?.securityInspection?.content)
        XCTAssertEqual(ThumbnailPreparation.prepare(bytes: realBytes, fileSize: realBytes.count,
            fileName: realURL.lastPathComponent, systemUTI: nil).thumbnailText, "1 envelope")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtPKCS12Real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let truncatedURL = temporary.appendingPathComponent("truncated.pfx")
        let truncatedBytes = Data(realBytes.dropLast())
        try truncatedBytes.write(to: truncatedURL, options: .atomic)

        var initial = GlimtSettingsV3.factoryDefaults
        initial.general.colorScheme = .light
        let session = SettingsSession(store: nil, snapshot: nil)
        session.update { $0 = initial }
        let root = SettingsRootViewController(session: session, sampleBundle: productShowcaseBundle())
        root.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        defer {
            window.contentViewController = nil
            window.close()
            root.general.preview.cancelLoading()
            try? FileManager.default.removeItem(at: temporary)
        }

        func capture(_ name: String) throws {
            for (suffix, width) in [("wide", 1100.0), ("narrow", 480.0)] {
                window.setContentSize(NSSize(width: width, height: 700))
                let view = root.general.preview.view
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let fileName = "\(name)-\(suffix).png"
                XCTAssertFalse(png.isEmpty, fileName)
                try png.write(to: captures.appendingPathComponent(fileName), options: .atomic)
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = fileName
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }

        root.preview(realURL)
        await root.general.preview.waitForPreview()
        let preview = root.general.preview.previewController
        let real = try XCTUnwrap(root.general.preview.currentPreparation)
        XCTAssertEqual(real.additionalInspection?.securityInspection?.summary, "1 envelope")
        XCTAssertEqual(try selectedLabel(preview), "Tree")
        try capture("tree")

        root.preview(truncatedURL)
        await root.general.preview.waitForPreview()
        let short = try XCTUnwrap(root.general.preview.currentPreparation)
        XCTAssertEqual(short.inspectionDiagnostics.first?.code, .parseError)
        XCTAssertNil(short.additionalInspection?.securityInspection?.content)
        XCTAssertEqual(try selectedLabel(preview), "Hex")
        XCTAssertEqual(try XCTUnwrap(visibleText(preview).first), HexPreview.format(truncatedBytes))
        try capture("hex")
        for name in ["tree-wide.png", "tree-narrow.png", "hex-wide.png", "hex-narrow.png"] {
            XCTAssertGreaterThan(try Data(contentsOf: captures.appendingPathComponent(name)).count, 0, name)
        }
    }

    @MainActor
    func testVCSInspectionUpdatesSharedPreviewAfterContentIsAlreadyVisible() async throws {
        let gate = VCSInspectionGate()
        let diff = try VCSLineDiff.compare(baseline: Data("before\n".utf8), working: Data("after\n".utf8))
        let result = VCSInspectionResult(repositoryType: .svn, fileStatus: .modified,
                                         comparison: .init(base: .svnBase, lineDiff: diff))
        var settings = GlimtSettingsV3()
        settings.general.vcsSupportEnabled = true
        let configuration = RenderConfiguration(settings: settings)
        let provider = GatedVCSProvider(gate: gate, result: result)
        let preview = SharedPreviewViewController(configuration: configuration, vcsProviders: [provider])
        preview.loadViewIfNeeded()
        preview.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        preview.view.layoutSubtreeIfNeeded()
        _ = try await preview.preview(for: fixtureURL("Cases/source/Example.swift"), configuration: configuration)

        let code = try XCTUnwrap(descendants(preview.view).compactMap { $0 as? SourceCodeView }.first)
        let ruler = try XCTUnwrap(code.scrollView.verticalRulerView as? SourceLineNumberRuler)
        XCTAssertFalse(code.textView.string.isEmpty, "The first useful content must render before provider completion")
        XCTAssertNil(ruler.lineDiff, "A suspended provider cannot delay or preempt the first source preview")
        let status = try XCTUnwrap(descendants(preview.view).compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        XCTAssertFalse(status.stringValue.contains("SVN:"))

        await gate.release()
        for _ in 0..<100 where ruler.lineDiff == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(ruler.lineDiff, diff)
        XCTAssertTrue(status.stringValue.contains("SVN: Modified"))
    }

    @MainActor
    func testDisabledVCSSettingDoesNotInvokeProviders() async throws {
        let calls = VCSProviderCallCount()
        let controller = SharedPreviewViewController(
            configuration: RenderConfiguration(settings: GlimtSettingsV3()),
            vcsProviders: [CountingVCSProvider(calls: calls)]
        )
        _ = try await controller.preview(for: fixtureURL("Cases/source/Example.swift"), configuration: controller.configuration)
        try await Task.sleep(for: .milliseconds(20))
        let callCount = await calls.read()
        XCTAssertEqual(callCount, 0)
        let status = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        XCTAssertFalse(status.stringValue.contains("SVN:"))
    }

    @MainActor
    func testDeclaredHexRepresentationUsesOneRendererForJsonAndDockerfile() throws {
        for path in ["Showcase/json/json.json", "Cases/ambiguous/Dockerfile"] {
            let inspection = try PreviewPreparation.read(at: fixtureURL(path))
            if path.hasSuffix(".json") {
                XCTAssertFalse(PreviewChromeModel(inspection: inspection).representations.contains(.hex),
                               "Hex is supported for JSON but not in the Structured Data profile")
            }
            let chrome = PreviewChromeModel(inspection: inspection, configuredViews: [.tree, .pretty, .raw, .hex])
            XCTAssertTrue(chrome.representations.contains(.hex), path)
            XCTAssertTrue(chrome.enabledRepresentations.contains(.hex), path)
            XCTAssertEqual(RepresentationRegistry.definitions[.hex]?.renderer, .hexBytes)
            XCTAssertEqual(RepresentationRegistry.definitions[.hex]?.input, .originalBytes)
            XCTAssertEqual(RepresentationRegistry.render(.hex, inspection: inspection), HexPreview.format(inspection.originalBytes))
        }
        let rows = HexPreview.format(Data((0..<17).map(UInt8.init)))
        XCTAssertTrue(rows.contains("00000000"))
        XCTAssertTrue(rows.contains("00000010"))
        let truncatedBytes = Data(repeating: 0x41, count: HexPreview.maximumBytes + 2)
        let truncated = PreviewPreparation.prepare(bytes: truncatedBytes, fileSize: truncatedBytes.count,
            fileName: "sample.json", systemUTI: nil)
        let status = PreviewChromeModel(inspection: truncated).statusItems(for: .hex)
        XCTAssertTrue(status.contains { $0.text == "Truncated" })
        XCTAssertTrue(status.contains { $0.text == "65536 bytes shown of 65538 bytes" })
    }

    @MainActor
    func testSameInputsProduceSameSharedAndAdapterPresentation() async throws {
        let paths = ["Showcase/markdown/markdown.md", "Cases/markdown/basic.md", "Cases/markdown/headings.md", "Cases/markdown/fenced-code.md",
                     "Cases/source/Example.swift", "Showcase/source/python.py", "Showcase/source/typescript.ts", "Showcase/source/shell.sh",
                     "Showcase/source/glimt.elm",
                     "Cases/json/valid/nested.json", "Showcase/yaml/yaml.yaml", "Cases/xml/valid/simple.xml",
                     "Cases/plist/xml/simple.plist", "Showcase/plist/binary.plist", "Showcase/text/plain.txt",
                     "Showcase/source/java.java", "Showcase/source/c.c", "Showcase/source/cpp.cpp", "Showcase/source/javascript.js",
                     "Cases/xml/valid/namespaces.xml", "Cases/yaml/valid/multi-document.yaml", "Cases/binary/extensionless",
                     "Cases/json/invalid/malformed.json", "Cases/yaml/invalid/malformed.yaml",
                     "Cases/xml/invalid/malformed.xml", "Cases/plist/invalid/malformed.plist"]
        for path in paths {
            let url = try fixtureURL(path)
            var settings = GlimtSettings()
            settings.markdown.frontMatter = .metadata; settings.markdown.tableOfContents = true
            settings.markdown.breakBehavior = .preserveSoftLines; settings.markdown.taskLists = false
            settings.source.indentationGuides = true
            settings.textCode.wordWrap = true
            settings.textCode.tabWidth = 2
            let shared = makeSizedPreviewController(configuration: RenderConfiguration(settings: settings))
            let preparation = try await shared.preview(for: url, configuration: RenderConfiguration(settings: settings))
            let configuration = RenderConfiguration(settings: settings)
            let adapter = PreviewViewController(debugDependencies: .init(loadingIndicatorDelay: contentFirstLoadingDelay, configurationLoader: { configuration }))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                adapter.preparePreviewOfFile(at: url) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let sharedViews = descendants(shared.view)
            let adapterViews = descendants(adapter.view)
            XCTAssertEqual(try header(sharedViews), try header(adapterViews), path)
            let sharedMode = try XCTUnwrap(sharedViews.compactMap { $0 as? PreviewTabStrip }.first)
            let adapterMode = try XCTUnwrap(adapterViews.compactMap { $0 as? PreviewTabStrip }.first)
            XCTAssertEqual(sharedMode.segmentCount, adapterMode.segmentCount, path)
            XCTAssertEqual(sharedMode.selectedSegment, adapterMode.selectedSegment, path)
            let sharedText = sharedViews.compactMap { $0 as? NSTextView }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.string)
            let adapterText = adapterViews.compactMap { $0 as? NSTextView }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.string)
            XCTAssertEqual(sharedText, adapterText, path)
            let sharedRows = sharedViews.compactMap { $0 as? NSOutlineView }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.numberOfRows)
            let adapterRows = adapterViews.compactMap { $0 as? NSOutlineView }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.numberOfRows)
            XCTAssertEqual(sharedRows, adapterRows, path)
            if let source = preparation.sourceDocument {
                let code = try XCTUnwrap(sharedViews.compactMap { $0 as? SourceCodeView }.first)
                XCTAssertTrue(code.options.indentationGuides)
                XCTAssertTrue(code.options.wrapLines)
                XCTAssertEqual(code.options.tabWidth, 2)
                XCTAssertEqual(code.textView.string, source.source)
                if let keyword = source.highlighting.runs.first(where: { $0.kind == .keyword }) {
                    XCTAssertNotNil(code.textView.textStorage?.attribute(.foregroundColor, at: keyword.range.location, effectiveRange: nil))
                }
            }
        }
    }

    @MainActor
    func testAdapterReloadsReadOnlySettingsForEachRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appStore = SettingsStore(directory: directory)
        let reader = SettingsStore(directory: directory, readOnly: true)
        let adapter = PreviewViewController(debugDependencies: .init(loadingIndicatorDelay: contentFirstLoadingDelay, configurationLoader: {
            RenderConfiguration(settings: (try? reader.load()) ?? .factoryDefaults)
        }))
        for presentation in [MarkdownPresentation.raw, .rendered] {
            var settings = GlimtSettings()
            settings.markdown.defaultPresentation = presentation
            try appStore.save(settings)
            let url = try fixtureURL("Cases/markdown/basic.md")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                adapter.preparePreviewOfFile(at: url) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let tabs = try mode(adapter)
            XCTAssertEqual(tabs.selectedSegment, 0, "The default view is the first tab")
            XCTAssertEqual(tabs.label(forSegment: 0), presentation == .raw ? "Source" : "Rendered")
            XCTAssertEqual(try reader.load(), settings)
        }
    }

    @MainActor
    func testExplicitAppearanceDefaultsAndFallbackWithoutFinder() async throws {
        let controller = makeSizedPreviewController()
        for appearance in PreviewAppearance.allCases {
            var settings = GlimtSettings()
            settings.markdown.defaultPresentation = .raw
            settings.structured.defaultPresentation = .pretty
            let markdown = try await controller.preview(for: fixtureURL("Cases/markdown/fenced-code.md"), configuration: RenderConfiguration(settings: settings, appearance: appearance))
            XCTAssertEqual(try selectedLabel(controller), "Source")
            XCTAssertEqual(try visibleText(controller), [markdown.markdownDocument?.raw ?? ""])
            XCTAssertEqual(controller.view.appearance?.name, appearance == .light ? .aqua : appearance == .dark ? .darkAqua : nil)
            _ = try await controller.preview(for: fixtureURL("Cases/xml/valid/simple.xml"), configuration: RenderConfiguration(settings: settings, appearance: appearance))
            XCTAssertEqual(try selectedLabel(controller), "Pretty")
            _ = try await controller.preview(for: fixtureURL("Cases/xml/invalid/malformed.xml"), configuration: RenderConfiguration(settings: settings, appearance: appearance))
            XCTAssertEqual(try mode(controller).selectedSegment, 0)
            XCTAssertEqual(try mode(controller).segmentCount, 1, "Unavailable views are hidden, not disabled")
            XCTAssertEqual(try selectedLabel(controller), "Raw")
            _ = try await controller.preview(for: fixtureURL("Cases/yaml/invalid/malformed.yaml"), configuration: RenderConfiguration(settings: settings, appearance: appearance))
            XCTAssertEqual(try mode(controller).selectedSegment, 0)
        }
    }

    @MainActor
    func testRepresentationTabsAreLocalBottomNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        var settings = GlimtSettings()
        settings.structured.defaultPresentation = .pretty
        settings.markdown.defaultPresentation = .raw
        try store.save(settings)
        let original = try Data(contentsOf: directory.appendingPathComponent(SettingsStore.legacyFilename))
        let controller = makeSizedPreviewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        for path in ["Cases/markdown/basic.md", "Cases/json/valid/nested.json", "Showcase/yaml/yaml.yaml", "Cases/xml/valid/simple.xml", "Cases/plist/xml/simple.plist", "Showcase/plist/binary.plist"] {
            let configuration = RenderConfiguration(settings: try store.load())
            _ = try await controller.preview(for: fixtureURL(path), configuration: configuration)
            let tabs = try mode(controller)
            let savedDefault = path.hasSuffix(".md") ? "Source" : "Pretty"
            XCTAssertFalse(tabs.isHiddenOrHasHiddenAncestor, path)
            XCTAssertEqual(tabs.selectedSegment, 0, path)
            XCTAssertEqual(tabs.label(forSegment: 0), savedDefault, path)
            controller.view.layoutSubtreeIfNeeded()
            let frame = tabs.convert(tabs.bounds, to: controller.view)
            let bottomDistance = controller.view.isFlipped ? controller.view.bounds.maxY - frame.maxY : frame.minY
            XCTAssertLessThan(bottomDistance, 40, "Representation tabs belong at the bottom: \(path)")
            XCTAssertTrue(tabs.acceptsFirstResponder)
            XCTAssertFalse((tabs.accessibilityLabel() ?? "").isEmpty)
            let footer = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewRepresentationTabStrip }.first)
            let tabButtons = tabs.subviews.compactMap { $0 as? NSButton }
            for index in 0..<tabs.segmentCount {
                tabButtons[index].performClick(nil)
                XCTAssertEqual(tabs.selectedSegment, index, "A real tab action must select the requested representation")
                controller.view.layoutSubtreeIfNeeded()
                let selectedFrame = try XCTUnwrap(footer.selectedTabFrame)
                XCTAssertEqual(selectedFrame.minX, PreviewRepresentationTabStrip.tabLeadingInset + CGFloat(index) * tabs.itemWidth,
                               "The outlined tab must follow the selected document representation")
                XCTAssertEqual(footer.selectedTabOutlineSegments.first?.minX, floor(selectedFrame.minX),
                               "The selected outline must be drawn around the active tab")
                if path == "Cases/json/valid/nested.json" {
                    footer.displayIfNeeded()
                    let bitmap = try XCTUnwrap(footer.bitmapImageRepForCachingDisplay(in: footer.bounds))
                    footer.effectiveAppearance.performAsCurrentDrawingAppearance {
                        footer.cacheDisplay(in: footer.bounds, to: bitmap)
                    }
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                   uniformTypeIdentifier: "public.png")
                    attachment.name = "Representation-tab-\(tabs.label(forSegment: index) ?? "unknown")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            controller.configuration = RenderConfiguration(settings: settings, appearance: .dark)
            XCTAssertEqual(tabs.selectedSegment, tabs.segmentCount - 1, "Appearance changes must retain the session choice")
            XCTAssertEqual(try store.load(), settings)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(SettingsStore.legacyFilename)), original)
            _ = try await controller.preview(for: fixtureURL(path), configuration: configuration)
            XCTAssertEqual(tabs.selectedSegment, 0, "A new preview starts from the saved default")
            XCTAssertEqual(tabs.label(forSegment: 0), savedDefault, path)
        }
        _ = try await controller.preview(for: fixtureURL("Cases/source/Example.swift"), configuration: .init())
        let sourceTabs = try mode(controller)
        XCTAssertEqual((0..<sourceTabs.segmentCount).compactMap(sourceTabs.label(forSegment:)), ["Source", "Raw"])
        XCTAssertEqual(sourceTabs.selectedSegment, 0)
        _ = try await controller.preview(for: fixtureURL("Showcase/text/plain.txt"), configuration: .init())
        let visible = descendants(controller.view).filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertFalse(visible.contains { $0 is NSSegmentedControl || $0 is NSButton || $0 is NSPopUpButton })
    }

    @MainActor
    func testSettingsWindowRendersFixtureInBothAppearances() async throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let root = SettingsRootViewController(session: session, sampleBundle: productShowcaseBundle())
        addTeardownBlock { @MainActor in NSApp.appearance = nil }
        root.presentSheet = { _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1200, height: 800))
        defer { window.contentViewController = nil; window.close() }
        let pane = root.general.preview
        try await pane.open(fixtureURL("Cases/markdown/gfm.md"), title: nil)
        for appearance in [PreviewAppearance.light, .dark] {
            session.update { $0.general.colorScheme = appearance }
            await pane.waitForPreview()
            root.view.layoutSubtreeIfNeeded()
            let previewFrame = pane.previewController.view.convert(pane.previewController.view.bounds, to: root.view)
            XCTAssertGreaterThan(previewFrame.height, 200)
            XCTAssertGreaterThan(previewFrame.width, 400)
            XCTAssertTrue(pane.diagnosticsText.contains("Markdown"))
            XCTAssertFalse(descendants(root.view).contains { $0.accessibilityLabel() == "Preview diagnostics" }, "Developer details do not belong below the footer")
            let modes = try mode(pane.previewController)
            XCTAssertEqual(modes.label(forSegment: 0), "Rendered")
            let bitmap = try XCTUnwrap(root.view.bitmapImageRepForCachingDisplay(in: root.view.bounds))
            root.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                root.view.cacheDisplay(in: root.view.bounds, to: bitmap)
            }
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "SettingsWindow-\(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testYANGSharedPreviewAndThumbnail() async throws {
        let fixture = try fixtureURL("Showcase/source/glimt.yang")
        let bytes = try Data(contentsOf: fixture)
        var settings = GlimtSettingsV3.factoryDefaults
        settings.general.colorScheme = .light
        settings.general.lineNumbers = false
        settings.general.wordWrap = .off
        settings.general.tabsToSpaces = 2
        let configuration = RenderConfiguration(settings: settings, appearance: .light)
        let controller = makeSizedPreviewController(configuration: configuration)
        let preparation = try PreviewPreparation.read(at: fixture, contentTypeIdentifier: { _ in nil })
        controller.display(preparation)

        XCTAssertEqual(preparation.formatDefinition?.id.rawValue, "reference-yang")
        XCTAssertEqual(preparation.sourceDocument?.language, .yang)
        XCTAssertEqual(try selectedLabel(controller), "Source")
        let document = try XCTUnwrap(preparation.sourceDocument)
        let expectedStatus = ["YANG", "UTF-8", "LF", "\(bytes.count) bytes", "\(document.lineCount) lines"]
        XCTAssertEqual(Set(preparation.statusSummary.items.map(\.text)), Set(expectedStatus))

        controller.view.layoutSubtreeIfNeeded()
        let sourceView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(sourceView.options, configuration.source(for: .yang))
        XCTAssertFalse(sourceView.options.showLineNumbers)
        XCTAssertFalse(sourceView.options.wrapLines)
        XCTAssertEqual(sourceView.options.tabWidth, 2)
        XCTAssertTrue(document.highlighting.runs.contains(HighlightRun(range: NSRange(location: 0, length: 6), kind: .keyword)))
        let activeKeyword = SourceSyntaxColors.color(
            for: .keyword,
            preset: sourceView.options.activeTheme(for: sourceView.effectiveAppearance),
            palette: sourceView.options.activePalette(for: sourceView.effectiveAppearance)
        )
        let renderedKeyword = try XCTUnwrap(sourceView.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        func resolvedSRGBComponents(_ color: NSColor) -> [CGFloat]? {
            var components: [CGFloat]?
            sourceView.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let resolved = color.usingColorSpace(.sRGB) else { return }
                components = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
            }
            return components
        }
        XCTAssertEqual(try XCTUnwrap(resolvedSRGBComponents(renderedKeyword)),
                       try XCTUnwrap(resolvedSRGBComponents(activeKeyword)))
        for item in expectedStatus {
            XCTAssertTrue(try header(descendants(controller.view)).contains(item), "header omits \(item)")
        }

        let rawButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        rawButton.performClick(nil)
        XCTAssertEqual(try selectedLabel(controller), "Raw")
        let visibleRaw = try XCTUnwrap(visibleText(controller).first)
        XCTAssertEqual(Data(visibleRaw.utf8), bytes)

        let binaryBytes = Data([0, 255, 0, 255])
        let binary = PreviewPreparation.prepare(bytes: binaryBytes, fileSize: binaryBytes.count,
                                               fileName: "binary.yang", systemUTI: nil)
        XCTAssertEqual(PreviewChromeModel(inspection: binary).representations, [.hex])

        let longText = "module glimt {\n" + String(repeating: "  // x\n", count: 20_000) + "}\n"
        let longBytes = Data(longText.utf8)
        let truncated = PreviewPreparation.prepare(bytes: longBytes, fileSize: longBytes.count,
                                                   fileName: "long.yang", systemUTI: nil)
        let retained = try XCTUnwrap(truncated.sourceDocument)
        let expectedRetainedSource = "module glimt {\n" + String(repeating: "  // x\n", count: 19_999)
        XCTAssertTrue(truncated.statusSummary.items.contains { $0.text == "Truncated" })
        XCTAssertEqual(retained.source, expectedRetainedSource)
        XCTAssertEqual(retained.lineCount, 20_000)
        XCTAssertTrue(retained.source.hasSuffix("\n"))
        XCTAssertEqual(truncated.originalBytes, longBytes)
        XCTAssertEqual(truncated.analysis.text, longText)

        let truncatedController = makeSizedPreviewController(configuration: configuration)
        truncatedController.display(truncated)
        XCTAssertEqual(try selectedLabel(truncatedController), "Source")
        let truncatedStatus = try XCTUnwrap(descendants(truncatedController.view).compactMap { $0 as? PreviewStatusView }.first)
        XCTAssertTrue(truncatedStatus.stringValue.contains("Truncated"))
        XCTAssertEqual(try XCTUnwrap(descendants(truncatedController.view).compactMap { $0 as? SourceCodeView }.first).textView.string,
                       expectedRetainedSource)
        let truncatedRawButton = try XCTUnwrap(descendants(truncatedController.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        truncatedRawButton.performClick(nil)
        let fullRaw = try XCTUnwrap(visibleText(truncatedController).first)
        XCTAssertEqual(Data(fullRaw.utf8), longBytes)
        XCTAssertEqual(truncated.originalBytes, Data(fullRaw.utf8))

        let thumbnail = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                                                     fileName: fixture.lastPathComponent, systemUTI: "com.glimt.yang-source")
        XCTAssertEqual(thumbnail.formatID?.rawValue, "reference-yang")
        XCTAssertEqual(FormatCatalog.definition(for: try XCTUnwrap(thumbnail.formatID))?.effectiveThumbnailStrategy, .sourceCode)
        XCTAssertEqual(thumbnail.sourceDocument?.language.displayName, "YANG")
        XCTAssertNil(thumbnail.thumbnailText)
        let selection = ThumbnailRenderer.visibleSourceLines(
            in: try XCTUnwrap(thumbnail.sourceDocument).source,
            contentRect: CGRect(x: 0, y: 0, width: 22, height: 22),
            fontAscent: 8, lineHeight: 10, lineSpacing: 2,
            maximumLines: ThumbnailRenderDefaults.maximumLines
        )
        XCTAssertEqual(selection.lines.map(\.text), Array(String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n").prefix(2)))
        XCTAssertEqual(selection.scannedLineCount, 2)
        XCTAssertNotNil(ThumbnailRenderer.render(analysis: thumbnail.analysis, sourceDocument: thumbnail.sourceDocument,
                                                 semanticText: thumbnail.thumbnailText, maximumSize: CGSize(width: 22, height: 22), scale: 1))
    }

    @MainActor
    func testElmSharedPreviewAndThumbnail() async throws {
        let fixture = try fixtureURL("Showcase/source/glimt.elm")
        let bytes = try Data(contentsOf: fixture)
        let decoded = String(decoding: bytes, as: UTF8.self)
        var settings = GlimtSettingsV3.factoryDefaults
        settings.general.colorScheme = .light
        settings.general.lineNumbers = false
        settings.general.wordWrap = .off
        settings.general.tabsToSpaces = 2
        let configuration = RenderConfiguration(settings: settings, appearance: .light)
        let controller = makeSizedPreviewController(configuration: configuration)
        let preparation = try PreviewPreparation.read(at: fixture, contentTypeIdentifier: { _ in nil })
        controller.display(preparation)

        XCTAssertEqual(preparation.formatDefinition?.id.rawValue, "reference-elm")
        XCTAssertEqual(preparation.sourceDocument?.language, .elm)
        XCTAssertEqual(PreviewChromeModel(inspection: preparation).representations, [.source, .raw, .hex])
        XCTAssertEqual(try selectedLabel(controller), "Source")
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        let document = try XCTUnwrap(preparation.sourceDocument)
        let expectedStatus = ["Elm", "UTF-8", "LF", "\(bytes.count) bytes", "\(document.lineCount) lines"]
        XCTAssertEqual(Set(preparation.statusSummary.items.map(\.text)), Set(expectedStatus))
        XCTAssertEqual(document.source, decoded)
        XCTAssertEqual(preparation.originalBytes, bytes)
        XCTAssertEqual(preparation.analysis.text, decoded)

        controller.view.layoutSubtreeIfNeeded()
        let sourceView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(sourceView.options, configuration.source(for: .elm))
        XCTAssertFalse(sourceView.options.showLineNumbers)
        XCTAssertFalse(sourceView.options.wrapLines)
        XCTAssertEqual(sourceView.options.tabWidth, 2)
        for item in expectedStatus {
            XCTAssertTrue(try header(descendants(controller.view)).contains(item), "header omits \(item)")
        }

        func resolvedSRGBComponents(_ color: NSColor) -> [CGFloat]? {
            var components: [CGFloat]?
            sourceView.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let resolved = color.usingColorSpace(.sRGB) else { return }
                components = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
            }
            return components
        }
        let preset = sourceView.options.activeTheme(for: sourceView.effectiveAppearance)
        let palette = sourceView.options.activePalette(for: sourceView.effectiveAppearance)
        let storage = try XCTUnwrap(sourceView.textView.textStorage)
        let sourceNSString = document.source as NSString
        for (token, kind) in [("module", SyntaxTokenKind.keyword), ("Chosen", .type),
                              ("42", .number), ("Glimt says:", .string),
                              ("-- Shown under", .comment)] {
            let run = try XCTUnwrap(document.highlighting.runs.first {
                $0.kind == kind && sourceNSString.substring(with: $0.range).contains(token)
            }, token)
            let actual = try XCTUnwrap(storage.attribute(.foregroundColor, at: run.range.location, effectiveRange: nil) as? NSColor)
            let expected = SourceSyntaxColors.color(for: kind, preset: preset, palette: palette)
            XCTAssertEqual(try XCTUnwrap(resolvedSRGBComponents(actual)),
                           try XCTUnwrap(resolvedSRGBComponents(expected)), token)
        }

        let rawButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        rawButton.performClick(nil)
        XCTAssertEqual(try selectedLabel(controller), "Raw")
        let visibleRaw = try XCTUnwrap(visibleText(controller).first)
        XCTAssertEqual(visibleRaw, decoded)
        XCTAssertEqual(Data(visibleRaw.utf8), bytes)
        XCTAssertEqual(preparation.originalBytes, Data(visibleRaw.utf8))
        let tabs = try mode(controller)
        tabs.selectedSegment = 2
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertEqual(try selectedLabel(controller), "Hex")
        XCTAssertEqual(try visibleText(controller), [HexPreview.format(preparation.originalBytes)])

        let binaryBytes = Data([0, 255, 0, 255])
        let binary = PreviewPreparation.prepare(bytes: binaryBytes, fileSize: binaryBytes.count,
            fileName: "binary.elm", systemUTI: nil)
        XCTAssertEqual(PreviewChromeModel(inspection: binary).representations, [.hex])

        let longText = "module Glimt exposing (..)\n" + String(repeating: "-- x\n", count: 20_000) + "tail = 1\n"
        let longBytes = Data(longText.utf8)
        let longPreview = PreviewPreparation.prepare(bytes: longBytes, fileSize: longBytes.count,
            fileName: "long.elm", systemUTI: nil)
        let retained = try XCTUnwrap(longPreview.sourceDocument)
        let expectedRetainedSource = "module Glimt exposing (..)\n" + String(repeating: "-- x\n", count: 19_999)
        XCTAssertTrue(longPreview.statusSummary.items.contains { $0.text == "Truncated" })
        XCTAssertEqual(retained.source, expectedRetainedSource)
        XCTAssertEqual(retained.lineCount, 20_000)
        XCTAssertEqual(longPreview.originalBytes, longBytes)
        XCTAssertEqual(longPreview.analysis.text, longText)
        let longController = makeSizedPreviewController(configuration: configuration)
        longController.display(longPreview)
        XCTAssertEqual(try selectedLabel(longController), "Source")
        let truncatedStatus = try XCTUnwrap(descendants(longController.view).compactMap { $0 as? PreviewStatusView }.first)
        XCTAssertTrue(truncatedStatus.stringValue.contains("Truncated"))
        XCTAssertEqual(try XCTUnwrap(descendants(longController.view).compactMap { $0 as? SourceCodeView }.first).textView.string,
                       expectedRetainedSource)
        let truncatedRawButton = try XCTUnwrap(descendants(longController.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        truncatedRawButton.performClick(nil)
        let fullRaw = try XCTUnwrap(visibleText(longController).first)
        XCTAssertTrue(fullRaw.contains("tail = 1\n"))
        XCTAssertEqual(Data(fullRaw.utf8), longBytes)
        XCTAssertEqual(longPreview.originalBytes, Data(fullRaw.utf8))
        let longTabs = try mode(longController)
        longTabs.selectedSegment = 2
        _ = longTabs.sendAction(longTabs.action, to: longTabs.target)
        XCTAssertEqual(try visibleText(longController), [HexPreview.format(Data(longBytes.prefix(HexPreview.maximumBytes)))])
        XCTAssertEqual(Data(longBytes.prefix(HexPreview.maximumBytes)).count, 65_536)

        let thumbnail = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "extensionless", systemUTI: "com.glimt.elm-source")
        XCTAssertEqual(thumbnail.formatID?.rawValue, "reference-elm")
        XCTAssertEqual(FormatCatalog.definition(for: try XCTUnwrap(thumbnail.formatID))?.effectiveThumbnailStrategy, .sourceCode)
        XCTAssertEqual(thumbnail.sourceDocument?.language.displayName, "Elm")
        XCTAssertNil(thumbnail.thumbnailText)
        let selection = ThumbnailRenderer.visibleSourceLines(
            in: try XCTUnwrap(thumbnail.sourceDocument).source,
            contentRect: CGRect(x: 0, y: 0, width: 22, height: 22),
            fontAscent: 8, lineHeight: 10, lineSpacing: 2,
            maximumLines: ThumbnailRenderDefaults.maximumLines
        )
        XCTAssertEqual(selection.lines.map(\.text), Array(decoded.components(separatedBy: "\n").prefix(2)))
        XCTAssertEqual(selection.scannedLineCount, 2)
        XCTAssertNotNil(ThumbnailRenderer.render(analysis: thumbnail.analysis, sourceDocument: thumbnail.sourceDocument,
            semanticText: thumbnail.thumbnailText, maximumSize: CGSize(width: 22, height: 22), scale: 1))
    }

    @MainActor
    func testBisonSharedPreviewAndThumbnail() throws {
        let formatID = FormatID(rawValue: "reference-bison")
        let fixture = try fixtureURL("Showcase/source/bison.y")
        let bytes = try Data(contentsOf: fixture)
        let decoded = String(decoding: bytes, as: UTF8.self)
        let expectedLineCount = decoded.components(separatedBy: "\n").count - (decoded.hasSuffix("\n") ? 1 : 0)

        var settings = GlimtSettingsV3.factoryDefaults
        settings.general.colorScheme = .light
        settings.general.lineNumbers = false
        settings.general.wordWrap = .off
        settings.general.tabsToSpaces = 2
        let configuration = RenderConfiguration(settings: settings, appearance: .light)
        let controller = makeSizedPreviewController(configuration: configuration)
        let preparation = try PreviewPreparation.read(at: fixture, contentTypeIdentifier: { _ in nil })
        controller.display(preparation)

        XCTAssertEqual(preparation.formatDefinition?.id, formatID)
        XCTAssertEqual(preparation.sourceDocument?.language, .bison)
        XCTAssertEqual(PreviewChromeModel(inspection: preparation).representations, [.source, .raw, .hex])
        XCTAssertEqual(try selectedLabel(controller), "Source")
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        let document = try XCTUnwrap(preparation.sourceDocument)
        let expectedStatus = ["Bison", "UTF-8", "LF", "\(bytes.count) bytes", "\(expectedLineCount) lines"]
        XCTAssertEqual(document.lineCount, expectedLineCount)
        XCTAssertEqual(Set(preparation.statusSummary.items.map(\.text)), Set(expectedStatus))
        XCTAssertEqual(document.source, decoded)
        XCTAssertEqual(preparation.originalBytes, bytes)
        XCTAssertEqual(preparation.analysis.text, decoded)

        controller.view.layoutSubtreeIfNeeded()
        let sourceView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(configuration.appearance, .light)
        XCTAssertEqual(sourceView.options, configuration.source(for: .bison))
        XCTAssertFalse(sourceView.options.showLineNumbers)
        XCTAssertFalse(sourceView.options.wrapLines)
        XCTAssertEqual(sourceView.options.tabWidth, 2)
        for item in expectedStatus {
            XCTAssertTrue(try header(descendants(controller.view)).contains(item), "header omits \(item)")
        }

        let session = SettingsSession(store: nil, snapshot: nil)
        let categorySheet = FormatsAndViewsSheet(session: session, selecting: .category(.sourceCode))
        categorySheet.loadViewIfNeeded()
        XCTAssertEqual(categorySheet.orderedViews, [.source, .raw])
        XCTAssertTrue(try XCTUnwrap(categorySheet.item(for: .category(.sourceCode))).children.contains {
            $0.scope == .format(formatID)
        })
        let formatSheet = FormatsAndViewsSheet(session: session, selecting: .format(formatID))
        formatSheet.loadViewIfNeeded()
        XCTAssertEqual(formatSheet.orderedViews, [.source, .raw, .hex])
        XCTAssertEqual(ViewResolver.supported(for: formatID), [.source, .raw, .hex])
        formatSheet.moveView(from: 0, to: 2)
        XCTAssertEqual(formatSheet.orderedViews, [.raw, .hex, .source])
        XCTAssertEqual(RenderConfiguration(settings: session.settings).configuredViews(for: formatID), [.raw, .hex, .source])
        for suffix in ["y", "yy"] {
            let association = try XCTUnwrap(FileAssociation(kind: .fileExtension, value: suffix, target: formatID).validated())
            XCTAssertTrue(association.matches("grammar.\(suffix)"))
            XCTAssertFalse(association.matches("grammar.\(suffix).txt"))
        }

        let rawButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        rawButton.performClick(nil)
        XCTAssertEqual(try selectedLabel(controller), "Raw")
        let visibleRaw = try XCTUnwrap(visibleText(controller).first)
        XCTAssertEqual(visibleRaw, decoded)
        XCTAssertEqual(Data(visibleRaw.utf8), bytes)
        XCTAssertEqual(preparation.originalBytes, Data(visibleRaw.utf8))
        let tabs = try mode(controller)
        tabs.selectedSegment = 2
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertEqual(try selectedLabel(controller), "Hex")
        XCTAssertEqual(try visibleText(controller), [HexPreview.format(bytes)])

        let longText = "%token WORD\n" + String(repeating: "// x\n", count: 20_000) + "tail\n"
        let longBytes = Data(longText.utf8)
        let longPreparation = PreviewPreparation.prepare(bytes: longBytes, fileSize: longBytes.count,
            fileName: "long.y", systemUTI: nil)
        let retainedSource = try XCTUnwrap(longPreparation.sourceDocument)
        let expectedRetainedSource = "%token WORD\n" + String(repeating: "// x\n", count: 19_999)
        XCTAssertEqual(retainedSource.source, expectedRetainedSource)
        XCTAssertTrue(longPreparation.statusSummary.items.contains { $0.text == "Truncated" })
        XCTAssertEqual(longPreparation.originalBytes, longBytes)
        XCTAssertEqual(longPreparation.analysis.text, longText)
        let longController = makeSizedPreviewController(configuration: configuration)
        longController.display(longPreparation)
        XCTAssertEqual(try selectedLabel(longController), "Source")
        let longSourceView = try XCTUnwrap(descendants(longController.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(longSourceView.textView.string, expectedRetainedSource)
        let status = try XCTUnwrap(descendants(longController.view).compactMap { $0 as? PreviewStatusView }.first)
        XCTAssertTrue(status.stringValue.contains("Truncated"))
        let longRawButton = try XCTUnwrap(descendants(longController.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        longRawButton.performClick(nil)
        let fullRaw = try XCTUnwrap(visibleText(longController).first)
        XCTAssertEqual(fullRaw, longText)
        XCTAssertEqual(Data(fullRaw.utf8), longBytes)

        let byteLimitPayload = Data("%token WORD\n".utf8) + Data(repeating: 120, count: 1_048_576)
        let byteLimitURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimt-Bison-\(UUID().uuidString).y")
        defer { try? FileManager.default.removeItem(at: byteLimitURL) }
        try byteLimitPayload.write(to: byteLimitURL, options: .atomic)
        let expectedBytes = Data(byteLimitPayload.prefix(1_048_576))
        let byteLimitPreparation = try PreviewPreparation.read(at: byteLimitURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(byteLimitPreparation.originalBytes, expectedBytes)
        let byteLimitController = makeSizedPreviewController(configuration: configuration)
        byteLimitController.display(byteLimitPreparation)
        let byteLimitRawButton = try XCTUnwrap(descendants(byteLimitController.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        byteLimitRawButton.performClick(nil)
        let byteLimitRaw = try XCTUnwrap(visibleText(byteLimitController).first)
        XCTAssertEqual(byteLimitRaw, String(decoding: expectedBytes, as: UTF8.self))
        XCTAssertEqual(Data(byteLimitRaw.utf8), expectedBytes)
        let byteLimitTabs = try mode(byteLimitController)
        byteLimitTabs.selectedSegment = 2
        _ = byteLimitTabs.sendAction(byteLimitTabs.action, to: byteLimitTabs.target)
        let hexBytes = Data(expectedBytes.prefix(65_536))
        XCTAssertEqual(try visibleText(byteLimitController), [HexPreview.format(hexBytes)])
        XCTAssertEqual(hexBytes.count, 65_536)

        let thumbnail = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "bison.yy", systemUTI: nil)
        XCTAssertEqual(thumbnail.formatID, formatID)
        XCTAssertEqual(thumbnail.sourceDocument?.language, .bison)
        XCTAssertEqual(FormatCatalog.definition(for: formatID)?.effectiveThumbnailStrategy, .sourceCode)
        XCTAssertNil(thumbnail.thumbnailText)
        XCTAssertNotNil(ThumbnailRenderer.render(analysis: thumbnail.analysis, sourceDocument: thumbnail.sourceDocument,
            semanticText: thumbnail.thumbnailText, maximumSize: CGSize(width: 22, height: 22), scale: 1))
    }

    @MainActor
    func testGraphvizSharedPreviewAndThumbnail() async throws {
        let formatID = FormatID(rawValue: "graphviz")
        let fixture = try fixtureURL("Showcase/source/graph.dot")
        let bytes = try Data(contentsOf: fixture)
        let decoded = String(decoding: bytes, as: UTF8.self)
        let expectedLineCount = decoded.components(separatedBy: "\n").count - (decoded.hasSuffix("\n") ? 1 : 0)

        var settings = GlimtSettingsV3.factoryDefaults
        settings.general.colorScheme = .light
        settings.general.lineNumbers = false
        settings.general.wordWrap = .off
        settings.general.tabsToSpaces = 2
        XCTAssertEqual(RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults).configuredViews(for: formatID),
                       [.source, .raw])
        settings.formatOverrides[formatID.rawValue] = ["source", "raw", "hex"]
        let configuration = RenderConfiguration(settings: settings, appearance: .light)
        let controller = makeSizedPreviewController(configuration: configuration)
        let preparation = try PreviewPreparation.read(at: fixture, contentTypeIdentifier: { _ in nil })
        controller.display(preparation)

        XCTAssertEqual(preparation.formatDefinition?.id, formatID)
        XCTAssertEqual(preparation.sourceDocument?.language, .graphviz)
        XCTAssertEqual(PreviewChromeModel(inspection: preparation).representations, [.source, .raw])
        XCTAssertEqual(ViewResolver.supported(for: formatID), [.source, .raw, .hex])
        XCTAssertEqual(configuration.configuredViews(for: formatID), [.source, .raw, .hex])
        XCTAssertEqual(try selectedLabel(controller), "Source")
        XCTAssertEqual(try mode(controller).selectedSegment, 0)
        let document = try XCTUnwrap(preparation.sourceDocument)
        let expectedStatus = ["Graphviz DOT", "UTF-8", "LF", "\(bytes.count) bytes", "\(expectedLineCount) lines"]
        XCTAssertEqual(document.lineCount, expectedLineCount)
        XCTAssertEqual(Set(preparation.statusSummary.items.map(\.text)), Set(expectedStatus))
        XCTAssertEqual(document.source, decoded)
        XCTAssertEqual(preparation.originalBytes, bytes)
        XCTAssertEqual(preparation.analysis.text, decoded)

        controller.view.layoutSubtreeIfNeeded()
        let sourceView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(sourceView.options, configuration.source(for: .graphviz))
        XCTAssertFalse(sourceView.options.showLineNumbers)
        XCTAssertFalse(sourceView.options.wrapLines)
        XCTAssertEqual(sourceView.options.tabWidth, 2)
        for item in expectedStatus {
            XCTAssertTrue(try header(descendants(controller.view)).contains(item), "header omits \(item)")
        }

        let session = SettingsSession(store: nil, snapshot: nil)
        let categorySheet = FormatsAndViewsSheet(session: session, selecting: .category(.sourceCode))
        categorySheet.loadViewIfNeeded()
        XCTAssertEqual(categorySheet.orderedViews, [.source, .raw])
        XCTAssertTrue(try XCTUnwrap(categorySheet.item(for: .category(.sourceCode))).children.contains {
            $0.scope == .format(formatID)
        })
        let formatSheet = FormatsAndViewsSheet(session: session, selecting: .format(formatID))
        formatSheet.loadViewIfNeeded()
        XCTAssertEqual(formatSheet.orderedViews, [.source, .raw])
        XCTAssertEqual(ViewResolver.supported(for: formatID), [.source, .raw, .hex])
        XCTAssertEqual(RenderConfiguration(settings: session.settings).configuredViews(for: formatID), [.source, .raw])
        formatSheet.setView(.hex, enabled: true, for: .format(formatID))
        XCTAssertEqual(formatSheet.orderedViews, [.source, .raw, .hex])
        XCTAssertEqual(RenderConfiguration(settings: session.settings).configuredViews(for: formatID), [.source, .raw, .hex])
        formatSheet.moveView(from: 0, to: 2)
        XCTAssertEqual(formatSheet.orderedViews, [.raw, .hex, .source])
        XCTAssertEqual(RenderConfiguration(settings: session.settings).configuredViews(for: formatID), [.raw, .hex, .source])
        for suffix in ["dot", "gv"] {
            let association = try XCTUnwrap(FileAssociation(kind: .fileExtension, value: suffix, target: formatID).validated())
            XCTAssertTrue(association.matches("graph.\(suffix)"))
            XCTAssertFalse(association.matches("graph.\(suffix).txt"))
        }

        let rawButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        rawButton.performClick(nil)
        XCTAssertEqual(try selectedLabel(controller), "Raw")
        let visibleRaw = try XCTUnwrap(visibleText(controller).first)
        XCTAssertEqual(visibleRaw, decoded)
        XCTAssertEqual(Data(visibleRaw.utf8), bytes)
        XCTAssertEqual(preparation.originalBytes, Data(visibleRaw.utf8))
        let tabs = try mode(controller)
        guard tabs.segmentCount > 2, tabs.label(forSegment: 2) == "Hex" else {
            XCTFail("The explicit Graphviz view configuration must expose Hex")
            return
        }
        tabs.selectedSegment = 2
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertEqual(try selectedLabel(controller), "Hex")
        XCTAssertEqual(try visibleText(controller), [HexPreview.format(bytes)])

        let plain = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "graph.dot.txt", systemUTI: nil)
        XCTAssertEqual(plain.formatDefinition?.id, .text)
        let plainChrome = PreviewChromeModel(inspection: plain)
        XCTAssertEqual(plainChrome.representations, [])
        XCTAssertEqual(plainChrome.enabledRepresentations, [.raw])
        XCTAssertFalse(plainChrome.isRecovery)
        XCTAssertNil(plain.sourceDocument)
        let plainController = makeSizedPreviewController(configuration: configuration)
        plainController.display(plain)
        plainController.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try visibleText(plainController), [decoded])
        XCTAssertTrue(try mode(plainController).isHidden)
        let swiftBytes = Data("import Foundation\n".utf8)
        let swift = PreviewPreparation.prepare(bytes: swiftBytes, fileSize: swiftBytes.count,
            fileName: "sample.swift", systemUTI: nil)
        XCTAssertEqual(swift.formatDefinition?.id, .swift)
        XCTAssertEqual(PreviewChromeModel(inspection: swift, configuredViews: [.source, .raw, .hex]).representations,
                       [.source, .raw, .hex])
        let binaryBytes = Data([0, 255, 0, 255])
        let binary = PreviewPreparation.prepare(bytes: binaryBytes, fileSize: binaryBytes.count,
            fileName: "unknown.bin", systemUTI: nil)
        XCTAssertNil(binary.sourceDocument)
        XCTAssertEqual(PreviewChromeModel(inspection: binary).representations, [.hex])
        for plistFormat in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let plistBytes = try PropertyListSerialization.data(fromPropertyList: ["node": "value"],
                format: plistFormat, options: 0)
            let plist = PreviewPreparation.prepare(bytes: plistBytes, fileSize: plistBytes.count,
                fileName: "sample.dot", systemUTI: nil)
            XCTAssertEqual(plist.formatDefinition?.id, .plist)
            XCTAssertEqual(PreviewChromeModel(inspection: plist).representations, [.tree, .pretty, .raw])
            XCTAssertNil(plist.sourceDocument)
        }

        let longText = "digraph G {\n" + String(repeating: "// x\n", count: 20_000) + "late_node;\n}\n"
        let longBytes = Data(longText.utf8)
        let truncated = PreviewPreparation.prepare(bytes: longBytes, fileSize: longBytes.count,
            fileName: "long.dot", systemUTI: nil)
        let retained = try XCTUnwrap(truncated.sourceDocument)
        let expectedRetainedSource = "digraph G {\n" + String(repeating: "// x\n", count: 19_999)
        XCTAssertEqual(retained.source, expectedRetainedSource)
        XCTAssertEqual(retained.lineCount, 20_000)
        XCTAssertTrue(truncated.statusSummary.items.contains { $0.text == "Truncated" })
        XCTAssertEqual(truncated.originalBytes, longBytes)
        XCTAssertEqual(truncated.analysis.text, longText)
        let truncatedController = makeSizedPreviewController(configuration: configuration)
        truncatedController.display(truncated)
        XCTAssertEqual(try selectedLabel(truncatedController), "Source")
        let status = try XCTUnwrap(descendants(truncatedController.view).compactMap { $0 as? PreviewStatusView }.first)
        XCTAssertTrue(status.stringValue.contains("Truncated"))
        let truncatedRaw = try XCTUnwrap(descendants(truncatedController.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        truncatedRaw.performClick(nil)
        XCTAssertEqual(try XCTUnwrap(visibleText(truncatedController).first), longText)
        XCTAssertEqual(truncated.originalBytes, Data(try XCTUnwrap(visibleText(truncatedController).first).utf8))

        let byteLimit = 1_048_576
        let byteLimitPayload = Data("digraph G {\n".utf8) + Data(repeating: 120, count: byteLimit + 32)
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("Glimt-DOT-\(UUID().uuidString).dot")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try byteLimitPayload.write(to: temporaryURL, options: .atomic)
        let expectedBytes = Data(byteLimitPayload.prefix(byteLimit))
        let expectedRaw = String(decoding: expectedBytes, as: UTF8.self)
        let byteLimitPreparation = try PreviewPreparation.read(at: temporaryURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(byteLimitPreparation.originalBytes, expectedBytes)
        let byteLimitController = makeSizedPreviewController(configuration: configuration)
        byteLimitController.display(byteLimitPreparation)
        let byteLimitRawButton = try XCTUnwrap(descendants(byteLimitController.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        byteLimitRawButton.performClick(nil)
        let byteLimitRaw = try XCTUnwrap(visibleText(byteLimitController).first)
        XCTAssertEqual(byteLimitRaw, expectedRaw)
        XCTAssertEqual(Data(byteLimitRaw.utf8), expectedBytes)
        let byteLimitTabs = try mode(byteLimitController)
        byteLimitTabs.selectedSegment = 2
        _ = byteLimitTabs.sendAction(byteLimitTabs.action, to: byteLimitTabs.target)
        XCTAssertEqual(try visibleText(byteLimitController), [HexPreview.format(Data(expectedBytes.prefix(65_536)))])

        let associationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimt-DOT-Associations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: associationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: associationDirectory) }
        let sourceURL = associationDirectory.appendingPathComponent("graph.dot")
        let unknownURL = associationDirectory.appendingPathComponent("graph.unknown")
        let gvURL = associationDirectory.appendingPathComponent("graph.gv")
        try bytes.write(to: sourceURL, options: .atomic)
        try bytes.write(to: unknownURL, options: .atomic)
        try bytes.write(to: gvURL, options: .atomic)
        var dotPlainSettings = GlimtSettingsV3.factoryDefaults
        dotPlainSettings.fileAssociations = [try XCTUnwrap(FileAssociation(kind: .fileExtension, value: "dot", target: .text).validated())]
        let dotPlain = try await SharedPreviewPipeline.preview(for: sourceURL,
            configuration: RenderConfiguration(settings: dotPlainSettings), contentTypeIdentifier: { _ in nil }).inspection
        XCTAssertEqual(dotPlain.formatDefinition?.id, .text)
        XCTAssertEqual(dotPlain.detectionReason, "userOverride")
        XCTAssertEqual(dotPlain.resolution.typeID, formatID.rawValue)
        XCTAssertEqual(dotPlain.resolution.evidence.first { $0.signalKind == .singleExtension }?.value, ".dot")
        XCTAssertNil(dotPlain.sourceDocument)
        let dotPlainConfiguration = RenderConfiguration(settings: dotPlainSettings)
        let dotPlainChrome = PreviewChromeModel(inspection: dotPlain,
            configuredViews: dotPlainConfiguration.configuredViews(for: dotPlain.formatDefinition?.id))
        XCTAssertEqual(dotPlainChrome.representations, [])
        XCTAssertEqual(dotPlainChrome.enabledRepresentations, [.raw])
        let dotPlainController = makeSizedPreviewController(configuration: dotPlainConfiguration)
        dotPlainController.display(dotPlain)
        dotPlainController.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try visibleText(dotPlainController), [decoded])
        XCTAssertTrue(try mode(dotPlainController).isHidden)

        var unknownGraphvizSettings = GlimtSettingsV3.factoryDefaults
        unknownGraphvizSettings.fileAssociations = [try XCTUnwrap(FileAssociation(kind: .fileExtension, value: "unknown", target: formatID).validated())]
        let unknownGraphviz = try await SharedPreviewPipeline.preview(for: unknownURL,
            configuration: RenderConfiguration(settings: unknownGraphvizSettings), contentTypeIdentifier: { _ in nil }).inspection
        XCTAssertEqual(unknownGraphviz.formatDefinition?.id, formatID)
        XCTAssertEqual(unknownGraphviz.detectionReason, "userOverride")
        XCTAssertEqual(unknownGraphviz.resolution.typeID, "unknown")
        XCTAssertEqual(unknownGraphviz.resolution.evidence.first { $0.signalKind == .singleExtension }?.value, "no-match")
        XCTAssertEqual(unknownGraphviz.sourceDocument?.language, .graphviz)
        let unknownGraphvizConfiguration = RenderConfiguration(settings: unknownGraphvizSettings)
        XCTAssertEqual(unknownGraphvizConfiguration.configuredViews(for: formatID), [.source, .raw])
        let unknownGraphvizChrome = PreviewChromeModel(inspection: unknownGraphviz,
            configuredViews: unknownGraphvizConfiguration.configuredViews(for: formatID))
        XCTAssertEqual(unknownGraphvizChrome.representations, [.source, .raw])
        let unknownGraphvizController = makeSizedPreviewController(configuration: unknownGraphvizConfiguration)
        unknownGraphvizController.display(unknownGraphviz)
        unknownGraphvizController.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try selectedLabel(unknownGraphvizController), "Source")
        XCTAssertEqual(try visibleText(unknownGraphvizController), [decoded])

        var gvPlainSettings = GlimtSettingsV3.factoryDefaults
        gvPlainSettings.fileAssociations = [try XCTUnwrap(FileAssociation(kind: .fileExtension, value: "gv", target: .text).validated())]
        let gvPlain = try await SharedPreviewPipeline.preview(for: gvURL,
            configuration: RenderConfiguration(settings: gvPlainSettings), contentTypeIdentifier: { _ in nil }).inspection
        XCTAssertEqual(gvPlain.formatDefinition?.id, .text)
        XCTAssertEqual(gvPlain.detectionReason, "userOverride")
        XCTAssertEqual(gvPlain.resolution.typeID, formatID.rawValue)
        XCTAssertEqual(gvPlain.resolution.evidence.first { $0.signalKind == .singleExtension }?.value, ".gv")
        XCTAssertNil(gvPlain.sourceDocument)
        let gvPlainConfiguration = RenderConfiguration(settings: gvPlainSettings)
        let gvPlainChrome = PreviewChromeModel(inspection: gvPlain,
            configuredViews: gvPlainConfiguration.configuredViews(for: gvPlain.formatDefinition?.id))
        XCTAssertEqual(gvPlainChrome.representations, [])
        XCTAssertEqual(gvPlainChrome.enabledRepresentations, [.raw])
        let gvPlainController = makeSizedPreviewController(configuration: gvPlainConfiguration)
        gvPlainController.display(gvPlain)
        gvPlainController.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try visibleText(gvPlainController), [decoded])
        XCTAssertTrue(try mode(gvPlainController).isHidden)

        for name in ["graph.dot", "graph.gv"] {
            let association = try XCTUnwrap(FileAssociation(kind: .fileExtension, value: (name as NSString).pathExtension,
                target: formatID).validated())
            XCTAssertTrue(association.matches(name))
            let thumbnail = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: name, systemUTI: nil)
            XCTAssertEqual(thumbnail.formatID, formatID, name)
            XCTAssertEqual(thumbnail.sourceDocument?.language, .graphviz, name)
            XCTAssertEqual(FormatCatalog.definition(for: formatID)?.effectiveThumbnailStrategy, .sourceCode)
            XCTAssertNil(thumbnail.thumbnailText)
            XCTAssertNotNil(ThumbnailRenderer.render(analysis: thumbnail.analysis, sourceDocument: thumbnail.sourceDocument,
                semanticText: thumbnail.thumbnailText, maximumSize: CGSize(width: 22, height: 22), scale: 1), name)
        }
    }

    @MainActor
    func testElmTruncatedHostPreviewCapture() throws {
        let longText = "module Glimt exposing (..)\n" + String(repeating: "-- x\n", count: 20_000) + "tail = 1\n"
        let longBytes = Data(longText.utf8)
        let preparation = PreviewPreparation.prepare(bytes: longBytes, fileSize: longBytes.count,
            fileName: "long.elm", systemUTI: nil)
        let document = try XCTUnwrap(preparation.sourceDocument)
        let expectedRetainedSource = "module Glimt exposing (..)\n" + String(repeating: "-- x\n", count: 19_999)
        XCTAssertEqual(document.source, expectedRetainedSource)
        XCTAssertEqual(document.lineCount, 20_000)
        XCTAssertTrue(preparation.statusSummary.items.contains { $0.text == "Truncated" })
        XCTAssertEqual(preparation.originalBytes, longBytes)

        var settings = GlimtSettingsV3.factoryDefaults
        settings.general.colorScheme = .light
        let configuration = RenderConfiguration(settings: settings, appearance: .light)
        let size = NSSize(width: 1100, height: 700)
        let controller = makeSizedPreviewController(configuration: configuration, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        defer { window.contentViewController = nil; window.close(); controller.cancelVCSInspection() }
        controller.display(preparation)
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(try selectedLabel(controller), "Source")
        let sourceView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(sourceView.textView.string, expectedRetainedSource)
        let status = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewStatusView }.first)
        XCTAssertTrue(status.stringValue.contains("Truncated"))
        XCTAssertFalse(status.isHiddenOrHasHiddenAncestor)

        let rawButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Raw" })
        rawButton.performClick(nil)
        XCTAssertEqual(try selectedLabel(controller), "Raw")
        let raw = try XCTUnwrap(visibleText(controller).first)
        XCTAssertTrue(raw.contains("tail = 1\n"))
        XCTAssertEqual(Data(raw.utf8), longBytes)
        XCTAssertEqual(preparation.originalBytes, Data(raw.utf8))
    }

    @MainActor
    func testTruncatedPlainTextHasReadableDiagnosticWithoutControls() throws {
        let bytes = Data("Readable prefix\n".utf8)
        let result = PreviewPreparation.prepare(bytes: bytes, fileSize: 1_048_577, fileName: "large.txt", systemUTI: nil)
        let controller = makeSizedPreviewController()
        controller.display(result)
        let views = descendants(controller.view)
        let diagnostic = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        XCTAssertFalse(diagnostic.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(diagnostic.stringValue.lowercased().contains("truncated"))
        XCTAssertFalse((diagnostic.accessibilityLabel() ?? "").isEmpty)
        XCTAssertEqual(try visibleText(controller), ["Readable prefix\n"])
        XCTAssertTrue(try mode(controller).isHiddenOrHasHiddenAncestor)
    }

    @MainActor
    func testCoreV1PreviewConsistencyAccessibilityAndDevelopmentMetrics() throws {
        let controller = makeSizedPreviewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 640, height: 480))
        defer { window.contentViewController = nil; window.close() }
        var metrics: [String] = []
        let paths = ["Showcase/text/plain.txt", "Cases/source/Example.swift", "Cases/markdown/headings.md", "Cases/json/valid/nested.json",
                     "Showcase/yaml/yaml.yaml", "Cases/xml/valid/simple.xml", "Cases/plist/xml/simple.plist", "Showcase/plist/binary.plist"]
        for appearance in [PreviewAppearance.light, .dark] {
            for path in paths {
                try autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = try PreviewPreparation.read(at: fixtureURL(path), contentTypeIdentifier: { _ in nil })
                    let inspected = ProcessInfo.processInfo.systemUptime
                    var settings = GlimtSettings()
                    settings.structured.defaultPresentation = .raw
                    controller.configuration = RenderConfiguration(settings: settings, appearance: appearance)
                    controller.display(result)
                    controller.view.layoutSubtreeIfNeeded()
                    XCTAssertGreaterThanOrEqual(controller.view.bounds.height, 480)
                    let views = descendants(controller.view)
                    let textViews = views.compactMap { $0 as? NSTextView }.filter { !$0.isHiddenOrHasHiddenAncestor }
                    for text in textViews {
                        XCTAssertFalse(text.isEditable, path)
                        XCTAssertTrue(text.isSelectable, path)
                        XCTAssertFalse((text.accessibilityLabel() ?? "").isEmpty, path)
                        XCTAssertEqual(text.textContainerInset, NSSize(width: 8, height: 8), path)
                        XCTAssertLessThanOrEqual(text.string.utf16.count, 2_097_152, path)
                    }
                    let previewed = ProcessInfo.processInfo.systemUptime
                    var usage = rusage()
                    _ = getrusage(RUSAGE_SELF, &usage)
                    // Development diagnostics only: CI load and other tests affect wall time/RSS.
                    let metric = "CORE_V1_METRIC format=\(result.formatName.replacingOccurrences(of: " ", with: "_")) appearance=\(appearance.rawValue) inspection_ms=\((inspected-start)*1000) preview_ms=\((previewed-inspected)*1000) process_peak_rss=\(usage.ru_maxrss)"
                    metrics.append(metric)
                    print(metric)
                    controller.configuration = RenderConfiguration(appearance: appearance)
                    controller.display(result)
                    controller.view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                    try XCTUnwrap(controller.view.appearance).performAsCurrentDrawingAppearance {
                        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                    }
                    let image = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                    image.name = "Core-v1-\(path.replacingOccurrences(of: "/", with: "-"))-\(appearance.rawValue)"
                    image.lifetime = .keepAlways
                    add(image)
                }
            }
        }
        let diagnostic = XCTAttachment(string: metrics.joined(separator: "\n"))
        diagnostic.name = "Core-v1-performance-diagnostic"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        for path in ["Cases/json/invalid/malformed.json", "Cases/yaml/invalid/malformed.yaml", "Cases/xml/invalid/malformed.xml", "Cases/plist/invalid/malformed.plist"] {
            let result = try PreviewPreparation.read(at: fixtureURL(path), contentTypeIdentifier: { _ in nil })
            controller.display(result)
            let views = descendants(controller.view)
            let diagnostic = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
            XCTAssertFalse(diagnostic.isHiddenOrHasHiddenAncestor, path)
            XCTAssertFalse((diagnostic.accessibilityLabel() ?? "").isEmpty, path)
            XCTAssertEqual(try mode(controller).selectedSegment, 0, path)
            XCTAssertEqual(try visibleText(controller), [result.structuredRawText], path)
        }
        for path in ["Cases/json/valid/nested.json", "Showcase/yaml/yaml.yaml", "Cases/xml/valid/simple.xml", "Cases/plist/xml/simple.plist"] {
            controller.configuration = .init()
            controller.display(try PreviewPreparation.read(at: fixtureURL(path), contentTypeIdentifier: { _ in nil }))
            controller.view.layoutSubtreeIfNeeded()
            let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
            XCTAssertFalse((outline.accessibilityLabel() ?? "").isEmpty, path)
            XCTAssertGreaterThan(outline.numberOfRows, 0, path)
            for row in 0..<outline.numberOfRows {
                let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTextField)
                XCTAssertFalse((cell.accessibilityLabel() ?? "").isEmpty, path)
            }
        }
    }

    @MainActor private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    @MainActor private func header(_ views: [NSView]) throws -> String { try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" }).accessibilityLabel() ?? "" }
    @MainActor private func mode(_ controller: SharedPreviewViewController) throws -> PreviewTabStrip { try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewTabStrip }.first) }
    @MainActor private func selectedLabel(_ controller: SharedPreviewViewController) throws -> String? {
        let tabs = try mode(controller)
        return tabs.label(forSegment: tabs.selectedSegment)
    }
    @MainActor private func visibleText(_ controller: SharedPreviewViewController) throws -> [String] { descendants(controller.view).compactMap { $0 as? NSTextView }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.string) }
}

private actor VCSInspectionGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct GatedVCSProvider: VCSProvider {
    let gate: VCSInspectionGate
    let result: VCSInspectionResult
    let repositoryType = VCSRepositoryType.svn

    func inspect(fileURL: URL) async -> VCSProviderInspection {
        await gate.suspend()
        return .inspected(result)
    }
}

private actor VCSProviderCallCount {
    private var value = 0
    func increment() { value += 1 }
    func read() -> Int { value }
}

private struct CountingVCSProvider: VCSProvider {
    let calls: VCSProviderCallCount
    let repositoryType = VCSRepositoryType.svn

    func inspect(fileURL: URL) async -> VCSProviderInspection {
        await calls.increment()
        return .notRepository
    }
}

/// Attach realistic geometry before any renderer can lay out its text system.
@MainActor
func makeSizedPreviewController(configuration: RenderConfiguration = .init(),
                                 size: NSSize = .init(width: 640, height: 480),
                                 renderMermaidBlocks: MermaidBlockRenderOperation? = nil,
                                 makeMermaidAttachment: MermaidAttachmentFactory? = nil,
                                 requestedMermaidWidth: MermaidRequestedWidthProvider? = nil,
                                 mermaidResultObserver: MermaidRenderResultObserver? = nil) -> SharedPreviewViewController {
    let controller = SharedPreviewViewController(
        configuration: configuration, vcsProviders: [SVNProvider(), GitProvider()],
        renderMermaidBlocks: renderMermaidBlocks, makeMermaidAttachment: makeMermaidAttachment,
        requestedMermaidWidth: requestedMermaidWidth, mermaidResultObserver: mermaidResultObserver)
    controller.loadViewIfNeeded()
    controller.view.frame = NSRect(origin: .zero, size: size)
    controller.view.layoutSubtreeIfNeeded()
    return controller
}
