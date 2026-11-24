import AppKit
import InspectorCore

/// The live preview beside General and Format settings: the shared Quick Look renderer, the
/// same surface Finder's preview column shows, under one example picker. Finder thumbnails have
/// no user settings and are not shown here (D62). The footer carries the example name (General)
/// or the file status (Format) (D32). Appearance comes from the persisted Color scheme only (D51).
/// Opened files stay read-only; file access ends after the bounded shared read.
@MainActor
final class PreviewPane: NSViewController {
    static let unableToPreview = "Unable to preview this file. Choose another file."
    static let unableToOpen = "Unable to open this file. Choose another file."

    let previewController: SharedPreviewViewController
    private let session: SettingsSession
    private let sampleBundle: Bundle
    private let exampleLabel = NSTextField(labelWithString: "")
    private let samplePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reopenDefaultButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reopen with default representation") ?? NSImage(), target: nil, action: nil)
    private var examples: [PreviewSamples.Example] = []

    private(set) var currentFileURL: URL?
    private(set) var currentPreparation: PreviewPreparation?
    private(set) var currentTitle: String?
    private var loading: (url: URL, title: String?)?
    /// Developer-only inspection summary; never shown in the product UI.
    private(set) var diagnosticsText = ""
    private var loadTask: Task<Void, Never>?
    private var requestID = 0
    private var lastConfiguration: RenderConfiguration

    /// Creates the shared preview surface and subscribes it to session changes.
    init(session: SettingsSession, sampleBundle: Bundle = .main) {
        self.session = session
        self.sampleBundle = sampleBundle
        lastConfiguration = session.renderConfiguration
        previewController = SharedPreviewViewController(configuration: session.renderConfiguration)
        super.init(nibName: nil, bundle: nil)
        previewController.loadViewIfNeeded()
        previewController.footerStrip.showsStatus = true
        previewController.footerStrip.showsRepresentations = true
        session.observe { [weak self] change in self?.sessionChanged(change) }
    }
    required init?(coder: NSCoder) { nil }

    /// Builds the example header above the shared renderer and the empty-state overlay.
    override func loadView() {
        let container = NSView()
        addChild(previewController)
        let preview = previewController.view
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        samplePicker.identifier = .init("PreviewSamplePicker")
        samplePicker.widthAnchor.constraint(equalToConstant: 102).isActive = true
        samplePicker.cell?.lineBreakMode = .byTruncatingTail
        samplePicker.setAccessibilityLabel("Preview example")
        samplePicker.target = self
        samplePicker.action = #selector(changeSample(_:))
        reopenDefaultButton.identifier = .init("ReopenDefaultRepresentation")
        reopenDefaultButton.setAccessibilityLabel("Reopen preview using the saved default representation")
        reopenDefaultButton.toolTip = "Reopen using the saved default representation"
        reopenDefaultButton.bezelStyle = .toolbar
        reopenDefaultButton.target = self
        reopenDefaultButton.action = #selector(reopenWithDefaultRepresentation(_:))
        let headerStack = NSStackView(views: [NSView(), samplePicker, reopenDefaultButton])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: header.topAnchor),
            headerStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        exampleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        exampleLabel.textColor = .secondaryLabelColor
        exampleLabel.lineBreakMode = .byTruncatingMiddle
        exampleLabel.identifier = .init("PreviewExampleLabel")
        previewController.footerStrip.leadingAccessory = exampleLabel
        samplePicker.isHidden = true
        view = container
    }

    // MARK: Session

    /// Reconfigures only the preview surface affected by a session change.
    private func sessionChanged(_ change: SettingsSession.Change) {
        switch change {
        case .settings:
            let configuration = session.renderConfiguration
            let previous = lastConfiguration
            lastConfiguration = configuration
            previewController.configuration = configuration
            // Inspection policy decides what is read and how it is detected: re-read the same file.
            let reinspect = previous.maximumPreviewBytes != configuration.maximumPreviewBytes
                || previous.fileAssociations != configuration.fileAssociations
                || previous.markdown.options != configuration.markdown.options
            // Inspection-affecting preferences must be applied to the same file with a fresh request.
            if reinspect, let target = loading ?? currentFileURL.map({ ($0, currentTitle) }) { show(target.url, title: target.title) }
        case .status:
            break
        }
    }

    /// Replaces the example menu and keeps the requested fixture selected when it remains available.
    func setExamples(_ values: [PreviewSamples.Example], selected: PreviewSamples.Example? = nil) {
        examples = values
        samplePicker.removeAllItems()
        for (index, example) in values.enumerated() {
            samplePicker.addItem(withTitle: example.title)
            samplePicker.lastItem?.representedObject = index
        }
        samplePicker.isHidden = values.isEmpty
        if let selected, let index = values.firstIndex(where: { $0.path == selected.path }) {
            samplePicker.selectItem(at: index)
        } else if !values.isEmpty {
            samplePicker.selectItem(at: 0)
        }
    }

    /// Makes the picker name the shown document: its example entry, or a file entry above the examples.
    private func selectPickerEntry(for url: URL) {
        guard !examples.isEmpty else { return }
        // Remove an earlier file entry and its separator; example items carry their index.
        while let first = samplePicker.itemArray.first, first.representedObject == nil {
            samplePicker.removeItem(at: 0)
        }
        let shown = url.standardizedFileURL
        if let index = examples.firstIndex(where: { PreviewSamples.url(for: $0, bundle: sampleBundle)?.standardizedFileURL == shown }) {
            samplePicker.selectItem(at: index)
            return
        }
        samplePicker.insertItem(withTitle: url.lastPathComponent, at: 0)
        samplePicker.menu?.insertItem(.separator(), at: 1)
        samplePicker.selectItem(at: 0)
    }

    @objc private func reopenWithDefaultRepresentation(_ sender: Any?) {
        guard let url = currentFileURL else { return }
        show(url, title: currentTitle)
    }

    /// Opens only a selected bundled example.
    @objc private func changeSample(_ sender: NSPopUpButton) {
        guard let index = sender.selectedItem?.representedObject as? Int, examples.indices.contains(index) else { return }
        let example = examples[index]
        guard let url = PreviewSamples.url(for: example, bundle: sampleBundle) else { return }
        show(url, title: "Example: \(example.title)")
    }

    // MARK: Loading

    /// Starts a cancellable load; a newer request replaces an older one.
    func show(_ url: URL, title: String?) {
        // Cancel the pending load before storing the new target so it cannot publish stale UI.
        loadTask?.cancel()
        previewController.cancelVCSInspection()
        // Record the target now so a settings change before the task starts re-reads this file.
        loading = (url, title)
        loadTask = Task { [weak self] in try? await self?.open(url, title: title) }
    }

    /// Reads and presents one file while holding any security-scoped grant through the asynchronous read.
    func open(_ url: URL, title: String?) async throws {
        loadViewIfNeeded()
        requestID += 1
        let id = requestID
        loading = (url, title)
        // Balance a drag/drop or open-panel grant for the full asynchronous read lifetime.
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            // A queued load must not use preferences captured before a settings change.
            let result = try await previewController.preview(for: url, configuration: session.renderConfiguration)
            // A cancelled/superseded load may finish after a newer request has already updated the pane.
            guard id == requestID else { throw CancellationError() }
            previewController.configuration = session.renderConfiguration
            finish(result, url: url, title: title)
        } catch {
            if id == requestID, !(error is CancellationError) {
                loading = nil
                diagnosticsText = Self.unableToPreview
                setLabel(Self.unableToOpen)
            }
            throw error
        }
    }

    /// Waits for the current preview preparation task to settle, mainly for UI capture workflows.
    func waitForPreview() async { await loadTask?.value }

    /// Invalidates pending loads in addition to cancellation so late completions cannot commit.
    func cancelLoading() {
        // Bump identity as well as cancelling so already-completed callbacks fail their stale-result guard.
        loadTask?.cancel()
        loadTask = nil
        loading = nil
        requestID += 1
    }

    /// Commits the current result, updates labels, and prepares a developer-only inspection summary.
    private func finish(_ result: PreviewPreparation, url: URL, title: String?) {
        // Commit the prepared model and UI metadata together only after the request identity check succeeds.
        loading = nil
        currentFileURL = url
        currentPreparation = result
        currentTitle = title
        selectPickerEntry(for: url)
        previewController.view.isHidden = false
        // The sample/filename header already identifies the document. Keep the footer for the
        // independent inspection facts; a load error may still use its leading slot.
        setLabel("")
        let exampleName = title.flatMap { title -> String? in
            let prefix = "Example: "
            return title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : nil
        }
        previewController.footerStrip.omittedStatusText = exampleName.flatMap { name in
            result.statusSummary.items.first { $0.kind == .information && $0.text == name }?.text
        }
        let analysis = result.analysis
        let messages = result.structuredDiagnostics + (result.markdownDocument?.diagnostics ?? []) + (result.sourceDocument?.diagnostics ?? [])
        let summary = messages.isEmpty ? "None" : messages.map { "\($0.code.rawValue): \($0.message)" }.joined(separator: "\n")
        let renderer = result.markdownDocument != nil ? "Markdown" : result.sourceDocument != nil ? "Source Code"
            : result.isStructured ? "\(result.formatName) structured" : analysis.isBinary ? "Binary fallback" : "Plain text"
        let truncated = analysis.truncated || result.sourceDocument?.truncated == true || messages.contains { $0.code == .truncated }
        diagnosticsText = ["Format: \(result.formatName)", "Detection: \(result.detectionReason)", "Renderer: \(renderer)",
                           "Encoding: \(analysis.encoding?.displayName ?? "Binary")",
                           "Size: \(analysis.fileSize) bytes · Truncated: \(truncated ? "Yes" : "No")",
                           "Diagnostics: \(summary)"].joined(separator: "\n")
    }

    /// Updates the preview title and its accessibility label together.
    private func setLabel(_ text: String) {
        exampleLabel.stringValue = text
        exampleLabel.setAccessibilityLabel(text)
        exampleLabel.toolTip = text.isEmpty ? nil : text
        previewController.footerStrip.needsLayout = true
    }

    var exampleText: String { exampleLabel.stringValue.isEmpty ? currentTitle ?? "" : exampleLabel.stringValue }

    /// Cancels work owned by this preview pane when its host view leaves the screen.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelLoading()
    }
}
