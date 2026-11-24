import AppKit
import GitInspection
import InspectorCore
import os

/// Presentation modes that the shared preview controller can render.
enum PreviewRepresentation: String, CaseIterable {
    case raw = "Raw", pretty = "Pretty", tree = "Tree", rendered = "Rendered", hex = "Hex", source = "Source", table = "Table", diff = "Diff"
}

/// Available presentation and compact inspection facts; no preference or persistence ownership.
struct PreviewChromeModel {
    let representations: [PreviewRepresentation]
    let enabledRepresentations: Set<PreviewRepresentation>
    /// True when no configured view was available and a safe inspection view was substituted.
    let isRecovery: Bool
    let status: PreviewStatusSummary
    private let binaryBytesShown: Int?
    private let binaryTotalBytes: Int
    private let retainedBytes: Int
    private let isStandaloneMermaid: Bool
    private let mermaidAdmission: StandaloneMermaidAdmission
    private let fstabRowWarning: PreviewStatusSummary.Item?
    /// Shows the configured views this inspection can render, in configured order (ADR-022).
    /// When none is available, Raw (text) or Hex (binary) keeps the document inspectable.
    /// `nil` uses the factory configuration.
    init(inspection: PreviewPreparation, configuredViews: [FormatDefinition.RepresentationID]? = nil,
         unavailableRepresentations: Set<FormatDefinition.RepresentationID> = []) {
        status = inspection.statusSummary
        binaryBytesShown = inspection.plistInspection?.isBinary == true ? min(inspection.plistInspection?.rawBytes.count ?? 0, HexPreview.maximumBytes) : nil
        binaryTotalBytes = inspection.analysis.fileSize
        retainedBytes = inspection.originalBytes.count
        isStandaloneMermaid = inspection.formatDefinition?.id == .mermaid
        mermaidAdmission = inspection.standaloneMermaidAdmission
        fstabRowWarning = Self.fstabWarning(for: inspection)
        let definition = inspection.formatDefinition
        let genericBinary = inspection.analysis.isBinary && inspection.plistInspection == nil
            && inspection.additionalInspection?.archiveListing == nil
            && inspection.additionalInspection?.tarArchiveListing == nil
            && inspection.additionalInspection?.certificateInspection == nil
            && inspection.additionalInspection?.securityInspection?.content == nil
        let failedPKCS12 = definition?.id == .pkcs12
            && inspection.additionalInspection?.securityInspection?.content == nil
        let declared = genericBinary ? [.hex] : (definition?.availableRepresentations ?? [])
        // A format without declared views (plain text) shows its text without a tab strip.
        guard !declared.isEmpty else {
            representations = []; enabledRepresentations = [.raw]; isRecovery = false
            return
        }
        let available = Set(declared.filter {
            !unavailableRepresentations.contains($0)
                &&
            RepresentationRegistry.definition(for: $0, inspection: inspection) != nil
                && Self.isAvailable($0, in: inspection, genericBinary: genericBinary)
        })
        let configured = configuredViews ?? definition.map { ViewResolver.resolve(.factoryDefaults, for: $0.id).configured }
            ?? ViewCategoryID.binaryAndUnknown.factoryProfile
        let presented = ViewResolver.presented(configured: configured, available: available,
                                               isBinary: genericBinary || failedPKCS12)
        representations = presented.views.compactMap { PreviewRepresentation(rawValue: $0.rawValue.capitalized) }
        enabledRepresentations = Set(representations)
        isRecovery = presented.isRecovery
    }

    /// Whether this inspection produced content for a view; Raw and Hex always render.
    private static func isAvailable(_ view: FormatDefinition.RepresentationID, in inspection: PreviewPreparation, genericBinary: Bool) -> Bool {
        switch view {
        case .raw:
            return !(inspection.formatDefinition?.id == .pkcs7 && inspection.analysis.isBinary)
        case .hex: return true
        case .source:
            guard inspection.sourceDocument != nil else { return false }
            // Markdown's Source tab is an alternate to successful Markdown rendering. If the
            // bounded Markdown inspector declines Rendered, expose the exact Raw fallback only.
            if inspection.formatDefinition?.id == .markdown {
                return inspection.markdownDocument?.renderedText != nil
            }
            return true
        case .table:
            return inspection.csvInspection?.table != nil
                || inspection.additionalInspection?.logTable != nil
                || inspection.additionalInspection?.archiveListing != nil
                || inspection.additionalInspection?.tarArchiveListing != nil
                || inspection.xmlInspection?.table != nil
        case .pretty: return inspection.structuredPrettyText != nil
        case .tree: return inspection.hasStructuredContent
        case .rendered:
            if inspection.formatDefinition?.id == .mermaid { return !inspection.analysis.isBinary }
            return inspection.markdownDocument?.renderedText != nil
        case .diff: return inspection.additionalInspection?.hasPrimaryContent == true
        }
    }

    /// Adds byte-count details only to raw/hex views whose display is intentionally capped.
    func statusItems(for representation: PreviewRepresentation, mermaidRenderFailed: Bool = false) -> [PreviewStatusSummary.Item] {
        let recovery: [PreviewStatusSummary.Item] = isRecovery ? [.init(text: "Fallback view", kind: .information)] : []
        let statusItems = fstabRowWarning.map { warning in
            [warning] + status.items.filter { $0.text != "Preview fallback" }
        } ?? status.items
        if isStandaloneMermaid, representation == .rendered {
            let warning: PreviewStatusSummary.Item?
            switch mermaidAdmission {
            case .rejected(.truncated): warning = .init(text: "Preview source is truncated", kind: .warning)
            case .rejected(.noSource): warning = .init(text: "No Mermaid source", kind: .warning)
            case .rejected(.exceedsLimits): warning = .init(text: "Mermaid source exceeds render limits", kind: .warning)
            case .admitted: warning = mermaidRenderFailed ? .init(text: "Mermaid diagram unavailable", kind: .warning) : nil
            case .notStandalone: warning = nil
            }
            let items = statusItems.filter { $0.text != "Truncated" }
            return recovery + (warning.map { [$0] } ?? []) + items
        }
        guard representation == .raw || representation == .hex else { return recovery + statusItems }
        let shown = binaryBytesShown ?? (isStandaloneMermaid && representation == .raw
            ? retainedBytes : min(retainedBytes, HexPreview.maximumBytes))
        guard shown < binaryTotalBytes else { return recovery + statusItems }
        return recovery + [.init(text: "Truncated", kind: .warning)] + statusItems.filter { $0.text != "Truncated" } + [.init(text: "\(shown) bytes shown of \(binaryTotalBytes) bytes", kind: .information)]
    }

    /// Promotes one fstab row diagnostic into a concise shared status warning for Tree and Raw.
    private static func fstabWarning(for inspection: PreviewPreparation) -> PreviewStatusSummary.Item? {
        guard inspection.formatDefinition?.id == .fstab,
              let diagnostic = inspection.structuredDiagnostics.first(where: { $0.code == .parseError }),
              let linePart = diagnostic.message.components(separatedBy: "line ").last else { return nil }
        let line = String(linePart.prefix(while: { $0.isNumber }))
        guard !line.isEmpty else { return nil }
        let reason = diagnostic.message.contains("fieldCount") ? "field count"
            : diagnostic.message.contains("numericField") ? "numeric field"
            : diagnostic.message.contains("bareCR") ? "bare CR" : "malformed row"
        return .init(text: "Line \(line): \(reason)", kind: .warning)
    }
}

/// Temporary document navigation; never encoded or persisted with GlimtSettings.
private struct PreviewSessionState {
    var selectedRepresentation: PreviewRepresentation = .raw
    var tocIsOpen = false
}

/// Coordinates one prepared inspection across the native source, table, tree, and text renderers.
class SharedPreviewViewController: NSViewController {
    private struct MermaidRenderKey: Equatable {
        let generation: UUID
        let width: Int
    }
    private struct MermaidRenderRequest {
        let id: UUID
        let key: MermaidRenderKey
        let blocks: [MarkdownMermaidBlock]
    }
    private struct CompletedMermaidRender {
        let key: MermaidRenderKey
        let attemptID: UUID
        let images: [String: NSImage]
    }

    private let footerHeight: CGFloat = 28
    private let scrollView = StructuredTextPreview()
    private var textView: PreviewTextView { scrollView.textView }
    private let treeView = StructuredTreeView()
    private let sourceView = SourceCodeView()
    private let tableView = CSVTablePreviewView()
    private let tocHUD = NSStackView()
    private let tocButtonSurface = MarkdownTOCHUDSurface()
    private let tocButton = NSButton(title: "", target: nil, action: nil)
    private let tocIndicatorSurface = MarkdownTOCHUDSurface()
    private let tocIndicator = NSTextField(labelWithString: "")
    private var tocIndicatorMaximumWidth: NSLayoutConstraint?
    private let modeControl = PreviewTabStrip()
    private lazy var footer = PreviewRepresentationTabStrip(modeControl: modeControl)
    private var chrome: PreviewChromeModel?
    private var currentPreparation: PreviewPreparation?
    private var currentVCSResult: VCSInspectionResult?
    private var session = PreviewSessionState()
    private var vcsInspectionTask: Task<Void, Never>?
    private lazy var mermaidKitRenderer = MermaidKitRenderer()
    private let mermaidRenderOverride: MermaidBlockRenderOperation?
    private let mermaidAttachmentOverride: MermaidAttachmentFactory?
    private let mermaidWidthOverride: MermaidRequestedWidthProvider?
    private let mermaidResultObserver: MermaidRenderResultObserver?
    private var mermaidRenderTask: Task<Void, Never>?
    private var mermaidRenderGeneration = UUID()
    private var activeMermaidRequest: MermaidRenderRequest?
    private var waitingMermaidRequest: MermaidRenderRequest?
    private var desiredMermaidAttemptID: UUID?
    private var activeMermaidCancellationRequested = false
    private var completedMermaidRender: CompletedMermaidRender?
    private var displayedMermaidKey: MermaidRenderKey?
    private var mermaidLayoutCheckScheduled = false
    private var mermaidRenderFailed = false
    private var renderedMermaidImages: [String: NSImage] = [:]
    private var tocMenu: MarkdownTOCMenu?
    private var sectionUpdateScheduled = false
    private(set) var activeMarkdownHeadingIndex: Int?
    var markdownTOCIsOpen: Bool { session.tocIsOpen }
    var markdownTOCMenuIsShown: Bool { tocMenu != nil }
    var markdownTOCIsAvailable: Bool { markdownTOCAvailable }
    var markdownTOCMenuForReview: MarkdownTOCMenu? { tocMenu }
    /// Shows the heading menu; `NSMenu.popUp` tracks modally and returns after the menu closes.
    /// Tests substitute a non-modal presenter that inspects or chooses items before returning.
    var markdownTOCMenuPresenter: (NSMenu, NSMenuItem?, NSPoint, NSView) -> Void = { menu, item, location, view in
        menu.popUp(positioning: item, at: location, in: view)
    }
    private let vcsProviders: [any VCSProvider]
    private let logger = Logger(subsystem: "com.glimt.app", category: "preview")
    var configuration: RenderConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            applyAppearance()
            if let currentPreparation {
                // A settings change keeps the session tab while it is still effective.
                display(currentPreparation, resetSession: false)
            }
        }
    }
    private var requestID = UUID()
    private let loadingOverlay = NSBox()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")
    private var loadingTask: Task<Void, Never>?

    /// Creates the host preview with the app's ordered local SVN and Git providers.
    init(configuration: RenderConfiguration = .init()) {
        self.configuration = configuration
        self.vcsProviders = [SVNProvider(), GitProvider()]
        mermaidRenderOverride = nil
        mermaidAttachmentOverride = nil
        mermaidWidthOverride = nil
        mermaidResultObserver = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// Injects providers for callers that need a controlled repository inspection set.
    init(configuration: RenderConfiguration, vcsProviders: [any VCSProvider]) {
        self.configuration = configuration
        self.vcsProviders = vcsProviders
        mermaidRenderOverride = nil
        mermaidAttachmentOverride = nil
        mermaidWidthOverride = nil
        mermaidResultObserver = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// Injects controlled Mermaid operations for lifecycle tests while production retains its
    /// controller-owned bundled runtime and the shared native attachment factory.
    init(configuration: RenderConfiguration, vcsProviders: [any VCSProvider],
         renderMermaidBlocks: MermaidBlockRenderOperation?,
         makeMermaidAttachment: MermaidAttachmentFactory?,
         requestedMermaidWidth: MermaidRequestedWidthProvider?,
         mermaidResultObserver: MermaidRenderResultObserver?) {
        self.configuration = configuration
        self.vcsProviders = vcsProviders
        mermaidRenderOverride = renderMermaidBlocks
        mermaidAttachmentOverride = makeMermaidAttachment
        mermaidWidthOverride = requestedMermaidWidth
        self.mermaidResultObserver = mermaidResultObserver
        super.init(nibName: nil, bundle: nil)
    }

    /// Adapts the AppKit nib initializer to Glimt's programmatic default configuration.
    override convenience init(nibName: NSNib.Name?, bundle: Bundle?) { self.init(configuration: .init()) }
    required init?(coder: NSCoder) {
        configuration = .init()
        vcsProviders = [SVNProvider(), GitProvider()]
        mermaidRenderOverride = nil
        mermaidAttachmentOverride = nil
        mermaidWidthOverride = nil
        mermaidResultObserver = nil
        super.init(coder: coder)
    }

    /// Cancels repository inspection when the controller is released.
    deinit {
        vcsInspectionTask?.cancel()
        mermaidRenderTask?.cancel()
        loadingTask?.cancel()
    }

    /// Canonical app presentation entry point; the Quick Look adapter uses this same pipeline/view.
    @discardableResult
    func preview(for url: URL, configuration: RenderConfiguration) async throws -> PreviewPreparation {
        try Task.checkCancellation()
        logger.debug("Host preview inspection started")
        let id = UUID()
        requestID = id
        cancelVCSInspection()
        self.configuration = configuration
        scheduleLoadingIndicator()
        let prepared: PreparedPreview
        do {
            prepared = try await SharedPreviewPipeline.preview(for: url, configuration: configuration)
        } catch {
            // A newer request owns the indicator; only the current request clears it.
            if requestID == id { hideLoadingIndicator() }
            throw error
        }
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
        display(prepared.inspection, inspecting: url, requestID: id)
        let format = prepared.inspection.formatDefinition?.id.rawValue ?? "unknown"
        logger.debug("Host preview inspection completed; format=\(format, privacy: .private) resolution=\(prepared.inspection.resolution.typeID, privacy: .private)")
        return prepared.inspection
    }

    /// Presents prepared content first, then starts optional repository inspection for both the
    /// host preview and Quick Look adapter paths.
    func display(_ preparation: PreviewPreparation, inspecting url: URL, requestID id: UUID = UUID()) {
        requestID = id
        hideLoadingIndicator()
        cancelVCSInspection()
        display(preparation)
        beginVCSInspection(for: url, requestID: id, preparation: preparation)
    }

    /// Cancels pending repository work and clears overlays so they cannot bleed into another document.
    func cancelVCSInspection() {
        // Clear both task and published diff so a previous document cannot leave stale repository status visible.
        vcsInspectionTask?.cancel()
        vcsInspectionTask = nil
        currentVCSResult = nil
        sourceView.displayVCSLineDiff(nil)
        if isViewLoaded { footer.updateVCSStatus(nil) }
    }

    /// Starts optional off-main repository inspection and applies a result only to its originating request.
    private func beginVCSInspection(for url: URL, requestID id: UUID, preparation: PreviewPreparation) {
        guard configuration.vcsSupportEnabled, preparation.sourceDocument != nil else {
            logger.debug("VCS inspection skipped; disabled or document is not source code")
            return
        }
        let registry = VCSProviderRegistry(providers: vcsProviders)
        vcsInspectionTask = Task.detached(priority: .utility) { [weak self] in
            // The preview URL may be a sandbox-scoped grant; balance access on this worker task.
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
            guard !Task.isCancelled else { return }
            let result = try? await registry.inspect(fileURL: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.requestID == id else { return }
                self.currentVCSResult = result
                self.sourceView.displayVCSLineDiff(result?.comparison?.lineDiff)
                self.footer.updateVCSStatus(result)
                self.logger.debug("VCS inspection completed; result=\(result == nil ? "unavailable" : "available", privacy: .public)")
            }
        }
    }

    /// The footer the host can add accessories to; see `PreviewRepresentationTabStrip`.
    var footerStrip: PreviewRepresentationTabStrip { footer }

    /// Applies the explicit preview appearance without changing the host application's appearance.
    private func applyAppearance() {
        // Settings previews can simulate a different appearance from the host app's actual appearance.
        guard isViewLoaded else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            switch configuration.appearance {
            case .system: view.appearance = nil
            case .light: view.appearance = NSAppearance(named: .aqua)
            case .dark: view.appearance = NSAppearance(named: .darkAqua)
            }
            view.needsDisplay = true
        }
    }

    /// Installs all representation surfaces under one footer and reserves scroll padding for that footer.
    override func loadView() {
        let container = PreviewMetadataHeaderView()
        modeControl.identifier = .init("PreviewModeControl")
        modeControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modeControl.setAccessibilityLabel("Document representation")
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))
        modeControl.isHidden = true

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.documentView = textView
        let contentView = NSView()
        contentView.clipsToBounds = true
        for child in [scrollView, treeView, sourceView, tableView] {
            contentView.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
            if child === scrollView {
                let top = child.topAnchor.constraint(equalTo: contentView.topAnchor)
                let leading = child.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
                top.isActive = true
                leading.isActive = true
            } else {
                child.leadingAnchor.constraint(equalTo: contentView.leadingAnchor).isActive = true
                child.topAnchor.constraint(equalTo: contentView.topAnchor).isActive = true
            }
        }
        buildMarkdownTOCHUD(in: contentView)
        buildLoadingOverlay(in: contentView)
        treeView.isHidden = true
        sourceView.isHidden = true
        tableView.isHidden = true
        contentView.identifier = .init("PreviewContent")
        container.addSubview(contentView)
        container.addSubview(footer)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: container.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerHeight)
        ])
        // Scrollable tails stay clear of the shared footer even at the document's final line.
        for scroll in descendantScrollViews(in: contentView) {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets.bottom = footerHeight
        }
        view = container
        installMarkdownGeometryObservers()
        applyAppearance()
    }

    /// Repositions the heading indicator after layout and schedules section tracking.
    override func viewDidLayout() {
        super.viewDidLayout()
        updateTOCIndicator()
        scheduleMarkdownSectionUpdate()
        scheduleMermaidLayoutCheck()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleMermaidLayoutCheck()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        invalidateMermaidWork(clearCache: true, changeGeneration: true)
    }

    // MARK: - Loading state

    /// Delay before the loading indicator appears, so fast previews never flash it (ADR-040).
    nonisolated static let loadingIndicatorDelay: Duration = .milliseconds(150)

    /// Shows the loading indicator once `delay` passes without a displayed result, then runs
    /// `onShow`. A later schedule, display, or hide cancels the pending indicator.
    func scheduleLoadingIndicator(after delay: Duration = SharedPreviewViewController.loadingIndicatorDelay,
                                  onShow: (@MainActor () -> Void)? = nil) {
        loadingTask?.cancel()
        loadingTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled, let self else { return }
            self.presentLoadingOverlay(message: "Loading preview…", isLoading: true)
            onShow?()
        }
    }

    /// Removes the loading indicator and any pending schedule.
    func hideLoadingIndicator() {
        loadingTask?.cancel()
        loadingTask = nil
        if isViewLoaded { loadingOverlay.isHidden = true }
        loadingSpinner.stopAnimation(nil)
    }

    /// Replaces the loading indicator with a failure message after Quick Look already has the view.
    func showLoadFailure() {
        loadingTask?.cancel()
        loadingTask = nil
        presentLoadingOverlay(message: "This file could not be previewed.", isLoading: false)
    }

    /// The visible loading-state message, or nil when content is shown.
    var loadingStateMessage: String? {
        isViewLoaded && !loadingOverlay.isHidden ? loadingLabel.stringValue : nil
    }

    private func presentLoadingOverlay(message: String, isLoading: Bool) {
        loadViewIfNeeded()
        loadingLabel.stringValue = message
        loadingSpinner.isHidden = !isLoading
        if isLoading { loadingSpinner.startAnimation(nil) } else { loadingSpinner.stopAnimation(nil) }
        loadingOverlay.isHidden = false
    }

    /// A native spinner and caption over the content area; it covers the previous document's content.
    private func buildLoadingOverlay(in contentView: NSView) {
        loadingOverlay.identifier = .init("PreviewLoadingState")
        loadingOverlay.boxType = .custom
        loadingOverlay.borderWidth = 0
        loadingOverlay.fillColor = .textBackgroundColor
        loadingOverlay.contentViewMargins = .zero
        loadingOverlay.isHidden = true
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isDisplayedWhenStopped = false
        loadingSpinner.setAccessibilityLabel("Loading")
        loadingLabel.font = .preferredFont(forTextStyle: .caption1)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center

        let stack = NSStackView(views: [loadingSpinner, loadingLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        let surface = NSView()
        loadingOverlay.contentView = surface
        surface.addSubview(stack)
        contentView.addSubview(loadingOverlay)
        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
    }

    // MARK: - Markdown navigation HUD

    /// A trailing button plus a one-line section label; it overlays the preview and never spans it.
    private func buildMarkdownTOCHUD(in contentView: NSView) {
        tocHUD.identifier = .init("MarkdownTOCHUD")
        tocHUD.orientation = .horizontal
        tocHUD.alignment = .centerY
        tocHUD.spacing = 6
        tocHUD.detachesHiddenViews = true
        tocHUD.translatesAutoresizingMaskIntoConstraints = false
        tocHUD.setHuggingPriority(.required, for: .horizontal)
        tocHUD.isHidden = true
        contentView.addSubview(tocHUD)

        tocIndicatorSurface.identifier = .init("MarkdownTOCSectionLabel")
        tocIndicatorSurface.translatesAutoresizingMaskIntoConstraints = false
        tocIndicatorSurface.addGestureRecognizer(NSClickGestureRecognizer(target: self,
                                                                          action: #selector(showMarkdownTOC(_:))))
        tocIndicator.translatesAutoresizingMaskIntoConstraints = false
        tocIndicator.identifier = .init("MarkdownTOCActiveSection")
        tocIndicator.font = .preferredFont(forTextStyle: .caption1)
        tocIndicator.textColor = .secondaryLabelColor
        tocIndicator.lineBreakMode = .byTruncatingTail
        tocIndicator.maximumNumberOfLines = 1
        tocIndicator.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tocIndicator.setAccessibilityElement(true)
        tocIndicator.setAccessibilityLabel("Current section")
        tocIndicator.setAccessibilityValue("No section")
        tocIndicatorSurface.addSubview(tocIndicator)

        tocButtonSurface.translatesAutoresizingMaskIntoConstraints = false
        tocButton.translatesAutoresizingMaskIntoConstraints = false
        tocButton.identifier = .init("MarkdownTOCToggle")
        tocButton.isBordered = false
        tocButton.imagePosition = .imageOnly
        tocButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        tocButton.contentTintColor = .secondaryLabelColor
        tocButton.toolTip = "Table of contents"
        tocButton.setAccessibilityLabel("Table of contents")
        tocButton.setAccessibilityHelp("Show the headings in this Markdown document.")
        tocButton.setAccessibilityValue("Menu hidden")
        tocButton.target = self
        tocButton.action = #selector(showMarkdownTOC(_:))
        tocButtonSurface.addSubview(tocButton)

        tocHUD.addArrangedSubview(tocIndicatorSurface)
        tocHUD.addArrangedSubview(tocButtonSurface)
        let maximumWidth = tocIndicator.widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        tocIndicatorMaximumWidth = maximumWidth
        NSLayoutConstraint.activate([
            // Clear of the overlay scroller on the trailing edge and of the host chrome above.
            tocHUD.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            tocHUD.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tocHUD.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            tocButtonSurface.widthAnchor.constraint(equalToConstant: 28),
            tocButtonSurface.heightAnchor.constraint(equalToConstant: 28),
            tocButton.leadingAnchor.constraint(equalTo: tocButtonSurface.leadingAnchor),
            tocButton.trailingAnchor.constraint(equalTo: tocButtonSurface.trailingAnchor),
            tocButton.topAnchor.constraint(equalTo: tocButtonSurface.topAnchor),
            tocButton.bottomAnchor.constraint(equalTo: tocButtonSurface.bottomAnchor),
            tocIndicatorSurface.heightAnchor.constraint(equalToConstant: 22),
            tocIndicator.leadingAnchor.constraint(equalTo: tocIndicatorSurface.leadingAnchor, constant: 8),
            tocIndicator.trailingAnchor.constraint(equalTo: tocIndicatorSurface.trailingAnchor, constant: -8),
            tocIndicator.centerYAnchor.constraint(equalTo: tocIndicatorSurface.centerYAnchor),
            maximumWidth
        ])
    }

    private var markdownTOCAvailable: Bool {
        session.selectedRepresentation == .rendered
            && currentPreparation?.markdownDocument?.renderedText != nil
            && !(currentPreparation?.markdownDocument?.headings.isEmpty ?? true)
    }

    @objc private func showMarkdownTOC(_ sender: Any?) {
        guard markdownTOCAvailable, tocMenu == nil, tocButton.window != nil,
              let markdown = currentPreparation?.markdownDocument else { return }
        // Open on the section under the reading threshold even if a geometry update is still queued.
        updateActiveMarkdownSection()
        let toc = MarkdownTOCMenu(headings: markdown.headings, activeIndex: activeMarkdownHeadingIndex)
        toc.onSelectHeading = { [weak self] index in self?.navigateToMarkdownHeading(index) }
        toc.menu.appearance = view.effectiveAppearance
        tocMenu = toc
        session.tocIsOpen = true
        tocButton.setAccessibilityValue("Menu shown")

        let gap: CGFloat = 6
        let menuSize = toc.menu.size
        let location = NSPoint(x: tocButton.bounds.maxX - menuSize.width,
                               y: tocButton.isFlipped ? tocButton.bounds.maxY + gap : tocButton.bounds.minY - gap)
        var availableHeight = menuSize.height
        if let window = tocButton.window, let screen = window.screen {
            let buttonOnScreen = window.convertToScreen(tocButton.convert(tocButton.bounds, to: nil))
            availableHeight = buttonOnScreen.minY - gap - screen.visibleFrame.minY
        }
        let positioning = MarkdownTOCMenu.positioningIndex(activeIndex: activeMarkdownHeadingIndex,
                                                           itemCount: toc.headingCount,
                                                           menuHeight: menuSize.height,
                                                           availableHeight: availableHeight)
        markdownTOCMenuPresenter(toc.menu, positioning.flatMap(toc.item(forHeading:)), location, tocButton)
        // Tracking has ended: the menu was dismissed or an item was chosen and navigated.
        tocMenu = nil
        session.tocIsOpen = false
        updateMarkdownTOCVisibility()
    }

    /// Shows navigation controls only when the active rendered document has headings.
    private func updateMarkdownTOCVisibility() {
        let available = markdownTOCAvailable
        tocHUD.isHidden = !available
        if !available {
            tocMenu?.menu.cancelTracking()
            session.tocIsOpen = false
        }
        tocButton.setAccessibilityValue(session.tocIsOpen ? "Menu shown" : "Menu hidden")
        updateTOCIndicator()
    }

    /// Observes document and clip-view changes needed to keep Markdown section tracking current.
    private func installMarkdownGeometryObservers() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(markdownGeometryDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(markdownGeometryDidChange(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(markdownGeometryDidChange(_:)),
                                               name: NSView.frameDidChangeNotification,
                                               object: textView)
    }

    @objc private func markdownGeometryDidChange(_ notification: Notification) {
        scheduleMarkdownSectionUpdate()
    }

    /// Coalesces repeated geometry events into one main-queue active-section update.
    private func scheduleMarkdownSectionUpdate() {
        guard markdownTOCAvailable, !sectionUpdateScheduled else { return }
        sectionUpdateScheduled = true
        // Common modes keep the section current while the heading menu is tracking events.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sectionUpdateScheduled = false
                self.updateActiveMarkdownSection()
            }
        }
    }

    /// Finds the heading nearest the visible text viewport and refreshes the TOC indicator.
    private func updateActiveMarkdownSection() {
        guard markdownTOCAvailable,
              let markdown = currentPreparation?.markdownDocument,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              textView.textStorage?.length ?? 0 > 0 else { return }
        layout.ensureLayout(for: container)
        let ranges = markdownHeadingRanges(in: textView)
        guard !ranges.isEmpty else { return }
        let visibleTop = scrollView.contentView.bounds.minY
            + min(80, max(36, scrollView.contentView.bounds.height * 0.16))
        var next = ranges.keys.sorted().first
        for index in markdown.headings.indices {
            guard let range = ranges[index], let rect = headingRect(range, in: textView) else { continue }
            if rect.minY <= visibleTop { next = index }
            else { break }
        }
        let clipView = scrollView.contentView
        let maximumOrigin = max(0, textView.frame.height - clipView.bounds.height)
        if maximumOrigin > 0, clipView.bounds.minY >= maximumOrigin - 2 {
            next = markdown.headings.indices.last ?? next
        } else if let activeMarkdownHeadingIndex,
                  next != activeMarkdownHeadingIndex,
                  let boundaryIndex = next.map({ $0 > activeMarkdownHeadingIndex ? $0 : activeMarkdownHeadingIndex }),
                  let range = ranges[boundaryIndex],
                  let rect = headingRect(range, in: textView),
                  abs(rect.minY - visibleTop) < 6 {
            // Keep the previous section through a small dead band around the reading threshold.
            next = activeMarkdownHeadingIndex
        }
        setActiveMarkdownHeading(next)
    }

    /// Updates the selected heading and its accessible label, clearing stale indices safely.
    private func setActiveMarkdownHeading(_ index: Int?) {
        guard index != activeMarkdownHeadingIndex else { return }
        activeMarkdownHeadingIndex = index
        tocMenu?.setActiveIndex(index)
        updateTOCIndicator()
    }

    /// Shows the active heading beside the button; narrow previews keep only the button.
    private func updateTOCIndicator() {
        let width = view.bounds.width
        tocIndicatorMaximumWidth?.constant = min(260, max(0, width * 0.45 - 40))
        guard let markdown = currentPreparation?.markdownDocument,
              let index = activeMarkdownHeadingIndex,
              markdown.headings.indices.contains(index) else {
            tocIndicator.stringValue = ""
            tocIndicator.toolTip = nil
            tocIndicator.setAccessibilityValue("No section")
            tocIndicatorSurface.isHidden = true
            return
        }
        let title = markdown.headings[index].title
        tocIndicator.stringValue = title
        tocIndicator.toolTip = title
        tocIndicator.setAccessibilityValue(title)
        tocIndicatorSurface.isHidden = width < Self.minimumWidthForSectionLabel
    }

    static let minimumWidthForSectionLabel: CGFloat = 420

    /// Scrolls a rendered Markdown heading into view and updates navigation selection.
    private func navigateToMarkdownHeading(_ index: Int) {
        guard markdownTOCAvailable,
              let markdown = currentPreparation?.markdownDocument,
              markdown.headings.indices.contains(index),
              let range = markdownHeadingRanges(in: textView)[index],
              let rect = headingRect(range, in: textView) else { return }
        let clipView = scrollView.contentView
        setActiveMarkdownHeading(index)
        let readingInset = min(80, max(36, clipView.bounds.height * 0.16))
        let maximumOrigin = max(0, textView.frame.height - clipView.bounds.height)
        let targetY = min(maximumOrigin, max(0, rect.minY - readingInset))
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        scheduleMarkdownSectionUpdate()
    }

    /// Maps parsed heading indices to their current UTF-16 ranges in the rendered text view.
    private func markdownHeadingRanges(in textView: NSTextView) -> [Int: NSRange] {
        guard let storage = textView.textStorage, storage.length > 0 else { return [:] }
        var ranges: [Int: NSRange] = [:]
        storage.enumerateAttribute(MarkdownRenderer.headingIndexAttribute,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let index = value as? Int, range.length > 0 else { return }
            ranges[index] = ranges[index].map { NSUnionRange($0, range) } ?? range
        }
        return ranges
    }

    /// Converts a heading's character range to the enclosing text-view coordinate rectangle.
    private func headingRect(_ characterRange: NSRange, in textView: NSTextView) -> NSRect? {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              characterRange.location >= 0, characterRange.length > 0,
              NSMaxRange(characterRange) <= (textView.textStorage?.length ?? 0) else { return nil }
        layout.ensureLayout(forCharacterRange: characterRange)
        let glyphs = layout.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(
            dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y
        )
    }

    /// Finds nested scroll views so each representation reserves space for the shared footer.
    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { descendantScrollViews(in: $0) }
    }

    /// Displays prepared content and updates the local tab session without repeating inspection.
    @MainActor
    func display(_ preparation: PreviewPreparation, resetSession: Bool = true,
                 unavailableRepresentations: Set<FormatDefinition.RepresentationID> = []) {
        loadViewIfNeeded()
        invalidateMermaidWork(clearCache: true, changeGeneration: true)
        let analysis = preparation.analysis
        currentPreparation = preparation
        textView.setAccessibilityLabel("Preview text")
        let content = preparation.structuredContent
        let model = PreviewChromeModel(inspection: preparation,
                                       configuredViews: configuration.configuredViews(for: preparation.formatDefinition?.id),
                                       unavailableRepresentations: unavailableRepresentations)
        chrome = model
        if resetSession {
            session.tocIsOpen = false
            activeMarkdownHeadingIndex = nil
        }
        // The default is the first effective view; a session tab survives only while effective.
        if resetSession || !model.enabledRepresentations.contains(session.selectedRepresentation) {
            session.selectedRepresentation = model.representations.first ?? .raw
        }
        footer.update(model, selected: session.selectedRepresentation)
        footer.updateVCSStatus(currentVCSResult)
        let isYAML = preparation.yamlInspection != nil
        let isMultiple = (preparation.yamlInspection?.documents?.count ?? 0) != 1
        let isJSONLines = preparation.additionalInspection?.formatID == .jsonl
        let structuredSettings = configuration.structured(for: preparation.formatDefinition?.id ?? .json)
        let isLog = preparation.formatDefinition?.id == .log
        treeView.configure(sortKeys: structuredSettings.sortKeys, expandDepth: structuredSettings.expandDepth,
                           highlightsLogLevels: isLog)
        if let plist = preparation.plistInspection { treeView.displayPlist(plist.content) }
        else if let xml = preparation.xmlInspection, xml.domainSummary == nil { treeView.displayXML(xml.root) }
        else {
            let securityID = preparation.additionalInspection?.securityInspection?.formatID
            let isStringCatalog = preparation.formatDefinition?.id == .xcstrings
            let formatName = isLog ? "Log" : isJSONLines ? "JSON Lines" : isYAML ? "YAML"
                : isStringCatalog ? "String Catalog"
                : securityID == .pkcs7 ? "PKCS#7"
                : securityID == .pkcs12 ? "PKCS#12"
                : securityID == .mobileprovision ? "Provisioning profile"
                : securityID == .jwt ? "JWT"
                : securityID == .jwk || securityID == .jwks ? "JSON Web Key"
                : [.cyclonedxSBOM, .cyclonedxSBOMProtobuf, .spdxSBOM, .cyclonedxSBOMXML, .spdxTagValue].contains(securityID ?? .text) ? "Software bill of materials" : "JSON"
            let isKML = preparation.formatDefinition?.id == .kml
            let isGPX = preparation.formatDefinition?.id == .gpx
            let isGeoJSON = preparation.formatDefinition?.id == .geojson
            let rootKey = isKML ? "KML" : isGPX ? "GPX" : isGeoJSON ? "GeoJSON" : securityID == .pkcs7 ? "Bundle" : securityID == .pkcs12 ? "PFX" : isLog || isJSONLines ? "Records"
                : securityID == .mobileprovision ? "Profile"
                : securityID == .jwt ? "Token"
                : securityID == .jwk || securityID == .jwks ? "Keys"
                : isStringCatalog ? "Catalog"
                : [.cyclonedxSBOM, .cyclonedxSBOMProtobuf, .spdxSBOM, .cyclonedxSBOMXML, .spdxTagValue].contains(securityID ?? .text) ? "SBOM"
                : isYAML && isMultiple ? "Documents" : "$"
            treeView.display(content, formatName: isKML ? "KML" : isGPX ? "GPX" : isGeoJSON ? "GeoJSON" : formatName, rootKey: rootKey,
                             preserveMultiline: isYAML || isLog)
        }
        let hasSourceTab = model.representations.contains(.source)
        let showLegacySource = preparation.sourceDocument != nil && !hasSourceTab
        treeView.isHidden = session.selectedRepresentation != .tree || preparation.sourceDocument != nil || preparation.markdownDocument != nil
        tableView.display(preparation.csvInspection?.table)
        if let logTable = preparation.additionalInspection?.logTable {
            tableView.display(headers: logTable.headers, rows: logTable.rows,
                              minimumWidths: [56, 180, 140, 84, 320] + Array(repeating: 144, count: max(0, logTable.headers.count - 5)),
                              interactiveHeaders: true, resetControls: resetSession)
        } else if let listing = preparation.additionalInspection?.archiveListing {
            let rows = listing.entries.isEmpty
                ? [["Empty archive", "—", "—", "—"]]
                : listing.entries.map { [$0.displayName, $0.isDirectory ? "Directory" : "File",
                                         String($0.compressedSize), String($0.uncompressedSize)] }
            tableView.display(headers: ["Name", "Kind", "Compressed bytes", "Uncompressed bytes"],
                              rows: rows)
        } else if let listing = preparation.additionalInspection?.tarArchiveListing {
            let rows = listing.entries.isEmpty
                ? [["Empty archive", "—", "—", "—"]]
                : listing.entries.map { [$0.displayName, $0.kind.displayName, String($0.size), $0.linkTarget ?? "—"] }
            tableView.display(headers: ["Name", "Kind", "Size", "Link target"], rows: rows)
        } else if let xmlTable = preparation.xmlInspection?.table {
            tableView.display(headers: xmlTable.headers, rows: xmlTable.rows)
        }
        let hasTable = preparation.csvInspection?.table != nil
            || preparation.additionalInspection?.logTable != nil || preparation.additionalInspection?.archiveListing != nil
            || preparation.additionalInspection?.tarArchiveListing != nil
            || preparation.xmlInspection?.table != nil
        tableView.isHidden = session.selectedRepresentation != .table || !hasTable
        scrollView.isHidden = (session.selectedRepresentation == .tree && preparation.isStructured)
            || session.selectedRepresentation == .source || session.selectedRepresentation == .table || showLegacySource
        sourceView.isHidden = preparation.sourceDocument == nil
            || (!showLegacySource && session.selectedRepresentation != .source)
        sourceView.updateOptions(preparation.sourceDocument.map { configuration.source(for: $0.language) } ?? configuration.source)
        if let source = preparation.sourceDocument { sourceView.display(source) } else { sourceView.clear() }

        textView.string = session.selectedRepresentation == .hex ? (RepresentationRegistry.render(.hex, inspection: preparation) ?? "")
            : session.selectedRepresentation == .diff ? (preparation.diffInspection.map(DiffPreviewText.renderPlain) ?? preparation.analysis.text)
            : analysis.isBinary && preparation.plistInspection == nil ? "" : session.selectedRepresentation == .pretty
            ? (preparation.structuredPrettyText ?? preparation.structuredRawText) : preparation.structuredRawText
        if preparation.formatDefinition?.id == .mermaid {
            textView.setAccessibilityLabel(session.selectedRepresentation == .raw ? "Raw Mermaid source" : "Mermaid source")
        }

        textView.textContainerInset = NSSize(width: 8, height: 8)
        if preparation.markdownDocument != nil { showMarkdownMode() }
        else {
            applyTextPresentation(preparation)
            applyDiffPresentation(preparation)
            updateMarkdownTOCVisibility()

        }

        let type = analysis.isBinary ? "BinaryData" : "PlainText"
        let format = preparation.formatDefinition?.id.rawValue ?? "unknown"
        let encoding = analysis.encoding?.displayName ?? "none"
        logger.info(
            "FR002_RENDER format=\(format, privacy: .private) dataKind=\(type, privacy: .private) encoding=\(encoding, privacy: .private) lineEnding=\(analysis.lineEnding.rawValue, privacy: .private) sizeBytes=\(analysis.fileSize, privacy: .private) lineCount=\(analysis.lineCount, privacy: .private) lineCountLowerBound=\(analysis.lineCountIsLowerBound, privacy: .private) binary=\(analysis.isBinary, privacy: .private)"
        )
        if session.selectedRepresentation == .rendered { refreshMermaidForCurrentState() }
    }

    /// Switches among representations already derived from the current inspection result.
    @objc private func changeMode(_ sender: PreviewTabStrip) {
        guard let preparation = currentPreparation else { return }
        guard let chrome, chrome.representations.indices.contains(sender.selectedSegment) else { return }
        let representation = chrome.representations[sender.selectedSegment]
        guard chrome.enabledRepresentations.contains(representation) else { return }
        session.selectedRepresentation = representation
        footer.update(chrome, selected: representation, mermaidRenderFailed: mermaidRenderFailed)
        footer.updateVCSStatus(currentVCSResult)
        if preparation.markdownDocument != nil {
            showMarkdownMode()
            refreshMermaidForCurrentState()
            return
        }
        let showTree = representation == .tree && preparation.hasStructuredContent
        treeView.isHidden = !showTree
        let hasSourceTab = chrome.representations.contains(.source)
        let showSource = preparation.sourceDocument != nil && (!hasSourceTab || representation == .source)
        let showTable = representation == .table
            && (preparation.csvInspection?.table != nil
                || preparation.additionalInspection?.logTable != nil
                || preparation.additionalInspection?.archiveListing != nil
                || preparation.additionalInspection?.tarArchiveListing != nil
                || preparation.xmlInspection?.table != nil)
        scrollView.isHidden = showTree || showSource || showTable
        sourceView.isHidden = !showSource
        tableView.isHidden = !showTable
        textView.string = representation == .hex ? (RepresentationRegistry.render(.hex, inspection: preparation) ?? "")
            : representation == .diff ? (preparation.diffInspection.map(DiffPreviewText.renderPlain) ?? preparation.analysis.text)
            : representation == .pretty
            ? (preparation.structuredPrettyText ?? preparation.structuredRawText) : preparation.structuredRawText
        if preparation.formatDefinition?.id == .mermaid {
            textView.setAccessibilityLabel(representation == .raw ? "Raw Mermaid source" : "Mermaid source")
        }
        if showSource, let source = preparation.sourceDocument { sourceView.display(source) }
        applyTextPresentation(preparation)
        applyDiffPresentation(preparation)
        updateMarkdownTOCVisibility()
        if preparation.formatDefinition?.id == .mermaid {
            if representation == .rendered { refreshMermaidForCurrentState() }
            else { stopMermaidSchedulingPreservingCache() }
        }
    }

    /// Applies hierarchy and semantic line colors from the parsed diff model; no parsing occurs here.
    private func applyDiffPresentation(_ preparation: PreviewPreparation) {
        guard session.selectedRepresentation == .diff, let diff = preparation.diffInspection else { return }
        textView.textStorage?.setAttributedString(DiffPreviewText.render(diff))
    }

    /// Applies wrapping and syntax decoration to plain/structured text while preserving raw content.
    private func applyTextPresentation(_ preparation: PreviewPreparation) {
        let plain = !preparation.isStructured && preparation.markdownDocument == nil && preparation.sourceDocument == nil
            && session.selectedRepresentation != .hex
        let font = plain
            ? SourceRenderConfiguration(fontFamily: configuration.text.fontFamily, fontSize: configuration.text.fontSize).resolvedFont()
            : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let binaryRaw = preparation.plistInspection?.isBinary == true && session.selectedRepresentation == .raw
        // Hard wrap applies to plain text only; structured Raw/Pretty and Tree are never re-broken (ADR-016).
        let hard = plain && !binaryRaw && configuration.text.wrapMode == .hard
        let wrap = !binaryRaw && (!plain || configuration.text.wrapMode == .soft)
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(width: wrap ? max(1, scrollView.contentSize.width) : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(plain ? configuration.text.tabWidth : 4)
        let original = textView.string
        let layout = hard
            ? (try? HardWrapLayout.wrap(original, lineLength: configuration.text.lineLength, tabStop: configuration.text.tabWidth)) ?? .identity(original)
            : .identity(original)
        textView.hardWrap = layout
        textView.textStorage?.setAttributedString(NSAttributedString(string: layout.displayed, attributes: [
            .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph
        ]))
        let isJSONLines = preparation.additionalInspection?.formatID == .jsonl
        let format: StructuredTextFormat? = preparation.isStructured && !binaryRaw
            ? (preparation.yamlInspection != nil ? .yaml : preparation.jsonInspection != nil || isJSONLines ? .json : .xml) : nil
        scrollView.decorate(format: format)
        // Sized after `decorate`, which decides whether the line-number ruler takes room.
        if wrap { fitWrappedTextToViewport() }
        textView.sizeToFit()
    }

    /// Sizes wrapped text to the visible clip. The ruler takes its room as a clip-view inset, which
    /// `contentSize` does not subtract, and lines end inside the text inset on both sides.
    private func fitWrappedTextToViewport() {
        scrollView.tile()
        let insets = scrollView.contentView.contentInsets
        let width = max(1, scrollView.contentView.bounds.width - insets.left - insets.right)
        textView.textContainer?.containerSize = NSSize(width: max(1, width - textView.textContainerInset.width * 2),
                                                       height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: width, height: max(scrollView.contentSize.height, textView.frame.height)))
    }

    /// Renders Markdown or shows its highlighted source while preserving the original text.
    private func showMarkdownMode() {
        guard let preparation = currentPreparation, let markdown = preparation.markdownDocument else { return }
        let showingSource = session.selectedRepresentation == .source
        textView.hardWrap = nil
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.hasHorizontalScroller = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        treeView.isHidden = true
        scrollView.rulersVisible = false
        scrollView.isHidden = showingSource
        sourceView.isHidden = !showingSource || preparation.sourceDocument == nil
        if showingSource, let source = preparation.sourceDocument {
            sourceView.updateOptions(configuration.source(for: .markdown))
            sourceView.display(source)
            textView.setAccessibilityLabel("Markdown source code")
            setActiveMarkdownHeading(nil)
        } else if session.selectedRepresentation == .rendered, markdown.renderedText != nil {
            fitWrappedTextToViewport()
            let diagramWidth = CGFloat(requestedMermaidWidth() ?? 0)
            textView.textStorage?.setAttributedString(MarkdownRenderer.render(
                markdown, configuration: configuration.markdown, source: configuration.source,
                appearance: view.effectiveAppearance, maximumDiagramWidth: diagramWidth,
                mermaidImages: renderedMermaidImages,
                makeMermaidAttachment: { [weak self] block, appearance, width, image in
                    self?.makeMermaidAttachment(for: block, appearance: appearance,
                                               maximumWidth: width, renderedImage: image)
                }))
            textView.setAccessibilityLabel("Rendered Markdown")
        } else {
            scrollView.isHidden = false
            fitWrappedTextToViewport()
            textView.textStorage?.setAttributedString(NSAttributedString(string: markdown.raw, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor
            ]))
            textView.setAccessibilityLabel("Raw Markdown fallback")
            setActiveMarkdownHeading(nil)
        }
        updateMarkdownTOCVisibility()
        scheduleMarkdownSectionUpdate()
    }

    /// Coalesces layout churn so only the latest usable viewport width can enqueue a render.
    private func scheduleMermaidLayoutCheck() {
        guard !mermaidLayoutCheckScheduled else { return }
        mermaidLayoutCheckScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.mermaidLayoutCheckScheduled = false
            self.refreshMermaidForCurrentState()
        }
    }

    /// Uses the shared scroll viewport and text insets; too-small or pre-layout geometry defers work.
    private func requestedMermaidWidth() -> Int? {
        if let mermaidWidthOverride {
            guard let width = mermaidWidthOverride(), (180...640).contains(width) else { return nil }
            return width
        }
        scrollView.tile()
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let viewport = clip.bounds.width - insets.left - insets.right
        let usable = viewport - textView.textContainerInset.width * 2
        guard viewport.isFinite, viewport > 0, usable.isFinite, usable >= 180 else { return nil }
        return Int(floor(min(640, usable)))
    }

    /// Resolves blocks through the identity-aware Rendered registry and manages its one serialized worker.
    private func refreshMermaidForCurrentState() {
        guard let preparation = currentPreparation,
              let rendered = RepresentationRegistry.definition(for: .rendered, inspection: preparation) else {
            stopMermaidSchedulingPreservingCache()
            return
        }
        guard session.selectedRepresentation == .rendered else {
            stopMermaidSchedulingPreservingCache()
            displayedMermaidKey = nil
            return
        }

        let blocks: [MarkdownMermaidBlock]
        switch rendered.renderer {
        case .markdownText:
            blocks = preparation.markdownDocument?.mermaidBlocks ?? []
        case .mermaidDiagram:
            guard case .admitted(let block) = preparation.standaloneMermaidAdmission else {
                stopMermaidSchedulingPreservingCache()
                displayStandaloneSource(preparation)
                updateMermaidFooter()
                return
            }
            blocks = [block]
        default:
            stopMermaidSchedulingPreservingCache()
            return
        }
        guard !blocks.isEmpty else {
            stopMermaidSchedulingPreservingCache()
            return
        }
        guard let width = requestedMermaidWidth() else {
            waitingMermaidRequest = nil
            desiredMermaidAttemptID = nil
            if activeMermaidRequest != nil { cancelActiveMermaidRequest() }
            completedMermaidRender = nil
            renderedMermaidImages.removeAll(keepingCapacity: true)
            displayedMermaidKey = nil
            mermaidRenderFailed = false
            if preparation.formatDefinition?.id == .mermaid { displayStandaloneSource(preparation) }
            else { showMarkdownMode() }
            updateMermaidFooter()
            return
        }

        let key = MermaidRenderKey(generation: mermaidRenderGeneration, width: width)
        if completedMermaidRender?.key != key {
            if completedMermaidRender != nil || displayedMermaidKey != nil {
                completedMermaidRender = nil
                renderedMermaidImages.removeAll(keepingCapacity: true)
                displayedMermaidKey = nil
                mermaidRenderFailed = false
                if preparation.formatDefinition?.id == .mermaid { displayStandaloneSource(preparation) }
                else { showMarkdownMode() }
                updateMermaidFooter()
            }
        }
        if let completed = completedMermaidRender, completed.key == key {
            if displayedMermaidKey != key {
                applyMermaidResult(completed.images, for: key, attemptID: completed.attemptID)
            }
            return
        }
        if displayedMermaidKey != key {
            renderedMermaidImages.removeAll(keepingCapacity: true)
            mermaidRenderFailed = false
            if preparation.formatDefinition?.id == .mermaid { displayStandaloneSource(preparation) }
            else { showMarkdownMode() }
            displayedMermaidKey = key
            updateMermaidFooter()
        }
        enqueueMermaidRender(blocks, key: key)
    }

    /// Reuses same-key work or replaces the single queued request while the cancelled call drains.
    private func enqueueMermaidRender(_ blocks: [MarkdownMermaidBlock], key: MermaidRenderKey) {
        if let activeMermaidRequest, activeMermaidRequest.key == key,
           !activeMermaidCancellationRequested {
            desiredMermaidAttemptID = activeMermaidRequest.id
            return
        }
        if let waitingMermaidRequest, waitingMermaidRequest.key == key {
            desiredMermaidAttemptID = waitingMermaidRequest.id
            return
        }
        let request = MermaidRenderRequest(id: UUID(), key: key, blocks: blocks)
        desiredMermaidAttemptID = request.id
        if activeMermaidRequest != nil {
            waitingMermaidRequest = request
            cancelActiveMermaidRequest()
        } else {
            waitingMermaidRequest = nil
            startMermaidRequest(request)
        }
    }

    private func startMermaidRequest(_ request: MermaidRenderRequest) {
        activeMermaidRequest = request
        activeMermaidCancellationRequested = false
        let renderer = mermaidKitRenderer
        let renderOverride = mermaidRenderOverride
        mermaidRenderTask = Task { @MainActor [weak self] in
            let result: Result<[String: NSImage], Error>
            do {
                let images: [String: NSImage]
                if let override = renderOverride {
                    images = try await override(request.blocks, Double(request.key.width))
                } else {
                    images = try await renderer.render(request.blocks, maximumWidth: Double(request.key.width))
                }
                result = .success(images)
            }
            catch { result = .failure(error) }
            let cancelled = Task.isCancelled
            self?.finishMermaidRequest(request, result: result, cancelled: cancelled)
        }
    }

    /// Publishes only the still-selected attempt after runtime cleanup, then starts the latest eligible waiter.
    private func finishMermaidRequest(_ request: MermaidRenderRequest,
                                      result: Result<[String: NSImage], Error>, cancelled: Bool) {
        guard activeMermaidRequest?.id == request.id else { return }
        let wasCancelled = cancelled || activeMermaidCancellationRequested
        activeMermaidRequest = nil
        mermaidRenderTask = nil
        activeMermaidCancellationRequested = false
        if !wasCancelled, desiredMermaidAttemptID == request.id,
           isCurrentMermaidRequest(request) {
            let images: [String: NSImage]
            switch result {
            case .success(let value): images = value
            case .failure(let error):
                guard !(error is CancellationError) else {
                    startEligibleWaitingRequest()
                    return
                }
                logger.debug("Bundled Mermaid rendering was unavailable")
                images = [:]
            }
            completedMermaidRender = CompletedMermaidRender(key: request.key, attemptID: request.id, images: images)
            applyMermaidResult(images, for: request.key, attemptID: request.id)
        } else if !wasCancelled, waitingMermaidRequest == nil {
            // The viewport changed while this attempt ran and nothing replaced it; request the current width.
            scheduleMermaidLayoutCheck()
        }
        startEligibleWaitingRequest()
    }

    private func isCurrentMermaidRequest(_ request: MermaidRenderRequest) -> Bool {
        guard let preparation = currentPreparation,
              mermaidRenderGeneration == request.key.generation,
              session.selectedRepresentation == .rendered,
              requestedMermaidWidth() == request.key.width,
              let rendered = RepresentationRegistry.definition(for: .rendered, inspection: preparation) else { return false }
        switch rendered.renderer {
        case .markdownText: return preparation.markdownDocument?.mermaidBlocks.map(\.source) == request.blocks.map(\.source)
        case .mermaidDiagram:
            guard case .admitted(let block) = preparation.standaloneMermaidAdmission else { return false }
            return request.blocks.count == 1 && request.blocks[0].source == block.source
        default: return false
        }
    }

    private func startEligibleWaitingRequest() {
        guard let request = waitingMermaidRequest else { return }
        waitingMermaidRequest = nil
        guard desiredMermaidAttemptID == request.id, isCurrentMermaidRequest(request) else { return }
        startMermaidRequest(request)
    }

    /// Keeps decoded source visible until the current request yields a valid image and attachment.
    private func applyMermaidResult(_ images: [String: NSImage], for key: MermaidRenderKey, attemptID: UUID) {
        guard let preparation = currentPreparation,
              mermaidRenderGeneration == key.generation,
              session.selectedRepresentation == .rendered else { return }
        renderedMermaidImages = images
        if preparation.formatDefinition?.id == .mermaid {
            let attachment: NSTextAttachment?
            if case .admitted(let block) = preparation.standaloneMermaidAdmission,
               let image = images[block.source] {
                attachment = makeMermaidAttachment(for: block, appearance: view.effectiveAppearance,
                                                   maximumWidth: CGFloat(key.width), renderedImage: image)
            } else { attachment = nil }
            if let attachment {
                scrollView.isHidden = false
                sourceView.isHidden = true
                treeView.isHidden = true
                tableView.isHidden = true
                textView.hardWrap = nil
                textView.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))
                textView.setAccessibilityLabel("Rendered Mermaid diagram")
                textView.sizeToFit()
                mermaidRenderFailed = false
            } else {
                displayStandaloneSource(preparation)
                mermaidRenderFailed = true
            }
            updateMermaidFooter()
        } else {
            mermaidRenderFailed = false
            showMarkdownMode()
        }
        displayedMermaidKey = key
        mermaidResultObserver?(attemptID, key.width)
    }

    private func makeMermaidAttachment(for block: MarkdownMermaidBlock, appearance: NSAppearance,
                                       maximumWidth: CGFloat, renderedImage: NSImage?) -> NSTextAttachment? {
        if let mermaidAttachmentOverride {
            return mermaidAttachmentOverride(block, appearance, maximumWidth, renderedImage)
        }
        return MermaidDiagramRenderer.attachment(for: block, appearance: appearance,
                                                 maximumWidth: maximumWidth, renderedImage: renderedImage)
    }

    private func displayStandaloneSource(_ preparation: PreviewPreparation) {
        scrollView.isHidden = false
        treeView.isHidden = true
        sourceView.isHidden = true
        tableView.isHidden = true
        textView.string = preparation.analysis.text
        textView.setAccessibilityLabel(session.selectedRepresentation == .raw ? "Raw Mermaid source" : "Mermaid source")
        applyTextPresentation(preparation)
    }

    private func updateMermaidFooter() {
        guard let chrome else { return }
        footer.update(chrome, selected: session.selectedRepresentation, mermaidRenderFailed: mermaidRenderFailed)
        footer.updateVCSStatus(currentVCSResult)
    }

    private func cancelActiveMermaidRequest() {
        guard activeMermaidRequest != nil, !activeMermaidCancellationRequested else { return }
        activeMermaidCancellationRequested = true
        mermaidRenderTask?.cancel()
    }

    private func stopMermaidSchedulingPreservingCache() {
        waitingMermaidRequest = nil
        desiredMermaidAttemptID = nil
        cancelActiveMermaidRequest()
    }

    private func invalidateMermaidWork(clearCache: Bool, changeGeneration: Bool) {
        waitingMermaidRequest = nil
        desiredMermaidAttemptID = nil
        cancelActiveMermaidRequest()
        if changeGeneration { mermaidRenderGeneration = UUID() }
        if clearCache {
            completedMermaidRender = nil
            renderedMermaidImages.removeAll(keepingCapacity: true)
            displayedMermaidKey = nil
            mermaidRenderFailed = false
        }
    }

}

/// Produces inert text and native attributed styling for parsed diff metadata.
private enum DiffPreviewText {
    /// Semantic row roles used to apply native diff colors and weights.
    private enum Role { case file, hunk, context, addition, deletion, metadata }
    /// One display line paired with the semantic role used by the attributed renderer.
    private struct Row { let text: String; let role: Role }

    /// Builds the plain diff representation without applying colors or interpreting paths.
    static func renderPlain(_ result: DiffInspectionResult) -> String {
        rows(for: result).map(\.text).joined()
    }

    @MainActor
    /// Styles parsed diff rows with system colors while keeping all file content inert.
    static func render(_ result: DiffInspectionResult) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let heading = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        for row in rows(for: result) {
            let color: NSColor
            let font: NSFont
            switch row.role {
            case .file: color = .textColor; font = heading
            case .hunk: color = .controlAccentColor; font = regular
            case .context: color = .textColor; font = regular
            case .addition: color = .systemGreen; font = regular
            case .deletion: color = .systemRed; font = regular
            case .metadata: color = .secondaryLabelColor; font = regular
            }
            output.append(NSAttributedString(string: row.text, attributes: [.font: font, .foregroundColor: color]))
        }
        return output
    }

    /// Flattens file and hunk models into display rows, including truncation and empty notices.
    private static func rows(for result: DiffInspectionResult) -> [Row] {
        var rows: [Row] = []
        for (index, file) in result.files.enumerated() {
            let oldPath = displayPath(file.oldPath) ?? "/dev/null"
            let newPath = displayPath(file.newPath) ?? "/dev/null"
            rows.append(.init(text: "\(file.change.rawValue.capitalized) · \(oldPath) → \(newPath)\n", role: .file))
            if file.isBinary { rows.append(.init(text: "Binary patch\n", role: .metadata)) }
            for hunk in file.hunks {
                let section = hunk.section.isEmpty ? "" : " \(hunk.section)"
                rows.append(.init(text: "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(section)\n", role: .hunk))
                for line in hunk.lines {
                    let marker: String
                    let role: Role
                    switch line.kind {
                    case .context: marker = " "; role = .context
                    case .addition: marker = "+"; role = .addition
                    case .deletion: marker = "-"; role = .deletion
                    case .metadata: marker = ""; role = .metadata
                    }
                    rows.append(.init(text: marker + line.text + "\n", role: role))
                }
            }
            if index < result.files.count - 1 { rows.append(.init(text: "\n", role: .metadata)) }
        }
        if result.isTruncated { rows.append(.init(text: "\nDiff preview truncated. Raw retains the bounded source prefix.\n", role: .metadata)) }
        if result.files.isEmpty { rows.append(.init(text: "No recognizable diff sections. Raw source is available.\n", role: .metadata)) }
        return rows
    }

    /// Bounds path display and replaces control characters without resolving or accessing paths.
    private static func displayPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let safe = path.unicodeScalars.prefix(512).map { CharacterSet.controlCharacters.contains($0) ? "�" : String($0) }.joined()
        return safe.isEmpty ? nil : safe
    }
}

extension SharedPreviewViewController: NSTextViewDelegate {
    /// Routes only a generated local link whose storage attribute matches a heading in this document.
    @discardableResult
    func navigateToMarkdownHeading(link: Any, characterIndex: Int, in textView: NSTextView) -> Bool {
        guard let url = link as? URL, url.scheme == "glimt-anchor", url.host == "heading",
              url.query == nil, url.fragment == nil,
              url.path.filter({ $0 == "/" }).count == 1,
              let rawIndex = url.path.split(separator: "/", omittingEmptySubsequences: true).first,
              let headingIndex = Int(rawIndex), String(headingIndex) == rawIndex,
              let markdown = currentPreparation?.markdownDocument,
              markdown.headings.indices.contains(headingIndex),
              textView === self.textView,
              let storage = textView.textStorage,
              characterIndex >= 0, characterIndex < storage.length,
              let clickedURL = storage.attribute(.link, at: characterIndex, effectiveRange: nil) as? URL,
              clickedURL == url else { return false }
        guard markdownHeadingRanges(in: textView)[headingIndex] != nil else { return false }
        navigateToMarkdownHeading(headingIndex)
        return true
    }

    /// Consumes every click locally, including invalid destinations, so arbitrary URLs are never delegated.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        _ = navigateToMarkdownHeading(link: link, characterIndex: charIndex, in: textView)
        return false
    }
}

/// A plain header surface avoids NSBox's frame-driven content layout conflicting with Auto Layout.
final class PreviewMetadataHeaderView: NSView {
    var fillColor: NSColor { .windowBackgroundColor }
    override var isOpaque: Bool { true }

    /// Paints the header's effective background without frame-driven box layout.
    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

/// Session-local native document tabs. Each tab is a focusable, accessible radio button.
@MainActor
final class PreviewTabStrip: NSControl {
    static let tabWidth: CGFloat = 76
    static let tabHeight: CGFloat = 28
    private var buttons: [PreviewTabButton] = []
    /// Recreates focusable radio tabs only when representation count changes.
    var segmentCount: Int {
        get { buttons.count }
        set {
            guard newValue != buttons.count else { return }
            buttons.forEach { $0.removeFromSuperview() }
            buttons = (0..<newValue).map { index in
                let button = PreviewTabButton(title: "", target: self, action: #selector(selectTab(_:)))
                button.tag = index
                // AppKit's toggle cell paints a persistent selected bezel of its own.
                // The footer draws the connected tab outline so there must be only one
                // source of selected-state visuals.
                button.setButtonType(.momentaryPushIn)
                button.isBordered = false
                // The connected tab outline is the selected state. A native button focus ring
                // can remain on the previously focused segment and look like stale selection.
                button.focusRingType = .none
                button.setAccessibilityRole(.radioButton)
                button.setAccessibilitySubrole(NSAccessibility.Subrole.tabButtonSubrole)
                button.setAccessibilityElement(true)
                addSubview(button)
                return button
            }
            setAccessibilityRole(.tabGroup)
            setAccessibilityChildren(buttons)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    var itemWidth: CGFloat { segmentCount > 3 ? 56 : Self.tabWidth }
    var selectedSegment = -1 { didSet { updateSelection() } }
    override var intrinsicContentSize: NSSize { .init(width: CGFloat(segmentCount) * itemWidth, height: Self.tabHeight) }
    var selectedTabFrame: NSRect? {
        guard buttons.indices.contains(selectedSegment) else { return nil }
        return buttons[selectedSegment].frame
    }
    /// Updates a tab title while keeping the tab object and its accessibility identity stable.
    func setLabel(_ value: String, forSegment index: Int) { buttons[index].title = value }
    /// Returns the displayed title for a representation segment.
    func label(forSegment index: Int) -> String? { buttons[index].title }
    /// Changes one tab's selection availability without rebuilding the control.
    func setEnabled(_ value: Bool, forSegment index: Int) { buttons[index].isEnabled = value }
    /// Reports whether a representation can currently be selected.
    func isEnabled(forSegment index: Int) -> Bool { buttons[index].isEnabled }
    /// Places equal-width buttons in display order; intrinsic width adapts to large tab counts.
    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
                button.frame = .init(x: CGFloat(index) * itemWidth, y: 0, width: itemWidth, height: bounds.height)
        }
    }
    /// Synchronizes custom drawing and the accessibility selected-child state.
    private func updateSelection() {
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedSegment
            button.isTabSelected = selected
            button.needsDisplay = true
        }
        setAccessibilitySelectedChildren(buttons.indices.contains(selectedSegment) ? [buttons[selectedSegment]] : [])
        needsDisplay = true
    }
    @objc private func selectTab(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        selectedSegment = sender.tag
        _ = sendAction(action, to: target)
    }
    /// Wraps keyboard navigation and skips disabled representations.
    func moveSelection(by delta: Int) {
        guard !buttons.isEmpty else { return }
        var index = selectedSegment
        for _ in buttons.indices {
            index = (index + delta + buttons.count) % buttons.count
            if buttons[index].isEnabled {
                selectTab(buttons[index])
                window?.makeFirstResponder(buttons[index])
                return
            }
        }
    }
}

/// Draws a compact representation tab and forwards left/right navigation to its tab strip.
private final class PreviewTabButton: NSButton {
    var isTabSelected = false

    /// Draws selected, inactive, and disabled tab labels with native system text colors.
    override func draw(_ dirtyRect: NSRect) {
        let selected = isTabSelected && isEnabled
        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: selected ? .medium : .regular),
            .foregroundColor: isEnabled
                ? (selected ? NSColor.labelColor : NSColor.secondaryLabelColor)
                : NSColor.disabledControlTextColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: .init(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    /// Keeps the keyboard focus ring inside the custom tab label bounds.
    override func drawFocusRingMask() { bounds.insetBy(dx: 3, dy: 3).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    /// Maps left/right arrows to enabled sibling tabs and leaves other key commands to AppKit.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { (superview as? PreviewTabStrip)?.moveSelection(by: -1) }
        else if event.keyCode == 124 { (superview as? PreviewTabStrip)?.moveSelection(by: 1) }
        else { super.keyDown(with: event) }
    }
}

/// Pure geometry helpers for the footer's selected tab and separator drawing.
enum PreviewTabGeometry {
    /// Leaves a small footer reveal below the selected tab so its bottom edge is
    /// visible in the actual preview instead of being clipped at the footer boundary.
    static let selectedTabBottomInset: CGFloat = 2

    /// Uses one physical pixel at the current display scale for crisp footer rules.
    static func hairlineThickness(backingScaleFactor: CGFloat) -> CGFloat {
        1 / max(backingScaleFactor, 1)
    }

    /// Extends the selected tab to the footer baseline while retaining its small bottom reveal.
    static func selectedTabFrame(buttonFrame: NSRect, footerHeight: CGFloat) -> NSRect {
        .init(x: buttonFrame.minX, y: selectedTabBottomInset,
              width: buttonFrame.width, height: max(0, footerHeight - selectedTabBottomInset))
    }

    /// Leaves a gap beneath the selected tab and pixel-aligns the remaining separator segments.
    static func separatorSegments(width: CGFloat, height: CGFloat, selectedTab: NSRect?, scale: CGFloat) -> [NSRect] {
        let hairline = hairlineThickness(backingScaleFactor: scale)
        guard let selectedTab else {
            return [NSRect(x: 0, y: height - hairline, width: width, height: hairline)]
        }
        let left = floor(selectedTab.minX * scale) / scale
        let right = ceil(selectedTab.maxX * scale) / scale
        var segments: [NSRect] = []
        if left > 0 { segments.append(.init(x: 0, y: height - hairline, width: left, height: hairline)) }
        if right < width {
            segments.append(.init(x: right, y: height - hairline, width: width - right, height: hairline))
        }
        return segments
    }

    /// Pixel-aligns the selected tab's three visible edges; the bottom is supplied by its background.
    static func selectedOutlineSegments(tab: NSRect, scale: CGFloat) -> [NSRect] {
        let hairline = hairlineThickness(backingScaleFactor: scale)
        let left = floor(tab.minX * scale) / scale
        let right = ceil(tab.maxX * scale) / scale
        let bottom = floor(tab.minY * scale) / scale
        let top = ceil(tab.maxY * scale) / scale
        return [
            .init(x: left, y: bottom, width: hairline, height: top - bottom),
            .init(x: right - hairline, y: bottom, width: hairline, height: top - bottom),
            .init(x: left, y: bottom, width: right - left, height: hairline)
        ]
    }
}

/// Individual labels and real separator views; full metadata stays available at narrow widths.
@MainActor
final class PreviewStatusView: NSView {
    private(set) var items: [PreviewStatusSummary.Item] = []
    private var sourceItems: [PreviewStatusSummary.Item] = []
    private(set) var visibleItemCount = 0
    private var visibleIndices: [Int] = []
    var omittedText: String? { didSet { apply(sourceItems) } }
    /// The last remaining item shows only its validity icon when its text no longer fits;
    /// the tooltip and accessibility label keep the full summary.
    private(set) var showsIconOnly = false
    var stringValue: String { items.map(\.text).joined(separator: ", ") }
    private let font = NSFont.systemFont(ofSize: 11)
    /// Stores the full semantic status list before layout chooses a width-fitting visible subset.
    func update(_ items: [PreviewStatusSummary.Item]) {
        sourceItems = items
        apply(items)
    }
    /// Filters accessory-owned text and publishes complete status through tooltip and accessibility labels.
    private func apply(_ source: [PreviewStatusSummary.Item]) {
        items = source.filter { $0.text != omittedText }
        toolTip = stringValue
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(stringValue)
        setAccessibilityChildren([])
        visibleIndices = []
        needsLayout = true
    }
    /// Measures the current text or compact icon-only representation for one status item.
    private func width(_ item: PreviewStatusSummary.Item) -> CGFloat {
        if showsIconOnly { return 13 }
        return textWidth(item)
    }
    /// Includes icon and label gaps so the fitting pass agrees with the actual subview frames.
    private func textWidth(_ item: PreviewStatusSummary.Item) -> CGFloat {
        ceil((item.text as NSString).size(withAttributes: [.font: font]).width) + 4 + (item.kind == .information ? 0 : 17)
    }
    /// The width that shows every item as text.
    var naturalWidth: CGFloat {
        items.reduce(0) { $0 + textWidth($1) } + CGFloat(max(0, items.count - 1)) * 25
    }
    /// Drops low-priority facts first, then shortens or hides the remaining status to fit the footer width.
    override func layout() {
        super.layout()
        // Measure real text widths; the previous pass's icon-only form must not decide the collapse (D31).
        let wasIconOnly = showsIconOnly
        showsIconOnly = false
        var indices = Array(items.indices)
        /// Recomputes width against the currently retained set of status facts.
        func requiredWidth() -> CGFloat { indices.reduce(0) { $0 + width(items[$1]) } + CGFloat(max(0, indices.count - 1)) * 25 }
        // Keep validation, encoding and size longer than count and line-ending details.
        let lowPriority = indices.filter { items[$0].text.contains("document") || items[$0].text.contains("line") || ["LF", "CRLF", "CR", "Mixed"].contains(items[$0].text) }
        for index in lowPriority.reversed() where requiredWidth() > bounds.width {
            indices.removeAll { $0 == index }
        }
        while indices.count > 1, requiredWidth() > bounds.width { indices.removeLast() }
        if let last = indices.first, requiredWidth() > bounds.width {
            showsIconOnly = items[last].kind != .information && bounds.width >= 13
            if !showsIconOnly { indices.removeAll() }
        }
        visibleItemCount = indices.count
        if indices != visibleIndices || showsIconOnly != wasIconOnly {
            subviews.forEach { $0.removeFromSuperview() }
            visibleIndices = indices
            for (position, index) in indices.enumerated() {
                if position > 0 {
                    let separator = NSBox()
                    separator.boxType = .separator
                    separator.identifier = .init("PreviewStatusSeparator")
                    addSubview(separator)
                }
                let item = items[index]
                let group = NSView()
                group.identifier = .init("PreviewStatusItem")
                if item.kind != .information {
                    let image = NSImage(systemSymbolName: item.kind == .valid ? "checkmark" : "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage()
                    let icon = NSImageView(image: image)
                    icon.contentTintColor = item.kind == .valid ? .systemGreen : .systemOrange
                    icon.frame = .init(x: 0, y: 2, width: 13, height: 13)
                    group.addSubview(icon)
                }
                if !showsIconOnly {
                    let label = NSTextField(labelWithString: item.text)
                    label.font = font
                    label.textColor = .secondaryLabelColor
                    let iconWidth: CGFloat = item.kind == .information ? 0 : 17
                    label.frame = .init(x: iconWidth, y: 0, width: width(item) - iconWidth, height: 17)
                    group.addSubview(label)
                }
                addSubview(group)
            }
        }
        var x = max(0, bounds.width - requiredWidth())
        var child = 0
        for (position, index) in indices.enumerated() {
            if position > 0 {
                subviews[child].frame = .init(x: x + 12, y: (bounds.height - 12) / 2, width: 1, height: 12)
                child += 1; x += 25
            }
            subviews[child].frame = .init(x: x, y: (bounds.height - 17) / 2, width: width(items[index]), height: 17)
            child += 1; x += width(items[index])
        }
    }
}

/// Shared preview footer: tab navigation and status are one component; content touches the selected tab.
@MainActor
/// A footer accessory that has a narrower form for when its regular form would cover the
/// representation tabs. The footer picks the form; the accessory only reports both sizes.
protocol PreviewFooterCompactable: NSView {
    var regularSize: NSSize { get }
    var compactSize: NSSize { get }
    var isCompact: Bool { get set }
}

/// Combines representation tabs, inspection status, and optional host-provided footer accessories.
final class PreviewRepresentationTabStrip: NSView {
    static let tabLeadingInset: CGFloat = 12
    private let modeControl: PreviewTabStrip
    private let status = PreviewStatusView()
    private var currentStatusItems: [PreviewStatusSummary.Item] = []
    private var vcsStatusItems: [PreviewStatusSummary.Item] = []
    /// Creates the tab strip adapter used to synchronize representation selection and status.
    init(modeControl: PreviewTabStrip) {
        self.modeControl = modeControl
        super.init(frame: .zero)
        identifier = .init("PreviewFooter")
        status.identifier = .init("PreviewStatus")
        status.wantsLayer = true
        status.layer?.masksToBounds = true
        addSubview(modeControl); addSubview(status)
    }
    required init?(coder: NSCoder) { nil }

    /// Host-supplied controls (the app's example label and session appearance control). Quick Look
    /// supplies none, so its footer is unchanged.
    var leadingAccessory: NSView? {
        didSet { oldValue?.removeFromSuperview(); leadingAccessory.map(addSubview); needsLayout = true }
    }
    var trailingAccessory: NSView? {
        didSet { oldValue?.removeFromSuperview(); trailingAccessory.map(addSubview); needsLayout = true }
    }
    var showsStatus = true { didSet { status.isHidden = !showsStatus } }
    var showsRepresentations = true { didSet { modeControl.isHidden = !showsRepresentations } }
    /// Host-only suppression for a status item already stated in its sample header. Quick Look
    /// leaves this nil because the system supplies the filename outside Glimt's footer.
    var omittedStatusText: String? {
        get { status.omittedText }
        set { status.omittedText = newValue; needsLayout = true }
    }

    /// Rebuilds representation availability and status from the active preview model.
    func update(_ model: PreviewChromeModel, selected: PreviewRepresentation, mermaidRenderFailed: Bool = false) {
        modeControl.segmentCount = model.representations.count
        for (index, representation) in model.representations.enumerated() {
            modeControl.setLabel(representation.rawValue, forSegment: index)
            modeControl.setEnabled(model.enabledRepresentations.contains(representation), forSegment: index)
        }
        modeControl.selectedSegment = model.representations.firstIndex(of: selected) ?? -1
        modeControl.isHidden = !showsRepresentations || model.representations.isEmpty
        currentStatusItems = model.statusItems(for: selected, mermaidRenderFailed: mermaidRenderFailed)
        status.update(currentStatusItems + vcsStatusItems)
        needsLayout = true
        // The selected-tab outline and separator gap are drawn by this parent view.
        // Invalidating only the buttons leaves the old tab boundary visible after a click.
        needsDisplay = true
    }

    /// Adds a concise repository state, plus the commit that last changed the file when known,
    /// or removes the status items when inspection is unavailable.
    func updateVCSStatus(_ result: VCSInspectionResult?) {
        guard let result else {
            vcsStatusItems = []
            status.update(currentStatusItems)
            needsLayout = true
            return
        }
        let repository = result.repositoryType == .git ? "Git" : "SVN"
        let fileStatus: String = switch result.fileStatus {
        case .clean: "Clean"
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .replaced: "Replaced"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        case .unavailable: "Status unavailable"
        }
        vcsStatusItems = [PreviewStatusSummary.Item(text: "\(repository): \(fileStatus)", kind: .information)]
        if let commit = result.lastCommit {
            let date = commit.authorDate.formatted(date: .abbreviated, time: .omitted)
            vcsStatusItems.append(.init(text: "Commit \(commit.shortID) · \(date)", kind: .information))
        }
        status.update(currentStatusItems + vcsStatusItems)
        needsLayout = true
    }
    var topSeparatorSegments: [NSRect] {
        let selected = selectedTabFrame
        return PreviewTabGeometry.separatorSegments(width: bounds.width, height: bounds.height,
                                                      selectedTab: selected, scale: backingScaleFactor)
    }
    var selectedTabOutlineSegments: [NSRect] {
        guard let selected = selectedTabFrame else { return [] }
        return PreviewTabGeometry.selectedOutlineSegments(tab: selected, scale: backingScaleFactor)
    }
    var selectedTabFrame: NSRect? {
        guard !modeControl.isHidden, let selected = modeControl.selectedTabFrame else { return nil }
        let buttonFrame = modeControl.convert(selected, to: self)
        return PreviewTabGeometry.selectedTabFrame(buttonFrame: buttonFrame, footerHeight: bounds.height)
    }
    var selectedTabBackgroundColor: NSColor { .textBackgroundColor }
    var footerBackgroundColor: NSColor { .controlBackgroundColor }
    private var backingScaleFactor: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 }
    /// Allocates footer width between tabs, status and accessories while preserving their priority.
    override func layout() {
        super.layout()
        let tabsWidth = modeControl.isHidden ? 0 : modeControl.intrinsicContentSize.width
        let leadingInset = tabsWidth == 0 ? 0 : Self.tabLeadingInset
        modeControl.frame = .init(x: leadingInset, y: 0, width: tabsWidth, height: bounds.height)
        var statusLeading = min(leadingInset + tabsWidth + 8, bounds.width)
        var statusTrailing = bounds.width - 8
        if let trailing = trailingAccessory {
            // The trailing accessory never covers the tabs: it compacts first, then gives way. It
            // also compacts when its regular form would truncate the leading accessory (D30) or
            // collapse the status (D32).
            let tabsEnd = leadingInset + tabsWidth + 8
            let leadingStart = tabsWidth == 0 ? Self.tabLeadingInset : tabsEnd
            var leadingNeed = leadingAccessory.flatMap { $0.isEmptyLabel ? nil : leadingStart + $0.fittingSize.width + 12 } ?? tabsEnd
            if showsStatus, !status.items.isEmpty { leadingNeed += status.naturalWidth + 12 }
            /// Tests accessory fit without allowing it to overlap the tab strip's reserved inset.
            func fits(_ size: NSSize, before end: CGFloat) -> Bool { bounds.width - Self.tabLeadingInset - size.width >= end }
            var size = trailing.fittingSize
            if let compactable = trailing as? PreviewFooterCompactable {
                let compact = !fits(compactable.regularSize, before: max(tabsEnd, leadingNeed))
                if compactable.isCompact != compact { compactable.isCompact = compact }
                size = compact ? compactable.compactSize : compactable.regularSize
            }
            trailing.isHidden = !fits(size, before: tabsEnd)
            trailing.frame = .init(x: bounds.width - Self.tabLeadingInset - size.width,
                                   y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height)
            if !trailing.isHidden { statusTrailing = trailing.frame.minX - 12 }
        }
        if let leading = leadingAccessory {
            // The leading accessory is shown in full in the room left before the trailing one, or
            // not at all: a truncated label is never shown (D30).
            let size = leading.fittingSize
            let x = tabsWidth == 0 ? Self.tabLeadingInset : statusLeading
            leading.isHidden = leading.isEmptyLabel || size.width > statusTrailing - x
            leading.frame = .init(x: x, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height)
            if !leading.isHidden { statusLeading = min(leading.frame.maxX + 12, bounds.width) }
        }
        status.frame = .init(x: statusLeading, y: 0,
                             width: max(0, statusTrailing - statusLeading), height: bounds.height)
        status.needsLayout = true
    }
    /// Paints the footer, selected-tab background and pixel-aligned separator geometry.
    override func draw(_ dirtyRect: NSRect) {
        footerBackgroundColor.setFill(); bounds.fill()
        if let selected = selectedTabFrame {
            selectedTabBackgroundColor.setFill()
            selected.fill()
            NSColor.separatorColor.setFill()
            selectedTabOutlineSegments.forEach { $0.fill() }
        }
        NSColor.separatorColor.setFill()
        topSeparatorSegments.forEach { $0.fill() }
    }
}

private extension NSView {
    /// A label with no text takes no footer room.
    var isEmptyLabel: Bool { (self as? NSTextField)?.stringValue.isEmpty == true }
}
