import AppKit
import XCTest
import InspectorCore

/// F1.9 / ADR-016: presentation-only Hard wrap with original-text copy.
final class HardWrapLayoutTests: XCTestCase {
    private func wrap(_ text: String, _ limit: Int, tab: Int = 4) throws -> HardWrapLayout {
        try HardWrapLayout.wrap(text, lineLength: limit, tabStop: tab)
    }

    private func displayedLines(_ layout: HardWrapLayout) -> [String] {
        layout.displayed.components(separatedBy: "\n")
    }

    // MARK: - Layout

    func testShortLinesAreIdentity() throws {
        let layout = try wrap("short\nlines\n", 20)
        XCTAssertEqual(layout, .identity("short\nlines\n"))
    }

    func testBreaksAfterLastWhitespaceWithinLimit() throws {
        let layout = try wrap("alpha beta gamma delta", 12)
        XCTAssertEqual(displayedLines(layout), ["alpha beta ", "gamma delta"])
        XCTAssertEqual(layout.original, "alpha beta gamma delta")
    }

    func testExactLimitDoesNotBreak() throws {
        XCTAssertTrue(try wrap(String(repeating: "x", count: 20), 20).insertions.isEmpty)
    }

    func testLongWordBreaksAtLimit() throws {
        let layout = try wrap(String(repeating: "a", count: 25), 10)
        XCTAssertEqual(displayedLines(layout), [String(repeating: "a", count: 10), String(repeating: "a", count: 10), "aaaaa"])
    }

    func testSpaceAtLimitStaysOnLine() throws {
        let layout = try wrap("abcd efgh", 4)
        XCTAssertEqual(displayedLines(layout), ["abcd ", "efgh"])
    }

    func testHangingIndentRepeatsLeadingWhitespace() throws {
        let layout = try wrap("    one two three four", 14)
        let lines = displayedLines(layout)
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines { XCTAssertTrue(line.hasPrefix("    "), line) }
        for line in lines { XCTAssertLessThanOrEqual(line.count, 15, line) }
    }

    func testHangingIndentIsCappedAtHalfTheLimit() throws {
        let indent = String(repeating: " ", count: 16)
        let layout = try wrap(indent + String(repeating: "z", count: 30), 20)
        for line in displayedLines(layout).dropFirst() {
            XCTAssertLessThanOrEqual(line.prefix { $0 == " " }.count, 10, line)
        }
    }

    func testTabsAdvanceToNextStop() throws {
        // "\t" is 4 columns, so "\tabcdef" is 10 columns and fits; one more character overflows.
        XCTAssertTrue(try wrap("\tabcdef", 10).insertions.isEmpty)
        let layout = try wrap("\tabcdefg", 10)
        XCTAssertEqual(displayedLines(layout).first, "\tabcdef")
        XCTAssertTrue(displayedLines(layout)[1].hasPrefix("\t"), "tab indent carried")
    }

    func testWideCharactersCountTwoColumns() throws {
        let layout = try wrap("日本語の文章です", 6)
        XCTAssertEqual(displayedLines(layout), ["日本語", "の文章", "です"])
        XCTAssertEqual(HardWrapLayout.columns(of: "日"), 2)
        XCTAssertEqual(HardWrapLayout.columns(of: "Ａ"), 2)
    }

    func testEmojiAndCombiningMarksAreNeverSplit() throws {
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(HardWrapLayout.columns(of: Character(family)), 2)
        XCTAssertEqual(HardWrapLayout.columns(of: "e\u{301}"), 1)
        XCTAssertEqual(HardWrapLayout.columns(of: "❤\u{FE0F}"), 2)
        let text = String(repeating: family, count: 5) + String(repeating: "e\u{301}", count: 7)
        let layout = try wrap(text, 4)
        for line in displayedLines(layout) {
            XCTAssertEqual(line.unicodeScalars.filter { $0.value == 0x200D }.count % 3, 0, "ZWJ sequence intact")
            XCTAssertFalse(line.unicodeScalars.first?.properties.generalCategory == .nonspacingMark, "combining mark kept with base")
        }
        XCTAssertEqual(layout.displayed.replacingOccurrences(of: "\n", with: ""), text)
    }

    func testCRLFAndCRAreLineBoundaries() throws {
        let layout = try wrap("aaaa bbbb\r\ncccc dddd\rshort", 5)
        XCTAssertEqual(layout.insertions.count, 2)
        XCTAssertEqual(layout.displayed, "aaaa \nbbbb\r\ncccc \ndddd\rshort")
    }

    func testCancellationIsHonoured() async throws {
        let text = String(repeating: "word word word word\n", count: 5_000)
        let task = Task { () -> HardWrapLayout in
            withUnsafeCurrentTask { $0?.cancel() }
            return try HardWrapLayout.wrap(text, lineLength: 8, tabStop: 4)
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }

    // MARK: - Mapping

    func testMappingRoundTripsEveryOriginalLocation() throws {
        let text = "    first second third fourth\n日本語の文章です and more words here\n"
        let layout = try wrap(text, 12)
        XCTAssertFalse(layout.insertions.isEmpty)
        let length = (text as NSString).length
        for location in 0...length {
            XCTAssertEqual(layout.originalLocation(forDisplayed: layout.displayedLocation(forOriginal: location)), location)
        }
        let full = NSRange(location: 0, length: (layout.displayed as NSString).length)
        XCTAssertEqual(layout.originalText(forDisplayed: full), text)
    }

    func testDisplayedRangeDoesNotIncludeInsertedText() throws {
        let layout = try wrap("alpha beta gamma", 11)
        let original = NSRange(location: 6, length: 5) // "beta "
        let displayed = layout.displayedRange(forOriginal: original)
        XCTAssertEqual((layout.displayed as NSString).substring(with: displayed), "beta ")
        let next = layout.displayedRange(forOriginal: NSRange(location: 11, length: 5))
        XCTAssertEqual((layout.displayed as NSString).substring(with: next), "gamma")
    }

    // MARK: - Views

    private func sourceOptions(_ mode: WordWrapMode, lineLength: Int = 20) -> SourceRenderConfiguration {
        .init(showLineNumbers: true, wrapMode: mode, lineLength: lineLength, tabsToSpaces: 4,
              fontFamily: "System Monospaced", fontSize: 12, lightTheme: .glimtDefault, darkTheme: .glimtDefault,
              lightPalette: nil, darkPalette: nil, indentationGuides: false)
    }

    private func sourceDocument(_ source: String) throws -> SourceDocument {
        let bytes = Data(source.utf8)
        return try SourceCodeInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), language: .swift)
    }

    @MainActor
    private func copied(from textView: NSTextView, range: NSRange) -> String? {
        let pasteboard = NSPasteboard(name: .init("GlimtHardWrapTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        textView.setSelectedRange(range)
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        return pasteboard.string(forType: .string)
    }

    @MainActor
    func testSourceHardWrapKeepsHighlightingLogicalLineNumbersAndCopyFidelity() throws {
        let source = "let greeting = \"hello world from glimt\"\nlet x = 1\n"
        let document = try sourceDocument(source)
        let view = SourceCodeView(options: sourceOptions(.hard))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.display(document)
        let displayed = view.textView.string
        XCTAssertNotEqual(displayed, source)
        XCTAssertEqual(displayed.replacingOccurrences(of: "\n", with: ""), source.replacingOccurrences(of: "\n", with: ""))
        XCTAssertEqual(view.textView.logicalLineStarts.count, document.lineStarts.count, "line numbers count logical lines only")
        let layout = try XCTUnwrap(view.textView.hardWrap)
        for start in document.lineStarts {
            XCTAssertTrue(view.textView.logicalLineStarts.contains(layout.displayedLocation(forOriginal: start)))
        }
        if let keyword = document.highlighting.runs.last(where: { $0.kind == .keyword }) {
            let displayedRange = layout.displayedRange(forOriginal: keyword.range)
            XCTAssertEqual((displayed as NSString).substring(with: displayedRange), (source as NSString).substring(with: keyword.range))
        }
        XCTAssertFalse(view.textView.textContainer?.widthTracksTextView ?? true, "Hard wrap does not also soft wrap")
        let all = NSRange(location: 0, length: (displayed as NSString).length)
        XCTAssertEqual(copied(from: view.textView, range: all), source)
    }

    @MainActor
    func testSourceOffAndSoftAreIdentity() throws {
        let source = "let greeting = \"hello world from glimt\"\n"
        for mode in [WordWrapMode.off, .soft] {
            let view = SourceCodeView(options: sourceOptions(mode))
            view.display(try sourceDocument(source))
            XCTAssertEqual(view.textView.string, source, mode.displayName)
            XCTAssertEqual(view.textView.textContainer?.widthTracksTextView, mode == .soft)
        }
    }

    @MainActor
    func testSwitchingFromHardBackToOffRestoresOriginal() throws {
        let source = "let greeting = \"hello world from glimt\"\n"
        let view = SourceCodeView(options: sourceOptions(.hard))
        view.display(try sourceDocument(source))
        XCTAssertNotEqual(view.textView.string, source)
        view.updateOptions(sourceOptions(.off))
        XCTAssertEqual(view.textView.string, source)
    }

    @MainActor
    private func previewText(_ contents: String, extension ext: String, mode: WordWrapMode) async throws -> (SharedPreviewViewController, String) {
        let controller = try await preview(contents, extension: ext, mode: mode)
        let text = descendants(controller.view).compactMap { $0 as? PreviewTextView }.filter { !$0.isHiddenOrHasHiddenAncestor }.first
        return (controller, try XCTUnwrap(text).string)
    }

    @MainActor
    private func preview(_ contents: String, extension ext: String, mode: WordWrapMode) async throws -> SharedPreviewViewController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtHardWrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.\(ext)")
        try Data(contents.utf8).write(to: url)
        var settings = GlimtSettingsV3()
        settings.general.wordWrap = mode
        settings.general.lineLength = 20
        let controller = SharedPreviewViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        _ = try await controller.preview(for: url, configuration: RenderConfiguration(settings: settings))
        return controller
    }

    @MainActor
    func testPlainTextHardWrapsAndCopiesOriginal() async throws {
        let contents = "a plain text line that is clearly longer than twenty columns\n"
        let (controller, displayed) = try await previewText(contents, extension: "txt", mode: .hard)
        XCTAssertNotEqual(displayed, contents)
        XCTAssertTrue(displayed.components(separatedBy: "\n").allSatisfy { $0.count <= 21 })
        let textView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewTextView }.first { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(copied(from: textView, range: NSRange(location: 0, length: (displayed as NSString).length)), contents)
    }

    @MainActor
    func testStructuredAndMarkdownAreNeverHardWrapped() async throws {
        let json = #"{"key": "a value that is clearly longer than twenty columns"}"# + "\n"
        let markdown = "A markdown paragraph that is clearly longer than twenty columns.\n"
        for (contents, ext) in [(json, "json"), (markdown, "md")] {
            let controller = try await preview(contents, extension: ext, mode: .hard)
            let tabs = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewTabStrip }.first)
            let target = ext == "json" ? "Raw" : "Rendered"
            let segment = try XCTUnwrap((0..<tabs.segmentCount).first { tabs.label(forSegment: $0) == target })
            tabs.selectedSegment = segment
            _ = tabs.sendAction(tabs.action, to: tabs.target)
            let textViews = descendants(controller.view).compactMap { $0 as? PreviewTextView }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
            XCTAssertFalse(textViews.isEmpty, ext)
            for textView in textViews {
                XCTAssertTrue(textView.hardWrap?.insertions.isEmpty ?? true, ext)
            }
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
