import AppKit
import InspectorCore
import XCTest

final class MermaidKitRendererTests: XCTestCase {
    private struct ByteLine {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    private struct WrappedEntry {
        let payload: Data
        let entry: Data
    }

    @MainActor
    func testInvalidDiagramKeepsItsVisibleFenceWithoutAnAttachment() async throws {
        let raw = "Before\n\n```mermaid\nnot-a-mermaid-diagram\n```\n\nAfter"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(
            bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        let renderer = MermaidKitRenderer()
        let images = try await renderer.render(document.mermaidBlocks, maximumWidth: 560)
        XCTAssertTrue(images.isEmpty)

        let output = MarkdownRenderer.render(document, mermaidImages: images)
        XCTAssertTrue(output.string.contains("not-a-mermaid-diagram"))
        var attachmentCount = 0
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, _ in
            if value is NSTextAttachment { attachmentCount += 1 }
        }
        XCTAssertEqual(attachmentCount, 0)
        XCTAssertEqual(document.raw, raw)
    }

    @MainActor
    func testEveryMermaidKitDiagramFamilyRendersOrFallsBackToSource() async throws {
        let expectedFixtureNames: Set<String> = [
            "agentflow", "architecture", "block", "c4", "class", "cynefin", "entity-relationship",
            "event-modeling", "flowchart", "gantt", "git-graph", "ishikawa", "kanban", "mindmap",
            "packet", "pie", "quadrant", "radar", "requirement", "sankey", "sequence", "state",
            "swimlanes", "timeline", "tree-view", "treemap", "use-case", "user-journey", "venn",
            "wardley", "xy-chart", "zenuml",
        ]
        let fixtureDirectory = try fixtureURL("Cases/mermaid/README.md").deletingLastPathComponent()
        let fixtureNames = try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path)
            .filter { $0.hasSuffix(".mmd") }
            .map { String($0.dropLast(".mmd".count)) }
            .sorted()
        XCTAssertEqual(Set(fixtureNames), expectedFixtureNames, "Every Mermaid 12.3.0 syntax family has one fixture.")
        let expectedFallbackFamilies: Set<String> = ["agentflow", "use-case"]

        let renderer = MermaidKitRenderer()
        for fixtureName in fixtureNames {
            let fixturePath = "Cases/mermaid/\(fixtureName).mmd"
            let url = try fixtureURL(fixturePath)
            let fixtureData = try Data(contentsOf: url)
            let source = String(decoding: fixtureData, as: UTF8.self).trimmingCharacters(in: .newlines)
            let family = fixtureName
            let wrappedSource = "Before\n\n```mermaid\n\(source)\n```\n\nAfter"
            let bytes = Data(wrappedSource.utf8)
            let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(
                bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
            XCTAssertEqual(document.raw, wrappedSource, family)
            let block = try XCTUnwrap(document.mermaidBlocks.first, family)
            if expectedFallbackFamilies.contains(family) {
                XCTAssertNil(block.mermaidKitDiagram, family)
                let fallback = MarkdownRenderer.render(document)
                XCTAssertTrue(fallback.string.contains(source), family)
                XCTAssertEqual(attachments(in: fallback).count, 0, family)
                continue
            }
            XCTAssertNotNil(block.mermaidKitDiagram, family)
            for maximumWidth in [180.0, 560.0] {
                var renderError: String?
                let familyImages = try await renderer.render([block], maximumWidth: maximumWidth) { _, error in
                    renderError = String(describing: error)
                }
                XCTAssertEqual(familyImages.count, 1, "\(family): \(renderError ?? "no MermaidKit image")")
                for image in familyImages.values {
                    XCTAssertTrue(image.isValid, family)
                    XCTAssertGreaterThan(image.size.width, 0, family)
                    XCTAssertGreaterThan(image.size.height, 0, family)
                    try assertVisuallyRendered(image, family: family)
                }
                if maximumWidth == 560, let image = familyImages.values.first,
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "Mermaid-\(family)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                } else if maximumWidth == 560 {
                    XCTFail("\(family): unable to capture rendered diagram")
                }
                let attributed = MarkdownRenderer.render(document, maximumDiagramWidth: CGFloat(maximumWidth),
                                                         mermaidImages: familyImages)
                var attachmentCount = 0
                attributed.enumerateAttribute(.attachment,
                    in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                        if value is NSTextAttachment { attachmentCount += 1 }
                    }
                XCTAssertEqual(attachmentCount, 1, "\(family) at \(Int(maximumWidth)) pt")
            }
        }
    }

    @MainActor
    func testAllSixteenDiagramsInWrappedFixtureRenderTogether() async throws {
        let url = try fixtureURL("Cases/mermaid/wrapped-02.md")
        let preparation = try PreviewPreparation.read(at: url)
        let document = try XCTUnwrap(preparation.markdownDocument)
        XCTAssertEqual(document.mermaidBlocks.count, 16)

        var failures: [String] = []
        let images = try await MermaidKitRenderer().render(document.mermaidBlocks, maximumWidth: 624) { index, error in
            failures.append("diagram \(index): \(error)")
        }
        let supportedCount = document.mermaidBlocks.filter { $0.mermaidKitDiagram != nil }.count
        XCTAssertEqual(images.count, supportedCount, failures.joined(separator: "\n"))
        let attributed = MarkdownRenderer.render(document, maximumDiagramWidth: 624, mermaidImages: images)
        XCTAssertEqual(attachments(in: attributed).count, supportedCount, "Every supported diagram should render in Markdown")
        for (index, block) in document.mermaidBlocks.enumerated() {
            if block.mermaidKitDiagram != nil {
                try assertVisuallyRendered(try XCTUnwrap(images[block.source], "wrapped-02 diagram \(index)"), family: "wrapped-02 diagram \(index)")
            } else {
                XCTAssertNil(images[block.source], "Unsupported source should remain readable")
            }
        }
    }

    @MainActor
    func testStandaloneAndWrappedFilesAttachForEveryOriginalAtBothWidths() async throws {
        let directory = try fixtureURL("Cases/mermaid/README.md").deletingLastPathComponent()
        let originals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mmd" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(originals.count, 32)

        var entries: [String: WrappedEntry] = [:]
        for wrapperName in ["wrapped-01.md", "wrapped-02.md"] {
            let wrapperURL = directory.appendingPathComponent(wrapperName)
            let wrapperBytes = try Data(contentsOf: wrapperURL)
            let wrapperInspection = try PreviewInspectionResult.read(at: wrapperURL)
            let document = try XCTUnwrap(wrapperInspection.markdownDocument)
            XCTAssertEqual(document.mermaidBlocks.count, 16, wrapperName)
            XCTAssertEqual(wrapperInspection.originalBytes, wrapperBytes, wrapperName)
            XCTAssertEqual(Data(document.raw.utf8), wrapperBytes, wrapperName)
            XCTAssertEqual(Data(wrapperInspection.analysis.text.utf8), wrapperBytes, wrapperName)
            let highlightedSource = try XCTUnwrap(wrapperInspection.sourceDocument, wrapperName)
            XCTAssertEqual(Data(highlightedSource.source.utf8), wrapperBytes, wrapperName)
            let scanned = try scanWrapper(wrapperBytes)
            let expectedNames = (wrapperName == "wrapped-01.md" ? Array(originals.prefix(16)) : Array(originals.suffix(16)))
                .map(\.lastPathComponent)
            XCTAssertEqual(Set(scanned.keys), Set(expectedNames), wrapperName)
            XCTAssertEqual(document.mermaidBlocks.map { Data($0.source.utf8) },
                           try expectedNames.map { name in
                               try wrappedPayload(for: Data(contentsOf: directory.appendingPathComponent(name)))
                           }, wrapperName)
            for (basename, entry) in scanned {
                XCTAssertNil(entries[basename], "Each original appears in exactly one durable wrapper")
                let original = try Data(contentsOf: directory.appendingPathComponent(basename))
                XCTAssertEqual(entry.payload, wrappedPayload(for: original), basename)
                entries[basename] = entry
            }
        }
        XCTAssertEqual(Set(entries.keys), Set(originals.map(\.lastPathComponent)))

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlimtMermaidWrapped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let renderer = MermaidKitRenderer()
        for originalURL in originals {
            let basename = originalURL.lastPathComponent
            let standalone = try PreviewPreparation.read(at: originalURL)
            XCTAssertEqual(standalone.originalBytes, try Data(contentsOf: originalURL), basename)
            guard case .admitted(let standaloneBlock) = standalone.standaloneMermaidAdmission else {
                XCTFail("Complete Mermaid fixture should be admitted: \(basename)")
                continue
            }

            let entry = try XCTUnwrap(entries[basename])
            let scratchURL = scratch.appendingPathComponent("\(originalURL.deletingPathExtension().lastPathComponent)-wrapped.md")
            try entry.entry.write(to: scratchURL, options: .atomic)
            let wrapped = try PreviewPreparation.read(at: scratchURL)
            let markdown = try XCTUnwrap(wrapped.markdownDocument)
            XCTAssertEqual(markdown.mermaidBlocks.count, 1, basename)
            let wrappedBlock = try XCTUnwrap(markdown.mermaidBlocks.first)
            XCTAssertEqual(Data(wrappedBlock.source.utf8), Data(String(decoding: entry.payload, as: UTF8.self).utf8), basename)

            if standaloneBlock.mermaidKitDiagram == nil {
                for width in [180.0, 560.0] {
                    let unsupportedImages = try await renderer.render([standaloneBlock], maximumWidth: width)
                    XCTAssertTrue(unsupportedImages.isEmpty, basename)
                    let fallback = MarkdownRenderer.render(markdown, maximumDiagramWidth: CGFloat(width))
                    XCTAssertTrue(fallback.string.contains(standaloneBlock.source), basename)
                    XCTAssertEqual(attachments(in: fallback).count, 0, basename)
                }
                continue
            }

            for width in [180.0, 560.0] {
                let standaloneImages = try await renderer.render([standaloneBlock], maximumWidth: width)
                let standaloneImage = try XCTUnwrap(standaloneImages[standaloneBlock.source], "\(basename) standalone at \(Int(width)) pt")
                try assertBoundedRuntimeImage(standaloneImage, width: width, file: basename)
                let standaloneAttachment = try XCTUnwrap(MermaidDiagramRenderer.attachment(
                    for: standaloneBlock, appearance: .currentDrawing(), maximumWidth: CGFloat(width),
                    renderedImage: standaloneImage))
                XCTAssertTrue(standaloneAttachment.image === standaloneImage, basename)
                assertBoundedAttachment(standaloneAttachment, width: width, file: basename)

                let markdownImages = try await renderer.render([wrappedBlock], maximumWidth: width)
                let markdownImage = try XCTUnwrap(markdownImages[wrappedBlock.source], "\(basename) Markdown at \(Int(width)) pt")
                try assertBoundedRuntimeImage(markdownImage, width: width, file: basename)
                let rendered = MarkdownRenderer.render(markdown, maximumDiagramWidth: CGFloat(width),
                                                       mermaidImages: markdownImages)
                let attachments = attachments(in: rendered)
                XCTAssertEqual(attachments.count, 1, "\(basename) Markdown at \(Int(width)) pt")
                XCTAssertTrue(attachments[0].image === markdownImage, basename)
                assertBoundedAttachment(attachments[0], width: width, file: basename)
            }
        }
    }

    @MainActor
    func testInvalidStandaloneFixtureKeepsItsExactSourceWhenUnsupported() async throws {
        let url = try fixtureURL("Cases/mermaid/invalid.mermaid")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes, Data([102, 108, 111, 119, 99, 104, 97, 114, 116, 32, 84, 68, 10, 65, 91]))
        let preparation = try PreviewPreparation.read(at: url)
        guard case .admitted(let block) = preparation.standaloneMermaidAdmission else {
            return XCTFail("Invalid syntax is complete and within render limits")
        }
        XCTAssertEqual(Data(block.source.utf8), bytes)
        let images = try await MermaidKitRenderer().render([block], maximumWidth: 560)
        XCTAssertTrue(images.isEmpty)
        XCTAssertEqual(Data(preparation.analysis.text.utf8), bytes)
    }

    private func scanWrapper(_ data: Data) throws -> [String: WrappedEntry] {
        let bytes = Array(data)
        let lines = byteLines(bytes)
        var entries: [String: WrappedEntry] = [:]
        var lineIndex = 0
        while lineIndex < lines.count {
            let header = lines[lineIndex]
            let headerBytes = Array(bytes[header.start..<header.contentEnd])
            guard headerBytes.starts(with: Array("## ".utf8)) else {
                lineIndex += 1
                continue
            }
            let basename = String(decoding: headerBytes.dropFirst(3), as: UTF8.self)
            guard lineIndex + 2 < lines.count,
                  bytes[lines[lineIndex + 1].start..<lines[lineIndex + 1].contentEnd].isEmpty,
                  Array(bytes[lines[lineIndex + 2].start..<lines[lineIndex + 2].contentEnd]) == Array("```mermaid".utf8) else {
                throw NSError(domain: "MermaidFixture", code: 1)
            }
            let payloadStart = lines[lineIndex + 2].end
            guard let closingIndex = lines.indices.dropFirst(lineIndex + 3).first(where: {
                Array(bytes[lines[$0].start..<lines[$0].contentEnd]) == Array("```".utf8)
            }) else { throw NSError(domain: "MermaidFixture", code: 2) }
            let closing = lines[closingIndex]
            let payload = Data(bytes[payloadStart..<closing.start])
            let wrappedEntry = Data(bytes[header.start..<closing.end])
            guard entries[basename] == nil else { throw NSError(domain: "MermaidFixture", code: 3) }
            entries[basename] = WrappedEntry(payload: payload, entry: wrappedEntry)
            lineIndex = closingIndex + 1
        }
        return entries
    }

    private func byteLines(_ bytes: [UInt8]) -> [ByteLine] {
        var lines: [ByteLine] = []
        var index = 0
        while index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
            let contentEnd = index
            if index < bytes.count, bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 {
                index += 2
            } else if index < bytes.count {
                index += 1
            }
            lines.append(ByteLine(start: start, contentEnd: contentEnd, end: index))
        }
        return lines
    }

    private func wrappedPayload(for original: Data) -> Data {
        guard let last = original.last, last != 10, last != 13 else { return original }
        return original + Data([10])
    }

    @MainActor
    private func attachments(in text: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    @MainActor
    private func assertBoundedRuntimeImage(_ image: NSImage, width: Double, file: String,
                                          filePath: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(image.isValid, file, file: filePath, line: line)
        XCTAssertTrue(image.size.width.isFinite && image.size.height.isFinite, file, file: filePath, line: line)
        XCTAssertGreaterThan(image.size.width, 0, file, file: filePath, line: line)
        XCTAssertGreaterThan(image.size.height, 0, file, file: filePath, line: line)
        XCTAssertLessThanOrEqual(image.size.width, CGFloat(width), file, file: filePath, line: line)
        XCTAssertLessThanOrEqual(image.size.height, 1_200, file, file: filePath, line: line)
        XCTAssertLessThanOrEqual(Int(ceil(image.size.width * image.size.height * 4)), 4 * 1_024 * 1_024,
                                 file, file: filePath, line: line)
    }

    @MainActor
    private func assertVisuallyRendered(_ image: NSImage, family: String,
                                        filePath: StaticString = #filePath, line: UInt = #line) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("\(family): rendered image has no pixels", file: filePath, line: line)
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            return XCTFail("\(family): rendered image has no readable pixels", file: filePath, line: line)
        }
        let expected = background.cgColor.components ?? [1, 1, 1, 1]
        var visiblyDifferent = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let components = color.cgColor.components, components.count >= 3 else { continue }
                let delta = abs(components[0] - expected[0]) + abs(components[1] - expected[1])
                    + abs(components[2] - expected[2])
                if delta > 0.12 { visiblyDifferent += 1 }
            }
        }
        let pixelCount = bitmap.pixelsWide * bitmap.pixelsHigh
        XCTAssertGreaterThan(Double(visiblyDifferent) / Double(pixelCount), 0.002,
                             "\(family): image is nearly uniform and may be visually blank", file: filePath, line: line)
    }

    @MainActor
    private func assertBoundedAttachment(_ attachment: NSTextAttachment, width: Double, file: String,
                                        filePath: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(attachment.bounds.width.isFinite && attachment.bounds.height.isFinite, file, file: filePath, line: line)
        XCTAssertGreaterThan(attachment.bounds.width, 0, file, file: filePath, line: line)
        XCTAssertGreaterThan(attachment.bounds.height, 0, file, file: filePath, line: line)
        XCTAssertLessThanOrEqual(attachment.bounds.width, CGFloat(width), file, file: filePath, line: line)
        XCTAssertLessThanOrEqual(attachment.bounds.height, 1_200, file, file: filePath, line: line)
    }
}
