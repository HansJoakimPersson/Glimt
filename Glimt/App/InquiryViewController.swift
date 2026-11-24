import AppKit
import InspectorCore
import os

/// Read-only inquiry over the same bounded inspection and explicit configuration as Preview in Glimt.
@MainActor
final class InquiryViewController: NSViewController {
    private let logger = Logger(subsystem: "com.glimt.app", category: "inquiry")
    var onPreview: ((URL) -> Void)?
    private(set) var report: InquiryReport?
    private(set) var currentFileURL: URL?
    private(set) var inspection: PreviewInspectionResult?
    private let configuration: RenderConfiguration
    private let sections = NSStackView()
    private let reportScroll = NSScrollView()
    private let copyButton = NSButton(title: "Copy Report", target: nil, action: nil)
    private let advancedButton = NSSegmentedControl(labels: ["Standard", "Advanced"], trackingMode: .selectOne, target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview in Glimt", target: nil, action: nil)
    private let diagnosticsButton = NSButton(title: "Quick Look Diagnostics…", target: nil, action: nil)
    private let fileLabel = NSTextField(labelWithString: "Choose a file to inquire about")
    private var loadTask: Task<Void, Never>?
    private var diagnosticsWindow: NSWindow?
    private var requestID = 0

    /// Creates an inquiry controller using the preview configuration supplied by its caller.
    init(configuration: RenderConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    /// Cancels any outstanding file read when the inquiry window is released.
    deinit { loadTask?.cancel() }

    /// Builds the report window's controls and an initial prompt before a file is selected.
    override func loadView() {
        let root = PreviewMetadataHeaderView()
        let open = NSButton(title: "Open Inquiry File…", target: self, action: #selector(openFile(_:)))
        open.identifier = .init("InquiryOpenFile")
        open.setAccessibilityLabel("Open a file for read-only inquiry")
        advancedButton.target = self; advancedButton.action = #selector(toggleAdvanced(_:))
        advancedButton.identifier = .init("InquiryMode")
        advancedButton.selectedSegment = 0
        advancedButton.setAccessibilityLabel("Inquiry detail level")
        previewButton.target = self; previewButton.action = #selector(previewFile(_:))
        previewButton.identifier = .init("InquiryPreview")
        previewButton.isEnabled = false
        copyButton.target = self; copyButton.action = #selector(copyReport(_:))
        copyButton.identifier = .init("InquiryCopyReport"); copyButton.isEnabled = false
        let controls = NSStackView(views: [open, previewButton, copyButton, advancedButton])
        controls.spacing = 8
        diagnosticsButton.target = self; diagnosticsButton.action = #selector(showQuickLookDiagnostics(_:))
        diagnosticsButton.identifier = .init("InquiryQuickLookDiagnostics")
        diagnosticsButton.bezelStyle = .inline
        let diagnosticsRow = NSStackView(views: [NSView(), diagnosticsButton])
        diagnosticsRow.spacing = 8
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.identifier = .init("InquiryFile")
        sections.orientation = .vertical; sections.alignment = .leading; sections.spacing = 16
        sections.identifier = .init("InquiryReport")
        let document = InquiryDocumentView()
        document.addSubview(sections)
        sections.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        reportScroll.hasVerticalScroller = true; reportScroll.autohidesScrollers = true
        reportScroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: reportScroll.contentView.widthAnchor),
            sections.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            sections.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            sections.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            sections.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        showSections([("Inquiry File", ["Choose a file: Open a file to see its detected format, available Glimt views, and routing limitations."])])
        let stack = NSStackView(views: [controls, diagnosticsRow, fileLabel, reportScroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reportScroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        reportScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        reportScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view = root
        switch configuration.appearance {
        case .system: break
        case .light: view.appearance = NSAppearance(named: .aqua)
        case .dark: view.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// The pipeline reads once; the report explains that exact result without reinspection.
    func loadFile(at url: URL) async {
        // Invalidate prior results before starting I/O; every later UI commit checks this request number.
        loadViewIfNeeded()
        requestID += 1
        let request = requestID
        logger.debug("Inquiry inspection started")
        report = nil; inspection = nil; currentFileURL = nil
        previewButton.isEnabled = false
        fileLabel.stringValue = url.lastPathComponent
        copyButton.isEnabled = false
        showSections([("Inquiry File", ["Status: Inspecting file…"])])
        // Keep user-granted access alive until both inspection and report construction have completed.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let prepared = try await SharedPreviewPipeline.preview(for: url, configuration: configuration)
            let inspection = prepared.inspection
            let reportTask = Task.detached(priority: .userInitiated) {
                // Report generation may inspect bundle metadata and format extensive evidence; keep it off main.
                try Task.checkCancellation()
                return InquiryReport.make(url: url, inspection: inspection, declaredTypeIDs: Self.embeddedPreviewDeclarations())
            }
            let report = try await withTaskCancellationHandler {
                try await reportTask.value
            } onCancel: {
                // Stop report work when the inquiry view or its request is superseded.
                reportTask.cancel()
            }
            try Task.checkCancellation()
            guard request == requestID else { return }
            self.inspection = inspection; self.report = report; currentFileURL = url
            previewButton.isEnabled = true; copyButton.isEnabled = true
            showReport()
            logger.debug("Inquiry report completed; detailsAvailable=\(!report.details.isEmpty, privacy: .public)")
        } catch {
            guard request == requestID else { return }
            let message = error is CancellationError ? "Inquiry cancelled." : "The file could not be read. Choose another file or check its access permissions."
            showSections([("Inquiry File", ["Status: " + message])])
            if error is CancellationError {
                logger.debug("Inquiry inspection cancelled")
            } else {
                logger.error("Inquiry inspection failed; errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    @objc private func toggleAdvanced(_ sender: NSSegmentedControl) { showReport() }

    /// Projects the cached report into Standard or Advanced sections without reinspection.
    private func showReport() {
        guard let report else { return }
        let advanced = advancedButton.selectedSegment == 1
        if advanced {
            let mapping = report.summary.components(separatedBy: "\n\n").filter { $0.hasPrefix("User mapping:") || $0.hasPrefix("Automatic result:") }
            let lines = report.details.components(separatedBy: "\n") + mapping
            let identity = ["File:", "Path:", "Size:", "Extension:", "Observed UTType:", "Transitive supertypes"]
            let content = ["Encoding:", "BOM:", "Line endings:", "Detection sample:", "Shebang", "File signature:", "Byte-order mark:"]
            let detection = ["Selected reason:", "Evidence ·"]
            /// Classifies report lines by their stable section prefixes.
            func matches(_ line: String, _ prefixes: [String]) -> Bool { prefixes.contains { line.hasPrefix($0) } }
            showSections([
                ("File identity", lines.filter { matches($0, identity) }),
                ("Content", lines.filter { matches($0, content) }),
                ("Detection", lines.filter { matches($0, detection) }),
                ("Glimt support and routing", lines.filter { !matches($0, identity + content + detection) }),
                ("Resolved rendering settings", Array(resolvedConfigurationText().components(separatedBy: "\n").dropFirst()))
            ])
        } else {
            let lines = report.summary.components(separatedBy: "\n\n")
            showSections([
                ("Detected format", lines.filter { $0.hasPrefix("Detected format:") || $0.hasPrefix("Why:") || $0.hasPrefix("User mapping:") || $0.hasPrefix("Automatic result:") }),
                ("Preview in Glimt", lines.filter { !$0.hasPrefix("Detected format:") && !$0.hasPrefix("Why:") && !$0.hasPrefix("User mapping:") && !$0.hasPrefix("Automatic result:") && !$0.hasPrefix("Conflicting evidence:") && !$0.hasPrefix("Finder routing") }),
                ("Finder preview", lines.filter { $0.hasPrefix("Conflicting evidence:") || $0.hasPrefix("Finder routing") })
            ])
        }
        sections.setAccessibilityLabel(advanced ? "Advanced inquiry report" : "Standard inquiry report")
        reportScroll.contentView.scroll(to: .zero)
        reportScroll.reflectScrolledClipView(reportScroll.contentView)
    }

    /// Rebuilds selectable, accessible rows from the already prepared report sections.
    private func showSections(_ groups: [(String, [String])]) {
        for child in sections.arrangedSubviews { sections.removeArrangedSubview(child); child.removeFromSuperview() }
        for (title, lines) in groups where !lines.isEmpty {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.identifier = .init("InquirySection")
            let fields = NSStackView(); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 8
            for line in lines {
                let split = line.firstIndex(of: ":")
                let originalName = split.map { String(line[..<$0]) } ?? "Note"
                let reportedName = line.hasPrefix("Finder routing is separate:") ? "Quick Look provider" : line == "Supported in Glimt." ? "Supported by Glimt" : originalName == "Conflicting evidence" ? "⚠ Type conflict" : originalName
                // The heading already says "Detected format"; the row names the fact itself.
                let name = reportedName == title && title == "Detected format" ? "Format" : reportedName
                let value = originalName == "Why" && inspection?.detectionReason == "fileExtension" && !(currentFileURL?.pathExtension.isEmpty ?? true) ? "Filename extension (." + (currentFileURL?.pathExtension ?? "") + ")" : line.hasPrefix("Finder routing is separate:") ? "macOS decides which installed provider handles this file." : line == "Supported in Glimt." ? "✓ Yes" : split.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? line
                let label = NSTextField(wrappingLabelWithString: name)
                label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 13)
                label.identifier = .init("InquiryLabel")
                let text = NSTextField(wrappingLabelWithString: value)
                text.isSelectable = true; text.isEditable = false; text.font = .systemFont(ofSize: 13)
                if advancedButton.selectedSegment == 1, ["Path", "Observed UTType", "Extension", "File signature"].contains(originalName) { text.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
                text.identifier = .init("InquiryValue"); text.setAccessibilityLabel(name + ": " + value)
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let row = NSStackView(views: [label, text]); row.alignment = .top; row.spacing = 8
                label.widthAnchor.constraint(equalToConstant: 140).isActive = true
                fields.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            }
            let separator = NSBox(); separator.boxType = .separator
            let group = NSStackView(views: [heading, fields, separator])
            group.orientation = .vertical; group.alignment = .leading; group.spacing = 8
            sections.addArrangedSubview(group)
            NSLayoutConstraint.activate([
                group.widthAnchor.constraint(equalTo: sections.widthAnchor),
                fields.widthAnchor.constraint(equalTo: group.widthAnchor),
                separator.widthAnchor.constraint(equalTo: group.widthAnchor)
            ])
        }
    }

    @objc private func copyReport(_ sender: NSButton) {
        guard let report else { return }
        let text = advancedButton.selectedSegment == 1 ? report.summary + "\n\n" + report.details + "\n\n" + resolvedConfigurationText() : report.summary
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    /// Summarizes effective rendering settings while leaving file contents out of the report.
    private func resolvedConfigurationText() -> String {
        let language = inspection?.sourceDocument?.language
        let source = language.map { configuration.source(for: $0) } ?? configuration.source
        return [
            "Resolved rendering settings",
            "Preview byte limit: \(configuration.maximumPreviewBytes) bytes",
            "Source language: \(language?.displayName ?? "none; showing global source defaults")",
            "Source font: \(source.fontFamily), \(source.fontSize) pt",
            "Source word wrap: \(source.wrapLines ? "on" : "off")",
            "Source visual tab width: \(source.tabWidth) spaces",
            "Source line numbers: \(source.showLineNumbers ? "on" : "off")"
        ].joined(separator: "\n")
    }

    @objc private func previewFile(_ sender: NSButton) {
        if let currentFileURL { onPreview?(currentFileURL) }
    }

    @objc private func showQuickLookDiagnostics(_ sender: NSButton) {
        guard diagnosticsWindow == nil, let parent = view.window else { return }
        let controller = GlimtQuickLookDiagnosticsViewController()
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Quick Look Diagnostics"
        sheet.styleMask = [.titled, .closable]
        sheet.setContentSize(GlimtQuickLookDiagnosticsViewController.preferredSize)
        diagnosticsWindow = sheet
        parent.beginSheet(sheet) { [weak self] _ in self?.diagnosticsWindow = nil }
    }

    @objc private func openFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.title = "Open Inquiry File"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.loadTask?.cancel()
            self.loadTask = Task { [weak self] in await self?.loadFile(at: url) }
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    /// Read only the host's embedded preview Info.plist; never enumerate or query other providers.
    private nonisolated static func embeddedPreviewDeclarations() -> [String]? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        for url in urls.prefix(32) where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.quicklook.preview",
                  let attributes = ext["NSExtensionAttributes"] as? [String: Any],
                  let types = attributes["QLSupportedContentTypes"] as? [String] else { continue }
            return Array(types.prefix(256))
        }
        return nil
    }
}

private final class InquiryDocumentView: NSView {
    override var isFlipped: Bool { true }
}
