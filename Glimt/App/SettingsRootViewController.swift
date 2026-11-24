import AppKit
import InspectorCore

/// The Glimt window: one unified Settings view beside its Live Preview, the Inquiry tool, a
/// persistence status banner and the secondary sheets. Opened files stay read-only.
@MainActor
final class SettingsRootViewController: NSViewController {
    static let saveFailedTitle = "Settings couldn't be saved."

    /// The frontmost window's root, for the app-level Open File command.
    private(set) static weak var current: SettingsRootViewController?

    let session: SettingsSession
    let general: GeneralSettingsViewController
    private let banner = NSTextField(wrappingLabelWithString: "")
    /// Inquiry sits at the trailing edge of the titlebar (D61).
    let inquiryButton = NSButton()
    private let inquiryAccessory = NSTitlebarAccessoryViewController()
    private var inquiryWindow: NSWindowController?
    private var saveAlertPresented = false
    /// Replaced in tests so sheets can be inspected without a window.
    var presentSheet: (NSViewController) -> Void = { _ in }
    private(set) weak var presentedSheet: NSViewController?

    /// Creates the settings window controller and wires it to the shared settings session.
    init(session: SettingsSession, sampleBundle: Bundle = .main) {
        self.session = session
        general = GeneralSettingsViewController(session: session, sampleBundle: sampleBundle)
        super.init(nibName: nil, bundle: nil)
        general.openFormatsAndViews = { [weak self] in
            self?.showFormatsAndViews()
        }
        presentSheet = { [weak self] sheet in self?.presentAsSheet(sheet) }
        session.observe { [weak self] change in
            if change == .status { self?.statusChanged() }
            if change == .settings { self?.applyColorScheme() }
        }
        applyColorScheme()
        Self.current = self
    }

    /// Color scheme applies to the whole app at once; `.system` follows macOS (D51).
    private func applyColorScheme() {
        let name: NSAppearance.Name? = switch session.settings.general.colorScheme {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
        guard NSApp.appearance?.name != name else { return }
        NSApp.appearance = name.flatMap(NSAppearance.init(named:))
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    /// Builds the single Settings view under the status banner.
    override func loadView() {
        let root = NSView()
        banner.textColor = .secondaryLabelColor
        banner.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        banner.identifier = .init("SettingsStatus")
        banner.setAccessibilityLabel("Settings status")
        let bannerBox = NSStackView(views: [NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage()), banner])
        bannerBox.edgeInsets = .init(top: 6, left: 16, bottom: 6, right: 16)
        bannerBox.identifier = .init("SettingsStatusBar")
        // A plain container has no intrinsic height, so the stack gives Settings the remaining height.
        let content = NSView()
        addChild(general)
        general.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(general.view)
        NSLayoutConstraint.activate([
            general.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            general.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            general.view.topAnchor.constraint(equalTo: content.topAnchor),
            general.view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let stack = NSStackView(views: [bannerBox, content])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bannerBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 1000),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 620)
        ])
        view = root
        statusChanged()
    }

    /// Installs the Inquiry accessory once the controller has a window. There is no pane toolbar:
    /// Settings is one view and Formats & Views is a sheet (spec §4).
    override func viewDidAppear() {
        super.viewDidAppear()
        Self.current = self
        guard let window = view.window, !window.titlebarAccessoryViewControllers.contains(inquiryAccessory) else { return }
        inquiryAccessory.view = makeInquiryAccessory()
        inquiryAccessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(inquiryAccessory)
        window.title = "Glimt"
        window.titleVisibility = .visible
        window.minSize = .init(width: 1000, height: 620)
#if DEBUG
        DeveloperMenu.install(for: self)
#endif
        statusChanged()
    }

    /// The Live Preview beside the settings.
    var activePreview: PreviewPane { general.preview }

    /// Inquiry for the trailing titlebar accessory. AppKit holds a trailing accessory to the title
    /// row's height, so icon and label sit side by side.
    private func makeInquiryAccessory() -> NSView {
        let box = NSView(frame: .init(x: 0, y: 0, width: 108, height: 28))
        inquiryButton.title = "Inquiry"
        inquiryButton.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Inquiry")
        inquiryButton.imagePosition = .imageLeading
        inquiryButton.bezelStyle = .toolbar
        inquiryButton.toolTip = "Inquiry"
        inquiryButton.setAccessibilityLabel("Inquiry")
        inquiryButton.identifier = .init("InquiryButton")
        inquiryButton.target = self
        inquiryButton.action = #selector(inquiryFile(_:))
        inquiryButton.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inquiryButton)
        NSLayoutConstraint.activate([
            inquiryButton.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            inquiryButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            inquiryButton.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor)
        ])
        return box
    }

    // MARK: Status

    /// Mirrors session persistence state into the banner and one-shot failure alert.
    private func statusChanged() {
        // The session is the authority for both the banner and save-failure alert state.
        guard isViewLoaded else { return }
        banner.stringValue = session.statusMessage
        banner.superview?.isHidden = session.statusMessage.isEmpty
        if session.saveFailed { presentSaveFailureIfNeeded() }
    }

    /// Presents one save failure at a time and offers details only after user request.
    private func presentSaveFailureIfNeeded() {
        // Avoid stacking alerts over another sheet or repeating the same failure notification.
        guard !saveAlertPresented, let window = view.window, window.attachedSheet == nil else { return }
        saveAlertPresented = true
        let alert = NSAlert()
        alert.messageText = Self.saveFailedTitle
        alert.informativeText = "Your changes apply to this preview only."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Details")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            let details = NSAlert()
            details.messageText = "Settings storage is unavailable."
            details.informativeText = "Glimt could not write its shared settings. Reopen the app after settings access is configured. Your documents have not been changed."
            details.beginSheetModal(for: window)
        }
    }

    // MARK: Sheets

    /// Opens Formats & Views; a second request brings the open sheet forward instead of stacking
    /// another one (spec §13).
    @discardableResult
    func showFormatsAndViews(selecting scope: ViewScope? = nil) -> FormatsAndViewsSheet {
        if let open = presentedSheet as? FormatsAndViewsSheet {
            open.loadViewIfNeeded()
            if let scope { open.select(scope) }
            open.view.window?.makeKeyAndOrderFront(nil)
            return open
        }
        let sheet = FormatsAndViewsSheet(session: session, selecting: scope)
        presentedSheet = sheet
        sheet.onDismiss = { [weak self, weak sheet] in
            guard let self, let sheet, self.presentedSheet === sheet else { return }
            self.presentedSheet = nil
        }
        presentSheet(sheet)
        return sheet
    }

    // MARK: Files

    /// Open File (⌘O): previews a user file in the Live Preview.
    @objc func openDocument(_ sender: Any?) {
        // PreviewPane balances the panel's scoped URL access for the duration of the asynchronous read.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Preview"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.preview(url)
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    /// Routes a selected user file to the Live Preview.
    func preview(_ url: URL) {
        general.preview.show(url, title: url.lastPathComponent)
    }

    /// Presents a single-file picker before starting a read-only Inspector inquiry.
    @objc func inquiryFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Inquire"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.showInquiry(for: url)
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    /// Fits the Standard report without a large empty area (E5-08); Advanced and long reports scroll.
    static let inquirySize = NSSize(width: 780, height: 480)

    /// Replaces the prior Inquiry window and returns its controller for callers and UI tests.
    @discardableResult
    func showInquiry(for url: URL) -> InquiryViewController {
        // Inquiry owns one utility window; close its previous instance before publishing the next report.
        let inquiry = InquiryViewController(configuration: session.renderConfiguration)
        inquiry.onPreview = { [weak self] file in
            self?.preview(file)
            self?.view.window?.makeKeyAndOrderFront(nil)
        }
        let window = NSWindow(contentRect: .init(origin: .zero, size: Self.inquirySize),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Glimt · Inquiry"
        window.isReleasedWhenClosed = false
        window.contentViewController = inquiry
        window.setContentSize(Self.inquirySize)
        inquiryWindow?.close()
        inquiryWindow = NSWindowController(window: window)
        inquiryWindow?.showWindow(nil)
        // Keep file loading asynchronous so presenting the utility window never blocks the UI.
        Task { await inquiry.loadFile(at: url) }
        return inquiry
    }
}

#if DEBUG
// MARK: - Developer menu

/// Debug-only fixtures and inspection details; never part of the product UI.
@MainActor
private enum DeveloperMenu {
    private static weak var owner: SettingsRootViewController?
    private static var window: NSWindowController?
    private static let handler = Handler()

    /// Adds debug-only fixtures and diagnostics without exposing these commands in release builds.
    static func install(for root: SettingsRootViewController) {
        // Developer-only commands attach once and remain absent from release builds.
        owner = root
        guard let main = NSApplication.shared.mainMenu, !main.items.contains(where: { $0.title == "Developer" }) else { return }
        let item = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Developer")
        item.submenu = menu
        for (title, action) in [("Developer Fixtures…", #selector(Handler.fixtures(_:))),
                                ("Inspection Details…", #selector(Handler.details(_:)))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = handler
            menu.addItem(entry)
        }
        if !root.session.isPersistent {
            menu.addItem(.separator())
            let mode = NSMenuItem(title: "Preview-only development mode", action: nil, keyEquivalent: "")
            mode.isEnabled = false
            menu.addItem(mode)
        }
        main.addItem(item)
    }

    /// Shows one reusable debug panel, replacing any earlier fixture or details panel.
    private static func show(_ content: NSView, title: String) {
        // Reuse one debug panel so dismissed windows do not retain old fixture content.
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 620, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        window?.close()
        window = NSWindowController(window: panel)
        window?.showWindow(nil)
    }

    @MainActor
    final class Handler: NSObject {
        private var choices: [URL] = []
        private let picker = NSPopUpButton(frame: .zero, pullsDown: false)

        /// Builds the fixture picker from repository files discovered by the bounded scanner.
        @objc func fixtures(_ sender: Any?) {
            picker.removeAllItems()
            let found = DeveloperMenu.fixtureChoices()
            choices = found.map(\.url)
            picker.addItems(withTitles: found.map(\.label))
            picker.target = self
            picker.action = #selector(choose(_:))
            let stack = NSStackView(views: [SettingsForm.heading("Developer Fixtures", subtitle: nil), picker])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.edgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
            DeveloperMenu.show(stack, title: "Glimt Developer Fixtures")
        }

    /// Applies the selected format mapping and refreshes the dependent controls.
    @objc func choose(_ sender: NSPopUpButton) {
            // A stale menu action must not index outside the fixture list currently displayed.
            guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
            DeveloperMenu.owner?.preview(choices[sender.indexOfSelectedItem])
        }

        /// Displays diagnostics for the currently selected preview without enabling editing.
        @objc func details(_ sender: Any?) {
            let text = NSTextView()
            text.isEditable = false
            text.string = DeveloperMenu.owner?.activePreview.diagnosticsText ?? ""
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            DeveloperMenu.show(scroll, title: "Glimt Inspection Details")
        }
    }

    /// The repository's Fixtures folder, found next to this source file in development builds.
    static func fixtureChoices() -> [(label: String, url: URL)] {
        // Walk only the source checkout and cap traversal so debug tooling remains bounded.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let root = directory.appendingPathComponent("Fixtures", isDirectory: true)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path) {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
                var found: [(label: String, url: URL)] = []
                var visited = 0
                while let url = enumerator.nextObject() as? URL, visited < 1_000, found.count < 200 {
                    visited += 1
                    guard url.lastPathComponent != "README.md",
                          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    found.append((String(url.path.dropFirst(root.path.count + 1)), url))
                }
                return found.sorted { $0.label < $1.label }
            }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return [] }
            directory.deleteLastPathComponent()
        }
        return []
    }
}
#endif
