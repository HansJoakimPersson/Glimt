import AppKit
import XCTest
import InspectorCore

/// F1.5–F1.10: the settings window built from SettingsSession — the unified Settings view, its
/// sheets, the shared preview pane and the Quick Look footer. Replaces PreviewHarnessTests (see docs/06).
@MainActor
final class SettingsWindowTests: XCTestCase {
    private nonisolated(unsafe) var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtSettingsWindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRoot(session: SettingsSession? = nil, size: NSSize = .init(width: 1100, height: 700)) -> (SettingsRootViewController, NSWindow) {
        let root = SettingsRootViewController(session: session ?? SettingsSession(store: nil, snapshot: nil), sampleBundle: productShowcaseBundle())
        root.presentSheet = { _ in }
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        window.setContentSize(size)
        root.view.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in window.contentViewController = nil; window.close() }
        return (root, window)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func visible(_ view: NSView) -> [NSView] { descendants(view).filter { !$0.isHiddenOrHasHiddenAncestor } }
    private func labels(_ view: NSView) -> [String] { visible(view).compactMap { ($0 as? NSTextField)?.stringValue } }

    // MARK: RC UX audit (generic quality checks over every visible control)

    /// One audit finding: what is wrong, and where.
    private struct AuditIssue: CustomStringConvertible {
        let kind: String, view: String, detail: String
        var description: String { "\(kind): \(view) \(detail)" }
    }

    private func name(of view: NSView) -> String? {
        let candidates: [String?] = [view.accessibilityLabel(), view.accessibilityTitle(), (view as? NSButton)?.title,
                                     (view as? NSButton)?.image?.accessibilityDescription,
                                     (view.accessibilityTitleUIElement() as? NSTextField)?.stringValue,
                                     (view as? NSSearchField)?.placeholderString]
        return candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func ancestors(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        var current = view.superview
        while let next = current { result.append(next); current = next.superview }
        return result
    }

    private func describe(_ view: NSView) -> String {
        "\(type(of: view))[\(view.identifier?.rawValue ?? "-")|\(name(of: view) ?? (view as? NSTextField)?.stringValue ?? "?")]"
    }

    /// Unnamed controls, truncated single-line labels, controls outside the pane and overlapping controls.
    private func audit(_ pane: NSView, in root: NSView) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        let shown = visible(pane).filter { view in
            !ancestors(of: view).contains { $0 is NSTableView || $0 is NSTextView }
        }
        let controls: [NSControl] = shown.compactMap { $0 as? NSControl }.filter { control in
            if let field = control as? NSTextField, !field.isEditable { return false }
            guard control.frame.width > 0, control.frame.height > 0, !(control is PreviewTabStrip), !(control is NSScroller) else { return false }
            // Representation tabs are audited one by one; their strip is only a container.
            return !ancestors(of: control).contains { $0 is NSControl && !($0 is PreviewTabStrip) }
        }
        for control in controls where name(of: control) == nil {
            issues.append(.init(kind: "unnamed", view: describe(control), detail: ""))
        }
        let bounds = root.bounds.insetBy(dx: -0.5, dy: -0.5)
        // Scrolled content is judged by the part its clip view shows, not by its document frame.
        let frames = controls.compactMap { control -> (NSControl, NSRect)? in
            let shownRect = ancestors(of: control).compactMap { $0 as? NSClipView }
                .reduce(control.convert(control.bounds, to: root)) { $0.intersection($1.convert($1.bounds, to: root)) }
            return shownRect.isNull || shownRect.isEmpty ? nil : (control, shownRect)
        }
        for control in controls where !ancestors(of: control).contains(where: { $0 is NSClipView }) {
            let frame = control.convert(control.bounds, to: root)
            if !bounds.contains(frame) { issues.append(.init(kind: "outside", view: describe(control), detail: "\(frame)")) }
        }
        for (i, a) in frames.enumerated() { for b in frames.dropFirst(i + 1) {
            let overlap = a.1.intersection(b.1)
            if !overlap.isNull, overlap.width > 1, overlap.height > 1 {
                issues.append(.init(kind: "overlap", view: describe(a.0), detail: "\(a.1) with \(describe(b.0)) \(b.1)"))
            }
        } }
        for label in shown.compactMap({ $0 as? NSTextField }) where !label.isEditable && label.frame.width > 0 {
            guard !ancestors(of: label).contains(where: { $0 is NSClipView }) else { continue }
            // Cut off by an enclosing view (scrolling aside), as when a footer is too narrow.
            let full = label.convert(label.alignmentRect(forFrame: label.bounds), to: root)
            let seen = ancestors(of: label).prefix { $0 !== root.superview }.filter { !($0 is NSClipView) && !ancestors(of: $0).contains { $0 is NSClipView } }
                .reduce(full) { $0.intersection($1.convert($1.bounds, to: root)) }
            if seen.isNull || seen.width < full.width - 1 {
                issues.append(.init(kind: "clipped", view: describe(label), detail: "\(full) shows \(seen)"))
            }
        }
        for label in shown.compactMap({ $0 as? NSTextField }) where !label.isEditable && label.maximumNumberOfLines == 1 && label.frame.width > 0 {
            if label.intrinsicContentSize.width > label.frame.width + 1 {
                issues.append(.init(kind: "truncated", view: describe(label), detail: "\(label.intrinsicContentSize.width) > \(label.frame.width)"))
            }
        }
        let window = root.window
        window?.recalculateKeyViewLoop()
        var reachable: [NSView] = []
        var next = window?.contentView?.nextValidKeyView
        while let view = next, !reachable.contains(where: { $0 === view }), reachable.count < 500 {
            reachable.append(view); next = view.nextValidKeyView
        }
        for control in controls where control.isEnabled && (control is NSTextField || control is NSTableView) {
            if !reachable.contains(where: { $0 === control || $0.isDescendant(of: control) }) {
                issues.append(.init(kind: "keyboard", view: describe(control), detail: "not in the key-view loop"))
            }
        }
        if controls.count < 4 { issues.append(.init(kind: "audit", view: "pane", detail: "saw only \(controls.count) controls")) }
        return issues
    }

    /// RC UX review (16 §6): in both appearances at the minimum window size, the Settings view with
    /// Advanced collapsed and expanded has no unnamed, clipped, truncated, overlapping or
    /// keyboard-unreachable control.
    func testEveryVisibleControlIsNamedUnclippedAndClearAtMinimumSize() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let session = SettingsSession(store: nil, snapshot: nil)
            let (root, window) = makeRoot(session: session, size: .init(width: 1000, height: 620))
            window.appearance = NSAppearance(named: appearance)
            await root.general.preview.waitForPreview()
            for state in ["collapsed", "advanced"] {
                if state == "advanced" { root.general.advancedDisclosure.performClick(nil) }
                root.view.layoutSubtreeIfNeeded()
                for issue in audit(root.general.view, in: root.view) { XCTFail("AUDIT settings/\(state) \(appearance.rawValue) \(issue)") }
            }
        }
    }

    /// Formats & Views (format with mappings and open editor, category, no selection) and Format
    /// Options meet the same audit at their opening sizes.
    func testSheetControlsAreNamedUnclippedAndClear() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let session = SettingsSession(store: nil, snapshot: nil)
            let (root, _) = makeRoot(session: session)
            var presented: NSViewController?
            root.presentSheet = { presented = $0 }
            XCTAssertNil(session.addMapping(kind: .fileExtension, value: "mdx2", target: .markdown))
            XCTAssertNil(session.addMapping(kind: .filename, value: "NOTES", target: .markdown))
            let formats = root.showFormatsAndViews(selecting: .format(.markdown))
            XCTAssertTrue(presented === formats)
            let options = FormatOptionsSheet(session: session, format: .markdown)
            for (sheet, tab) in [(formats as NSViewController, "format"), (formats, "editor"), (formats, "category"), (formats, "none"), (options, "")] {
                sheet.loadViewIfNeeded()
                switch tab {
                case "editor": formats.mappings.beginAdd(nil)
                case "category": formats.mappings.cancelDraft(nil); formats.select(.category(.renderedDocuments))
                case "none": formats.outline.deselectAll(nil)
                default: break
                }
                let size = sheet === formats ? FormatsAndViewsSheet.preferredSize : sheet.view.fittingSize
                let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentViewController = sheet
                window.setContentSize(size)
                sheet.view.layoutSubtreeIfNeeded()
                for issue in audit(sheet.view, in: sheet.view) { XCTFail("AUDIT \(type(of: sheet)) \(tab) \(appearance.rawValue) \(issue)") }
                window.contentViewController = nil
            }
        }
    }

    /// A disabled number field also dims its unit, so "characters" never looks available (D35).
    func testDisabledNumberFieldDimsItsSuffix() throws {
        let field = NumberStepperField(range: 1...10, suffix: "characters", accessibilityLabel: "Line length", identifier: "Test")
        let suffix = try XCTUnwrap(field.arrangedSubviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "characters" })
        field.isEnabled = false
        XCTAssertEqual(suffix.textColor, .disabledControlTextColor)
        field.isEnabled = true
        XCTAssertEqual(suffix.textColor, .labelColor)
    }

    /// The swatch sample shows whole tokens: all of them at the preferred width, never a cut word (D36).
    func testThemeSwatchSampleShowsWholeTokens() {
        XCTAssertEqual(ThemeSwatchButton.sampleTokenCount(fitting: 156), ThemeSwatchButton.sample.count)
        XCTAssertGreaterThanOrEqual(ThemeSwatchButton.sampleTokenCount(fitting: 88), 3, "Keyword, name and operator at the minimum width")
    }

    // MARK: F1.5 window shell

    /// One unified Settings view (spec §4): no pane toolbar and no tabs; Inquiry stays a trailing
    /// titlebar accessory.
    func testWindowIsOneSettingsViewWithInquiryAccessory() throws {
        let (root, window) = makeRoot()
        root.viewDidAppear()
        XCTAssertNil(window.toolbar, "No General/Format toolbar")
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.title, "Glimt")
        XCTAssertFalse(descendants(root.view).contains { $0 is NSTabView }, "No settings tabs")
        let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.first { root.inquiryButton.isDescendant(of: $0.view) })
        XCTAssertEqual(accessory.layoutAttribute, .trailing)
        root.viewDidAppear()
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1, "Appearing again does not add a second Inquiry")
        XCTAssertEqual(root.inquiryButton.toolTip, "Inquiry")
        XCTAssertEqual(root.inquiryButton.accessibilityLabel(), "Inquiry")
        XCTAssertEqual(root.inquiryButton.image?.accessibilityDescription, "Inquiry")
        XCTAssertEqual(root.inquiryButton.action, #selector(SettingsRootViewController.inquiryFile(_:)))
        XCTAssertEqual(root.inquiryButton.title, "Inquiry", "Inquiry keeps its visible label")
        XCTAssertTrue(root.activePreview === root.general.preview)
        XCTAssertFalse(root.general.view.isHiddenOrHasHiddenAncestor)
    }

    /// E5-08: Inquiry opens compact enough for Standard, stays resizable, and Advanced scrolls.
    func testInquiryOpensCompactAndAdvancedScrolls() async throws {
        let (root, _) = makeRoot()
        let savedSettings = root.session.settings
        let inquiry = root.showInquiry(for: try fixtureURL("Cases/source/Example.swift"))
        XCTAssertEqual(root.session.settings, savedSettings, "Inquiry does not change saved settings")
        let window = try XCTUnwrap(inquiry.view.window)
        defer { window.close() }
        for _ in 0..<100 where inquiry.report == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(inquiry.report)
        XCTAssertEqual(window.contentLayoutRect.height, SettingsRootViewController.inquirySize.height, accuracy: 1)
        XCTAssertLessThan(SettingsRootViewController.inquirySize.height, 650, "Smaller than the earlier 650 pt")
        XCTAssertTrue(window.styleMask.contains(.resizable))
        let scroll = try XCTUnwrap(descendants(inquiry.view).compactMap { $0 as? NSScrollView }.first)
        func overflow() -> CGFloat {
            inquiry.view.layoutSubtreeIfNeeded()
            return (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        }
        XCTAssertLessThanOrEqual(overflow(), 0, "Standard fits without scrolling")
        let mode = try XCTUnwrap(descendants(inquiry.view).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == "InquiryMode" })
        mode.selectedSegment = 1; _ = mode.sendAction(mode.action, to: mode.target)
        XCTAssertGreaterThan(overflow(), 0, "Advanced keeps every row and scrolls")
        XCTAssertTrue(scroll.hasVerticalScroller)
    }

    func testWindowHonorsMinimumSize() {
        let (root, window) = makeRoot(size: .init(width: 600, height: 400))
        root.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(root.view.fittingSize.width, 1000)
        XCTAssertGreaterThanOrEqual(root.view.fittingSize.height, 620)
        _ = window
    }

    func testStatusBannerShowsPersistenceStateOnly() async throws {
        let (preview, _) = makeRoot()
        XCTAssertTrue(labels(preview.view).contains(SettingsSession.unconfiguredMessage))
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        XCTAssertFalse(labels(root.view).contains(SettingsSession.unconfiguredMessage))
        XCTAssertFalse(descendants(root.view).first { $0.identifier?.rawValue == "SettingsStatusBar" }?.isHidden == false)
    }

    // MARK: F1.6 General

    /// The General switch reaches the drawn Quick Look preview: guides appear at each indentation level.
    func testGeneralIndentationGuidesDrawInQuickLookPreview() async throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        root.general.showShowcase()
        await root.general.preview.waitForPreview()
        root.view.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(descendants(root.general.preview.view).compactMap { $0 as? SourceCodeTextView }.first)
        let toggle = root.general.indentationGuides
        XCTAssertEqual(toggle.state, .on, "On by default")
        XCTAssertTrue(text.indentationGuidesEnabled)
        let guides = text.indentationGuideRects(in: text.visibleRect)
        XCTAssertGreaterThan(Set(guides.map { Int($0.minX) }).count, 1, "Guides at more than one indentation level")
        func pixels() throws -> Data {
            let rep = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: text.visibleRect))
            text.cacheDisplay(in: text.visibleRect, to: rep)
            return try XCTUnwrap(rep.tiffRepresentation)
        }
        let on = try pixels()
        toggle.state = .off
        XCTAssertTrue(NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle))
        XCTAssertNotEqual(on, try pixels(), "Turning guides off changes the drawn preview")
    }

    /// D62: General edits re-render the interactive preview at once; there is no thumbnail surface.
    func testGeneralEditsUpdateTheInteractivePreview() async throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        let general = root.general
        general.showShowcase()
        await general.preview.waitForPreview()
        XCTAssertNil(descendants(general.preview.view).first { $0.identifier?.rawValue == "PreviewSurfaceMode" },
                     "No Quick Look/Thumbnail switch")
        XCTAssertNil(descendants(general.view).first { $0.identifier?.rawValue == "ThumbnailStage" })

        let toggle = general.indentationGuides
        toggle.state = .off
        XCTAssertTrue(NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle))
        XCTAssertFalse(general.preview.previewController.configuration.source(for: .swift).indentationGuides)
        general.quickLookFontSize.onChange?(16)
        XCTAssertEqual(general.preview.previewController.configuration.source(for: .swift).fontSize, 16)
        XCTAssertFalse(general.preview.previewController.footerStrip.isHiddenOrHasHiddenAncestor)
    }

    func testGeneralRowsAreOrderedAndControlsWriteGeneral() async throws {
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        let general = root.general
        general.advancedDisclosure.performClick(nil)
        let expectedRows = ["GeneralRow-ColorScheme", "GeneralRow-TextFont", "GeneralRow-Font",
                            "GeneralRow-QuickLookFontSize", "GeneralRow-WordWrap", "GeneralRow-LineLength", "GeneralRow-LineNumbers",
                            "GeneralRow-IndentationGuides", "GeneralRow-Tabs", "GeneralRow-FormatsAndViews",
                            "GeneralRow-DataLimit", "GeneralRow-VCSSupport"]
        let rows = visible(general.view).compactMap { $0.identifier?.rawValue }.filter { expectedRows.contains($0) }
        XCTAssertEqual(rows, expectedRows)
        XCTAssertFalse(labels(general.view).contains("General settings"))
        XCTAssertFalse(labels(general.view).contains("Settings applied to all supported formats"))
        XCTAssertFalse(labels(general.view).contains { $0.localizedCaseInsensitiveContains("Diagnostics") })
        XCTAssertEqual(general.vcsSupport.state, .off, "VCS reads default to off")
        XCTAssertTrue(labels(general.view).contains("Number of spaces a tab character will render as."))
        XCTAssertEqual(descendants(general.view).compactMap { $0 as? NSSlider }.map(\.identifier?.rawValue),
                       ["QuickLookFontSize", "TabsToSpaces"])
        let expectedSwitches: [String?]
#if DEBUG
        expectedSwitches = ["LineNumbers", "IndentationGuides", "VCSSupport", "DebugLogging", "DebugBuildMarker"]
#else
        expectedSwitches = ["LineNumbers", "IndentationGuides", "VCSSupport", "DebugLogging"]
#endif
        XCTAssertEqual(descendants(general.view).compactMap { $0 as? NSSwitch }.map(\.identifier?.rawValue), expectedSwitches)
        XCTAssertEqual(general.indentationGuides.state, .on, "Guides default to on")
        general.indentationGuides.state = .off
        XCTAssertTrue(NSApp.sendAction(general.indentationGuides.action!, to: general.indentationGuides.target, from: general.indentationGuides))
        XCTAssertFalse(session.settings.general.indentationGuides)
        XCTAssertFalse(session.renderConfiguration.source(for: .swift).indentationGuides, "General guides reach every source format")
        XCTAssertEqual(general.textFont.value, "System")
        general.textFont.selectItem(withTitle: "Georgia")
        XCTAssertTrue(NSApp.sendAction(general.textFont.action!, to: general.textFont.target, from: general.textFont))
        XCTAssertEqual(session.renderConfiguration.markdown.textFont, "Georgia")
        XCTAssertTrue(general.font.accessibilityLabel()?.contains(general.font.value.family) == true)
        XCTAssertTrue(general.font.menu?.items.contains { $0.title == general.font.value.family } == true)
        XCTAssertFalse(general.font.menu?.items.contains { $0.title.hasSuffix(" pt") } == true)
        XCTAssertEqual(general.quickLookFontSize.slider.doubleValue, session.settings.general.font.size)
        general.quickLookFontSize.slider.doubleValue = 17
        XCTAssertTrue(NSApp.sendAction(general.quickLookFontSize.slider.action!, to: general.quickLookFontSize.slider.target, from: general.quickLookFontSize.slider))
        XCTAssertEqual(session.settings.general.font.size, 17)
        XCTAssertEqual(session.renderConfiguration.source.fontSize, 17)

        // Line length is editable only with Hard wrap; its value is retained otherwise.
        XCTAssertFalse(general.lineLength.isEnabled)
        general.wordWrap.selectItem(at: 2)
        general.wordWrap.onChange?(.hard)
        XCTAssertTrue(general.lineLength.isEnabled)
        general.lineLength.onChange?(100)
        general.wordWrap.onChange?(.soft)
        XCTAssertFalse(general.lineLength.isEnabled)
        XCTAssertEqual(session.settings.general.lineLength, 100)

        // A legacy stored 0 shows as the kept tab stop without being rewritten.
        session.update { $0.general.tabsToSpaces = 0 }
        XCTAssertEqual(general.tabs.value, 4)
        XCTAssertEqual(session.settings.general.tabsToSpaces, 0)
        general.tabs.slider.doubleValue = 8
        XCTAssertTrue(NSApp.sendAction(general.tabs.slider.action!, to: general.tabs.slider.target, from: general.tabs.slider))
        XCTAssertEqual(session.settings.general.tabsToSpaces, 8)
        general.dataLimit.unitPopup.selectItem(at: 0)
        general.dataLimit.onUnitChange?(.kb)
        let feedback = general.dataLimit.onCommit?(Double(1_048_577) / Double(DataLimitUnit.kb.bytes), .kb)
        XCTAssertEqual(feedback, "The maximum is 1 MiB (1024 KiB).")
        await session.waitForPersistence()
        let saved = try SettingsStore(directory: directory).loadV3().settings.general
        XCTAssertEqual(saved.lineLength, 100)
        XCTAssertEqual(saved.wordWrap, .soft)
        XCTAssertEqual(saved.dataLimitBytes, 1_048_576)
    }

    func testVCSSupportToggleIsOptInAndPersists() async throws {
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        let toggle = root.general.vcsSupport

        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertTrue(session.settings.general.vcsSupportEnabled)
        await session.waitForPersistence()

        let saved = try SettingsStore(directory: directory).loadV3().settings.general
        XCTAssertTrue(saved.vcsSupportEnabled)
    }

    /// ADR-023: Debug logging is an opt-in Advanced switch; Show Log File reveals the log in Finder.
    func testDebugLoggingToggleIsOptInAndPersists() async throws {
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        let general = root.general
        general.advancedDisclosure.performClick(nil)
        let rows = visible(general.view).compactMap { $0.identifier?.rawValue }
        let advanced = ["GeneralRow-DataLimit", "GeneralRow-VCSSupport", "GeneralRow-DebugLogging", "GeneralRow-DebugLogFile"]
        XCTAssertEqual(rows.filter { advanced.contains($0) }, advanced)
        XCTAssertTrue(labels(general.view).contains("Write a local troubleshooting log. File names, paths and contents are never logged."))
        var revealed = 0
        general.revealLogFile = { revealed += 1 }
        general.showLogFile.performClick(nil)
        XCTAssertEqual(revealed, 1)

        let toggle = general.debugLogging
        XCTAssertEqual(toggle.state, .off)
        toggle.performClick(nil)
        XCTAssertTrue(session.settings.general.debugLoggingEnabled)
        await session.waitForPersistence()
        XCTAssertTrue(try SettingsStore(directory: directory).loadV3().settings.general.debugLoggingEnabled)
    }

    /// Debug builds offer Advanced › Build marker after the log rows; turning it off persists.
#if DEBUG
    func testDebugBuildMarkerToggleFollowsTheLogRowsAndPersists() async throws {
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        let general = root.general
        general.advancedDisclosure.performClick(nil)
        let rows = visible(general.view).compactMap { $0.identifier?.rawValue }
        let tail = ["GeneralRow-DebugLogging", "GeneralRow-DebugLogFile", "GeneralRow-DebugBuildMarker"]
        XCTAssertEqual(rows.filter { tail.contains($0) }, tail)

        let toggle = general.debugBuildMarker
        XCTAssertEqual(toggle.state, .on)
        toggle.performClick(nil)
        XCTAssertFalse(session.settings.general.debugBuildMarker)
        XCTAssertFalse(session.renderConfiguration.showsDebugBuildMarker)
        await session.waitForPersistence()
        XCTAssertFalse(try SettingsStore(directory: directory).loadV3().settings.general.debugBuildMarker)
    }
#endif

    /// Spec §4: Appearance, Preview, Formats & Views and a collapsible Advanced section; no
    /// Thumbnails group (D62) and no General/Format tabs.
    func testUnifiedSettingsSectionsAndHelp() throws {
        let (root, _) = makeRoot()
        let sections = ["GeneralAppearance", "GeneralPreview", "GeneralFormatsAndViews", "GeneralAdvanced"]
        let sectionIDs = visible(root.general.view).compactMap(\.identifier?.rawValue).filter { sections.contains($0) || $0 == "GeneralThumbnails" }
        XCTAssertEqual(sectionIDs, sections, "No Thumbnails group (D62)")
        for title in ["Appearance", "Preview", "Formats & Views", "Advanced"] {
            XCTAssertTrue(labels(root.general.view).contains(title), title)
        }
        XCTAssertFalse(labels(root.general.view).contains("Thumbnails"))
        XCTAssertFalse(labels(root.general.view).contains("Quick Look"))
        var headingLeadingEdge: CGFloat?
        for identifier in sections.dropLast() {
            let heading = try XCTUnwrap(visible(root.general.view).first { $0.identifier?.rawValue == identifier } as? NSTextField)
            XCTAssertEqual(heading.alignment, .left, "Section heading is left-aligned: \(identifier)")
            let leadingEdge = heading.convert(heading.bounds, to: root.general.view).minX
            if let headingLeadingEdge {
                XCTAssertEqual(leadingEdge, headingLeadingEdge, accuracy: 0.5,
                               "Section headings share a consistent leading edge: \(identifier)")
            } else { headingLeadingEdge = leadingEdge }
        }
        // Advanced is collapsed until its disclosure is used; its heading follows the disclosure.
        let advanced = try XCTUnwrap(visible(root.general.view).first { $0.identifier?.rawValue == "GeneralAdvanced" })
        let disclosure = root.general.advancedDisclosure
        XCTAssertEqual(disclosure.bezelStyle, .disclosure)
        XCTAssertLessThan(disclosure.convert(disclosure.bounds, to: root.general.view).minX, advanced.convert(advanced.bounds, to: root.general.view).minX)
        XCTAssertEqual(disclosure.accessibilityLabel(), "Show Advanced settings")
        XCTAssertNil(visible(root.general.view).first { $0.identifier?.rawValue == "GeneralRow-DataLimit" })
        disclosure.performClick(nil)
        let dataLimit = try XCTUnwrap(visible(root.general.view).first { $0.identifier?.rawValue == "GeneralRow-DataLimit" })
        let clip = try XCTUnwrap(dataLimit.enclosingScrollView?.contentView)
        XCTAssertTrue(clip.bounds.intersects(dataLimit.convert(dataLimit.bounds, to: clip)), "Expanding scrolls the Advanced rows into view")
        XCTAssertEqual(disclosure.accessibilityLabel(), "Hide Advanced settings")
        XCTAssertFalse(labels(root.general.view).contains("General settings"))
        XCTAssertFalse(labels(root.general.view).contains("Settings applied to all supported formats"))

        let expectedRows = ["GeneralRow-ColorScheme", "GeneralRow-TextFont", "GeneralRow-Font",
                            "GeneralRow-QuickLookFontSize", "GeneralRow-WordWrap", "GeneralRow-LineLength", "GeneralRow-LineNumbers",
                            "GeneralRow-IndentationGuides", "GeneralRow-Tabs", "GeneralRow-FormatsAndViews",
                            "GeneralRow-DataLimit", "GeneralRow-VCSSupport"]
        XCTAssertEqual(visible(root.general.view).compactMap { $0.identifier?.rawValue }.filter { expectedRows.contains($0) }, expectedRows)
        // UX-02 (`16` §3.2, D60): every General row carries help; spacing, not hairlines, separates rows.
        XCTAssertTrue(visible(root.general.view).filter { $0 is NSBox && ($0 as! NSBox).boxType == .separator }.isEmpty,
                      "No separators between General rows")
        for help in [
            "Choose the app's appearance.",
            "Set font for rendered Markdown text.",
            "Set font for places like source code, code blocks and structured text.",
            "Number of spaces a tab character will render as.",
            "Maximum size for text-based previews.",
            "Show local Git and SVN changes in the gutter.",
            "Font size in points that affects source and structured text.",
            "Wrap long lines. Affects display, never the original file.",
            "Characters per line with Hard wrap.",
            "Show line numbers in the gutter.",
            "Choose which views each format offers, their order and default, and which file names preview as which format."
        ] {
            XCTAssertTrue(labels(root.general.view).contains(help), "Missing v8 help: \(help)")
        }
        XCTAssertTrue(root.general.resetAll.isHidden, "Factory defaults have no reset action")
        XCTAssertTrue(root.general.retiredRow.isHiddenOrHasHiddenAncestor, "No retired overrides at factory values")
    }

    /// Configure… opens Formats & Views; Open File… and Inquiry previews stay in the Live Preview.
    func testConfigureOpensFormatsAndViews() throws {
        let (root, window) = makeRoot()
        root.presentSheet = { [weak root] sheet in root?.presentAsSheet(sheet) }
        let configure = root.general.configureFormats
        XCTAssertEqual(configure.title, "Configure…")
        XCTAssertEqual(configure.accessibilityLabel(), "Configure Formats & Views")
        configure.performClick(nil)
        let sheet = try XCTUnwrap(root.presentedSheet as? FormatsAndViewsSheet)
        XCTAssertTrue(window.attachedSheet?.contentViewController === sheet, "Configure presents the actual sheet")
        XCTAssertTrue(root.showFormatsAndViews(selecting: .format(.yaml)) === sheet, "One sheet")
        XCTAssertEqual(sheet.mappings.context, .format(.yaml, hiddenBySearch: false), "File Mappings follow the selected format")
    }

    func testConfigureCanReopenFormatsAndViewsAfterDismissal() async throws {
        let (root, window) = makeRoot()
        root.presentSheet = { [weak root] sheet in root?.presentAsSheet(sheet) }
        let configure = root.general.configureFormats

        configure.performClick(nil)
        let first = try XCTUnwrap(root.presentedSheet as? FormatsAndViewsSheet)
        first.doneButton.performClick(nil)
        for _ in 0..<20 where window.attachedSheet != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(window.attachedSheet, "Done closes the first Formats & Views sheet")

        configure.performClick(nil)
        let second = try XCTUnwrap(root.presentedSheet as? FormatsAndViewsSheet)
        XCTAssertFalse(first === second, "A dismissed sheet must not be reused")
        XCTAssertTrue(window.attachedSheet?.contentViewController === second)
    }

    /// Spec §12: retired per-format appearance is kept and announced; discarding needs confirmation
    /// and keeps view and option overrides.
    func testRetiredOverridesAreAnnouncedAndDiscardedOnlyOnConfirmation() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        let general = root.general
        session.updateFormat(.python) { $0.lineNumbers = .init(isEnabled: true, value: false) }
        session.updateFormat(.swift) { $0.font = .init(isEnabled: true, value: session.settings.general.font) }
        session.updateFormat(.json) { $0.structured = .init(sortKeys: true) }
        root.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(general.retiredRow.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(general.retiredNotice.stringValue, "2 formats keep appearance values that no longer apply.")
        XCTAssertEqual(general.discardRetired.title, "Discard Retired Overrides…")
        general.confirmDiscardRetired = { completion in completion(false) }
        general.discardRetired.performClick(nil)
        XCTAssertEqual(session.settings.formatsWithRetiredAppearance, ["python", "swift"], "Cancel keeps the data")
        general.confirmDiscardRetired = { completion in completion(true) }
        general.discardRetired.performClick(nil)
        XCTAssertEqual(session.settings.formatsWithRetiredAppearance, [])
        XCTAssertEqual(session.settings[.json].structured?.sortKeys, true, "Format Options are not retired")
        XCTAssertTrue(general.retiredRow.isHiddenOrHasHiddenAncestor)
    }

    /// ADR-038: a file inside a Git working copy shows its line changes and last commit without any
    /// folder setup; the repository is found from the file's own path.
    func testRepositoryFileShowsGitChangesAndLastCommitWithoutSetup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = repository.appendingPathComponent("main.swift")
        try Data("let a = 1\nlet b = 2\n".utf8).write(to: file)
        for arguments in [["init", "-q"], ["add", "main.swift"],
                          ["-c", "user.name=Glimt", "-c", "user.email=glimt@example.invalid", "commit", "-q", "-m", "base"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = repository
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        try Data("let a = 1\nlet b = 3\n".utf8).write(to: file)

        let session = SettingsSession(store: nil, snapshot: nil)
        session.update { $0.general.vcsSupportEnabled = true }
        let general = GeneralSettingsViewController(session: session, sampleBundle: productShowcaseBundle())
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = general
        addTeardownBlock { @MainActor in window.contentViewController = nil; window.close() }
        general.preview.show(file, title: "main.swift")
        await general.preview.waitForPreview()

        let code = try XCTUnwrap(descendants(general.preview.view).compactMap { $0 as? SourceCodeView }.first)
        let ruler = try XCTUnwrap(code.scrollView.verticalRulerView as? SourceLineNumberRuler)
        let status = try XCTUnwrap(descendants(general.preview.view).compactMap { $0 as? PreviewStatusView }.first {
            $0.identifier == NSUserInterfaceItemIdentifier("PreviewStatus")
        })
        for _ in 0..<200 where ruler.lineDiff == nil || !status.stringValue.contains("Commit ") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ruler.lineDiff?.changes.map(\.kind), [.modified])
        XCTAssertTrue(status.stringValue.contains("Git: Modified"), status.stringValue)
        XCTAssertTrue(status.stringValue.contains("Commit "), status.stringValue)
    }

    func testGeneralV7GeometryAndScrollContainment() throws {
        let (root, window) = makeRoot()
        let sizes: [NSSize] = [.init(width: 1000, height: 620), .init(width: 1100, height: 700),
                               .init(width: 1280, height: 800), .init(width: 1600, height: 1000)]
        for (index, size) in sizes.enumerated() {
            root.general.view.appearance = NSAppearance(named: index.isMultiple(of: 2) ? .aqua : .darkAqua)
            window.setContentSize(size)
            root.view.layoutSubtreeIfNeeded()
            root.general.view.layoutSubtreeIfNeeded()
            if root.general.advancedContent.isHidden { root.general.advancedDisclosure.performClick(nil); root.view.layoutSubtreeIfNeeded() }
            let width = root.general.view.bounds.width
            let divider = try XCTUnwrap(visible(root.general.view).first { $0.identifier?.rawValue == "GeneralDivider" })
            let settings = try XCTUnwrap(visible(root.general.view).first { $0.identifier?.rawValue == "GeneralSettings" } as? NSScrollView)
            let preview = root.general.preview.view
            XCTAssertEqual(settings.frame.width, (width - 1) * 0.6, accuracy: 0.5, "settings width at \(size)")
            XCTAssertEqual(divider.frame.width, 1, accuracy: 0.5)
            XCTAssertEqual(preview.frame.width, (width - 1) * 0.4, accuracy: 0.5, "preview width at \(size)")
            XCTAssertEqual(settings.frame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(divider.frame.minX, settings.frame.maxX, accuracy: 0.5)
            XCTAssertEqual(preview.frame.minX, divider.frame.maxX, accuracy: 0.5)
            XCTAssertEqual(preview.frame.maxX, width, accuracy: 0.5)
            XCTAssertFalse(settings.hasHorizontalScroller)
            XCTAssertEqual(settings.documentView?.frame.width ?? 0, settings.contentView.bounds.width, accuracy: 0.5)
            let expectedRows = ["GeneralRow-ColorScheme", "GeneralRow-TextFont", "GeneralRow-Font",
                            "GeneralRow-QuickLookFontSize", "GeneralRow-WordWrap", "GeneralRow-LineLength", "GeneralRow-LineNumbers",
                            "GeneralRow-IndentationGuides", "GeneralRow-Tabs", "GeneralRow-FormatsAndViews",
                            "GeneralRow-DataLimit", "GeneralRow-VCSSupport"]
            let formRows = visible(root.general.view).filter { expectedRows.contains($0.identifier?.rawValue ?? "") }
            XCTAssertEqual(formRows.count, 12)
            for row in formRows {
                let inDocument = row.convert(row.bounds, to: settings.documentView)
                XCTAssertGreaterThanOrEqual(inDocument.minX, 23.5)
                XCTAssertLessThanOrEqual(inDocument.maxX, (settings.documentView?.bounds.maxX ?? 0) - 23.5)
            }
        }
    }

    func testGeneralV7DisabledValueAndResetBehavior() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        session.update { $0.general.wordWrap = .hard; $0.general.lineLength = 80 }
        root.view.layoutSubtreeIfNeeded()
        session.update { $0.general.wordWrap = .soft }
        XCTAssertFalse(root.general.lineLength.isEnabled)
        XCTAssertEqual(session.settings.general.lineLength, 80)

        var confirmed = false
        root.general.confirmResetAll = { completion in completion(false) }
        root.general.resetAll.performClick(nil)
        XCTAssertFalse(confirmed)
        XCTAssertNotEqual(session.settings, .factoryDefaults)

        root.general.confirmResetAll = { completion in confirmed = true; completion(true) }
        root.general.resetAll.performClick(nil)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(session.settings, .factoryDefaults)
        XCTAssertTrue(root.general.resetAll.isHidden)
        XCTAssertEqual(root.general.colorScheme.value, .system)
    }

    /// D51: Color scheme is a persisted General setting that switches the whole app at once.
    func testColorSchemeSwitchesTheWholeAppAndPersists() async throws {
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        addTeardownBlock { @MainActor in NSApp.appearance = nil }
        let popup = root.general.colorScheme
        XCTAssertEqual((0..<popup.numberOfItems).map { popup.itemTitle(at: $0) }, ["Light", "Dark", "Adapt to system"])
        popup.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(popup.action!, to: popup.target, from: popup))
        XCTAssertEqual(session.settings.general.colorScheme, .dark)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        XCTAssertEqual(session.renderConfiguration.appearance, .dark)
        popup.selectItem(at: 2)
        XCTAssertTrue(NSApp.sendAction(popup.action!, to: popup.target, from: popup))
        XCTAssertNil(NSApp.appearance, "Adapt to system follows macOS")
        popup.selectItem(at: 0)
        XCTAssertTrue(NSApp.sendAction(popup.action!, to: popup.target, from: popup))
        await session.waitForPersistence()
        let reloaded = await SettingsSession.load(store: SettingsStore(directory: directory))
        XCTAssertEqual(reloaded.settings.general.colorScheme, .light)
    }

    func testGeneralPreviewIsTheSourceShowcaseWithSessionAppearance() async throws {
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        root.general.showShowcase()
        await root.general.preview.waitForPreview()
        let preview = root.general.preview
        XCTAssertEqual(preview.exampleText, "Example: Swift")
        XCTAssertNotNil(preview.currentPreparation?.sourceDocument)
        XCTAssertFalse(descendants(preview.previewController.view).first { $0.identifier?.rawValue == "PreviewModeControl" }?.isHiddenOrHasHiddenAncestor ?? true,
                       "General Quick Look exposes supported representations")
        XCTAssertTrue(preview.previewController.footerStrip.showsRepresentations)
        XCTAssertTrue(preview.previewController.footerStrip.showsStatus)
        XCTAssertNil(preview.previewController.footerStrip.trailingAccessory, "No appearance buttons in the footer (D51)")
        addTeardownBlock { @MainActor in NSApp.appearance = nil }
        session.update { $0.general.colorScheme = .dark }
        XCTAssertEqual(preview.previewController.configuration.appearance, .dark)
    }

    func testSharedPreviewKeepsTheSelectedExample() async throws {
        let (root, window) = makeRoot()
        root.general.showShowcase()
        let generalPreview = root.general.preview
        await generalPreview.waitForPreview()
        let picker = try XCTUnwrap(descendants(generalPreview.view).first { $0.identifier?.rawValue == "PreviewSamplePicker" } as? NSPopUpButton)
        XCTAssertEqual(picker.numberOfItems, PreviewSamples.examples(for: "rendering").count)
        guard let jsonIndex = PreviewSamples.examples(for: "rendering").firstIndex(where: { $0.path.contains("json") }) else {
            return XCTFail("A JSON Showcase should be available in General")
        }
        picker.selectItem(at: jsonIndex)
        _ = NSApp.sendAction(picker.action!, to: picker.target, from: picker)
        await generalPreview.waitForPreview()
        XCTAssertTrue(generalPreview.currentFileURL?.lastPathComponent.localizedCaseInsensitiveContains("json") == true,
                      "Selected JSON example was not loaded: \(String(describing: generalPreview.currentFileURL))")

        // D62: the Settings preview is always the interactive Quick Look preview; no thumbnail switch.
        XCTAssertNil(descendants(generalPreview.view).first { $0.identifier?.rawValue == "PreviewSurfaceMode" })
        XCTAssertFalse(generalPreview.previewController.footerStrip.isHiddenOrHasHiddenAncestor)
        for width in [1600.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: max(620, window.contentView?.bounds.height ?? 620)))
            root.view.layoutSubtreeIfNeeded()
            await generalPreview.waitForPreview()
            XCTAssertTrue(generalPreview.currentFileURL?.lastPathComponent.localizedCaseInsensitiveContains("json") == true,
                          "Resizing the window keeps the selected example")
        }
    }

    func testPreviewExampleDropdownIsSortedAlphabetically() {
        for section in ["rendering", "source", "structured", "table", "text", "markdown"] {
            let examples = PreviewSamples.examples(for: section)
            let expected = examples.sorted {
                let titleOrder = $0.title.localizedStandardCompare($1.title)
                return titleOrder == .orderedSame
                    ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    : titleOrder == .orderedAscending
            }.map(\.path)
            XCTAssertEqual(examples.map(\.path), expected, section)
        }
    }

    func testExamplePickerNamesTheDocumentShownInThePreview() async throws {
        let (root, _) = makeRoot()
        root.general.showShowcase()
        let preview = root.general.preview
        await preview.waitForPreview()
        let picker = try XCTUnwrap(descendants(preview.view).first { $0.identifier?.rawValue == "PreviewSamplePicker" } as? NSPopUpButton)
        let examples = PreviewSamples.examples(for: "rendering")
        let json = try XCTUnwrap(examples.first { $0.path.hasSuffix("json/json.json") })
        let jsonURL = try XCTUnwrap(PreviewSamples.url(for: json, bundle: productShowcaseBundle()))

        // A bundled example opened outside the picker (Open File, capture) selects its own entry.
        root.preview(jsonURL)
        await preview.waitForPreview()
        XCTAssertEqual(picker.titleOfSelectedItem, json.title)
        XCTAssertEqual(picker.numberOfItems, examples.count)

        // A user file is named at the top of the picker, above the examples.
        let userFile = directory.appendingPathComponent("notes.json")
        try Data(#"{"a":1}"#.utf8).write(to: userFile)
        root.preview(userFile)
        await preview.waitForPreview()
        XCTAssertEqual(picker.titleOfSelectedItem, "notes.json")
        XCTAssertEqual(picker.numberOfItems, examples.count + 2, "file entry and separator")

        // Choosing an example again loads it and removes the file entry.
        let swiftIndex = try XCTUnwrap(picker.itemArray.firstIndex { $0.title == "Swift" })
        picker.selectItem(at: swiftIndex)
        _ = NSApp.sendAction(picker.action!, to: picker.target, from: picker)
        await preview.waitForPreview()
        XCTAssertEqual(preview.currentFileURL?.pathExtension, "swift")
        XCTAssertEqual(picker.titleOfSelectedItem, "Swift")
        XCTAssertEqual(picker.numberOfItems, examples.count)
    }

    func testRenderedMarkdownFitsThePreviewAfterTheWindowGrows() async throws {
        let (root, window) = makeRoot(size: .init(width: 1000, height: 620))
        let preview = root.general.preview
        let examples = PreviewSamples.examples(for: "rendering")
        let url: (String) throws -> URL = { suffix in
            let example = try XCTUnwrap(examples.first { $0.path.hasSuffix(suffix) })
            return try XCTUnwrap(PreviewSamples.url(for: example, bundle: productShowcaseBundle()))
        }
        root.preview(try url("json/json.json"))
        await preview.waitForPreview()
        window.setContentSize(.init(width: 1100, height: 700))
        root.view.layoutSubtreeIfNeeded()
        root.preview(try url("markdown/markdown.md"))
        await preview.waitForPreview()
        root.view.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(visible(preview.previewController.view).compactMap { $0 as? NSTextView }.first)
        let clip = try XCTUnwrap(text.enclosingScrollView?.contentView)
        XCTAssertLessThanOrEqual(text.frame.width, clip.bounds.width + 0.5, "Rendered Markdown wraps inside the visible preview")
        let layout = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        layout.ensureLayout(for: container)
        XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxX + text.textContainerInset.width, clip.bounds.width + 0.5,
                                 "No rendered line extends past the visible preview")
    }

    func testReadOnlySettingsDisableEveryControl() async throws {
        try Data(#"{"schemaVersion":5}"#.utf8).write(to: directory.appendingPathComponent(SettingsStore.v3Filename))
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        XCTAssertFalse(root.general.font.isEnabled)
        XCTAssertFalse(root.general.wordWrap.isEnabled)
        XCTAssertFalse(root.general.tabs.isEnabled)
        XCTAssertFalse(root.general.lineNumbers.isEnabled)
        XCTAssertTrue(labels(root.view).contains(SettingsStoreError.newerSchema.errorDescription ?? "-"))
    }

    // MARK: F1.7 Settings beside the Live Preview

    /// Spec §4: settings on the left, the Live Preview on the right, inside the window at every size.
    func testSettingsSitLeftOfTheLivePreviewAtEverySize() throws {
        for size in [NSSize(width: 1000, height: 620), .init(width: 1100, height: 700), .init(width: 1600, height: 1000)] {
            let (root, _) = makeRoot(size: size)
            root.view.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(root.view.fittingSize.width, 1000, "Settings fit the minimum window at \(size)")
            let previewView = root.general.preview.view
            let preview = previewView.convert(previewView.bounds, to: root.view)
            let fontRow = try XCTUnwrap(visible(root.general.view).first { $0.identifier?.rawValue == "GeneralRow-Font" })
            let row = fontRow.convert(fontRow.bounds, to: root.view)
            XCTAssertLessThanOrEqual(row.maxX, preview.minX + 0.5, "Settings stay left of the preview at \(size)")
            XCTAssertLessThanOrEqual(preview.maxX, root.view.bounds.maxX + 0.5)
            XCTAssertGreaterThan(preview.width, root.view.bounds.width * 0.35, "The preview keeps a useful width at \(size)")
        }
    }

    func testSoftWrappedPreviewCodeEndsInsideTheWindowAtEverySize() throws {
        for size in [NSSize(width: 1100, height: 700), NSSize(width: 1000, height: 620), NSSize(width: 1600, height: 1000)] {
            let (root, window) = makeRoot(size: size)
            do {
                root.view.layoutSubtreeIfNeeded()
                let preview = root.general.preview.previewController.view
                guard let code = descendants(preview).compactMap({ $0 as? SourceCodeView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
                      let layout = code.textView.layoutManager, let container = code.textView.textContainer else { continue }
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container).offsetBy(dx: code.textView.textContainerOrigin.x, dy: 0)
                let usedInWindow = code.textView.convert(used, to: nil)
                let windowWidth = try XCTUnwrap(window.contentView).bounds.width
                let scrollInWindow = code.scrollView.convert(code.scrollView.bounds, to: nil)
                XCTAssertLessThanOrEqual(scrollInWindow.maxX, windowWidth + 0.5, "\(size): preview scroll view extends past the window")
                XCTAssertLessThanOrEqual(usedInWindow.maxX, windowWidth + 0.5, "\(size): a code fragment ends outside the window")
            }
        }
    }


    /// Both preview tab bars stay: representation tabs share the footer with the status, never overlapping.
    func testFooterAccessoriesNeverOverlapBesideRepresentationTabs() async throws {
        let json = try XCTUnwrap(PreviewSamples.examples(for: "rendering").first { $0.path == "Showcase/json/json.json" })
        let url = try XCTUnwrap(PreviewSamples.url(for: json, bundle: productShowcaseBundle()))
        for size in [NSSize(width: 1000, height: 620), .init(width: 1100, height: 700), .init(width: 1600, height: 1000)] {
            let (root, _) = makeRoot(size: size)
            root.preview(url)
            await root.general.preview.waitForPreview()
            root.view.layoutSubtreeIfNeeded()
            let footer = root.general.preview.previewController.footerStrip
            footer.layoutSubtreeIfNeeded()
            let leading = try XCTUnwrap(footer.leadingAccessory)
            XCTAssertNil(footer.trailingAccessory, "No appearance buttons in the footer (D51) at \(size)")
            let tabs = try XCTUnwrap(descendants(footer).first { $0 is PreviewTabStrip })
            XCTAssertTrue(leading.isHidden || leading.frame.minX >= tabs.convert(tabs.bounds, to: footer).maxX, "Example label clears the representation tabs at \(size)")
        }
    }

    func testGeneralExampleIdentityIsNotRepeatedInQuickLookFooter() async throws {
        for size in [NSSize(width: 1000, height: 620), .init(width: 1100, height: 700), .init(width: 1600, height: 1000)] {
            let session = SettingsSession(store: nil, snapshot: nil)
            let (root, _) = makeRoot(session: session, size: size)
            root.general.showShowcase()
            await root.general.preview.waitForPreview()
            root.view.layoutSubtreeIfNeeded()
            let footer = root.general.preview.previewController.footerStrip
            footer.layoutSubtreeIfNeeded()
            let leading = try XCTUnwrap(footer.leadingAccessory as? NSTextField)
            XCTAssertNil(footer.trailingAccessory, "No appearance buttons in the footer (D51)")
            XCTAssertTrue(leading.stringValue.isEmpty, "Example identity remains in the preview header, not the footer")
            XCTAssertTrue(leading.isHidden)
            let sample = try XCTUnwrap(descendants(root.general.preview.view).first { $0.identifier?.rawValue == "PreviewSamplePicker" } as? NSPopUpButton)
            XCTAssertEqual(sample.titleOfSelectedItem, "Swift")
            let status = try XCTUnwrap(descendants(footer).compactMap { $0 as? PreviewStatusView }.first)
            XCTAssertGreaterThan(status.visibleItemCount, 0, "Inspection metadata remains in the footer")
            XCTAssertFalse(status.items.contains { $0.text == "Swift" }, "The sample identity is not repeated as status")
            XCTAssertTrue(status.items.contains { $0.text == "UTF-8" }, "Encoding metadata remains visible")
            XCTAssertTrue(status.items.contains { $0.text == "LF" }, "Line-ending metadata remains visible")
            XCTAssertTrue(status.items.contains { $0.text.contains("bytes") }, "File-size metadata remains visible")
            XCTAssertTrue(status.items.contains { $0.text.contains("lines") }, "Line-count metadata remains visible")
        }
    }

    func testRemovingRepeatedExampleStatusKeepsValidationMetadata() {
        let status = PreviewStatusView()
        status.update([
            .init(text: "JSON", kind: .information),
            .init(text: "Valid JSON", kind: .valid),
            .init(text: "UTF-8", kind: .information)
        ])
        status.omittedText = "JSON"
        XCTAssertEqual(status.items.map(\.text), ["Valid JSON", "UTF-8"])
    }


    // MARK: F1.8 Reset and default view

    func testGlobalResetIsVisibleOnlyWhenMeaningfulAndConfirmed() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        let resetAll = root.general.resetAll
        XCTAssertTrue(resetAll.isHiddenOrHasHiddenAncestor, "Factory values offer no global reset")
        session.update { $0.general.tabsToSpaces = 2 }
        session.update { $0.fileAssociations = [FileAssociation(kind: .fileExtension, value: "conf", target: .python)] }
        XCTAssertFalse(resetAll.isHiddenOrHasHiddenAncestor)
        var asked = 0
        root.general.confirmResetAll = { completion in asked += 1; completion(false) }
        resetAll.performClick(nil)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(session.settings.general.tabsToSpaces, 2, "Cancel changes nothing")
        root.general.confirmResetAll = { completion in completion(true) }
        resetAll.performClick(nil)
        XCTAssertEqual(session.settings, .factoryDefaults)
        XCTAssertTrue(resetAll.isHidden)
    }

    /// A saved Default View never moves the open preview tab; the reopen action applies it.
    func testDefaultViewIsSeparateFromSessionTab() async throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        let json = try XCTUnwrap(PreviewSamples.examples(for: "rendering").first { $0.path == "Showcase/json/json.json" })
        root.preview(try XCTUnwrap(PreviewSamples.url(for: json, bundle: productShowcaseBundle())))
        let pane = root.general.preview
        await pane.waitForPreview()
        let tabs = try XCTUnwrap(descendants(pane.previewController.view).compactMap { $0 as? PreviewTabStrip }.first)
        func select(_ label: String) throws {
            tabs.selectedSegment = try XCTUnwrap((0..<tabs.segmentCount).first { tabs.label(forSegment: $0) == label })
            _ = NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs)
        }
        func selectedLabel() -> String? { tabs.label(forSegment: tabs.selectedSegment) }
        try select("Pretty")
        session.update { $0.formatOverrides["json"] = ["raw", "tree", "pretty"] }
        XCTAssertEqual(selectedLabel(), "Pretty", "Changing the saved default leaves the open preview tab untouched")
        let reopen = try XCTUnwrap(descendants(pane.view).first { $0.identifier?.rawValue == "ReopenDefaultRepresentation" } as? NSButton)
        reopen.performClick(nil)
        await pane.waitForPreview()
        XCTAssertEqual(selectedLabel(), "Raw", "Explicit reopen applies the newly saved default")
        try select("Pretty")
        XCTAssertEqual(session.settings.formatOverrides["json"], ["raw", "tree", "pretty"], "A session tab never writes the saved default")
    }

    // MARK: Sheets (D15, D16)

    /// Hosts Formats & Views at its opening size, as the settings window presents it.
    private func hostedFormats(_ session: SettingsSession, selecting scope: ViewScope) throws -> FormatsAndViewsSheet {
        let (root, _) = makeRoot(session: session)
        var presented: NSViewController?
        root.presentSheet = { presented = $0 }
        root.showFormatsAndViews(selecting: scope)
        let sheet = try XCTUnwrap(presented as? FormatsAndViewsSheet)
        let window = NSWindow(contentRect: .init(origin: .zero, size: FormatsAndViewsSheet.preferredSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = sheet
        window.setContentSize(FormatsAndViewsSheet.preferredSize)
        sheet.view.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in window.contentViewController = nil; window.close() }
        return sheet
    }

    /// Sheet content keeps the 20 pt margins of its heading; the mapping list spans the detail column (D37, D68).
    func testSheetContentKeepsTheHeadingMargins() throws {
        let sheet = try hostedFormats(SettingsSession(store: nil, snapshot: nil), selecting: .format(.yaml))
        let width = sheet.view.bounds.width
        for view in descendants(sheet.view) where !view.isHiddenOrHasHiddenAncestor && (view is NSScrollView || view is NSTextField || view is NSButton) {
            guard !(view.enclosingScrollView.map { $0 !== view } ?? false) else { continue }
            let frame = view.convert(view.alignmentRect(forFrame: view.bounds), to: sheet.view)
            XCTAssertGreaterThanOrEqual(frame.minX, 19, "\(view) starts inside the margin")
            XCTAssertLessThanOrEqual(frame.maxX, width - 19, "\(view) ends inside the margin")
        }
        let list = try XCTUnwrap(sheet.mappings.table.enclosingScrollView)
        let order = try XCTUnwrap(sheet.orderTable.enclosingScrollView)
        XCTAssertEqual(list.convert(list.bounds, to: sheet.view).width, order.convert(order.bounds, to: sheet.view).width, accuracy: 1,
                       "The mapping list spans the detail column like View Order")
    }

    /// E5-07: an empty mapping table says so inside the table; Add and Remove still work.
    func testFileMappingsEmptyTableExplainsItselfAndAddRemoveStillWork() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = try hostedFormats(session, selecting: .format(.yaml))
        let mappings = sheet.mappings
        let scroll = try XCTUnwrap(mappings.table.enclosingScrollView)
        func empty() -> NSTextField? {
            visible(sheet.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "MappingListEmpty" }
        }
        let label = try XCTUnwrap(empty())
        let list = scroll.convert(scroll.bounds, to: sheet.view)
        let text = label.convert(label.bounds, to: sheet.view)
        XCTAssertTrue(list.contains(text), "\(text) lies inside the list \(list)")
        XCTAssertGreaterThan(text.height, 0)
        XCTAssertEqual(label.stringValue, "No custom file mappings")
        mappings.beginAdd(nil)
        mappings.valueField.stringValue = "conf"
        mappings.add(nil)
        XCTAssertNil(empty())
        XCTAssertEqual(mappings.table.numberOfRows, 1)
        XCTAssertEqual(mappings.table.selectedRow, 0, "The new mapping is selected")
        mappings.remove(nil)
        XCTAssertNotNil(empty())
        XCTAssertEqual(mappings.table.numberOfRows, 0)
    }

    func testFileMappingsValidateAndRequireSelectionForRemoval() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = try hostedFormats(session, selecting: .format(.yaml))
        let mappings = sheet.mappings
        mappings.beginAdd(nil)
        mappings.valueField.stringValue = "a/b"
        mappings.add(nil)
        XCTAssertEqual(mappings.feedback.stringValue, SettingsSession.mappingInvalidMessage)
        XCTAssertFalse(mappings.feedback.isHidden)
        XCTAssertTrue(mappings.isEditing, "A rejected entry keeps the editor open")
        mappings.valueField.stringValue = "*.conf"
        mappings.add(nil)
        XCTAssertEqual(session.settings.fileAssociations, [.init(kind: .fileExtension, value: "conf", target: .yaml)])
        XCTAssertFalse(mappings.isEditing)
        mappings.table.deselectAll(nil)
        XCTAssertFalse(mappings.removeButton.isEnabled)
        mappings.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(mappings.removeButton.isEnabled)
        mappings.remove(nil)
        XCTAssertTrue(session.settings.fileAssociations.isEmpty)
    }

    // MARK: Preview pane (ported from PreviewHarnessTests)

    func testEveryShippedShowcaseTraversesTheSharedPipeline() async throws {
        var paths = Set<String>()
        for definition in FormatCatalog.supported {
            let main = try XCTUnwrap(definition.showcaseFixture)
            for path in [main] + (definition.showcaseVariants ?? []).map(\.path) {
                paths.insert(path)
                let url = try XCTUnwrap(PreviewSamples.url(for: .init(title: definition.displayName, path: path), bundle: productShowcaseBundle()))
                let preparation = try await SharedPreviewPipeline.preview(for: url, configuration: .init()).inspection
                XCTAssertEqual(preparation.formatDefinition?.id, definition.id, path)
                XCTAssertFalse(preparation.statusSummary.items.contains { $0.kind == .warning }, path)
            }
        }
        let expectedPaths = FormatCatalog.supported.flatMap { definition in
            [definition.showcaseFixture].compactMap { $0 } + (definition.showcaseVariants ?? []).map(\.path)
        }
        XCTAssertEqual(paths.count, expectedPaths.count, "Every catalog showcase path is unique and traversed")
    }

    func testSelectedFileReportsDiagnosticsAndStaysReadOnly() async throws {
        let (root, _) = makeRoot()
        let url = try fixtureURL("Cases/markdown/fenced-code.md")
        let before = try Data(contentsOf: url)
        try await root.general.preview.open(url, title: url.lastPathComponent)
        let preview = root.general.preview
        XCTAssertEqual(preview.currentFileURL, url)
        XCTAssertNotNil(preview.currentPreparation?.markdownDocument)
        for line in ["Format: Markdown", "Renderer: Markdown", "Encoding: UTF-8", "Detection:", "Truncated: No"] {
            XCTAssertTrue(preview.diagnosticsText.contains(line), line)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(labels(root.view).contains { $0.contains("Format: Markdown") }, "Diagnostics are developer-only")
    }

    func testUnavailableFileHasCleanErrorAndKeepsPriorPreview() async throws {
        let (root, _) = makeRoot()
        let preview = root.general.preview
        let valid = try fixtureURL("Cases/json/valid/simple.json")
        try await preview.open(valid, title: nil)
        let missing = directory.appendingPathComponent("missing-input")
        do {
            try await preview.open(missing, title: nil)
            XCTFail("Expected a file error")
        } catch {
            XCTAssertEqual(preview.currentFileURL, valid)
            XCTAssertEqual(preview.diagnosticsText, PreviewPane.unableToPreview)
            XCTAssertFalse(preview.diagnosticsText.contains(missing.path))
            XCTAssertEqual(preview.exampleText, PreviewPane.unableToOpen)
        }
    }

    func testThemeChangeWhileExampleIsQueuedUsesLatestPresentation() async throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        addTeardownBlock { @MainActor in NSApp.appearance = nil }
        session.update { $0.general.colorScheme = .light }
        root.general.showShowcase()
        session.update { $0.general.themeAssignment.light = .init(preset: .neutral) }
        await root.general.preview.waitForPreview()
        let code = try XCTUnwrap(descendants(root.general.preview.previewController.view).compactMap { $0 as? SourceCodeView }.first)
        XCTAssertEqual(code.options.lightTheme, .neutral)
        let source = try XCTUnwrap(root.general.preview.currentPreparation?.sourceDocument?.source)
        let keyword = (source as NSString).range(of: "import").location
        let color = try XCTUnwrap(code.textView.textStorage?.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor)
        code.effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB)
            XCTAssertEqual(resolved?.redComponent, resolved?.greenComponent)
            XCTAssertEqual(resolved?.greenComponent, resolved?.blueComponent)
        }
    }

    func testInspectionPolicyChangeDuringQueuedExampleKeepsRequestedFile() async throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        let preview = root.general.preview
        try await preview.open(try fixtureURL("Showcase/text/plain.txt"), title: nil)
        let expected = try XCTUnwrap(PreviewSamples.url(for: GeneralSettingsViewController.showcase, bundle: productShowcaseBundle()))
        root.general.showShowcase()
        _ = session.setDataLimit(amount: 64, unit: .kb)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "swift", target: .text))
        await preview.waitForPreview()
        XCTAssertEqual(preview.currentFileURL, expected)
        XCTAssertEqual(preview.previewController.configuration.maximumPreviewBytes, 65_536)
        XCTAssertEqual(preview.currentPreparation?.formatName, "Plain text")
        XCTAssertNil(preview.currentPreparation?.sourceDocument)
        XCTAssertEqual(preview.currentPreparation?.detectionReason, "userOverride")
    }

    func testSourceWrapMatchesBetweenSettingsPreviewAndQuickLookAdapter() async throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        let url = try fixtureURL("Showcase/source/swift.swift")
        for wrap in [WordWrapMode.off, .soft] {
            session.update { $0.general.wordWrap = wrap }
            try await root.general.preview.open(url, title: nil)
            let configuration = session.renderConfiguration
            let adapter = PreviewViewController(debugDependencies: .init(loadingIndicatorDelay: contentFirstLoadingDelay, configurationLoader: { configuration }))
            adapter.view.frame = .init(x: 0, y: 0, width: 640, height: 480)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                adapter.preparePreviewOfFile(at: url) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            for view in [root.general.preview.previewController.view, adapter.view] {
                let code = try XCTUnwrap(descendants(view).compactMap { $0 as? SourceCodeView }.first)
                XCTAssertEqual(code.options.wrapLines, wrap != .off)
                XCTAssertEqual(code.textView.textContainer?.widthTracksTextView, wrap != .off)
            }
        }
    }

    func testMarkdownOptionChangeReinspectsWhileRawStaysOriginal() async throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let (root, _) = makeRoot(session: session)
        let pane = root.general.preview
        let url = try fixtureURL("Cases/markdown/gfm.md")
        try await pane.open(url, title: nil)
        let before = try XCTUnwrap(pane.currentPreparation)
        var options = EffectiveSettingsResolver.resolve(session.settings, for: .markdown).markdown
        options.taskLists.toggle()
        session.updateFormat(.markdown) { $0.markdown = options }
        await pane.waitForPreview()
        let after = try XCTUnwrap(pane.currentPreparation)
        XCTAssertNotEqual(String(describing: after.markdownDocument), String(describing: before.markdownDocument),
                          "Markdown options decide inspection, so the file is re-read")
        XCTAssertEqual(pane.currentFileURL, url)
        XCTAssertEqual(after.analysis.text, before.analysis.text, "Raw stays the original file")
    }

    func testSaveFailureIsSeparateFromInspectionDiagnosticsAndReloadKeepsSavedValues() async throws {
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        let (root, _) = makeRoot(session: session)
        session.update { $0.general.tabsToSpaces = 2 }
        await session.waitForPersistence()
        let reloaded = await SettingsSession.load(store: SettingsStore(directory: directory))
        XCTAssertEqual(reloaded.settings.general.tabsToSpaces, 2)
        XCTAssertEqual(reloaded.renderConfiguration.source.tabsToSpaces, 2)

        try await root.general.preview.open(try fixtureURL("Cases/json/valid/simple.json"), title: nil)
        let diagnostics = root.general.preview.diagnosticsText
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        session.update { $0.general.tabsToSpaces = 8 }
        await session.waitForPersistence()
        XCTAssertTrue(session.saveFailed)
        XCTAssertEqual(session.settings.general.tabsToSpaces, 8, "The change still applies to this preview")
        XCTAssertTrue(labels(root.view).contains(SettingsSession.saveFailedMessage))
        XCTAssertEqual(root.general.preview.diagnosticsText, diagnostics)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: F1.10 Quick Look footer

    func testFooterOrderAndNarrowCollapseKeepStatusLongest() throws {
        let controller = makeSizedPreviewController(size: .init(width: 900, height: 400))
        controller.display(try PreviewPreparation.read(at: try fixtureURL("Cases/json/valid/simple.json")))
        controller.view.layoutSubtreeIfNeeded()
        let status = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PreviewStatusView }.first)
        let texts = status.items.map(\.text)
        XCTAssertEqual(texts.first, "Valid JSON", "Validation leads only because it actually ran")
        let encoding = try XCTUnwrap(texts.firstIndex(of: "UTF-8"))
        let lineEnding = try XCTUnwrap(texts.firstIndex { ["LF", "CRLF", "CR", "Mixed"].contains($0) })
        let size = try XCTUnwrap(texts.firstIndex { $0.hasSuffix("bytes") || $0.hasSuffix("KB") })
        let lines = try XCTUnwrap(texts.firstIndex { $0.hasSuffix("lines") || $0.hasSuffix("line") })
        XCTAssertTrue(encoding < lineEnding && lineEnding < size && size < lines, "\(texts)")
        XCTAssertEqual(status.visibleItemCount, status.items.count)

        status.setFrameSize(.init(width: 100, height: status.bounds.height))
        status.layout()
        XCTAssertEqual(status.visibleItemCount, 1)
        let first = try XCTUnwrap(descendants(status).compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(first.stringValue, "Valid JSON")
        XCTAssertLessThanOrEqual(first.convert(first.bounds, to: status).maxX, status.bounds.width + 0.5)

        // Too narrow for the text: the validity icon stays, never a cut-off word.
        let full = status.accessibilityLabel()
        status.setFrameSize(.init(width: 60, height: status.bounds.height))
        status.layout()
        XCTAssertEqual(status.visibleItemCount, 1)
        XCTAssertTrue(status.showsIconOnly)
        XCTAssertTrue(descendants(status).compactMap { $0 as? NSTextField }.isEmpty)
        XCTAssertEqual(descendants(status).compactMap { $0 as? NSImageView }.count, 1)
        XCTAssertEqual(status.accessibilityLabel(), full)

        // A second pass at the same width measures real text again, so no empty item or orphan
        // separator follows the icon (D31).
        status.layout()
        XCTAssertEqual(status.visibleItemCount, 1)
        XCTAssertTrue(descendants(status).filter { $0.identifier?.rawValue == "PreviewStatusSeparator" }.isEmpty)
    }

    func testPlainTextHasNoValidityAndBinaryOmitsTextMetadata() throws {
        let text = PreviewPreparation.prepare(bytes: Data("a\nb\n".utf8), fileSize: 4, fileName: "notes.txt", systemUTI: nil)
        XCTAssertFalse(text.statusSummary.items.contains { $0.kind == .valid })
        let binary = PreviewPreparation.prepare(bytes: Data([0, 159, 146, 150, 0, 1, 2]), fileSize: 7, fileName: "blob.bin", systemUTI: nil)
        let items = binary.statusSummary.items.map(\.text)
        XCTAssertFalse(items.contains("UTF-8"))
        XCTAssertFalse(items.contains { ["LF", "CRLF", "CR"].contains($0) })
        XCTAssertFalse(items.contains { $0.hasSuffix("line") || $0.hasSuffix("lines") })
        XCTAssertTrue(items.contains("7 bytes"))
    }
}

/// Resolve the actual built product, including Release where repository fallbacks do not exist.
func productShowcaseBundle() -> Bundle {
    let url = Bundle(for: SettingsWindowTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Glimt.app")
    let bundle = Bundle(url: url)
    XCTAssertNotNil(bundle, "The built Glimt.app must supply product Showcase resources")
    return bundle ?? .main
}
