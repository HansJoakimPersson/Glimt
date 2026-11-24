import AppKit
import Foundation
import ImageIO
import InspectorCore
import UniformTypeIdentifiers
import XCTest

final class MarkdownPreviewTests: XCTestCase {
    @MainActor
    func testTextBundleRendersThroughSharedMarkdownPreview() throws {
        let bundleURL = try fixtureURL("Showcase/markdown-family/note.textbundle")
        let preparation = try PreviewInspectionResult.read(at: bundleURL)
        XCTAssertEqual(preparation.formatDefinition?.id, .textbundle)
        XCTAssertEqual(preparation.markdownDocument?.headings.first?.title, "Glimt")

        let controller = makeSizedPreviewController()
        controller.display(preparation)
        try snapshots(controller, tableHeader: "Glimt", tableBody: "Anteckning")
    }

    @MainActor
    func testMathTypesetsSupportedFormsAndKeepsUnsupportedSource() throws {
        let raw = #"Inline $x^2 + \alpha_i$ and \(\frac{a}{b}\)."# +
            "\n\n$$\\sqrt{x} = 2$$\n\n" +
            "\\[\nz^2\n\\]\n\n" +
            "| Result | Note |\n|---|---|\n| $t$ | after |\n\n" +
            #"Bad $\unknowncommand{x}$ and styled $\color{red}{x}$; `$code$`."#
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(
            bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.mathExpressions.count, 7)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var rendered: NSAttributedString?
            appearance.performAsCurrentDrawingAppearance {
                rendered = MarkdownRenderer.render(document, appearance: appearance)
            }
            let output = try XCTUnwrap(rendered)
            var descriptions: [String] = []
            output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      let image = attachment.image else { return }
                descriptions.append(image.accessibilityDescription ?? "")
                XCTAssertGreaterThan(image.size.width, 0)
                XCTAssertGreaterThan(image.size.height, 0)
            }
            XCTAssertEqual(descriptions, ["x^2 + \\alpha_i", "\\frac{a}{b}", "\\sqrt{x} = 2", "z^2", "t"])
            XCTAssertTrue(output.string.contains(#"\unknowncommand{x}"#), output.string)
            XCTAssertTrue(output.string.contains(#"\color{red}{x}"#), output.string)
            XCTAssertTrue(output.string.contains("$code$"), output.string)
        }

        let tooWideSource = "$" + String(repeating: "x", count: 200) + "$"
        let tooWideBytes = Data(tooWideSource.utf8)
        let tooWideDocument = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(
            bytes: tooWideBytes, fileSize: tooWideBytes.count, maximumBytes: tooWideBytes.count))
        let tooWideOutput = MarkdownRenderer.render(tooWideDocument)
        XCTAssertEqual(tooWideDocument.mathExpressions.count, 1)
        XCTAssertTrue(tooWideOutput.string.contains(tooWideSource))
        tooWideOutput.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tooWideOutput.length)) { value, _, _ in
            XCTAssertNil(value, "Oversized formulas stay readable source.")
        }

        let manyMathBytes = Data(String(repeating: "$x$ ", count: 70).utf8)
        let manyMathDocument = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(
            bytes: manyMathBytes, fileSize: manyMathBytes.count, maximumBytes: manyMathBytes.count))
        let manyMathOutput = MarkdownRenderer.render(manyMathDocument)
        XCTAssertEqual(manyMathDocument.mathExpressions.count, 70)
        var renderedFormulaCount = 0
        manyMathOutput.enumerateAttribute(.attachment, in: NSRange(location: 0, length: manyMathOutput.length)) { value, _, _ in
            if value is NSTextAttachment { renderedFormulaCount += 1 }
        }
        XCTAssertEqual(renderedFormulaCount, 64)
        XCTAssertTrue(manyMathOutput.string.contains("$x$"), "Formulas above the render-count cap stay readable.")

        let controller = makeSizedPreviewController()
        controller.display(PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                                                      fileName: "math.md", systemUTI: nil))
        let textView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first)
        let modes = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewTabStrip }.first)
        modes.selectedSegment = 0
        _ = modes.sendAction(modes.action, to: modes.target)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            controller.view.appearance = appearance
            modes.selectedSegment = 1
            _ = modes.sendAction(modes.action, to: modes.target)
            modes.selectedSegment = 0
            _ = modes.sendAction(modes.action, to: modes.target)
            controller.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            appearance.performAsCurrentDrawingAppearance { controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap) }
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                           uniformTypeIdentifier: "public.png")
            attachment.name = "Markdown-Math-\(name.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        var previewAttachments = 0
        textView.textStorage?.enumerateAttribute(.attachment,
            in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)) { value, _, _ in
                if value is NSTextAttachment { previewAttachments += 1 }
            }
        XCTAssertEqual(previewAttachments, 5)
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        let sourceView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(sourceView.textView.string, raw)
        sourceView.textView.textStorage?.enumerateAttribute(.attachment,
            in: NSRange(location: 0, length: sourceView.textView.textStorage?.length ?? 0)) { value, _, _ in
                XCTAssertNil(value, "Raw Markdown stays exact and attachment-free.")
            }
    }

    @MainActor
    func testCodeFencesUseTheSelectedNativeSourceTheme() throws {
        let source = "Body text.\n\n```swift\nlet value = 42\n```\n"
        let bytes = Data(source.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        let configuration = SourceRenderConfiguration(lightTheme: .neutral, darkTheme: .highContrast)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let rendered = MarkdownRenderer.render(document, source: configuration, appearance: appearance)
                let keyword = (rendered.string as NSString).range(of: "let").location
                let preset = configuration.activeTheme(for: appearance)
                let actual = rendered.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor
                let expected = SourceSyntaxColors.color(for: .keyword, preset: preset)
                XCTAssertEqual(actual?.usingColorSpace(.sRGB), expected.usingColorSpace(.sRGB))
                XCTAssertNotNil(rendered.attribute(.backgroundColor, at: keyword, effectiveRange: nil))
                XCTAssertEqual(rendered.string, document.renderedText)
                rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
                    XCTAssertNil(attributes[.link])
                    XCTAssertNil(attributes[.attachment])
                }
            }
        }
    }

    @MainActor
    func testFootnoteReferencesAreSuperscriptAndDefinitionsAreSecondary() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/markdown/footnotes.md"))
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        let configuration = MarkdownRenderConfiguration()
        let rendered = MarkdownRenderer.render(document, configuration: configuration)
        XCTAssertEqual(rendered.string, document.renderedText)
        let text = rendered.string as NSString
        let reference = text.range(of: "[1]")
        let referenceFont = try XCTUnwrap(rendered.attribute(.font, at: reference.location, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(referenceFont.pointSize, CGFloat(configuration.fontSize))
        XCTAssertGreaterThan(try XCTUnwrap(rendered.attribute(.baselineOffset, at: reference.location, effectiveRange: nil) as? CGFloat), 0)
        let definition = text.range(of: "Second note")
        let definitionFont = try XCTUnwrap(rendered.attribute(.font, at: definition.location, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(definitionFont.pointSize, CGFloat(configuration.fontSize))
        XCTAssertNil(rendered.attribute(.baselineOffset, at: definition.location, effectiveRange: nil))
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.link])
        }
    }

    @MainActor
    func testBundledEmojiShortcodesRenderAsInertTextAndKeepRaw() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/markdown/emoji-shortcodes.md"))
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count,
                                                                                    maximumBytes: bytes.count))
        let rendered = MarkdownRenderer.render(document)
        XCTAssertEqual(document.raw, String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(rendered.string, document.renderedText)
        XCTAssertTrue(rendered.string.hasPrefix("😄 ❤️ 🚀 🎉 ⚠️ 👍 :unknown: :smile :smile: :heart:"), rendered.string)
        XCTAssertTrue(rendered.string.contains(":rocket:"), rendered.string)
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.attachment])
        }
    }

    @MainActor
    func testCommonMarkReferencesAutolinksAndEntitiesRenderWithoutActiveLinks() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/markdown/commonmark-inline.md"))
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count,
                                                                                    maximumBytes: bytes.count))
        let rendered = MarkdownRenderer.render(document)
        XCTAssertEqual(document.raw, String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(rendered.string, document.renderedText)
        XCTAssertTrue(rendered.string.contains("https://example.invalid/path reader@example.invalid"))
        XCTAssertTrue(rendered.string.contains("Entities: & © 😀 &not-an-entity;."))
        XCTAssertTrue(rendered.string.contains("Escapes: *literal* and > marker."))
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.attachment])
        }
    }

    @MainActor
    func testContinuedDefinitionRendersInlineStylesInSharedMarkdownRenderer() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/markdown/definition-lists.md"))
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count,
                                                                                    maximumBytes: bytes.count))
        let rendered = MarkdownRenderer.render(document)
        XCTAssertEqual(document.raw, String(decoding: bytes, as: UTF8.self))
        let definition = try XCTUnwrap(document.definitionLists.first?.definitionRanges.first)
        let text = rendered.string as NSString
        XCTAssertTrue(text.substring(with: definition).contains("Continued with emphasis and code."))
        let emphasis = text.range(of: "emphasis")
        let traits = rendered.attribute(.font, at: emphasis.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(traits?.fontDescriptor.symbolicTraits.contains(.italic), true)
        let code = text.range(of: "code", options: [], range: NSRange(location: text.range(of: "Continued").location, length: text.length - text.range(of: "Continued").location))
        let codeFont = try XCTUnwrap(rendered.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(codeFont.fontName.localizedCaseInsensitiveContains("mono"))
    }

    @MainActor
    func testCodeFencesUseCustomSourcePaletteAndCoreOptionsStayInert() throws {
        let raw = "---\ntitle: Metadata\n---\n# Title\n\n- [x] Done\n\n~~Removed~~\n\n```swift\nlet value = 42\n```\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count),
            options: .init(taskLists: false, strikethrough: false, frontMatter: .hide, tableOfContents: true))
        let black = SourceThemeColor(red: 0, green: 0, blue: 0)
        let white = SourceThemeColor(red: 1, green: 1, blue: 1)
        let accent = SourceThemeColor(red: 0.7, green: 0, blue: 0.3)
        let palette = SourceThemePalette(background: white, foreground: black, comment: black,
            keyword: accent, string: black, number: black, type: black, directive: black)
        let configuration = SourceRenderConfiguration(lightPalette: palette, darkPalette: palette)
        let rendered = MarkdownRenderer.render(document, source: configuration)
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(rendered.string, document.renderedText)
        XCTAssertTrue(rendered.string.contains("Contents"))
        XCTAssertTrue(rendered.string.contains("[x] Done"))
        XCTAssertFalse(rendered.string.contains("Metadata"))
        let keyword = (rendered.string as NSString).range(of: "let").location
        let actual = rendered.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor
        XCTAssertEqual(actual?.usingColorSpace(.sRGB), SourceSyntaxColors.color(for: .keyword, palette: palette).usingColorSpace(.sRGB))
        var links: [URL] = []
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            if let link = attributes[.link] as? URL { links.append(link) }
            XCTAssertNil(attributes[.attachment]); XCTAssertNil(attributes[.strikethroughStyle])
        }
        XCTAssertEqual(links.count, document.navigationLinks.count)
        XCTAssertTrue(links.allSatisfy { $0.scheme == "glimt-anchor" && $0.host == "heading" })
    }

    @MainActor
    func testNativeTablesHaveHeadersPaddingSeparatorsAndPreservedCellStyles() throws {
        let raw = "Before **bold**.\n\n| Name | Value |\n|---|---|\n| *one* | `two` |\n| | [safe](https://example.invalid) |\n\nAfter.\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var appearanceResult: NSAttributedString?
            appearance.performAsCurrentDrawingAppearance { appearanceResult = MarkdownRenderer.render(document, appearance: appearance) }
            let rendered = try XCTUnwrap(appearanceResult)
            let text = rendered.string as NSString
            var blocks: [NSTextTableBlock] = []
            for word in ["Name", "Value", "one", "two", "safe"] {
                let range = text.range(of: word)
                XCTAssertNotEqual(range.location, NSNotFound)
                let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
                let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
                blocks.append(block)
                XCTAssertEqual(block.table.numberOfColumns, 2)
                XCTAssertGreaterThan(block.width(for: .padding, edge: .minX), 0)
                XCTAssertGreaterThan(block.width(for: .border, edge: .maxY), 0)
            }
            XCTAssertEqual(blocks.map(\.startingColumn), [0, 1, 0, 1, 1])
            XCTAssertEqual(blocks.map(\.startingRow), [0, 0, 1, 1, 2])
            XCTAssertTrue(blocks.allSatisfy { $0.table === blocks[0].table })
            XCTAssertNotNil(blocks[0].backgroundColor)
            XCTAssertNotEqual(blocks[0].backgroundColor, blocks[2].backgroundColor)
            XCTAssertTrue(rendered.string.contains("Before bold."))
            XCTAssertTrue(rendered.string.contains("After."))
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
                XCTAssertNil(attributes[.link]); XCTAssertNil(attributes[.attachment])
            }
            let italicIndex = text.range(of: "one").location
            let italicFont = try XCTUnwrap(rendered.attribute(.font, at: italicIndex, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
            let codeFont = try XCTUnwrap(rendered.attribute(.font, at: text.range(of: "two").location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(codeFont.fontName, SourceRenderConfiguration().resolvedFont().fontName)
            XCTAssertEqual(document.raw, raw)
        }
    }

    @MainActor
    func testAlertsHaveReadableColoredTitlesAndALeadingBorder() throws {
        let raw = "> [!WARNING]\n> Body text.\n\n> Plain quote.\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let rendered = MarkdownRenderer.render(document, appearance: appearance)
            let text = rendered.string as NSString
            let title = text.range(of: "Warning").location
            let titleFont = try XCTUnwrap(rendered.attribute(.font, at: title, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: titleFont).contains(.boldFontMask))
            let titleColor = try XCTUnwrap(rendered.attribute(.foregroundColor, at: title, effectiveRange: nil) as? NSColor)
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(titleColor, .textBackgroundColor), 4.5)
                XCTAssertNotEqual(titleColor.usingColorSpace(.sRGB), NSColor.textColor.usingColorSpace(.sRGB))
            }
            for needle in ["Warning", "Body text."] {
                let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: text.range(of: needle).location, effectiveRange: nil) as? NSParagraphStyle)
                let block = try XCTUnwrap(style.textBlocks.first)
                XCTAssertGreaterThan(block.width(for: .border, edge: .minX), 0)
                XCTAssertEqual(block.width(for: .border, edge: .maxX), 0)
                XCTAssertNotNil(block.borderColor(for: .minX))
            }
            let plain = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: text.range(of: "Plain quote.").location, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertTrue(plain.textBlocks.isEmpty)
            XCTAssertFalse(text.substring(to: text.range(of: "Plain").location).contains("> Body"))
        }
    }

    @MainActor
    func testAdmonitionsReuseAlertStylesAndWrap() throws {
        let longText = String(repeating: "A bounded admonition body wraps inside its native alert block. ", count: 4)
        let body = "\(longText) **bold** *italic* ~~strike~~ `code` ==highlight== x^2^ [^n]\n\nSecond paragraph."
        let tail = "\n\nOutside.\n\nTerm\n: definition\n\n| Name | Value |\n|---|---|\n| one | two |\n\n[^n]: Footnote text.\n"
        let sourceConfiguration = SourceRenderConfiguration()
        for kind in MarkdownAlertKind.allCases {
            let upper = kind.rawValue.uppercased()
            let admonitionBody = body.components(separatedBy: "\n").map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n")
            let alertBody = body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
            let admonitionRaw = "!!! \(kind.rawValue)\n\(admonitionBody)\(tail)"
            let alertRaw = "> [!\(upper)]\n\(alertBody)\(tail)"
            func inspect(_ raw: String) throws -> MarkdownDocument {
                let bytes = Data(raw.utf8)
                return try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
            }
            let admonition = try inspect(admonitionRaw)
            let github = try inspect(alertRaw)
            XCTAssertEqual(admonition.raw, admonitionRaw)
            XCTAssertEqual(admonition.alerts.map(\.kind), [kind])
            XCTAssertEqual(admonition.renderedText, github.renderedText)
            XCTAssertEqual(admonition.alerts, github.alerts)
            XCTAssertEqual(admonition.runs, github.runs)
            XCTAssertEqual(admonition.definitionLists.count, 1)

            for profile in [MarkdownProfile.default, .compact, .reading] {
                for name in [NSAppearance.Name.aqua, .darkAqua] {
                    let appearance = try XCTUnwrap(NSAppearance(named: name))
                    var admonitionResult: NSAttributedString?
                    var githubResult: NSAttributedString?
                    appearance.performAsCurrentDrawingAppearance {
                        let configuration = MarkdownRenderConfiguration(fontSize: 16, profile: profile)
                        admonitionResult = MarkdownRenderer.render(admonition, configuration: configuration,
                                                                   source: sourceConfiguration, appearance: appearance)
                        githubResult = MarkdownRenderer.render(github, configuration: configuration,
                                                               source: sourceConfiguration, appearance: appearance)
                    }
                    let rendered = try XCTUnwrap(admonitionResult)
                    let comparison = try XCTUnwrap(githubResult)
                    XCTAssertEqual(rendered.string, comparison.string)
                    let text = rendered.string as NSString
                    let alert = try XCTUnwrap(admonition.alerts.first)
                    let titleLocation = text.range(of: kind.title).location
                    let bodyLocation = text.range(of: longText.prefix(20).description).location
                    let secondLocation = text.range(of: "Second paragraph.").location
                    let outsideLocation = text.range(of: "Outside.").location
                    let titleFont = try XCTUnwrap(rendered.attribute(.font, at: titleLocation, effectiveRange: nil) as? NSFont)
                    XCTAssertTrue(NSFontManager.shared.traits(of: titleFont).contains(.boldFontMask))
                    let titleColor = try XCTUnwrap(rendered.attribute(.foregroundColor, at: titleLocation, effectiveRange: nil) as? NSColor)
                    appearance.performAsCurrentDrawingAppearance {
                        XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(titleColor, .textBackgroundColor), 4.5)
                    }
                    let edges: [NSRectEdge] = [.minX, .maxX, .minY, .maxY]
                    let layers: [NSTextBlock.Layer] = [.border, .padding]
                    for location in [titleLocation, bodyLocation, secondLocation] {
                        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
                        let block = try XCTUnwrap(style.textBlocks.first)
                        let equivalentStyle = try XCTUnwrap(comparison.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
                        let equivalentBlock = try XCTUnwrap(equivalentStyle.textBlocks.first)
                        XCTAssertEqual(block.contentWidth, 100)
                        XCTAssertEqual(block.contentWidthValueType, .percentageValueType)
                        XCTAssertEqual(block.contentWidth, equivalentBlock.contentWidth)
                        XCTAssertEqual(block.contentWidthValueType, equivalentBlock.contentWidthValueType)
                        for layer in layers {
                            for edge in edges {
                                XCTAssertEqual(block.width(for: layer, edge: edge), equivalentBlock.width(for: layer, edge: edge))
                                XCTAssertEqual(block.widthValueType(for: layer, edge: edge), equivalentBlock.widthValueType(for: layer, edge: edge))
                            }
                        }
                        for edge in edges {
                            XCTAssertEqual(block.borderColor(for: edge)?.usingColorSpace(.sRGB),
                                           equivalentBlock.borderColor(for: edge)?.usingColorSpace(.sRGB))
                        }
                        XCTAssertEqual(style.paragraphSpacing, equivalentStyle.paragraphSpacing)
                        XCTAssertEqual(style.paragraphSpacingBefore, equivalentStyle.paragraphSpacingBefore)
                        XCTAssertTrue(style.textBlocks.first === rendered.attribute(.paragraphStyle, at: titleLocation, effectiveRange: nil)
                            .flatMap { ($0 as? NSParagraphStyle)?.textBlocks.first })
                        XCTAssertTrue(equivalentStyle.textBlocks.first === comparison.attribute(.paragraphStyle, at: titleLocation, effectiveRange: nil)
                            .flatMap { ($0 as? NSParagraphStyle)?.textBlocks.first })
                    }
                    let outsideStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: outsideLocation, effectiveRange: nil) as? NSParagraphStyle)
                    XCTAssertTrue(outsideStyle.textBlocks.isEmpty)
                    let termLocation = text.range(of: "Term").location
                    let termStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: termLocation, effectiveRange: nil) as? NSParagraphStyle)
                    XCTAssertEqual(termStyle.firstLineHeadIndent, 0)
                    XCTAssertEqual(termStyle.headIndent, 0)
                    let definitionStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: text.range(of: "definition").location, effectiveRange: nil) as? NSParagraphStyle)
                    XCTAssertEqual(definitionStyle.firstLineHeadIndent, 16)
                    XCTAssertEqual(definitionStyle.headIndent, 16)
                    XCTAssertTrue(definitionStyle.textBlocks.isEmpty)
                    let tableStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: text.range(of: "one").location, effectiveRange: nil) as? NSParagraphStyle)
                    XCTAssertTrue(tableStyle.textBlocks.first is NSTextTableBlock)
                    for needle in ["bold", "italic", "strike", "code", "highlight", "x2", "[1]"] {
                        let location = text.range(of: needle).location
                        let left = rendered.attributes(at: location, effectiveRange: nil)
                        let right = comparison.attributes(at: location, effectiveRange: nil)
                        XCTAssertEqual(left[.font] as? NSFont, right[.font] as? NSFont, needle)
                        XCTAssertEqual((left[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
                                       (right[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB), needle)
                        XCTAssertEqual(left[.backgroundColor] as? NSColor, right[.backgroundColor] as? NSColor, needle)
                        XCTAssertEqual(left[.baselineOffset] as? CGFloat, right[.baselineOffset] as? CGFloat, needle)
                        XCTAssertEqual(left[.strikethroughStyle] as? Int, right[.strikethroughStyle] as? Int, needle)
                    }
                    rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
                        XCTAssertNil(attributes[.link])
                        XCTAssertNil(attributes[.attachment])
                    }
                    XCTAssertEqual(alert.range, github.alerts.first?.range)
                }
            }

            let preview = StructuredTextPreview(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
            preview.textView.frame = preview.bounds
            preview.textView.textStorage?.setAttributedString(MarkdownRenderer.render(admonition, configuration: .init(fontSize: 16)))
            XCTAssertNil(preview.textView.textLayoutManager)
            let layout = try XCTUnwrap(preview.textView.layoutManager)
            let container = try XCTUnwrap(preview.textView.textContainer)
            let text = preview.textView.string as NSString
            let first = text.range(of: longText.prefix(20).description).location
            let wrapped = text.range(of: "inside its native").location
            let firstGlyph = layout.glyphRange(forCharacterRange: NSRange(location: first, length: 1), actualCharacterRange: nil).location
            let wrappedGlyph = layout.glyphRange(forCharacterRange: NSRange(location: wrapped, length: 1), actualCharacterRange: nil).location
            let firstLine = layout.lineFragmentUsedRect(forGlyphAt: firstGlyph, effectiveRange: nil)
            let wrappedLine = layout.lineFragmentUsedRect(forGlyphAt: wrappedGlyph, effectiveRange: nil)
            XCTAssertGreaterThan(wrappedLine.minY, firstLine.minY)
            XCTAssertEqual(wrappedLine.minX, firstLine.minX, accuracy: 1)
            for needle in ["Second paragraph.", "Outside."] {
                let location = text.range(of: needle).location
                let style = try XCTUnwrap(preview.textView.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
                if needle == "Second paragraph." { XCTAssertFalse(style.textBlocks.isEmpty) }
                else { XCTAssertTrue(style.textBlocks.isEmpty) }
            }
            _ = container // Keeps the TextKit 1 container alive while querying layout.
        }
    }

    @MainActor
    func testHighlightKeepsReadableTextOnAYellowBackground() throws {
        let raw = "Plain ==marked *word*== and `==code==`.\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let rendered = MarkdownRenderer.render(document, appearance: appearance)
            let text = rendered.string as NSString
            for needle in ["marked", "word"] {
                let background = try XCTUnwrap(rendered.attribute(.backgroundColor, at: text.range(of: needle).location, effectiveRange: nil) as? NSColor)
                let foreground = try XCTUnwrap(rendered.attribute(.foregroundColor, at: text.range(of: needle).location, effectiveRange: nil) as? NSColor)
                appearance.performAsCurrentDrawingAppearance {
                    XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(foreground, background), 4.5)
                    XCTAssertNotEqual(background.usingColorSpace(.sRGB), NSColor.textBackgroundColor.usingColorSpace(.sRGB))
                }
            }
            XCTAssertNil(rendered.attribute(.backgroundColor, at: text.range(of: "Plain").location, effectiveRange: nil))
            let code = try XCTUnwrap(rendered.attribute(.backgroundColor, at: text.range(of: "==code==").location, effectiveRange: nil) as? NSColor)
            XCTAssertNotEqual(code, MarkdownRenderer.highlightBackground)
        }
    }

    @MainActor
    func testHashtagsUseAReadableAccentOutsideLinks() throws {
        let raw = "Plain #tag, ==hot #lit== and [link #linked](https://example.com).\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let rendered = MarkdownRenderer.render(document, appearance: appearance)
            let text = rendered.string as NSString
            let tag = try XCTUnwrap(rendered.attribute(.foregroundColor, at: text.range(of: "#tag").location, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(tag, MarkdownRenderer.hashtagColor)
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(tag, .textBackgroundColor), 4.5)
            }
            XCTAssertNil(rendered.attribute(.link, at: text.range(of: "#tag").location, effectiveRange: nil))
            let lit = try XCTUnwrap(rendered.attribute(.foregroundColor, at: text.range(of: "#lit").location, effectiveRange: nil) as? NSColor)
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(lit, MarkdownRenderer.highlightBackground), 4.5)
            }
            let linked = rendered.attribute(.foregroundColor, at: text.range(of: "#linked").location, effectiveRange: nil) as? NSColor
            XCTAssertNotEqual(linked, MarkdownRenderer.hashtagColor)
        }
    }

    @MainActor
    func testWikilinksRenderAsInertPlainLabels() throws {
        let raw = "Go [[Home]] or [[Notes#Part|the *guide*]] now.\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        let rendered = MarkdownRenderer.render(document)
        XCTAssertEqual(rendered.string, "Go Home or the guide now.")
        let text = rendered.string as NSString
        let plain = rendered.attributes(at: text.range(of: "Go").location, effectiveRange: nil)
        for needle in ["Home", "the"] {
            let attributes = rendered.attributes(at: text.range(of: needle).location, effectiveRange: nil)
            XCTAssertNil(attributes[.link])
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, plain[.foregroundColor] as? NSColor)
            XCTAssertEqual(attributes[.font] as? NSFont, plain[.font] as? NSFont)
        }
    }

    @MainActor
    func testDefinitionListsPreserveStylesAndWrap() throws {
        let longDefinition = "A definition with enough words to wrap repeatedly in the narrow preview while keeping every continuation aligned with its first line and preserving ordinary body typography. " +
            String(repeating: "Wrapping remains stable across the selected reading profile. ", count: 3)
        let raw = "Term 😀 **bold *italic*** `code` ==highlighted== x^2^ [^note]\n: \(longDefinition)\n\n| Name | Value |\n|---|---|\n| one | two |\n\nAfter.\n\n[^note]: Footnote text.\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.definitionLists.count, 1)
        let source = SourceRenderConfiguration()
        let text = try XCTUnwrap(document.renderedText) as NSString
        let group = try XCTUnwrap(document.definitionLists.first)
        XCTAssertEqual(text.substring(with: group.termRange), "Term 😀 bold italic code highlighted x2 [1]")
        XCTAssertEqual(text.substring(with: group.definitionRanges[0]), longDefinition)

        for (profile, spacing, lineSpacing) in [
            (MarkdownProfile.default, CGFloat(4), CGFloat(0)),
            (.compact, CGFloat(0), CGFloat(0)),
            (.reading, CGFloat(8), CGFloat(2))
        ] {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                var renderedResult: NSAttributedString?
                appearance.performAsCurrentDrawingAppearance {
                    renderedResult = MarkdownRenderer.render(document, configuration: .init(fontSize: 16, profile: profile),
                                                             source: source, appearance: appearance)
                }
                let rendered = try XCTUnwrap(renderedResult)
                let body = text.range(of: "Term").location
                let bold = text.range(of: "bold").location
                let italic = text.range(of: "italic").location
                let code = text.range(of: "code").location
                let highlighted = text.range(of: "highlighted").location
                let superscript = text.range(of: "x2").location + 1
                let reference = text.range(of: "[1]").location
                func font(_ location: Int) throws -> NSFont {
                    try XCTUnwrap(rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
                }
                XCTAssertTrue(NSFontManager.shared.traits(of: try font(body)).contains(.boldFontMask))
                XCTAssertTrue(NSFontManager.shared.traits(of: try font(bold)).contains(.boldFontMask))
                XCTAssertTrue(NSFontManager.shared.traits(of: try font(italic)).contains(.italicFontMask))
                XCTAssertEqual(try font(code).fontName, source.resolvedFont(weight: .bold).fontName)
                XCTAssertNotNil(rendered.attribute(.backgroundColor, at: highlighted, effectiveRange: nil))
                XCTAssertEqual(try font(superscript).pointSize, 12, accuracy: 0.01)
                XCTAssertTrue(NSFontManager.shared.traits(of: try font(superscript)).contains(.boldFontMask))
                XCTAssertEqual(rendered.attribute(.baselineOffset, at: superscript, effectiveRange: nil) as? CGFloat, 16 * 0.35)
                XCTAssertEqual(try font(reference).pointSize, 12, accuracy: 0.01)
                XCTAssertFalse(NSFontManager.shared.traits(of: try font(reference)).contains(.boldFontMask))
                XCTAssertEqual(rendered.attribute(.baselineOffset, at: reference, effectiveRange: nil) as? CGFloat, 16 * 0.35)
                let termStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: body, effectiveRange: nil) as? NSParagraphStyle)
                let definitionIndex = text.range(of: "A definition").location
                let definitionStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: definitionIndex, effectiveRange: nil) as? NSParagraphStyle)
                XCTAssertEqual(termStyle.firstLineHeadIndent, 0)
                XCTAssertEqual(termStyle.headIndent, 0)
                XCTAssertEqual(definitionStyle.firstLineHeadIndent, 16)
                XCTAssertEqual(definitionStyle.headIndent, 16)
                XCTAssertEqual(definitionStyle.paragraphSpacing, spacing)
                XCTAssertEqual(definitionStyle.lineSpacing, lineSpacing)
                let foreground = try XCTUnwrap(rendered.attribute(.foregroundColor, at: definitionIndex, effectiveRange: nil) as? NSColor)
                let background = NSColor.textBackgroundColor
                appearance.performAsCurrentDrawingAppearance {
                    XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(foreground, background), 4.5)
                }
                let tableCell = text.range(of: "one").location
                let tableStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: tableCell, effectiveRange: nil) as? NSParagraphStyle)
                XCTAssertTrue(tableStyle.textBlocks.first is NSTextTableBlock)
                rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
                    XCTAssertNil(attributes[.link]); XCTAssertNil(attributes[.attachment])
                }
            }
        }

        let preview = StructuredTextPreview(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        preview.textView.frame = preview.bounds
        preview.textView.textStorage?.setAttributedString(MarkdownRenderer.render(document, configuration: .init(fontSize: 16)))
        let layout = try XCTUnwrap(preview.textView.layoutManager)
        _ = try XCTUnwrap(preview.textView.textContainer)
        let renderedText = preview.textView.string as NSString
        let termLocation = renderedText.range(of: "Term").location
        let firstDefinitionLocation = renderedText.range(of: "A definition").location
        let wrappedWordLocation = renderedText.range(of: "continuation").location
        func lineRect(_ location: Int) -> NSRect {
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil).location
            return layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        XCTAssertEqual(lineRect(termLocation).minX, 0, accuracy: 1)
        XCTAssertEqual(lineRect(firstDefinitionLocation).minX - lineRect(termLocation).minX, 16, accuracy: 1)
        XCTAssertEqual(lineRect(wrappedWordLocation).minX, lineRect(firstDefinitionLocation).minX, accuracy: 1)
    }

    @MainActor
    func testSuperscriptAndSubscriptAreSmallerAndShiftedKeepingTraits() throws {
        let raw = "Body x^2^ and H<sub>2</sub>O and **a<sup>bold</sup>**.\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        let rendered = MarkdownRenderer.render(document, configuration: .init(fontSize: 16))
        let text = rendered.string as NSString
        func font(_ location: Int) throws -> NSFont { try XCTUnwrap(rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont) }
        func offset(_ location: Int) -> CGFloat { rendered.attribute(.baselineOffset, at: location, effectiveRange: nil) as? CGFloat ?? 0 }
        let superscript = text.range(of: "x2").location + 1
        let subscriptDigit = text.range(of: "H2O").location + 1
        let bold = text.range(of: "bold").location
        XCTAssertEqual(try font(superscript).pointSize, 12, accuracy: 0.01)
        XCTAssertEqual(offset(superscript), 16 * 0.35, accuracy: 0.01)
        XCTAssertEqual(try font(subscriptDigit).pointSize, 12, accuracy: 0.01)
        XCTAssertEqual(offset(subscriptDigit), -16 * 0.15, accuracy: 0.01)
        XCTAssertTrue(NSFontManager.shared.traits(of: try font(bold)).contains(.boldFontMask))
        XCTAssertGreaterThan(offset(bold), 0)
        XCTAssertEqual(try font(text.range(of: "Body").location).pointSize, 16, accuracy: 0.01)
        XCTAssertEqual(offset(text.range(of: "Body").location), 0)
    }

    /// Attribute checks alone cannot see this: TextKit 2 ignores NSTextTable/NSTextBlock layout.
    @MainActor
    func testPreviewSurfaceLaysOutTablesAndAlertBlocks() throws {
        let raw = "| A | B |\n|---|---|\n| one | two |\n\n> [!TIP]\n> Inside.\n\nOutside.\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        let preview = StructuredTextPreview(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        preview.textView.frame = preview.bounds
        preview.textView.textStorage?.setAttributedString(MarkdownRenderer.render(document))
        XCTAssertNil(preview.textView.textLayoutManager)
        let layout = try XCTUnwrap(preview.textView.layoutManager)
        let container = try XCTUnwrap(preview.textView.textContainer)
        let text = preview.textView.string as NSString
        func rect(_ needle: String) -> NSRect {
            let glyphs = layout.glyphRange(forCharacterRange: text.range(of: needle), actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: container)
        }
        XCTAssertEqual(rect("one").midY, rect("two").midY, accuracy: 1)
        XCTAssertGreaterThan(rect("two").minX, rect("one").maxX)
        XCTAssertGreaterThan(rect("Inside.").minX, rect("Outside.").minX + 8)
    }

    @MainActor
    func testNestedListsHangUnderTheirParentText() throws {
        let raw = "1. parent\n   - [ ] child\n\n     more child\n2. next\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        let rendered = MarkdownRenderer.render(document)
        let text = rendered.string as NSString
        func style(_ needle: String) throws -> NSParagraphStyle {
            try XCTUnwrap(rendered.attribute(.paragraphStyle, at: text.range(of: needle).location, effectiveRange: nil) as? NSParagraphStyle)
        }
        let parent = try style("parent"), child = try style("child"), more = try style("more child"), next = try style("next")
        XCTAssertEqual(parent.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(parent.headIndent, 0)
        XCTAssertEqual(child.firstLineHeadIndent, parent.headIndent, accuracy: 0.01)
        XCTAssertGreaterThan(child.headIndent, child.firstLineHeadIndent)
        XCTAssertEqual(more.firstLineHeadIndent, child.headIndent, accuracy: 0.01)
        XCTAssertEqual(more.headIndent, child.headIndent, accuracy: 0.01)
        XCTAssertEqual(next.firstLineHeadIndent, 0)
        XCTAssertEqual(next.headIndent, parent.headIndent, accuracy: 0.01)
    }

    @MainActor
    func testTasksStaySingleReadOnlyMarkersInBothAppearances() throws {
        let raw = "- [ ] todo\n- [x] done\n- ordinary\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let rendered = MarkdownRenderer.render(document, appearance: try XCTUnwrap(NSAppearance(named: name)))
            XCTAssertFalse(rendered.string.contains("• ☐")); XCTAssertFalse(rendered.string.contains("• ☑"))
            XCTAssertTrue(rendered.string.contains("• ordinary"))
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
                XCTAssertNil(attributes[.attachment]); XCTAssertNil(attributes[.link])
            }
            XCTAssertEqual(document.raw, raw)
        }
    }

    @MainActor
    func testConfiguredTypographyProfilesAndCodeFont() throws {
        let source = "# Title\n\nBody text.\n\n```swift\nlet value = 42\n```\n"
        let bytes = Data(source.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        let sourceConfiguration = SourceRenderConfiguration(fontFamily: "Menlo", fontSize: 20)
        for (profile, spacing, lineSpacing, headingMultiplier): (MarkdownProfile, CGFloat, CGFloat, CGFloat) in [
            (.default, 4, 0, 1), (.compact, 0, 0, 0.9), (.reading, 8, 2, 1.1)
        ] {
            let rendered = MarkdownRenderer.render(document, configuration: .init(fontSize: 17, profile: profile), source: sourceConfiguration)
            let text = rendered.string as NSString
            let body = text.range(of: "Body").location
            let heading = text.range(of: "Title").location
            let code = text.range(of: "let").location
            let bodyFont = try XCTUnwrap(rendered.attribute(.font, at: body, effectiveRange: nil) as? NSFont)
            let headingFont = try XCTUnwrap(rendered.attribute(.font, at: heading, effectiveRange: nil) as? NSFont)
            let codeFont = try XCTUnwrap(rendered.attribute(.font, at: code, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(bodyFont.pointSize, 17)
            XCTAssertEqual(headingFont.pointSize, NSFont.preferredFont(forTextStyle: .title1).pointSize * 17 / 13 * headingMultiplier, accuracy: 0.01)
            XCTAssertEqual(codeFont.pointSize, 20)
            XCTAssertEqual(codeFont.fontName, sourceConfiguration.resolvedFont().fontName)
            let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: body, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(paragraph.paragraphSpacing, spacing)
            XCTAssertEqual(paragraph.lineSpacing, lineSpacing)
            XCTAssertEqual(rendered.string, document.renderedText)
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
                XCTAssertNil(attributes[.link])
                XCTAssertNil(attributes[.attachment])
            }
        }

        let customRaw = "!!! warning \"Build status\"\n    Running slowly."
        let customBytes = Data(customRaw.utf8)
        let custom = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: customBytes, fileSize: customBytes.count,
                                                                                   maximumBytes: customBytes.count))
        XCTAssertEqual(custom.raw, customRaw)
        XCTAssertEqual(custom.alerts.first?.title, "Build status")
        let customRendered = MarkdownRenderer.render(custom)
        XCTAssertEqual(customRendered.string, "Build status\nRunning slowly.")
        let titleRange = (customRendered.string as NSString).range(of: "Build status")
        XCTAssertNotNil(customRendered.attribute(.foregroundColor, at: titleRange.location, effectiveRange: nil))
        customRendered.enumerateAttributes(in: NSRange(location: 0, length: customRendered.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.attachment])
        }
    }

    @MainActor
    func testSharedMarkdownRoutingModesAndInertAttributes() throws {
        for name in ["basic", "headings", "lists", "links", "blockquote", "inline-code", "fenced-code", "gfm", "comprehensive"] {
            let url = try fixtureURL(name == "comprehensive" ? "Showcase/markdown/markdown.md" : "Cases/markdown/\(name).md")
            let result = try PreviewPreparation.read(at: url, markdownOptions: .init(tableOfContents: name == "comprehensive"))
            let document = try XCTUnwrap(result.markdownDocument)
            if name == "comprehensive" {
                XCTAssertEqual(document.alerts.first(where: { $0.kind == .tip })?.title, "A short tip")
                XCTAssertEqual(document.navigationLinks.count, document.headings.count + 1)
            }
            XCTAssertEqual(result.sourceDocument?.language, .markdown)
            XCTAssertEqual(result.sourceDocument?.source, document.raw)
            if name == "headings" || name == "comprehensive" {
                XCTAssertTrue(result.sourceDocument?.highlighting.runs.contains { $0.kind == .keyword } == true)
            }
            if name == "inline-code" {
                XCTAssertTrue(result.sourceDocument?.highlighting.runs.contains { $0.kind == .string } == true)
            }
            if name == "fenced-code" {
                XCTAssertTrue(result.sourceDocument?.highlighting.runs.contains { $0.kind == .directive } == true)
            }
            XCTAssertNil(result.yamlInspection)
            let controller = makeSizedPreviewController()
            controller.display(result)
            let views = descendants(controller.view)
            let control = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
            let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
            XCTAssertEqual(control.segmentCount, 2)
            XCTAssertEqual(control.label(forSegment: 0), "Rendered")
            XCTAssertEqual(control.label(forSegment: 1), "Source")
            XCTAssertEqual(text.string, MarkdownRenderer.render(document).string)
            XCTAssertEqual(text.accessibilityLabel(), "Rendered Markdown")
            let attributed = try XCTUnwrap(text.textStorage)
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, _ in
                if let link = attributes[.link] as? URL {
                    XCTAssertEqual(link.scheme, "glimt-anchor")
                    XCTAssertEqual(link.host, "heading")
                } else {
                    XCTAssertNil(attributes[.link])
                }
                XCTAssertNil(attributes[.attachment])
            }
            if name == "comprehensive" {
                let navigation = try XCTUnwrap(document.navigationLinks.first)
                let directRendered = MarkdownRenderer.render(document)
                XCTAssertNotNil(directRendered.attribute(.link, at: navigation.range.location, effectiveRange: nil),
                                "Renderer must attach the internal destination to this fragment link.")
                let destination = try XCTUnwrap(attributed.attribute(.link, at: navigation.range.location, effectiveRange: nil) as? URL)
                XCTAssertEqual(destination.path, "/\(navigation.headingIndex)")
                XCTAssertNil(destination.query)
                XCTAssertNil(destination.fragment)
                XCTAssertTrue(document.headings.indices.contains(navigation.headingIndex))
                XCTAssertGreaterThan(document.headings[navigation.headingIndex].range.length, 0)
                XCTAssertTrue(text.isSelectable, "Native link attributes remain keyboard/accessibility discoverable.")
                let controller = try XCTUnwrap(text.delegate as? SharedPreviewViewController)
                let selectionBeforeNavigation = text.selectedRange()
                XCTAssertTrue(controller.navigateToMarkdownHeading(link: destination, characterIndex: navigation.range.location, in: text),
                              "The controller consumes a local destination and never opens the URL.")
                XCTAssertFalse(controller.textView(text, clickedOnLink: destination, at: navigation.range.location),
                               "The text-view delegate blocks system URL opening.")
                XCTAssertEqual(text.selectedRange(), selectionBeforeNavigation,
                               "Following a fragment must not move the document insertion point.")
                _ = try XCTUnwrap(document.renderedText)
                let fragmentLocation = (directRendered.string as NSString).range(of: "inline syntax").location
                XCTAssertNotEqual(fragmentLocation, NSNotFound)
                XCTAssertNotNil(directRendered.attribute(.link, at: fragmentLocation,
                                                                      effectiveRange: nil),
                                "The source fragment range must receive an internal attribute during rendering.")
                let fragmentDestination = try XCTUnwrap(attributed.attribute(.link, at: fragmentLocation,
                                                                              effectiveRange: nil) as? URL,
                    "The rendered source fragment must carry its internal destination.")
                let selectionBeforeFragment = text.selectedRange()
                XCTAssertTrue(controller.navigateToMarkdownHeading(link: fragmentDestination,
                                                                   characterIndex: fragmentLocation, in: text))
                XCTAssertEqual(text.selectedRange(), selectionBeforeFragment,
                               "Fragment navigation preserves the text view's keyboard selection.")
            }
            control.selectedSegment = 1
            _ = control.sendAction(control.action, to: control.target)
            let sourceView = try XCTUnwrap(views.compactMap { $0 as? SourceCodeView }.first)
            XCTAssertFalse(sourceView.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(sourceView.textView.string, document.raw)
            if name == "comprehensive" {
                sourceView.textView.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: sourceView.textView.textStorage?.length ?? 0)) { value, _, _ in
                    XCTAssertNil(value, "Source Markdown must not retain navigation attributes.")
                }
            }
            control.selectedSegment = 0
            _ = control.sendAction(control.action, to: control.target)
            XCTAssertEqual(text.string, MarkdownRenderer.render(document).string)
            if name == "gfm" { try snapshots(controller) }
            if name == "comprehensive" { try snapshots(controller, tableHeader: "Preview", tableBody: "Rendered / Source") }
        }
    }

    @MainActor
    func testAPIBlueprintAndCursorMDCUseTheSharedMarkdownPreview() throws {
        for (path, expectedText) in [
            ("Showcase/markdown/api.apib", "Glimt API"),
            ("Showcase/markdown/rule.mdc", "Project conventions")
        ] {
            let result = try PreviewPreparation.read(at: fixtureURL(path))
            XCTAssertNotNil(result.markdownDocument, path)
            XCTAssertEqual(result.formatDefinition?.inspectionKind, .markdown, path)
            let configuration = RenderConfiguration(settings: GlimtSettingsV3.factoryDefaults)
            let configured = configuration.configuredViews(for: result.formatDefinition?.id)
            XCTAssertTrue(configured.contains(.rendered), "Rendered is the factory default for \(path)")
            let controller = makeSizedPreviewController(configuration: configuration)
            controller.display(result)
            let views = descendants(controller.view)
            let rendered = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Rendered Markdown" }, path)
            XCTAssertTrue(rendered.string.contains(expectedText), path)
            XCTAssertFalse(rendered.string.contains("# \(expectedText)"), path)
            if path.hasSuffix("rule.mdc") {
                XCTAssertTrue(rendered.string.contains("Swift source conventions"), path)
            }
        }
    }

    @MainActor
    func testLocalMarkdownImagesAttachOnlyInRenderedModeAndKeepMissingAltText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtMarkdownImage-\(UUID().uuidString)",
                                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmapContext = try XCTUnwrap(CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8,
                                                    bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmapContext.setFillColor(CGColor(red: 0.12, green: 0.42, blue: 0.76, alpha: 1))
        bitmapContext.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
        bitmapContext.setFillColor(CGColor(red: 0.96, green: 0.72, blue: 0.18, alpha: 1))
        bitmapContext.fill(CGRect(x: 32, y: 8, width: 32, height: 32))
        let sourceImage = try XCTUnwrap(bitmapContext.makeImage())
        let imageData = NSMutableData()
        let imageDestination = try XCTUnwrap(CGImageDestinationCreateWithData(imageData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, sourceImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(imageDestination))
        let png = imageData as Data
        try png.write(to: directory.appendingPathComponent("pixel.png"))
        let url = directory.appendingPathComponent("images.md")
        try Data("|Name|Value|\n|---|---|\n|one|two|\n\n![pixel](pixel.png) ![missing](missing.png)".utf8).write(to: url)

        let preparation = try PreviewPreparation.read(at: url)
        let document = try XCTUnwrap(preparation.markdownDocument)
        XCTAssertEqual(document.images.count, 2)
        XCTAssertNotNil(document.images[0].data)
        XCTAssertNil(document.images[1].data)
        let controller = makeSizedPreviewController()
        controller.display(preparation)
        try snapshots(controller)
        let textView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first)
        let modes = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewTabStrip }.first)
        modes.selectedSegment = 0
        _ = modes.sendAction(modes.action, to: modes.target)
        let countAttachments: (NSTextView) -> Int = { textView in
            var count = 0
            textView.textStorage?.enumerateAttribute(.attachment,
                in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)) { value, _, _ in
                    if value != nil { count += 1 }
                }
            return count
        }
        XCTAssertEqual(countAttachments(textView), 1)
        XCTAssertTrue(textView.string.contains("missing"))
        modes.selectedSegment = 1
        _ = modes.sendAction(modes.action, to: modes.target)
        let sourceView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(sourceView.textView.string, document.raw)
        XCTAssertEqual(countAttachments(sourceView.textView), 0)
    }

    @MainActor
    func testMermaidFlowchartsRenderInMixedMarkdownAtNarrowAndRegularWidths() async throws {
        let fixture = try Data(contentsOf: fixtureURL("Cases/markdown/mermaid-composite.md"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtMermaid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("composite.md")
        try fixture.write(to: documentURL)
        let imageContext = try XCTUnwrap(CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8,
                                                  bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        imageContext.setFillColor(CGColor(red: 0.12, green: 0.42, blue: 0.76, alpha: 1))
        imageContext.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
        imageContext.setFillColor(CGColor(red: 0.96, green: 0.72, blue: 0.18, alpha: 1))
        imageContext.fill(CGRect(x: 64, y: 0, width: 32, height: 48))
        let image = try XCTUnwrap(imageContext.makeImage())
        let imageData = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try imageData.write(to: directory.appendingPathComponent("pixel.png"))

        let preparation = try PreviewInspectionResult.read(at: documentURL,
                                                            contentTypeIdentifier: { _ in "net.daringfireball.markdown" })
        let document = try XCTUnwrap(preparation.markdownDocument)
        XCTAssertEqual(document.raw, String(decoding: fixture, as: UTF8.self))
        XCTAssertEqual(document.mathExpressions.count, 3)
        XCTAssertEqual(document.mermaidBlocks.count, 5)
        XCTAssertEqual(document.mermaidBlocks.filter { $0.flowchart != nil }.count, 2)
        XCTAssertEqual(document.mermaidBlocks.filter { $0.sequenceDiagram != nil }.count, 1)
        XCTAssertEqual(document.mermaidBlocks.filter { $0.classDiagram != nil }.count, 1)
        XCTAssertEqual(document.mermaidBlocks.filter { $0.stateDiagram != nil }.count, 1)
        XCTAssertEqual(document.images.count, 1)
        XCTAssertNotNil(document.images.first?.data)
        XCTAssertEqual(document.navigationLinks.count, 1)
        XCTAssertGreaterThan(document.runs.filter { $0.footnote == .definition }.count, 0)
        XCTAssertEqual(document.alerts.map(\.kind), [.note])
        XCTAssertEqual(document.listParagraphs.filter { $0.task != nil }.count, 2)
        XCTAssertTrue(try XCTUnwrap(document.renderedText).contains("literal"))

        for width in [260.0, 640.0, 1000.0] {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                // MermaidKit renders off the display path; the observer fires once the attachments are in place.
                let mermaidRendered = expectation(description: "Mermaid renders at \(Int(width)) \(name.rawValue)")
                mermaidRendered.assertForOverFulfill = false
                let controller = makeSizedPreviewController(size: NSSize(width: width, height: 500),
                                                            mermaidResultObserver: { _, _ in mermaidRendered.fulfill() })
                // A real window gives the scroll view its settled viewport, from which the preview derives the render width.
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentViewController = controller
                window.setContentSize(NSSize(width: width, height: 500))
                defer { window.contentViewController = nil; window.close() }
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                window.appearance = appearance
                controller.view.appearance = appearance
                controller.display(preparation)
                await fulfillment(of: [mermaidRendered], timeout: 90)
                let views = descendants(controller.view)
                let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
                let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
                modes.selectedSegment = 0
                _ = modes.sendAction(modes.action, to: modes.target)
                controller.view.layoutSubtreeIfNeeded()

                let overviewBitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: overviewBitmap)
                let overviewData = try XCTUnwrap(overviewBitmap.representation(using: .png, properties: [:]))
                let overview = XCTAttachment(data: overviewData, uniformTypeIdentifier: "public.png")
                overview.name = "Markdown-Composite-\(Int(width))-\(name.rawValue)"
                overview.lifetime = .keepAlways
                add(overview)

                var descriptions: [String] = []
                var diagramRanges: [String: NSRange] = [:]
                let rendered = try XCTUnwrap(textView.textStorage)
                rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
                    guard let attachment = value as? NSTextAttachment,
                          let image = attachment.image,
                          let description = image.accessibilityDescription else { return }
                    descriptions.append(description)
                    // MermaidKit labels each image with the diagram's header line.
                    if description.hasPrefix("Mermaid flowchart ") { diagramRanges["Flowchart"] = range }
                    if description.hasPrefix("Mermaid sequenceDiagram ") { diagramRanges["Sequence"] = range }
                    if description.hasPrefix("Mermaid classDiagram ") { diagramRanges["Class"] = range }
                    if description.hasPrefix("Mermaid stateDiagram") { diagramRanges["State"] = range }
                }
                XCTAssertEqual(descriptions.filter { $0.hasPrefix("Mermaid flowchart ") || $0.hasPrefix("Mermaid graph ") }.count, 2)
                XCTAssertEqual(descriptions.filter { $0.hasPrefix("Mermaid sequenceDiagram ") }.count, 1)
                XCTAssertEqual(descriptions.filter { $0.hasPrefix("Mermaid classDiagram ") }.count, 1)
                XCTAssertEqual(descriptions.filter { $0.hasPrefix("Mermaid stateDiagram") }.count, 1)
                XCTAssertTrue(rendered.string.contains("flowchart TD A --> B"), "Ordinary fenced code keeps Mermaid-like text literal.")
                XCTAssertFalse(rendered.string.contains("Browser->>API"))
                var internalLinkCount = 0
                rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                    if let url = value as? URL, url.scheme == "glimt-anchor" { internalLinkCount += 1 }
                    else { XCTAssertNil(value, "Diagram labels never create active links.") }
                }
                XCTAssertEqual(internalLinkCount, 1)
                for diagramName in ["Flowchart", "Sequence", "Class", "State"] {
                    let range = try XCTUnwrap(diagramRanges[diagramName])
                    textView.scrollRangeToVisible(range)
                    controller.view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let screenshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    screenshot.name = "Mermaid-\(diagramName)-\(Int(width))-\(name.rawValue)"
                    screenshot.lifetime = .keepAlways
                    add(screenshot)
                }

                modes.selectedSegment = 1
                _ = modes.sendAction(modes.action, to: modes.target)
                let sourceView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SourceCodeView }.first)
                XCTAssertEqual(sourceView.textView.string, document.raw)
                sourceView.textView.textStorage?.enumerateAttribute(.attachment,
                    in: NSRange(location: 0, length: sourceView.textView.textStorage?.length ?? 0)) { value, _, _ in
                        XCTAssertNil(value, "Raw remains exact and contains no rendered Mermaid attachments.")
                    }
            }
        }
    }

    @MainActor
    func testRepositoryReadmeAndMarkdownTechnicalDocumentRenderWithExactRaw() throws {
        let repositoryRoot = try fixtureURL("README.md").deletingLastPathComponent().deletingLastPathComponent()
        // The project documents are local and untracked; only the README is guaranteed in every checkout.
        for path in ["README.md", "docs/10-autonomous-quality-workflow.md"] {
            let url = repositoryRoot.appendingPathComponent(path)
            guard path == "README.md" || FileManager.default.fileExists(atPath: url.path) else { continue }
            let bytes = try Data(contentsOf: url)
            let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(
                bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
            XCTAssertEqual(document.raw, String(decoding: bytes, as: UTF8.self), path)
            XCTAssertNotNil(document.renderedText, path)
            XCTAssertTrue(document.diagnostics.isEmpty, path)
            let rendered = MarkdownRenderer.render(document)
            XCTAssertFalse(rendered.string.isEmpty, path)
            rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                XCTAssertNil(value, "Repository document links remain inert: \(path)")
            }
        }
    }

    @MainActor
    func testMermaidUnknownAndMalformedSyntaxKeepCodeFallback() throws {
        let raw = "```mermaid\ngitGraph\ncommit\n```\n\n```mermaid\nflowchart TD\nA -->\n```\n"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count,
                                                                                     maximumBytes: bytes.count))
        let rendered = MarkdownRenderer.render(document)
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.mermaidBlocks.map(\.diagnostic), [.unsupportedSyntax, .malformedSyntax])
        XCTAssertTrue(rendered.string.contains("gitGraph"))
        XCTAssertTrue(rendered.string.contains("A -->"))
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.attachment])
        }
    }

    @MainActor
    func testLimitsFallBackAndControllerReuseResetsModesAndStyles() throws {
        let controller = makeSizedPreviewController()
        let oversized = Data(repeating: 97, count: 1_048_577)
        controller.display(PreviewPreparation.prepare(bytes: oversized, fileSize: oversized.count, fileName: "large.md", systemUTI: nil))
        let views = descendants(controller.view)
        let modes = try XCTUnwrap(views.compactMap { $0 as? PreviewTabStrip }.first)
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual((0..<modes.segmentCount).compactMap(modes.label(forSegment:)), ["Raw"], "Incomplete Markdown shows only the exact Raw fallback")
        XCTAssertEqual(modes.selectedSegment, 0)
        XCTAssertEqual(text.string.utf8.count, 1_048_576)
        let styled = Data("~~removed~~\n".utf8)
        controller.display(PreviewPreparation.prepare(bytes: styled, fileSize: styled.count, fileName: "note.md", systemUTI: nil))
        XCTAssertNotNil(text.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
        let json = Data("{}".utf8)
        controller.display(PreviewPreparation.prepare(bytes: json, fileSize: json.count, fileName: "note.json", systemUTI: "net.daringfireball.markdown"))
        XCTAssertEqual((0..<modes.segmentCount).compactMap(modes.label(forSegment:)), ["Tree", "Pretty", "Raw"])
        modes.selectedSegment = 2
        _ = modes.sendAction(modes.action, to: modes.target)
        XCTAssertEqual(text.string, "{}")
        XCTAssertNil(text.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testWrappedTextStaysInsideTheViewportBesideItsInset() throws {
        let controller = makeSizedPreviewController()
        let text = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first)
        let clip = try XCTUnwrap(text.enclosingScrollView?.contentView)
        let long = String(repeating: "word ", count: 200)
        let documents = [("note.md", "# Title\n\n" + long), ("note.json", #"{"text": "\#(long)"}"#)]
        for (name, source) in documents {
            let bytes = Data(source.utf8)
            controller.display(PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: name, systemUTI: nil))
            // Choosing the shown view again re-applies its layout without a frame change.
            let modes = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewTabStrip }.first)
            for segment in name.hasSuffix(".json") ? [2, 2] : [0] {
                modes.selectedSegment = segment
                _ = modes.sendAction(modes.action, to: modes.target)
            }
            // A full line ends at the container's edge, so the container must end inside the clip.
            let container = try XCTUnwrap(text.textContainer)
            XCTAssertLessThanOrEqual(text.frame.width, clip.bounds.width + 0.5, name)
            XCTAssertLessThanOrEqual(text.textContainerOrigin.x + container.size.width, clip.bounds.maxX + 0.5,
                                     "\(name): no line runs past the visible clip")
        }
    }

    @MainActor
    private func snapshots(_ controller: SharedPreviewViewController, tableHeader: String = "Value",
                           tableBody: String = "two") throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 640, height: 480))
        defer { window.contentViewController = nil; window.close() }
        let modes = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewTabStrip }.first)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            window.appearance = appearance
            controller.view.appearance = appearance
            for mode in 0...1 {
                modes.selectedSegment = mode
                _ = modes.sendAction(modes.action, to: modes.target)
                controller.view.layoutSubtreeIfNeeded()
                if mode == 0 {
                    let text = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first)
                    text.scrollRangeToVisible(NSRange(location: 0, length: 0))
                    let layout = try XCTUnwrap(text.layoutManager)
                    layout.ensureLayout(for: try XCTUnwrap(text.textContainer))
                    let headerIndex = (text.string as NSString).range(of: tableHeader).location
                    let bodyIndex = (text.string as NSString).range(of: tableBody).location
                    let headerGlyph = layout.glyphIndexForCharacter(at: headerIndex)
                    let bodyGlyph = layout.glyphIndexForCharacter(at: bodyIndex)
                    let headerX = layout.lineFragmentRect(forGlyphAt: headerGlyph, effectiveRange: nil).minX + layout.location(forGlyphAt: headerGlyph).x
                    let bodyX = layout.lineFragmentRect(forGlyphAt: bodyGlyph, effectiveRange: nil).minX + layout.location(forGlyphAt: bodyGlyph).x
                    XCTAssertEqual(headerX, bodyX, accuracy: 0.5, "Table cells share their column positions")
                }
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                appearance.performAsCurrentDrawingAppearance { controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap) }
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "Markdown-\(name.rawValue)-\(mode)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
