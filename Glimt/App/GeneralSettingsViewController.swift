import AppKit
import InspectorCore

/// The unified Settings view (spec §4): Appearance, Preview, Formats & Views and a collapsible
/// Advanced section (60%) beside the Live Preview (40%). Every edit applies to the preview at once.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    static let showcase = PreviewSamples.Example(title: "Swift", path: "Showcase/source/swift.swift")

    private let session: SettingsSession
    private let sampleBundle: Bundle
    let preview: PreviewPane

    let colorScheme = ColorSchemePopup()
    let textFont = TextFontPopup()
    let font = FontChooser()
    let quickLookFontSize = ValueSlider(range: 9...24, step: 1, defaultValue: FontSetting.defaultSize,
                                        name: "Quick Look font size", identifier: "QuickLookFontSize") { "\(Int($0.rounded())) pt" }
    let wordWrap = WordWrapPopup()
    let lineLength = NumberStepperField(range: GeneralSettingsV3.lineLengthRange, suffix: "characters",
                                        accessibilityLabel: "Line length", identifier: "LineLength")
    let lineNumbers = NSSwitch()
    let indentationGuides = NSSwitch()
    let vcsSupport = NSSwitch()
    let debugLogging = NSSwitch()
    let showLogFile = NSButton(title: "Show Log File", target: nil, action: nil)
#if DEBUG
    let debugBuildMarker = NSSwitch()
#endif
    /// Replaced in tests; the default reveals the shared debug log (or its folder) in Finder.
    var revealLogFile: () -> Void = {
        let url = GlimtDebugLog.shared.logFileURL
        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
    /// 1–16; a stored legacy 0 renders like the kept tab stop and is shown as 4 until edited.
    let tabs = ValueSlider(range: 1...16, step: 1, defaultValue: Double(GeneralSettingsV3.keptTabStop),
                           name: "Tab width", identifier: "TabsToSpaces") { "\(Int($0.rounded()))" }
    let dataLimit = DataLimitControl()
    let resetAll = NSButton(title: "Reset All Settings…", target: nil, action: nil)
    let configureFormats = NSButton(title: "Configure…", target: nil, action: nil)
    /// The owning settings controller supplies the action so this control does not depend on
    /// AppKit's weak parent relationship at click time.
    var openFormatsAndViews: () -> Void = {}
    /// Shown only while stored per-format appearance overrides from before ADR-022 remain (spec §12).
    private(set) var retiredRow = NSView()
    private(set) var retiredNotice = NSTextField()
    let discardRetired = NSButton(title: "Discard Retired Overrides…", target: nil, action: nil)
    let advancedDisclosure = NSButton()
    private(set) var advancedContent = NSStackView()
    private weak var formStack: NSStackView?
    private weak var lastSection: NSView?
    /// Replaced in tests; the default asks before discarding the retired values.
    var confirmDiscardRetired: (@escaping (Bool) -> Void) -> Void = { completion in
        let alert = NSAlert()
        alert.messageText = "Discard retired format overrides?"
        alert.informativeText = "These per-format appearance values no longer apply; the Appearance and Preview settings are used for every format. Format Options and views are kept."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        completion(alert.runModal() == .alertFirstButtonReturn)
    }
    /// Replaced in tests; the default asks before resetting everything.
    var confirmResetAll: (@escaping (Bool) -> Void) -> Void = { completion in
        let alert = NSAlert()
        alert.messageText = "Reset all Glimt settings?"
        alert.informativeText = "Settings, views, format options, custom themes and file mappings return to factory defaults. Your files are not changed."
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        completion(alert.runModal() == .alertFirstButtonReturn)
    }

    /// Connects controls to one settings session and uses the supplied bundle for deterministic previews.
    init(session: SettingsSession, sampleBundle: Bundle = .main) {
        self.session = session
        self.sampleBundle = sampleBundle
        preview = PreviewPane(session: session, sampleBundle: sampleBundle)
        super.init(nibName: nil, bundle: nil)
        session.observe { [weak self] change in
            if change == .settings { self?.synchronize() }
        }
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    /// Builds the form and preview split while keeping the scroll document tied to the visible width.
    override func loadView() {
        let root = NSView()
        let form = makeForm()
        let scroll = GeneralSettingsScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: SettingsForm.margin),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -SettingsForm.margin),
            form.topAnchor.constraint(equalTo: document.topAnchor, constant: SettingsForm.margin),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -SettingsForm.margin)
        ])
        scroll.identifier = .init("GeneralSettings")
        document.identifier = .init("GeneralDocument")

        addChild(preview)
        let divider = GeneralDividerView()
        divider.identifier = .init("GeneralDivider")
        for child in [scroll, divider, preview.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.6, constant: -0.6),
            divider.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            preview.view.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            preview.view.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.4, constant: -0.4),
            preview.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: root.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        synchronize()
    }

    /// Wires edits into the session before constructing the grouped general settings controls.
    private func makeForm() -> NSView {
        font.showsSizeOptions = false
        colorScheme.onChange = { [weak self] value in self?.session.update { $0.general.colorScheme = value } }
        textFont.onChange = { [weak self] value in self?.session.update { $0.general.textFont = value } }
        font.onChange = { [weak self] value in self?.session.update { $0.general.font = value } }
        quickLookFontSize.onChange = { [weak self] value in self?.session.update { $0.general.font.size = value.rounded() } }
        wordWrap.onChange = { [weak self] value in self?.session.update { $0.general.wordWrap = value } }
        lineLength.onChange = { [weak self] value in self?.session.update { $0.general.lineLength = value } }
        lineNumbers.target = self
        lineNumbers.action = #selector(toggleLineNumbers(_:))
        lineNumbers.identifier = .init("LineNumbers")
        lineNumbers.setAccessibilityLabel("Line numbers")
        indentationGuides.target = self
        indentationGuides.action = #selector(toggleIndentationGuides(_:))
        indentationGuides.identifier = .init("IndentationGuides")
        indentationGuides.setAccessibilityLabel("Indentation guides")
        vcsSupport.target = self
        vcsSupport.action = #selector(toggleVCSSupport(_:))
        vcsSupport.identifier = .init("VCSSupport")
        vcsSupport.setAccessibilityLabel("VCS Support")
        debugLogging.target = self
        debugLogging.action = #selector(toggleDebugLogging(_:))
        debugLogging.identifier = .init("DebugLogging")
        debugLogging.setAccessibilityLabel("Debug logging")
        showLogFile.target = self
        showLogFile.action = #selector(revealDebugLog(_:))
        showLogFile.identifier = .init("ShowLogFile")
#if DEBUG
        debugBuildMarker.target = self
        debugBuildMarker.action = #selector(toggleDebugBuildMarker(_:))
        debugBuildMarker.identifier = .init("DebugBuildMarker")
        debugBuildMarker.setAccessibilityLabel("Build marker")
#endif
        tabs.onChange = { [weak self] value in self?.session.update { $0.general.tabsToSpaces = Int(value.rounded()) } }
        dataLimit.onCommit = { [weak self] amount, unit in self?.session.setDataLimit(amount: amount, unit: unit) }
        dataLimit.onUnitChange = { [weak self] unit in self?.session.setDataLimitUnit(unit) }
        font.cell?.lineBreakMode = .byTruncatingTail
        resetAll.target = self
        resetAll.action = #selector(confirmReset(_:))
        resetAll.identifier = .init("ResetAllSettings")
        configureFormats.target = self
        configureFormats.action = #selector(configureFormatsAndViews(_:))
        configureFormats.identifier = .init("ConfigureFormatsAndViews")
        configureFormats.setAccessibilityLabel("Configure Formats & Views")
        discardRetired.target = self
        discardRetired.action = #selector(confirmDiscardRetired(_:))
        discardRetired.identifier = .init("DiscardRetiredOverrides")
        let appearanceRows: [NSView] = [
            GeneralSettingsForm.row(label: "Color scheme", help: "Choose the app's appearance.", control: colorScheme, identifier: "GeneralRow-ColorScheme"),
            GeneralSettingsForm.row(label: "Text font", help: "Set font for rendered Markdown text.", control: textFont, identifier: "GeneralRow-TextFont"),
            GeneralSettingsForm.row(label: "Monospace font", help: "Set font for places like source code, code blocks and structured text.", control: font, identifier: "GeneralRow-Font")
        ]
        let previewRows: [NSView] = [
            GeneralSettingsForm.row(label: "Font size", help: "Font size in points that affects source and structured text.", control: quickLookFontSize, identifier: "GeneralRow-QuickLookFontSize"),
            GeneralSettingsForm.row(label: "Word wrap", help: "Wrap long lines. Affects display, never the original file.", control: wordWrap, identifier: "GeneralRow-WordWrap"),
            GeneralSettingsForm.row(label: "Line length", help: "Characters per line with Hard wrap.", control: lineLength, identifier: "GeneralRow-LineLength"),
            GeneralSettingsForm.row(label: "Line numbers", help: "Show line numbers in the gutter.", control: lineNumbers, identifier: "GeneralRow-LineNumbers"),
            GeneralSettingsForm.row(label: "Indentation guides", help: "Show vertical lines at each indentation level in source code.", control: indentationGuides, identifier: "GeneralRow-IndentationGuides"),
            GeneralSettingsForm.row(label: "Tab width", help: "Number of spaces a tab character will render as.", control: tabs, identifier: "GeneralRow-Tabs")
        ]
        retiredRow = GeneralSettingsForm.row(label: "Retired format overrides", help: " ", control: discardRetired,
                                             identifier: "GeneralRow-RetiredOverrides")
        // The row's help text is the notice, so its count stays current.
        retiredNotice = Self.descendant(of: retiredRow, identifier: "GeneralRow-RetiredOverrides-Help") as? NSTextField ?? retiredNotice
        let formatRows: [NSView] = [
            GeneralSettingsForm.row(label: "Views and file mappings", help: "Choose which views each format offers, their order and default, and which file names preview as which format.",
                                    control: configureFormats, identifier: "GeneralRow-FormatsAndViews"),
            retiredRow
        ]
        var advancedRows: [NSView] = [
            GeneralSettingsForm.row(label: "Data limit", help: "Maximum size for text-based previews.", control: dataLimit, identifier: "GeneralRow-DataLimit"),
            GeneralSettingsForm.row(label: "VCS Support", help: "Show local Git and SVN changes in the gutter.", control: vcsSupport, identifier: "GeneralRow-VCSSupport"),
            GeneralSettingsForm.row(label: "Debug logging", help: "Write a local troubleshooting log. File names, paths and contents are never logged.",
                                    control: debugLogging, identifier: "GeneralRow-DebugLogging"),
            GeneralSettingsForm.row(label: "Log file", help: "~/Library/Logs/Glimt/Glimt.log", control: showLogFile, identifier: "GeneralRow-DebugLogFile")
        ]
#if DEBUG
        // Release builds draw no build marker, so only Debug builds offer the switch.
        advancedRows.append(GeneralSettingsForm.row(label: "Build marker", help: "Show when this Debug build was made in Quick Look and thumbnails.",
                                                    control: debugBuildMarker, identifier: "GeneralRow-DebugBuildMarker"))
#endif
        let appearance = makeSection("Appearance", id: "GeneralAppearance",
                                     help: "Color scheme and fonts.", rows: appearanceRows)
        let preview = makeSection("Preview", id: "GeneralPreview",
                                  help: "Document readability settings for the app and Quick Look.", rows: previewRows)
        let formats = makeSection("Formats & Views", id: "GeneralFormatsAndViews",
                                  help: "Views, view order and file mappings per format.", rows: formatRows)
        let advanced = makeSection("Advanced", id: "GeneralAdvanced",
                                   help: "Processing limits, version control and debug logging.", rows: advancedRows)
        makeCollapsible(advanced)
        let sections = [appearance, preview, formats, advanced]
        let stack = NSStackView(views: sections + [resetAll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.identifier = .init("GeneralForm")
        for section in sections {
            section.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(GeneralSettingsForm.sectionGap, after: section)
        }
        formStack = stack
        lastSection = advanced
        return stack
    }

    private static func descendant(of view: NSView, identifier: String) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { descendant(of: $0, identifier: identifier) }.first
    }

    /// Advanced starts collapsed; a disclosure button beside its heading shows or hides the rows.
    private func makeCollapsible(_ section: NSStackView) {
        guard let heading = section.arrangedSubviews.first, let content = section.arrangedSubviews.last as? NSStackView else { return }
        advancedContent = content
        advancedDisclosure.bezelStyle = .disclosure
        advancedDisclosure.setButtonType(.pushOnPushOff)
        advancedDisclosure.title = ""
        advancedDisclosure.state = .off
        advancedDisclosure.identifier = .init("AdvancedDisclosure")
        advancedDisclosure.setAccessibilityLabel("Show Advanced settings")
        advancedDisclosure.target = self
        advancedDisclosure.action = #selector(toggleAdvanced(_:))
        section.removeArrangedSubview(heading)
        heading.removeFromSuperview()
        let header = NSStackView(views: [advancedDisclosure, heading])
        header.orientation = .horizontal
        header.spacing = 4
        section.insertArrangedSubview(header, at: 0)
        content.isHidden = true
    }

    /// Groups rows under one accessible heading; spacing alone separates rows (D60).
    private func makeSection(_ title: String, id: String, help: String, rows: [NSView]) -> NSStackView {
        let heading = GeneralSettingsForm.sectionHeading(title, identifier: id, help: help)
        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = GeneralSettingsForm.rowGap
        let section = NSStackView(views: [heading, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = GeneralSettingsForm.headingGap
        content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        // Every row spans the section, so text starts at the row indent and controls share one column.
        for row in rows { row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        return section
    }

    /// Loads the showcase only when no user-selected document is already active.
    override func viewDidAppear() {
        super.viewDidAppear()
        if preview.currentFileURL == nil { showShowcase() }
    }

    /// The live source showcase; never an example picker (D14).
    func showShowcase() {
        preview.setExamples(PreviewSamples.examples(for: "rendering"), selected: Self.showcase)
        guard let url = PreviewSamples.url(for: Self.showcase, bundle: sampleBundle) else { return }
        preview.show(url, title: "Example: \(Self.showcase.title)")
    }

    // MARK: Synchronization

    /// Reflects normalized session values without overwriting values the current control cannot display.
    func synchronize() {
        let general = session.settings.general
        colorScheme.set(general.colorScheme)
        textFont.set(general.textFont)
        font.set(general.font)
        font.setAccessibilityLabel("Monospace font: \(font.value.family)")
        font.toolTip = font.value.family
        // Keep legacy v3 values above the v7 slider range visible and intact until the user edits.
        quickLookFontSize.setStepRange(maximum: general.font.size > 24 ? 32 : 24)
        quickLookFontSize.set(min(max(general.font.size, 9), quickLookFontSize.slider.maxValue))
        wordWrap.set(general.wordWrap)
        lineLength.set(general.lineLength)
        lineNumbers.state = general.lineNumbers ? .on : .off
        indentationGuides.state = general.indentationGuides ? .on : .off
        vcsSupport.state = general.vcsSupportEnabled ? .on : .off
        debugLogging.state = general.debugLoggingEnabled ? .on : .off
#if DEBUG
        debugBuildMarker.state = general.debugBuildMarker ? .on : .off
        debugBuildMarker.isEnabled = session.canEdit
#endif
        tabs.set(Double(general.tabsToSpaces == 0 ? GeneralSettingsV3.keptTabStop : general.tabsToSpaces))
        dataLimit.set(bytes: general.dataLimitBytes, unit: general.dataLimitDisplayUnit)
        let editable = session.canEdit
        colorScheme.isEnabled = editable
        textFont.isEnabled = editable
        font.isEnabled = editable
        quickLookFontSize.isEnabled = editable
        wordWrap.isEnabled = editable
        // The value is retained while another wrap mode is selected.
        let lineLengthEnabled = editable && general.wordWrap == .hard
        if lineLength.isEnabled, !lineLengthEnabled, !view.isHiddenOrHasHiddenAncestor,
           let window = view.window, lineLengthOwnsFocus(in: window) {
            _ = window.makeFirstResponder(wordWrap)
        }
        lineLength.isEnabled = lineLengthEnabled
        lineNumbers.isEnabled = editable
        indentationGuides.isEnabled = editable
        vcsSupport.isEnabled = editable
        debugLogging.isEnabled = editable
        tabs.isEnabled = editable
        dataLimit.isEnabled = editable
        let retired = session.settings.formatsWithRetiredAppearance
        retiredNotice.stringValue = retired.isEmpty ? "" : retired.count == 1
            ? "1 format keeps appearance values that no longer apply."
            : "\(retired.count) formats keep appearance values that no longer apply."
        retiredRow.isHidden = retired.isEmpty
        discardRetired.isEnabled = editable
        // Global reset (FR-TGT-028): shown only when something differs from factory values.
        resetAll.isHidden = !editable || session.isFactoryDefault
        if let formStack, let lastSection {
            formStack.setCustomSpacing(resetAll.isHidden ? 0 : GeneralSettingsForm.sectionGap, after: lastSection)
        }
    }

    // MARK: Actions

    /// Opens the Formats & Views sheet; it is available read-only too, so its state can be inspected.
    @objc private func configureFormatsAndViews(_ sender: Any?) {
        openFormatsAndViews()
    }

    @objc private func toggleAdvanced(_ sender: NSButton) {
        let expanded = sender.state == .on
        advancedContent.isHidden = !expanded
        sender.setAccessibilityLabel(expanded ? "Hide Advanced settings" : "Show Advanced settings")
        guard expanded else { return }
        // Revealed rows sit at the end of the scrolling form; bring them into view.
        view.layoutSubtreeIfNeeded()
        advancedContent.scrollToVisible(advancedContent.bounds)
    }

    /// Discards retired per-format appearance only after explicit confirmation; never silently (spec §12).
    @objc private func confirmDiscardRetired(_ sender: Any?) {
        confirmDiscardRetired { [weak self] confirmed in
            guard confirmed else { return }
            self?.session.update { $0.discardRetiredAppearance() }
        }
    }

    /// Keeps keyboard focus predictable across the confirmation sheet and reset-driven view updates.
    @objc private func confirmReset(_ sender: Any?) {
        let window = view.window
        let resetHadFocus = window?.firstResponder === resetAll
        confirmResetAll { [weak self] confirmed in
            guard let self else { return }
            if confirmed {
                if resetHadFocus { window?.makeFirstResponder(self.colorScheme) }
                self.session.resetAll()
            } else if resetHadFocus {
                window?.makeFirstResponder(self.resetAll)
            }
        }
    }

    /// Includes the stepper and its field editor because either can own the active edit session.
    private func lineLengthOwnsFocus(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder === lineLength.field || responder === lineLength.stepper { return true }
        return lineLength.field.currentEditor() === responder
    }

    @objc private func toggleLineNumbers(_ sender: NSSwitch) {
        session.update { $0.general.lineNumbers = sender.state == .on }
    }

    @objc private func toggleIndentationGuides(_ sender: NSSwitch) {
        session.update { $0.general.indentationGuides = sender.state == .on }
    }

    @objc private func toggleVCSSupport(_ sender: NSSwitch) {
        session.update { $0.general.vcsSupportEnabled = sender.state == .on }
    }

    @objc private func toggleDebugLogging(_ sender: NSSwitch) {
        session.update { $0.general.debugLoggingEnabled = sender.state == .on }
    }

    @objc private func revealDebugLog(_ sender: NSButton) { revealLogFile() }

#if DEBUG
    @objc private func toggleDebugBuildMarker(_ sender: NSSwitch) {
        session.update { $0.general.debugBuildMarker = sender.state == .on }
    }
#endif
}

private final class GeneralDividerView: NSView {
    /// Paints the section boundary using the system separator color for current appearance.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

@MainActor
private final class GeneralSettingsScrollView: NSScrollView {
    /// Re-tiles after bounds changes, then keeps the document aligned to the visible width.
    override func tile() {
        super.tile()
        synchronizeDocumentWidth()
    }

    /// Reapplies width synchronization after Auto Layout updates the viewport.
    override func layout() {
        super.layout()
        synchronizeDocumentWidth()
    }

    /// Prevents horizontal overflow in the General form while allowing vertical scrolling.
    private func synchronizeDocumentWidth() {
        guard let documentView else { return }
        let width = contentView.bounds.width
        guard width > 0, abs(documentView.frame.width - width) > 0.5 else { return }
        var frame = documentView.frame
        frame.size.width = width
        documentView.setFrameSize(frame.size)
    }
}

/// Short forms stay anchored at the top of their scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
