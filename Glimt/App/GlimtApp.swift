import SwiftUI
import AppKit
import InspectorCore
#if DEBUG
import GitInspection
#endif

@main
/// SwiftUI app entry point that creates the settings window and its shared session.
struct GlimtApp: App {
    var body: some Scene {
        Window("Glimt", id: "settings") {
            SettingsScene()
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 700)
        // Glimt's only window: open it on every launch, even if it was closed when the app quit.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Glimt") { Self.showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open File…") { SettingsRootViewController.current?.openDocument(nil) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Button("Formats & Views…") { SettingsRootViewController.current?.showFormatsAndViews() }
                    .keyboardShortcut("1")
            }
        }
    }

    /// Standard About panel showing the pre-release label, e.g. "Version 0.1.0 Beta 1 (1)".
    @MainActor private static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let version = GlimtVersion.current {
            options[.applicationVersion] = version.displayVersion
            options[.version] = version.buildNumber
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate()
    }
}

private struct SettingsScene: View {
    @State private var controller: SettingsRootViewController?

    var body: some View {
        Group {
            if let controller { SettingsHost(controller: controller) }
            else { ProgressView("Loading settings…") }
        }
        .task {
            // Create the session once per scene; capture mode injects an isolated temporary store.
            guard controller == nil else { return }
#if DEBUG
            if VCSProbe.isRequested {
                await VCSProbe.inspectRequestedFile()
                return
            }
            if ProcessInfo.processInfo.environment["GLIMT_CAPTURE_SETTINGS_UI"] == "1" {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtUI-\(UUID().uuidString)")
                let session = await SettingsSession.load(store: SettingsStore(directory: temporary.appendingPathComponent("settings")))
                let host = SettingsRootViewController(session: session)
                controller = host
                await AppVisualEvidence.capture(host, directory: temporary.appendingPathComponent("images"))
                return
            }
#endif
            let session = await SettingsSession.load()
            guard !Task.isCancelled else { return }
            followDebugLogging(session)
            controller = SettingsRootViewController(session: session)
        }
    }

    /// Keeps the shared debug log in step with General › Debug logging (ADR-023). Only version,
    /// OS and save outcomes are logged here; never paths or settings content.
    private func followDebugLogging(_ session: SettingsSession) {
        let log = GlimtDebugLog.shared
        log.setEnabled(session.settings.general.debugLoggingEnabled)
        let info = Bundle.main.infoDictionary
        log.info("Glimt started; version=\(info?["CFBundleShortVersionString"] as? String ?? "unknown") build=\(info?["CFBundleVersion"] as? String ?? "unknown") macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        session.observe { [weak session] change in
            guard let session else { return }
            switch change {
            case .settings: log.setEnabled(session.settings.general.debugLoggingEnabled)
            case .status: if session.saveFailed { log.error("Settings could not be saved.") }
            }
        }
    }
}

private struct SettingsHost: NSViewControllerRepresentable {
    let controller: SettingsRootViewController
    /// The SwiftUI scene owns the controller's lifetime, so the adapter returns the same instance.
    func makeNSViewController(context: Context) -> SettingsRootViewController { controller }
    /// SettingsSession notifications update the existing AppKit view tree directly.
    func updateNSViewController(_ controller: SettingsRootViewController, context: Context) {}
}

#if DEBUG
/// Opt-in sandbox evidence for Git inspection (ADR-038), driven by `scripts/vcs-sandbox-probe.sh`.
/// `GLIMT_VCS_PROBE_FILE` inspects one file through the host's own providers, with no grant other
/// than the app's entitlements, prints one `GLIMT_VCS_PROBE` line and exits.
@MainActor
enum VCSProbe {
    private static let environment = ProcessInfo.processInfo.environment

    static var isRequested: Bool { environment["GLIMT_VCS_PROBE_FILE"] != nil }

    /// Inspects the requested file and reports status, line changes, last commit and the drawn gutter.
    static func inspectRequestedFile() async {
        guard let path = environment["GLIMT_VCS_PROBE_FILE"] else { return }
        let registry = VCSProviderRegistry(providers: [SVNProvider(), GitProvider()])
        guard let result = try? await registry.inspect(fileURL: URL(fileURLWithPath: path)) else {
            finish("result=none")
        }
        let changes = result.comparison?.lineDiff.changes.map { "\($0.kind.rawValue)@\($0.workingLines.lowerBound)" } ?? []
        let gutter = await renderedGutter(of: URL(fileURLWithPath: path))
        finish("result=\(result.repositoryType.rawValue) status=\(result.fileStatus.rawValue) "
               + "changes=\(changes.joined(separator: ",")) commit=\(result.lastCommit?.id ?? "none") "
               + "diagnostics=\(result.diagnostics.map(\.rawValue).joined(separator: ",")) gutter=\(gutter)")
    }

    /// Shows the file in the host's preview pane, as Settings does, and reports the line changes its
    /// gutter draws. The pane is also printed as a base64 PNG so the script can keep it as evidence.
    private static func renderedGutter(of file: URL) async -> String {
        let session = SettingsSession(store: nil, snapshot: nil)
        session.update { $0.general.vcsSupportEnabled = true }
        let pane = PreviewPane(session: session)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.setContentSize(.init(width: 1000, height: 360))
        defer {
            window.contentViewController = nil
            window.close()
        }
        pane.show(file, title: file.lastPathComponent)
        await pane.waitForPreview()
        let ruler = descendants(pane.view).compactMap { ($0 as? SourceCodeView)?.scrollView.verticalRulerView as? SourceLineNumberRuler }.first
        for _ in 0..<300 where ruler?.lineDiff == nil { try? await Task.sleep(for: .milliseconds(10)) }
        // The commit item arrives with the same inspection; give the footer a moment to show it.
        try? await Task.sleep(for: .milliseconds(200))
        pane.view.layoutSubtreeIfNeeded()
        pane.view.displayIfNeeded()
        if let bitmap = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) {
            pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                print("GLIMT_VCS_PROBE_IMAGE \(data.base64EncodedString())")
            }
        }
        guard let ruler else { return "none" }
        let marks = ruler.lineDiff?.changes.map { "\($0.kind.rawValue)@\($0.workingLines.lowerBound)" } ?? []
        return marks.isEmpty ? "none" : marks.joined(separator: ",")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private static func finish(_ line: String) -> Never {
        print("GLIMT_VCS_PROBE \(line)")
        fflush(stdout)
        exit(0)
    }
}

/// Opt-in visual evidence from the real app window, using the SettingsStore injection seam so no
/// App Group or production preferences are touched. Each image also passes structural checks;
/// any failed check prints `GLIMT_APP_UI_CAPTURE_BLOCKED`.
@MainActor
private enum AppVisualEvidence {
    /// Error raised when a startup self-check does not meet its expected condition.
    struct CheckFailure: Error, CustomStringConvertible { let description: String }

    /// Exercises the real settings window and writes screenshots plus named invariant results.
    static func capture(_ host: SettingsRootViewController, directory: URL) async {
        // This opt-in debug run captures a real window while using isolated settings storage.
        var checks: [String] = []
        var scopes: [String: String] = [:]
        /// Records a stable pass name or aborts capture at the first violated invariant.
        func check(_ condition: Bool, _ name: String) throws {
            // Fail the capture at the first broken invariant and include a stable check name in the receipt.
            guard condition else { throw CheckFailure(description: name) }
            checks.append("PASS \(name)")
        }
        do {
            for _ in 0..<100 {
                if host.view.window?.titlebarAccessoryViewControllers.isEmpty == false { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let window = host.view.window else { throw CheckFailure(description: "window") }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            for _ in 0..<40 {
                if NSApplication.shared.isActive && window.isKeyWindow { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(NSApplication.shared.isActive && window.isKeyWindow,
                      "capture window is active for native selection styling")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = host.session

            /// Waits for preview, persistence, and layout to settle before visual evidence is captured.
            func settle() async throws {
                // Wait for previews and debounced persistence so each image records a stable UI state.
                await host.general.preview.waitForPreview()
                await session.waitForPersistence()
                try await Task.sleep(for: .milliseconds(200))
                window.contentView?.layoutSubtreeIfNeeded()
            }
            /// Captures a view as a flattened PNG and records the tested view's bounds.
            func shot(_ name: String, _ view: NSView? = nil) async throws {
                // Render through AppKit, then flatten against the active window background for consistent captures.
                try await settle()
                let target = view ?? window.contentView?.superview ?? host.view
                target.layoutSubtreeIfNeeded()
                target.displayIfNeeded()
                guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { throw CheckFailure(description: "bitmap \(name)") }
                target.effectiveAppearance.performAsCurrentDrawingAppearance { target.cacheDisplay(in: target.bounds, to: bitmap) }
                // The window background is drawn by the compositor, not by cacheDisplay; paint it
                // underneath so dark captures do not show light-on-transparent text.
                guard let flattened = bitmap.copy() as? NSBitmapImageRep,
                      let context = NSGraphicsContext(bitmapImageRep: flattened) else { throw CheckFailure(description: "flatten \(name)") }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                // The context is in points; the window's own appearance decides the background.
                let bounds = NSRect(origin: .zero, size: flattened.size)
                (NSApplication.shared.appearance ?? target.effectiveAppearance).performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    bounds.fill()
                    bitmap.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                }
                NSGraphicsContext.restoreGraphicsState()
                guard let data = flattened.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                scopes[name] = scope(of: target)
            }
            /// Finds an identifier only in currently visible content, avoiding stale hidden tabs.
            func visible(_ identifier: String) -> NSView? {
                // Ignore hidden tab content so a stale view cannot satisfy a screenshot assertion.
                descendants(window.contentView ?? host.view).first { $0.identifier?.rawValue == identifier && !$0.isHiddenOrHasHiddenAncestor }
            }
            /// Activates the real preview tab button so tests cover AppKit target/action wiring.
            func clickTab(_ preview: PreviewPane, _ title: String) throws {
                // Drive the actual AppKit button so action wiring and selection state are both exercised.
                // Tabs are found by title because View Order decides their position.
                guard let tabs = descendants(preview.previewController.view).compactMap({ $0 as? PreviewTabStrip }).first else { throw CheckFailure(description: "tabs") }
                guard let button = tabs.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw CheckFailure(description: "tab \(title)") }
                button.performClick(nil)
            }
            /// Waits for the window's attached sheet to appear or go away.
            func waitForSheet(_ present: Bool) async throws {
                for _ in 0..<40 { if (window.attachedSheet != nil) == present { break }; try await Task.sleep(for: .milliseconds(50)) }
            }
            // One unified view (spec §4): no pane toolbar; Inquiry stays a trailing titlebar accessory.
            try check(window.toolbar == nil && window.title == "Glimt", "no pane toolbar, window titled Glimt: title=\(window.title)")
            let inquiryAccessory = window.titlebarAccessoryViewControllers.first { host.inquiryButton.isDescendant(of: $0.view) }
            try check(inquiryAccessory?.layoutAttribute == .trailing && host.inquiryButton.toolTip == "Inquiry"
                      && host.inquiryButton.accessibilityLabel() == "Inquiry", "inquiry trailing with tooltip and accessibility name")
            if let box = inquiryAccessory?.view {
                box.layoutSubtreeIfNeeded()
                let button = host.inquiryButton.frame
                try check(button.minY >= 0 && button.maxY <= box.bounds.height + 0.5, "inquiry icon not clipped: \(button) in \(box.bounds)")
            }

            let sizes: [(name: String, size: NSSize)] = [("normal", .init(width: 1100, height: 700)),
                                                         ("minimum", .init(width: 1000, height: 620)),
                                                         ("large", .init(width: 1600, height: 1000))]
            // E5-03: Reset All is shown only when something differs from factory values (FR-TGT-028).
            // Check that state first, then change the data limit so every image shows one state.
            try await settle()
            try check(session.isFactoryDefault,
                      "visual capture session starts with factory settings (general=\(session.settings.general), factory=\(GlimtSettingsV3.factoryDefaults.general), formats=\(session.settings.formats.count), themes=\(session.settings.customThemes.count), mappings=\(session.settings.fileAssociations.count))")
            try check(host.general.resetAll.isHiddenOrHasHiddenAncestor, "reset all hidden at factory values")
            try check(host.general.retiredRow.isHiddenOrHasHiddenAncestor, "no retired-overrides notice at factory values")
            try check(host.general.advancedContent.isHidden, "Advanced starts collapsed")
            _ = session.setDataLimit(amount: 512, unit: .kb)
            for scheme in [PreviewAppearance.light, .dark] {
                let mode = scheme.rawValue
                // D51: the persisted Color scheme switches the whole app; no window-level override.
                session.update { $0.general.colorScheme = scheme }
                try await settle()
                let expected: NSAppearance.Name = scheme == .light ? .aqua : .darkAqua
                let appearance = expected
                try check(NSApp.appearance?.name == expected && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                          "color scheme applies app-wide \(mode)")
                host.general.showShowcase()
                for (sizeName, size) in sizes {
                    window.setContentSize(size)
                    try await settle()
                    let contentBounds = window.contentView?.bounds ?? .zero
                    try check(contentBounds.width >= 1000 && contentBounds.height >= 620, "minimum size \(mode) \(sizeName)")
                    try check(visible("GeneralForm") != nil && visible("PreviewSamplePicker") != nil,
                              "settings form and example picker \(mode) \(sizeName)")
                    try check(visible("PreviewSurfaceMode") == nil && visible("GeneralThumbnails") == nil,
                              "no thumbnail switch or Thumbnails group \(mode) \(sizeName)")
                    try check(visible("GeneralRowSeparator") == nil, "no separators between settings rows \(mode) \(sizeName)")
                    let headingViews = ["GeneralAppearance", "GeneralPreview", "GeneralFormatsAndViews", "GeneralAdvanced"].compactMap(visible)
                    let sectionHeadings = headingViews.map { $0.convert($0.bounds, to: host.general.view).minX }
                    try check(sectionHeadings.count == 4, "four settings sections \(mode) \(sizeName)")
                    // Advanced's heading follows its disclosure button; the other three share one edge.
                    try check(sectionHeadings.prefix(3).allSatisfy { abs($0 - sectionHeadings[0]) <= 0.5 },
                              "section headings share a leading edge \(mode) \(sizeName)")
                    try check(visible("ConfigureFormatsAndViews") != nil, "Formats & Views has Configure… \(mode) \(sizeName)")
                    try check(host.general.preview.exampleText == "Example: Swift", "settings example label")
                    try check(!host.general.resetAll.isHiddenOrHasHiddenAncestor, "reset all shown after a change \(mode) \(sizeName)")
                    // E5-01: Soft wrap keeps every code fragment inside the visible clip.
                    let softWrap = softWrapFits(host.general.preview.previewController.view)
                    checks.append("\(softWrap ? "PASS" : "REVIEW") Live Preview soft-wrap geometry \(mode) \(sizeName): \(softWrapGeometry(host.general.preview.previewController.view))")
                    try await shot("\(mode)-\(sizeName)-01-settings.png")
                    if sizeName == "normal" {
                        // The interactive preview with Indentation guides off and on; the footer stays.
                        let pane = host.general.preview
                        for guides in [false, true] {
                            session.update { $0.general.indentationGuides = guides }
                            try await settle()
                            try check(!pane.previewController.footerStrip.isHiddenOrHasHiddenAncestor,
                                      "representation footer \(mode)")
                            try await shot("\(mode)-normal-01-settings-guides-\(guides ? "on" : "off").png")
                        }
                        session.update { $0.general.indentationGuides = false }
                        host.general.advancedDisclosure.performClick(nil)
                        try await settle()
                        try check(visible("GeneralRow-DataLimit") != nil && visible("GeneralRow-VCSSupport") != nil, "Advanced expands \(mode)")
                        try await shot("\(mode)-normal-02-settings-advanced.png")
                        host.general.advancedDisclosure.performClick(nil)
                        try await settle()
                        try check(visible("GeneralRow-DataLimit") == nil, "Advanced collapses \(mode)")
                    }
                }
                // The Live Preview's representation tabs at the minimum size, then at normal size.
                guard let jsonFile = PreviewSamples.url(for: .init(title: "JSON", path: "Showcase/json/json.json")),
                      let markdownFile = PreviewSamples.url(for: .init(title: "Markdown", path: "Showcase/markdown/markdown.md")) else { throw CocoaError(.fileNoSuchFile) }
                window.setContentSize(sizes[1].size)
                host.preview(jsonFile)
                try await settle()
                try clickTab(host.general.preview, "Tree")
                try await shot("\(mode)-minimum-03-json-tree.png")
                window.setContentSize(sizes[0].size)
                let footer = host.general.preview.previewController.footerStrip
                /// Confirms the compact status view retains readable text at narrow widths.
                func statusShowsText() -> Bool {
                    footer.layoutSubtreeIfNeeded()
                    guard let status = descendants(footer).compactMap({ $0 as? PreviewStatusView }).first else { return false }
                    status.layoutSubtreeIfNeeded()
                    return status.visibleItemCount > 0 && !status.showsIconOnly
                }
                for name in ["raw", "pretty", "tree"] {
                    try clickTab(host.general.preview, name.capitalized)
                    checks.append("\(statusShowsText() ? "PASS" : "REVIEW") status text \(mode) normal json-\(name)")
                    try await shot("\(mode)-normal-03-json-\(name).png")
                }
                host.preview(markdownFile)
                try await settle()
                try clickTab(host.general.preview, "Rendered")
                checks.append("\(statusShowsText() ? "PASS" : "REVIEW") status text \(mode) normal markdown")
                let markdown = renderedTextGeometry(host.general.preview.previewController.view)
                checks.append("\(markdown.fits ? "PASS" : "REVIEW") rendered Markdown inside the preview \(mode) normal: \(markdown.detail)")
                try await shot("\(mode)-normal-04-markdown-rendered.png")
                host.general.showShowcase()

                // Formats & Views (spec §5): the matrix and order editor, then File Mappings.
                let formats = host.showFormatsAndViews(selecting: .format(.json))
                try await waitForSheet(true)
                guard let sheet = window.attachedSheet, let sheetFrame = sheet.contentView?.superview else { throw CheckFailure(description: "formats and views sheet") }
                let sheetSize = sheet.contentLayoutRect.size
                try check(sheetSize.width >= 1000 && sheetSize.height >= 660 && sheet.styleMask.contains(.resizable),
                          "Formats & Views opens near 1060×720 and resizes \(mode): \(sheetSize)")
                try check(host.showFormatsAndViews() === formats && window.attachedSheet === sheet, "one Formats & Views sheet \(mode)")
                let inSheet = { (id: String) in descendants(sheetFrame).contains { $0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor } }
                try check(inSheet("FormatsMatrix") && inSheet("ViewOrder") && inSheet("DefaultViewMarker") && inSheet("FormatsSearch"),
                          "matrix, view order with Default marker and search \(mode)")
                // D68: one detail column; File Mappings follow the selected format, no section picker.
                try check(!descendants(sheetFrame).contains { $0 is NSSegmentedControl || $0 is NSTabView }, "no Views | File Mappings picker \(mode)")
                // E5-06, E5-07: the empty list explains itself inside the list.
                try check(inSheet("FileMappingsHeading") && inSheet("MappingListEmpty") && inSheet("AddMapping") && !inSheet("MappingEditor"),
                          "contextual empty file mappings for JSON \(mode)")
                let mappings = formats.mappings
                // Visible means inside the detail column's clip view, not merely unhidden.
                let shown = { (view: NSView) -> Bool in
                    guard let clip = view.enclosingScrollView.flatMap({ $0.identifier?.rawValue == "FormatDetail" ? $0 : $0.enclosingScrollView })?.contentView else { return false }
                    return clip.convert(clip.bounds, to: nil).contains(view.convert(view.alignmentRect(forFrame: view.bounds), to: nil))
                }
                try check(shown(mappings.addButton) && shown(mappings.removeButton), "+/– visible without scrolling at the opening size \(mode)")
                try await shot("\(mode)-06-formats-and-views.png", sheetFrame)
                for (kind, value, target) in [(FileAssociation.Kind.fileExtension, "customjson", FormatID.json), (.filename, "Pipfile.lock", .json), (.fileExtension, "conf", .yaml)] {
                    _ = session.addMapping(kind: kind, value: value, target: target)
                }
                mappings.beginAdd(nil)
                mappings.valueField.stringValue = "conf"
                mappings.add(nil)
                try await settle()
                try check(mappings.table.numberOfRows == 2 && inSheet("MappingList") && !inSheet("MappingListEmpty") && inSheet("MappingEditor")
                          && mappings.feedback.stringValue == "This extension is already mapped to YAML.",
                          "JSON lists only its two mappings; conflict shown in the open editor \(mode)")
                try check(shown(mappings.feedback) && shown(mappings.confirmButton), "open editor scrolled into view \(mode)")
                try await shot("\(mode)-07-file-mappings.png", sheetFrame)
                mappings.cancelDraft(nil)
                formats.select(.category(.structuredData))
                try await settle()
                try check(inSheet("MappingContextMessage") && !inSheet("MappingList") && inSheet("ViewOrder"), "category explains file mappings \(mode)")
                try await shot("\(mode)-07b-file-mappings-category.png", sheetFrame)
                for mapping in session.settings.fileAssociations { session.removeMapping(mapping) }
                host.dismiss(formats)
                try await waitForSheet(false)
                try check(window.attachedSheet == nil, "Formats & Views closes \(mode)")

                // Inquiry: a read-only report in its own window.
                guard let inquiryFile = PreviewSamples.url(for: .init(title: "JSON", path: "Showcase/json/json.json")) else { throw CocoaError(.fileNoSuchFile) }
                let inquiry = host.showInquiry(for: inquiryFile)
                for _ in 0..<80 { if inquiry.report != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
                try check(inquiry.report != nil, "inquiry report \(mode)")
                // D40: no row label repeats its section heading.
                let inquiryGroups = descendants(inquiry.view).compactMap { $0 as? NSStackView }.filter { ($0.arrangedSubviews.first as? NSTextField)?.identifier?.rawValue == "InquirySection" }
                try check(!inquiryGroups.isEmpty && inquiryGroups.allSatisfy { group in
                    let heading = (group.arrangedSubviews.first as? NSTextField)?.stringValue
                    return !descendants(group).contains { ($0 as? NSTextField)?.identifier?.rawValue == "InquiryLabel" && ($0 as? NSTextField)?.stringValue == heading }
                }, "inquiry rows do not repeat their heading \(mode)")
                guard let inquiryWindow = inquiry.view.window, let inquiryFrame = inquiryWindow.contentView?.superview else { throw CheckFailure(description: "inquiry window") }
                inquiryWindow.appearance = NSAppearance(named: appearance)
                try await shot("\(mode)-09-inquiry.png", inquiryFrame)
                inquiryWindow.close()

                // Quick Look's shared preview at a narrow width: status survives longest (F1.10).
                let narrow = SharedPreviewViewController(configuration: .init(settings: session.settings, appearance: mode == "light" ? .light : .dark))
                let panel = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
                panel.appearance = NSAppearance(named: appearance)
                panel.isReleasedWhenClosed = false
                panel.contentViewController = narrow
                panel.setContentSize(.init(width: 360, height: 420))
                panel.orderFront(nil)
                guard let json = PreviewSamples.url(for: .init(title: "JSON", path: "Showcase/json/json.json")) else { throw CocoaError(.fileNoSuchFile) }
                _ = try await narrow.preview(for: json, configuration: narrow.configuration)
                narrow.view.layoutSubtreeIfNeeded()
                let status = descendants(narrow.view).compactMap { $0 as? PreviewStatusView }.first
                try check(status.map { $0.visibleItemCount >= 1 && $0.visibleItemCount <= $0.items.count } == true, "narrow status collapse \(mode)")
                try await shot("\(mode)-narrow-08-quicklook.png", narrow.view)
                panel.close()
            }
            try (checks.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
            // E5-09: the receipt records what each image actually covers, measured at capture time.
            let receipt: [String: Any] = [
                "capturesWindowChrome": scopes.values.contains("window-with-titlebar"),
                "method": "NSView cacheDisplay",
                "images": scopes
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("capture-scope.json"), options: .atomic)
            let provenance = """
            Captured from the visible NSWindow of the running Glimt.app Debug target with NSView cacheDisplay.
            Window frame views include the titlebar; sheets are captured from their own frame view.
            The narrow Quick Look image is the shared preview controller used by the extension, hosted at 360×420.
            Settings are isolated through SettingsStore directory injection; no App Group or production preferences changed.
            capture-scope.json records, per image, whether it covers a window frame with its titlebar.
            No Screen Recording or Accessibility permission was used. Process: \(ProcessInfo.processInfo.processIdentifier).
            """
            try (provenance + "\n").write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            print("GLIMT_APP_UI_CAPTURE_READY \(directory.path)")
        } catch {
            try? (checks.joined(separator: "\n") + "\nFAIL \(error)\n").write(to: directory.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
            print("GLIMT_APP_UI_CAPTURE_BLOCKED \(error)")
        }
        // macOS protects the sandbox container from other processes, so callers may ask for the files
        // on stdout instead; the temporary directory is then removed.
        if ProcessInfo.processInfo.environment["GLIMT_CAPTURE_STDOUT"] == "1" {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: file) else { continue }
                print("GLIMT_CAPTURE_FILE \(file.lastPathComponent) \(data.base64EncodedString())")
            }
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        // Capture runs headless from scripts with redirected stdout; flush the marker and exit
        // directly, since terminate(_:) can be deferred while the scene is still settling.
        fflush(stdout)
        exit(0)
    }

    /// Includes the root view so callers can find a match anywhere in the captured hierarchy.
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// What a captured view covers: a window frame with its titlebar, a frame without
    /// one (a sheet), or only a view inside a window.
    private static func scope(of view: NSView) -> String {
        guard let window = view.window, view === window.contentView?.superview else { return "view" }
        return view.bounds.height > window.contentLayoutRect.height + 0.5 ? "window-with-titlebar" : "window-frame"
    }

    /// True when the source view's laid-out text ends inside its visible clip (Soft wrap only).
    private static func softWrapFits(_ view: NSView) -> Bool {
        guard let code = descendants(view).compactMap({ $0 as? SourceCodeView }).first,
              let layout = code.textView.layoutManager, let container = code.textView.textContainer else { return false }
        // The line-number ruler is a clip-view inset; text must fit beside it and inside the window.
        let insets = code.scrollView.contentView.contentInsets
        let clip = code.scrollView.contentView.bounds.width - insets.left - insets.right
        // Reads the current layout only; forcing layout here would hide a stale one from the image.
        let used = layout.usedRect(for: container).offsetBy(dx: code.textView.textContainerOrigin.x, dy: 0)
        return code.textView.frame.width <= clip + 0.5 && used.maxX <= clip + 0.5
    }

    /// Reports laid-out source, clip, and used widths when a soft-wrap assertion needs diagnosis.
    private static func softWrapGeometry(_ view: NSView) -> String {
        guard let code = descendants(view).compactMap({ $0 as? SourceCodeView }).first,
              let layout = code.textView.layoutManager, let container = code.textView.textContainer else { return "no source view" }
        let insets = code.scrollView.contentView.contentInsets
        let clip = code.scrollView.contentView.bounds.width - insets.left - insets.right
        let used = layout.usedRect(for: container).offsetBy(dx: code.textView.textContainerOrigin.x, dy: 0)
        return "text=\(code.textView.frame), clip=\(clip), used=\(used)"
    }

    /// Measures the rendered text against both its clip and the window, so clipping by either is reported.
    private static func renderedTextGeometry(_ view: NSView) -> (fits: Bool, detail: String) {
        guard let text = descendants(view).compactMap({ $0 as? NSTextView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
              let clip = text.enclosingScrollView?.contentView, let window = text.window,
              let layout = text.layoutManager, let container = text.textContainer else { return (false, "no text view") }
        let used = layout.usedRect(for: container).offsetBy(dx: text.textContainerOrigin.x, dy: 0)
        let clipInWindow = clip.convert(clip.bounds, to: nil)
        let windowWidth = window.contentView?.bounds.width ?? 0
        let fits = text.frame.width <= clip.bounds.width + 0.5 && used.maxX <= clip.bounds.width + 0.5
            && clipInWindow.maxX <= windowWidth + 0.5
        return (fits, "text=\(text.frame), clip=\(clip.bounds), clipInWindow=\(clipInWindow), window=\(windowWidth), used=\(used)")
    }
}
#endif
