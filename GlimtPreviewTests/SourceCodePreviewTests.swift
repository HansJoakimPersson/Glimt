import AppKit
import Foundation
import InspectorCore
import XCTest

final class SourceCodePreviewTests: XCTestCase {
    @MainActor
    func testResolvedWordWrapControlsLongLineHorizontalScrolling() throws {
        let bytes = Data(("let text = \"" + String(repeating: "long line ", count: 100) + "\"\n").utf8)
        let document = try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), language: .swift)
        var settings = GlimtSettings.factoryDefaults
        for wrap in [false, true] {
            settings.textCode.wordWrap = wrap
            let resolved = RenderConfiguration(settings: settings).source(for: .swift)
            let code = SourceCodeView(options: resolved)
            code.frame = .init(x: 0, y: 0, width: 400, height: 300)
            code.layoutSubtreeIfNeeded()
            code.display(document)
            code.layoutSubtreeIfNeeded()
            XCTAssertEqual(code.options.wrapLines, wrap)
            XCTAssertEqual(code.scrollView.hasHorizontalScroller, !wrap)
            XCTAssertEqual(code.textView.textContainer?.widthTracksTextView, wrap)
            if !wrap {
                XCTAssertGreaterThan(code.textView.bounds.width, code.scrollView.contentSize.width)
                code.scrollView.contentView.scroll(to: .init(x: 200, y: 0))
                XCTAssertGreaterThan(code.scrollView.contentView.bounds.minX, 0)
            }
        }
    }

    @MainActor
    func testLineNumberDividerStopsAtVisibleScrollViewport() throws {
        let source = String(repeating: "let value = 42\n", count: 200)
        let bytes = Data(source.utf8)
        let document = try SourceCodeInspector.inspect(
            analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count),
            language: .swift
        )
        let view = SourceCodeView(options: SourceRenderConfiguration(showLineNumbers: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.display(document)
        view.layoutSubtreeIfNeeded()
        view.scrollView.contentView.contentInsets = NSEdgeInsets(top: 18, left: 0, bottom: 12, right: 0)
        view.layoutSubtreeIfNeeded()

        let ruler = try XCTUnwrap(view.scrollView.verticalRulerView as? SourceLineNumberRuler)
        let viewport = view.scrollView.contentView.convert(view.scrollView.contentView.bounds, to: ruler)
        XCTAssertEqual(ruler.dividerFrame.minY, max(ruler.bounds.minY, viewport.minY), accuracy: 0.01)
        XCTAssertEqual(ruler.dividerFrame.maxY, min(ruler.bounds.maxY, viewport.maxY), accuracy: 0.01)
        XCTAssertGreaterThan(ruler.dividerFrame.height, 0)

        window.contentView = nil
        window.close()
    }

    @MainActor
    func testSyntheticVCSChangesOverlayTheLogicalLineRulerAndClearWithoutChangingText() throws {
        let baseline = Data("one\ntwo\nthree\nremove\nfour\n".utf8)
        let working = Data("zero\none\nTWO with a line long enough to wrap in both modes\nthree\nfour\nlast\n".utf8)
        let diff = try VCSLineDiff.compare(baseline: baseline, working: working)
        XCTAssertEqual(diff.changes.map(\.kind), [.added, .modified, .deleted, .added])
        let bytes = working
        let document = try SourceCodeInspector.inspect(
            analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count),
            language: .swift
        )
        let soft = SourceRenderConfiguration(showLineNumbers: true, wrapLines: true)
        let hard = SourceRenderConfiguration(showLineNumbers: true, wrapMode: .hard, lineLength: 20,
                                             tabsToSpaces: 4, fontFamily: "System Monospaced", fontSize: 12,
                                             lightTheme: .glimtDefault, darkTheme: .glimtDefault,
                                             lightPalette: nil, darkPalette: nil, indentationGuides: false)
        for options in [soft, hard] {
            let view = SourceCodeView(options: options)
            view.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
            view.display(document)
            view.layoutSubtreeIfNeeded()
            let ruler = try XCTUnwrap(view.scrollView.verticalRulerView as? SourceLineNumberRuler)
            let widthWithoutMarkers = ruler.ruleThickness
            let textInsetWithoutMarkers = view.scrollView.contentView.contentInsets.left

            view.displayVCSLineDiff(diff)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(ruler.lineDiff, diff)
            XCTAssertGreaterThan(ruler.ruleThickness, widthWithoutMarkers)
            XCTAssertGreaterThan(view.scrollView.contentView.contentInsets.left, textInsetWithoutMarkers,
                                 "The marker column must reserve room so it cannot overlap preview text")
            XCTAssertEqual(ruler.lineStarts.count, diff.workingLineCount)
            if options.wrapMode == .hard {
                XCTAssertFalse(try XCTUnwrap(view.textView.hardWrap).insertions.isEmpty)
                XCTAssertEqual(view.textView.hardWrap?.original, document.source)
            } else {
                XCTAssertEqual(view.textView.string, document.source)
            }
            let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { ruler.cacheDisplay(in: ruler.bounds, to: bitmap) }
            for color in [NSColor.systemGreen, .systemOrange, .systemRed] {
                let expected = try XCTUnwrap(color.usingColorSpace(.sRGB))
                let visible = (0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in
                        guard let actual = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                        return abs(actual.redComponent - expected.redComponent) < 0.02
                            && abs(actual.greenComponent - expected.greenComponent) < 0.02
                            && abs(actual.blueComponent - expected.blueComponent) < 0.02
                    }
                }
                XCTAssertTrue(visible, "Expected a visible \(color) VCS gutter marker")
            }

            view.displayVCSLineDiff(nil)
            XCTAssertNil(ruler.lineDiff)
            view.displayVCSLineDiff(diff)
            view.clear()
            XCTAssertNil(ruler.lineDiff, "Clearing one document must not leak its VCS overlay to the next preview")
        }
    }

    /// E5-01: with Soft wrap every wrapped fragment ends inside the visible clip, whatever order the
    /// document, the line-number ruler and the final width arrive in.
    @MainActor
    func testSoftWrapKeepsEveryFragmentInsideTheVisibleWidthAfterResizes() throws {
        let source = "struct Item {\n    func greeting(for name: String) -> String {\n        return \"" + String(repeating: "long line ", count: 30) + "\"\n    }\n}\n"
        let bytes = Data(source.utf8)
        let document = try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), language: .swift)
        var settings = GlimtSettings.factoryDefaults
        settings.textCode.wordWrap = true
        settings.source.showLineNumbers = true
        let options = RenderConfiguration(settings: settings).source(for: .swift)
        let sequences: [(String, [CGFloat])] = [("zero, then wide", [0, 640]), ("wide, then narrow", [1200, 480]),
                                                ("narrow, then wide", [480, 900]), ("same width twice", [640, 640])]
        for (name, widths) in sequences {
            let code = SourceCodeView(options: options)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: max(widths[0], 1), height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = code
            code.layoutSubtreeIfNeeded()
            code.display(document)
            for width in widths.dropFirst() {
                window.setContentSize(.init(width: width, height: 400))
                code.layoutSubtreeIfNeeded()
            }
            // A second display or option change at an unchanged width must not widen the container.
            code.display(document)
            code.updateOptions(SourceRenderConfiguration(showLineNumbers: true, wrapLines: true, tabWidth: options.tabWidth == 2 ? 3 : 2))
            code.updateOptions(options)
            let container = try XCTUnwrap(code.textView.textContainer)
            // The ruler takes its room as a clip-view inset, so the visible text width excludes it.
            let insets = code.scrollView.contentView.contentInsets
            let clip = code.scrollView.contentView.bounds.width - insets.left - insets.right
            XCTAssertGreaterThan(insets.left, 0, "\(name): line numbers take room beside the text")
            XCTAssertLessThanOrEqual(container.size.width + 2 * code.textView.textContainerInset.width, code.textView.frame.width + 0.5,
                                     "\(name): text container wider than the text view inside its insets")
            code.textView.layoutManager?.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(code.textView.frame.width, clip + 0.5, "\(name): text view wider than the visible clip")
            let used = try XCTUnwrap(code.textView.layoutManager?.usedRect(for: container))
            XCTAssertLessThanOrEqual(used.maxX + code.textView.textContainerOrigin.x, clip + 0.5, "\(name): a fragment ends outside the visible clip")
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    func testCustomPalettesRoundTripAndOverrideTheSelectedPresetPerAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var lightPalette = SourceSyntaxColors.palette(for: .glimtDefault, appearance: light)
        lightPalette.keyword = .init(red: 0.8, green: 0.1, blue: 0.2)
        var darkPalette = SourceSyntaxColors.palette(for: .glimtDefault, appearance: dark)
        darkPalette.keyword = .init(red: 0.2, green: 0.9, blue: 0.4)
        let encoded = try JSONEncoder().encode(lightPalette)
        XCTAssertEqual(try JSONDecoder().decode(SourceThemePalette.self, from: encoded), lightPalette)
        var malformed = SourceThemeColor(red: 0, green: 0, blue: 0)
        malformed.red = .nan; malformed.green = 2; malformed.blue = -1; malformed.alpha = .infinity
        XCTAssertEqual(malformed.normalized(), .init(red: 0, green: 1, blue: 0))
        let configuration = SourceRenderConfiguration(lightTheme: .highContrast, darkTheme: .neutral,
                                                       lightPalette: lightPalette, darkPalette: darkPalette)
        let source = "let value = 42\n"
        let bytes = Data(source.utf8)
        let document = try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), language: .swift)
        let view = SourceCodeView(options: configuration)
        for (appearance, palette) in [(light, lightPalette), (dark, darkPalette)] {
            view.appearance = appearance
            view.display(document)
            XCTAssertEqual(configuration.activePalette(for: appearance), palette)
            let color = try XCTUnwrap(view.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            let resolved = try XCTUnwrap(color.usingColorSpace(.sRGB))
            XCTAssertEqual(resolved.redComponent, palette.keyword.red, accuracy: 0.001)
            XCTAssertEqual(resolved.greenComponent, palette.keyword.green, accuracy: 0.001)
            XCTAssertEqual(resolved.blueComponent, palette.keyword.blue, accuracy: 0.001)
            XCTAssertEqual(view.textView.string, source)
        }
    }

    @MainActor
    func testIndentationGuidesTrackSpacesTabsAndRespectWrappingWithoutChangingSource() throws {
        let source = "func greet() {\n    let one = 1\n\tlet two = 2\n  \tlet three = 3\n}\n"
        let bytes = Data(source.utf8)
        let document = try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), language: .swift)
        let view = SourceCodeView(options: .init(indentationGuides: true))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.display(document)
        view.layoutSubtreeIfNeeded()
        let layout = try XCTUnwrap(view.textView.layoutManager)
        let container = try XCTUnwrap(view.textView.textContainer)
        layout.ensureLayout(for: container)
        let fourSpaceGuides = view.textView.indentationGuideRects(in: view.textView.bounds)
        XCTAssertEqual(fourSpaceGuides.count, 3)
        XCTAssertEqual(Set(fourSpaceGuides.map(\.minX)).count, 1, "Equivalent space/tab indentation aligns")
        XCTAssertEqual(try XCTUnwrap(fourSpaceGuides.first).minX, view.textView.textContainerOrigin.x + container.lineFragmentPadding, accuracy: 0.01)
        view.textView.setSelectedRange(NSRange(location: 2, length: 3))
        view.updateOptions(.init(tabWidth: 2, indentationGuides: true))
        layout.ensureLayout(for: container)
        XCTAssertEqual(view.textView.indentationGuideRects(in: view.textView.bounds).count, 5)
        XCTAssertEqual(view.textView.string, source)
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 2, length: 3))
        view.display(document)
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 2, length: 3), "Redisplaying the same inspection after host settings changes keeps selection")
        view.updateOptions(.init(indentationGuides: false))
        XCTAssertTrue(view.textView.indentationGuideRects(in: view.textView.bounds).isEmpty)

        let longSource = "    let message = \"" + String(repeating: "long code ", count: 30) + "\"\n"
        let longBytes = Data(longSource.utf8)
        let longDocument = try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: longBytes, fileSize: longBytes.count, maximumBytes: longBytes.count), language: .swift)
        view.updateOptions(.init(wrapLines: true, indentationGuides: true))
        view.display(longDocument)
        layout.ensureLayout(for: container)
        XCTAssertEqual(view.textView.indentationGuideRects(in: view.textView.bounds).count, 1, "Guides never cross soft-wrap continuation text")
        XCTAssertEqual(view.textView.string, longSource)
    }

    @MainActor
    func testThemeSwatchesAreInertAndUseTheirExplicitAppearance() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let neutral = SourceSyntaxColors.swatch(for: .neutral, appearance: appearance)
        let colorful = SourceSyntaxColors.swatch(for: .glimtDefault, appearance: appearance)
        XCTAssertEqual(neutral.string, colorful.string)
        let neutralKeyword = try XCTUnwrap(neutral.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let colorfulKeyword = try XCTUnwrap(colorful.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertNotEqual(neutralKeyword, colorfulKeyword)
        for sample in [neutral, colorful] {
            sample.enumerateAttributes(in: NSRange(location: 0, length: sample.length)) { attributes, _, _ in
                XCTAssertNil(attributes[.link])
                XCTAssertNil(attributes[.attachment])
                XCTAssertNotNil(attributes[.backgroundColor])
            }
        }
    }

    @MainActor
    func testThemeOnlyChangeUpdatesAlreadyDisplayedSourceImmediately() throws {
        let source = "let message: String = \"Glimt\"\n"
        let bytes = Data(source.utf8)
        let document = try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), language: .swift)
        let view = SourceCodeView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 200)
        view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        let keyword = (source as NSString).range(of: "let").location
        let appearance = view.effectiveAppearance
        func keywordColor() throws -> NSColor {
            let color = try XCTUnwrap(view.textView.textStorage?.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor)
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            return try XCTUnwrap(resolved)
        }
        let before = try keywordColor()
        XCTAssertGreaterThan(abs(before.redComponent - before.greenComponent), 0.05)
        _ = try XCTUnwrap(view.textView.bitmapImageRepForCachingDisplay(in: view.textView.bounds))
        view.updateOptions(.init(lightTheme: .neutral))
        let neutral = try keywordColor()
        XCTAssertEqual(neutral.redComponent, neutral.greenComponent, accuracy: 0.01)
        XCTAssertEqual(neutral.greenComponent, neutral.blueComponent, accuracy: 0.01)
        XCTAssertEqual(view.options.fontSize, 12)
        view.updateOptions(.init())
        let restored = try keywordColor()
        XCTAssertEqual(restored.redComponent, before.redComponent, accuracy: 0.01)
        XCTAssertEqual(restored.greenComponent, before.greenComponent, accuracy: 0.01)
        XCTAssertEqual(view.textView.string, source)
    }

    @MainActor
    func testNativeThemePresetsFollowEffectiveAppearanceAndStayReadable() throws {
        let source = "// Glimt\nlet value: String = \"hello\"\n"
        let bytes = Data(source.utf8)
        let document = try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), language: .swift)
        let options = SourceRenderConfiguration(lightTheme: .neutral, darkTheme: .highContrast)
        let view = SourceCodeView(options: options)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            view.appearance = appearance
            view.display(document)
            let selected = options.activeTheme(for: view.effectiveAppearance)
            XCTAssertEqual(selected, name == .darkAqua ? .highContrast : .neutral)
            appearance.performAsCurrentDrawingAppearance {
                for preset in SourceThemePreset.allCases {
                    let background = SourceSyntaxColors.background(for: preset)
                    XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(SourceSyntaxColors.foreground(for: preset), background), 4.5)
                    for kind in SyntaxTokenKind.allCases {
                        let color = SourceSyntaxColors.color(for: kind, preset: preset)
                        XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(color, background), preset == .highContrast ? 7 : 4.5)
                        if preset == .neutral, let gray = color.usingColorSpace(.sRGB) {
                            XCTAssertEqual(gray.redComponent, gray.greenComponent, accuracy: 0.01)
                            XCTAssertEqual(gray.greenComponent, gray.blueComponent, accuracy: 0.01)
                        }
                    }
                }
                let keyword = (source as NSString).range(of: "let").location
                let actual = view.textView.textStorage?.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor
                let expected = SourceSyntaxColors.color(for: .keyword, preset: selected)
                XCTAssertEqual(actual?.usingColorSpace(.sRGB), expected.usingColorSpace(.sRGB))
            }
            XCTAssertEqual(view.textView.string, source)
        }
    }

    @MainActor
    func testConfiguredFontControlsTextTabsAndRulerMetrics() throws {
        let source = String(repeating: "\tlet value = 42\n", count: 1_000)
        let bytes = Data(source.utf8)
        let document = try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), language: .swift)
        let view = SourceCodeView()
        view.display(document)
        for family in ["System Monospaced", "Menlo", "Monaco"] {
            let configuration = SourceRenderConfiguration(tabWidth: 8, fontFamily: family, fontSize: 20)
            view.updateOptions(configuration)
            let font = try XCTUnwrap(view.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, 20)
            if family != "System Monospaced", let expected = NSFont(name: family, size: 20) {
                XCTAssertEqual(font.fontName, expected.fontName)
            }
            let paragraph = try XCTUnwrap(view.textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(paragraph.defaultTabInterval, (" " as NSString).size(withAttributes: [.font: font]).width * 8, accuracy: 0.01)
            let ruler = try XCTUnwrap(view.scrollView.verticalRulerView)
            let expectedWidth = max(32, ("1000" as NSString).size(withAttributes: [.font: font]).width + 16)
            XCTAssertEqual(ruler.ruleThickness, expectedWidth, accuracy: 0.01)
            XCTAssertEqual(view.textView.string, source)
        }
    }

    @MainActor
    func testSourceRoutingAndSpecializedFormats() throws {
        for (path, language) in [
            ("Cases/source/Example.swift", SourceLanguage.swift), ("Showcase/source/java.java", .java),
            ("Showcase/source/c.c", .c), ("Showcase/source/cpp.cpp", .cpp), ("Showcase/source/python.py", .python),
            ("Showcase/source/javascript.js", .javascript), ("Showcase/source/typescript.ts", .typescript), ("Showcase/source/shell.sh", .shell),
            ("Showcase/source/terraform.tf", .terraform), ("Showcase/source/styles.scss", .scss),
            ("Showcase/source/Greeting.tsx", .tsx), ("Showcase/source/App.vue", .vue),
            ("Showcase/source/Counter.svelte", .svelte), ("Showcase/fileformats/guide.adoc", .asciidoc),
            ("Showcase/source/Greeter.m", .objectiveC), ("Showcase/source/hello.pl", .perl),
            ("Showcase/source/analysis.R", .r), ("Showcase/source/Main.scala", .scala),
            ("Showcase/source/analysis.jl", .julia), ("Showcase/source/vb.vb", .visualBasic),
            ("Showcase/source/vala.vala", .vala), ("Showcase/source/plugin.vim", .vimscript),
            ("Showcase/source/nim.nim", .nim), ("Showcase/source/model.scad", .openSCAD),
            ("Showcase/source/add.wat", .webAssemblyText),
            ("Showcase/source/pascal.pas", .pascal), ("Showcase/source/counter.vh", .verilog),
            ("Showcase/source/counter.vhd", .vhdl),
            ("Showcase/source/hello.cob", .cobol), ("Showcase/source/board.dts", .deviceTree),
            ("Showcase/source/sv.po", .gettext),
            ("Showcase/source/page.html.erb", .erb), ("Showcase/source/Component.qml", .qml),
            ("Showcase/source/Counter.sol", .solidity),
            ("Showcase/fileformats/notes.org", .org),
            ("Showcase/web/home.asp", .asp), ("Showcase/web/home.aspx", .aspx),
            ("Showcase/web/page.jinja", .jinja), ("Showcase/web/page.twig", .twig),
            ("Showcase/fileformats/gentoo/portage.ebuild", .shell),
            ("Showcase/fileformats/gentoo/profile.eclass", .shell),
            ("Showcase/fileformats/fortran/legacy.ftn", .fortran),
            ("Showcase/fileformats/cython/fast.pyx", .python),
            ("Showcase/fileformats/ada/main.adb", .ada),
            ("Showcase/fileformats/ada/spec.ads", .ada),
            ("Showcase/fileformats/ada/project.gnad", .ada),
            ("Showcase/fileformats/eiffel/example.se", .eiffel),
            ("Showcase/fileformats/autohotkey/hotkeys.ahk", .autoHotkey),
            ("Showcase/fileformats/inno/installer.iss", .innoSetup),
            ("Showcase/fileformats/nsis/installer.nsi", .nsis),
            ("Showcase/fileformats/nsis/macros.nsh", .nsis),
            ("Showcase/policy/allow.rego", .rego),
            ("Showcase/directory/people.ldif", .ldif),
            ("Showcase/data/catalog.ttl", .turtle),
            ("Showcase/data/catalog.n3", .turtle),
            ("Showcase/data/catalog.nt", .turtle),
            ("Showcase/fileformats/ini/org.glimt.viewer.desktop", .ini),
            ("Showcase/fileformats/ini/Doxyfile.doxyfile", .ini),
            ("Showcase/fileformats/ini/project.kdev3", .ini),
            ("Cases/config/toml/valid/features.toml", .toml), ("Cases/config/ini/valid/features.ini", .ini),
            ("Cases/config/properties/valid/features.properties", .properties)
        ] {
            let url = try fixtureURL(path)
            let name = url.lastPathComponent
            let bytes = try Data(contentsOf: url)
            let text = String(decoding: bytes, as: UTF8.self)
            let result = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: name,
                                                    systemUTI: name.hasSuffix(".ts") ? "public.mpeg-2-transport-stream" : nil)
            let document = try XCTUnwrap(result.sourceDocument, name)
            XCTAssertEqual(document.language, language)
            XCTAssertEqual(document.source, text)
            XCTAssertFalse(document.highlighting.runs.isEmpty, name)
            let controller = makeSizedPreviewController()
            controller.display(result)
            let views = allViews(controller.view)
            let code = try XCTUnwrap(views.compactMap { $0 as? SourceCodeView }.first)
            XCTAssertFalse(code.isHidden)
            XCTAssertEqual(code.textView.string, text)
            XCTAssertEqual(code.textView.accessibilityLabel(), "\(language.displayName) source code")
            if [.toml, .ini, .properties].contains(language) {
                let key = try XCTUnwrap(document.highlighting.runs.first { $0.kind == .type }, name)
                let keyColor = try XCTUnwrap(code.textView.textStorage?.attribute(.foregroundColor, at: key.range.location, effectiveRange: nil) as? NSColor, name)
                XCTAssertNotEqual(keyColor, code.textView.textColor, "The configuration key receives syntax color: \(name)")
            }
            if [.objectiveC, .perl, .r, .scala, .julia, .visualBasic, .vala, .vimscript, .nim, .openSCAD, .webAssemblyText, .pascal, .verilog, .vhdl, .cobol, .deviceTree, .gettext, .erb, .qml, .solidity, .org, .asp, .aspx, .jinja, .twig, .shell, .fortran, .autoHotkey, .innoSetup, .nsis, .rego, .ldif, .turtle].contains(language), !(language == .turtle && url.pathExtension == "nt") {
                let keyword = try XCTUnwrap(document.highlighting.runs.first { $0.kind == .keyword }, name)
                let keywordColor = try XCTUnwrap(code.textView.textStorage?.attribute(.foregroundColor, at: keyword.range.location, effectiveRange: nil) as? NSColor, name)
                let keywordText = (document.source as NSString).substring(with: keyword.range)
                let plainLocation = keyword.range.location + keyword.range.length
                let plainColor = try XCTUnwrap(code.textView.textStorage?.attribute(.foregroundColor, at: plainLocation, effectiveRange: nil) as? NSColor, name)
                XCTAssertNotEqual(keywordColor, plainColor,
                                  "The \(language.displayName) keyword \(keywordText) receives syntax color")
            }
            let header = try XCTUnwrap(views.compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
            let fullStatus = header.accessibilityLabel() ?? header.stringValue
            XCTAssertTrue(fullStatus.contains(language.displayName), fullStatus)
            XCTAssertTrue(fullStatus.contains("UTF-8"), fullStatus)
            XCTAssertTrue(fullStatus.contains("LF"), fullStatus)
            XCTAssertFalse(fullStatus.contains("✓"), "Source language detection does not validate its syntax")
            XCTAssertFalse(header.stringValue.contains("Confidence"))
        }
        let pythonFixture = try fixtureURL("Showcase/source/python.py")
        let pythonBytes = try Data(contentsOf: pythonFixture)
        let pythonText = String(decoding: pythonBytes, as: UTF8.self)
        let pythonAliases = ["sample.pyi", "sample.pyw", "sample.py3", "sample.cpy", "sample.gyp", "sample.gypi",
                             "sample.pxd", "sample.pxi", "sample.rpy", "SConstruct", "Snakefile", "wscript"]
        for fileName in pythonAliases {
            let result = PreviewPreparation.prepare(bytes: pythonBytes, fileSize: pythonBytes.count, fileName: fileName, systemUTI: nil)
            let document = try XCTUnwrap(result.sourceDocument, fileName)
            XCTAssertEqual(result.formatDefinition?.id, .python, fileName)
            XCTAssertEqual(document.language, .python, fileName)
            XCTAssertEqual(document.source, pythonText, fileName)
            let keyword = try XCTUnwrap(document.highlighting.runs.first { $0.kind == .keyword }, fileName)
            let controller = makeSizedPreviewController()
            controller.display(result)
            let code = try XCTUnwrap(allViews(controller.view).compactMap { $0 as? SourceCodeView }.first, fileName)
            XCTAssertEqual(code.textView.string, pythonText, fileName)
            let keywordColor = try XCTUnwrap(code.textView.textStorage?.attribute(.foregroundColor, at: keyword.range.location, effectiveRange: nil) as? NSColor, fileName)
            let plainColor = try XCTUnwrap(code.textView.textStorage?.attribute(.foregroundColor, at: keyword.range.location + keyword.range.length, effectiveRange: nil) as? NSColor, fileName)
            XCTAssertNotEqual(keywordColor, plainColor, "Python syntax is visibly colored for \(fileName)")
        }
        for path in ["Cases/json/valid/simple.json", "Showcase/yaml/yaml.yaml"] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: url.lastPathComponent, systemUTI: "public.python-script")
            XCTAssertNil(result.sourceDocument)
            XCTAssertTrue(result.isStructured)
        }
        let yml = Data("a: 1\n".utf8)
        XCTAssertTrue(PreviewPreparation.prepare(bytes: yml, fileSize: yml.count, fileName: "sample.yml", systemUTI: nil).isStructured)
        let binary = PreviewPreparation.prepare(bytes: Data([0, 1]), fileSize: 2, fileName: "sample.ts", systemUTI: nil)
        XCTAssertNil(binary.sourceDocument)
        let unknown = Data("ordinary words\n".utf8)
        XCTAssertNil(PreviewPreparation.prepare(bytes: unknown, fileSize: unknown.count, fileName: "unknown", systemUTI: nil).sourceDocument)
    }

    @MainActor
    func testPreviewOptionsWrappingAndTabs() throws {
        let source = "\tlet value = \"" + String(repeating: "long value ", count: 40) + "\"\n"
        let bytes = Data(source.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
        let document = try SourceCodeInspector.inspect(analysis: analysis, language: .swift)
        let code = SourceCodeView(options: .init())
        code.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        code.display(document)
        code.layoutSubtreeIfNeeded()
        XCTAssertTrue(code.scrollView.rulersVisible)
        XCTAssertTrue(code.scrollView.hasHorizontalScroller)
        XCTAssertFalse(code.textView.textContainer?.widthTracksTextView ?? true)
        let layout = try XCTUnwrap(code.textView.layoutManager)
        let container = try XCTUnwrap(code.textView.textContainer)
        layout.ensureLayout(for: container)
        let unwrappedHeight = layout.usedRect(for: container).height
        code.updateOptions(.init(showLineNumbers: true, wrapLines: true, tabWidth: 4))
        XCTAssertTrue(code.options.wrapLines)
        XCTAssertTrue(code.textView.textContainer?.widthTracksTextView ?? false)
        XCTAssertFalse(code.scrollView.hasHorizontalScroller)
        layout.ensureLayout(for: container)
        XCTAssertGreaterThan(layout.usedRect(for: container).height, unwrappedHeight)
        code.updateOptions(.init(showLineNumbers: false, wrapLines: true, tabWidth: 8))
        XCTAssertFalse(code.scrollView.rulersVisible)
        XCTAssertEqual(code.options.tabWidth, 8)
        XCTAssertTrue(allViews(code).compactMap { $0 as? NSButton }.isEmpty)
        XCTAssertTrue(allViews(code).compactMap { $0 as? NSPopUpButton }.isEmpty)
        let paragraph = try XCTUnwrap(code.textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        XCTAssertEqual(paragraph.defaultTabInterval, (" " as NSString).size(withAttributes: [.font: font]).width * 8, accuracy: 0.01)
        XCTAssertEqual(code.textView.string, source)
        XCTAssertEqual(SourceRenderConfiguration(tabWidth: 100).tabWidth, 8)
        XCTAssertEqual(SourceRenderConfiguration(tabWidth: -1).tabWidth, 1)
    }

    private struct UnavailableHighlighter: SyntaxHighlighting {
        struct Failure: Error {}
        func highlight(_ source: String, language: SourceLanguage) throws -> HighlightedSource { throw Failure() }
        func highlight(_ source: String, language: SourceLanguage, literateHaskell: Bool) throws -> HighlightedSource { throw Failure() }
    }

    @MainActor
    func testPlainFallbackStillRendersAndClearsPriorContent() throws {
        let source = "let value = 42\n"
        let bytes = Data(source.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
        let document = try SourceCodeInspector.inspect(analysis: analysis, language: .swift, highlighter: UnavailableHighlighter())
        XCTAssertTrue(document.highlighting.runs.isEmpty)
        let code = SourceCodeView(options: .init())
        code.display(document)
        XCTAssertEqual(code.textView.string, source)
        XCTAssertTrue(code.textView.isSelectable)
        XCTAssertFalse(code.textView.isEditable)
        XCTAssertEqual(code.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        code.clear()
        XCTAssertEqual(code.textView.string, "")
    }

    @MainActor
    func testTruncationAndAppearance() throws {
        let text = "// Glimt\nlet message: String = \"hello\"\nlet count = 42\n"
        let bytes = Data(text.utf8)
        let result = PreviewPreparation.prepare(bytes: bytes, fileSize: bytes.count + 10, fileName: "Example.swift", systemUTI: nil)
        XCTAssertTrue(try XCTUnwrap(result.sourceDocument).truncated)
        let controller = makeSizedPreviewController()
        controller.display(result)
        let diagnostic = try XCTUnwrap(allViews(controller.view).compactMap { $0 as? PreviewStatusView }.first { $0.identifier?.rawValue == "PreviewStatus" })
        XCTAssertTrue((diagnostic.accessibilityLabel() ?? diagnostic.stringValue).lowercased().contains("truncated"))
        XCTAssertFalse(diagnostic.isHidden)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        window.setContentSize(NSSize(width: 640, height: 480))
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            window.appearance = appearance
            controller.view.appearance = appearance
            controller.view.layoutSubtreeIfNeeded()
            let code = try XCTUnwrap(allViews(controller.view).compactMap { $0 as? SourceCodeView }.first)
            XCTAssertGreaterThan(code.scrollView.bounds.height, 200)
            XCTAssertEqual(code.textView.string, text)
            appearance.performAsCurrentDrawingAppearance {
                for kind in SyntaxTokenKind.allCases {
                    let resolved = SourceSyntaxColors.color(for: kind).usingColorSpace(.sRGB)
                    XCTAssertNotNil(resolved)
                    if let resolved { XCTAssertGreaterThanOrEqual(SourceSyntaxColors.contrast(resolved, .textBackgroundColor), 4.5, kind.rawValue) }
                }
            }
            let view = controller.view
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            let bodyFrame = code.scrollView.convert(code.scrollView.bounds, to: view)
            let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            let top = max(0, Int((view.bounds.maxY - bodyFrame.maxY) * scale) + 16)
            let bottom = min(bitmap.pixelsHigh, top + 80)
            let background = bitmap.colorAt(x: bitmap.pixelsWide - 4, y: top)
            let codeHasInk = stride(from: top, to: bottom, by: 2).contains { y in
                stride(from: 100, to: min(800, bitmap.pixelsWide - 4), by: 2).contains { x in
                    bitmap.colorAt(x: x, y: y) != background
                }
            }
            XCTAssertTrue(codeHasInk, "The gutter must not paint over the source text")
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Source-\(appearanceName.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
}
