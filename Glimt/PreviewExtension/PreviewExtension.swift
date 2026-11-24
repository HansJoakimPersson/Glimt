import AppKit
import Darwin
import GitInspection
import InspectorCore
import os
import QuickLookUI
import UniformTypeIdentifiers

#if DEBUG || GLIMT_TESTING
/// Serializes and reads synthetic fixture correlation markers for local provider probes.
enum PreviewProviderMarkerSerializer {
    private static let requiredSignals: [DetectionEvidence.SignalKind] = [
        .filename, .multiExtension, .singleExtension, .shebang,
        .yamlMapping, .yamlDocumentMarker, .systemUTI
    ]
    private static let supportedTypes: Set<String> = [
        "unknown", "typescript", "typescript-declaration", "dotenv", "makefile",
        "dockerfile", "generic-local", "python", "yaml", "plist", "json", "xml"
    ]

    /// Emits a smoke-test marker only when every value is canonical and belongs to the expected provider phase.
    static func serialize(
        token: String,
        provider: String,
        phase: String,
        typeID: String,
        confidence: Double,
        scores: [(DetectionEvidence.SignalKind, Double)],
        sampleByteCount: Int,
        sampleIsComplete: Bool
    ) -> String? {
        guard isCanonicalToken(token), supportedTypes.contains(typeID),
              ((provider == "preview" && phase == "display-prepared")
                || (provider == "thumbnail" && phase == "reply-prepared")),
              confidence.isFinite, (0...1).contains(confidence),
              (0...65_536).contains(sampleByteCount) else {
            return nil
        }

        var selected: [Double?] = Array(repeating: nil, count: requiredSignals.count)
        for (signal, score) in scores {
            guard signal != .utiConflict else { continue }
            guard let index = requiredSignals.firstIndex(of: signal),
                  selected[index] == nil,
                  score.isFinite, (0...1).contains(score) else {
                return nil
            }
            selected[index] = score
        }
        guard selected.allSatisfy({ $0 != nil }) else { return nil }

        let formattedScores = selected.compactMap { $0 }.map(formatHundredths).joined(separator: ",")
        return "FR005_PROVIDER_V1 token=\(token) provider=\(provider) phase=\(phase) type=\(typeID) confidence=\(formatHundredths(confidence)) scores=\(formattedScores) sampleBytes=\(sampleByteCount) complete=\(sampleIsComplete ? 1 : 0)"
    }

    /// Reads only the synthetic test xattr and returns it when its fixed UUID format is valid.
    static func readToken(from url: URL) -> String? {
        // Read only the dedicated synthetic-fixture xattr; it is correlation metadata, never file content.
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            return "com.glimt.fr005-evidence".withCString { name in
                var bytes = [UInt8](repeating: 0, count: 37)
                let count = bytes.withUnsafeMutableBufferPointer { buffer in
                    getxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
                }
                guard count == 36 else { return nil }
                let tokenBytes = bytes.prefix(36)
                guard let token = String(bytes: tokenBytes, encoding: .ascii), isCanonicalToken(token) else {
                    return nil
                }
                return token
            }
        }
    }

    /// Allows only lowercase UUID-shaped correlation tokens in debug log markers.
    static func isCanonicalToken(_ token: String) -> Bool {
        // Accept a fixed lowercase UUID shape so fixture metadata cannot inject arbitrary log text.
        let bytes = Array(token.utf8)
        guard bytes.count == 36 else { return false }
        for index in 0..<36 {
            if [8, 13, 18, 23].contains(index) {
                guard bytes[index] == 0x2D else { return false }
            } else {
                let byte = bytes[index]
                guard (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) else { return false }
            }
        }
        return true
    }

    /// Formats confidence scores with two decimal places for stable debug markers.
    private static func formatHundredths(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded(.toNearestOrAwayFromZero))
        return "\(hundredths / 100).\(hundredths % 100 < 10 ? "0" : "")\(hundredths % 100)"
    }
}

/// Injectable filesystem and logging adapters used by preview-provider debug probes.
struct PreviewProviderDebugDependencies {
    let loadingIndicatorDelay: Duration
    let tokenReader: @Sendable (URL) -> String?
    let contentTypeIdentifier: @Sendable (URL) throws -> String?
    let markerObserver: (@MainActor (String) -> Void)?
    let provenanceObserver: (@MainActor (String) -> Void)?
    let renderMermaidBlocks: MermaidBlockRenderOperation?
    let makeMermaidAttachment: MermaidAttachmentFactory?
    let requestedMermaidWidth: MermaidRequestedWidthProvider?
    let mermaidResultObserver: MermaidRenderResultObserver?
    let runtimeIdentity: @MainActor () -> QuickLookProviderRuntimeIdentity
    let configurationLoader: @Sendable () -> RenderConfiguration
    let previewTimeLimit: Duration

    /// Creates provider probe dependencies, defaulting to the extension's local read-only adapters.
    init(
        loadingIndicatorDelay: Duration = SharedPreviewViewController.loadingIndicatorDelay,
        tokenReader: @escaping @Sendable (URL) -> String? = PreviewProviderMarkerSerializer.readToken,
        contentTypeIdentifier: @escaping @Sendable (URL) throws -> String? = { url in
            try url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        },
        markerObserver: (@MainActor (String) -> Void)? = nil,
        provenanceObserver: (@MainActor (String) -> Void)? = nil,
        renderMermaidBlocks: MermaidBlockRenderOperation? = nil,
        makeMermaidAttachment: MermaidAttachmentFactory? = nil,
        requestedMermaidWidth: MermaidRequestedWidthProvider? = nil,
        mermaidResultObserver: MermaidRenderResultObserver? = nil,
        runtimeIdentity: @escaping @MainActor () -> QuickLookProviderRuntimeIdentity = {
            QuickLookProviderRuntimeIdentity.from(extensionBundle: Bundle(for: PreviewViewController.self))
        },
        configurationLoader: @escaping @Sendable () -> RenderConfiguration = { PreviewViewController.savedConfiguration() },
        previewTimeLimit: Duration = InspectionWatchdog.previewLimit
    ) {
        self.loadingIndicatorDelay = loadingIndicatorDelay
        self.tokenReader = tokenReader
        self.contentTypeIdentifier = contentTypeIdentifier
        self.markerObserver = markerObserver
        self.provenanceObserver = provenanceObserver
        self.renderMermaidBlocks = renderMermaidBlocks
        self.makeMermaidAttachment = makeMermaidAttachment
        self.requestedMermaidWidth = requestedMermaidWidth
        self.mermaidResultObserver = mermaidResultObserver
        self.runtimeIdentity = runtimeIdentity
        self.configurationLoader = configurationLoader
        self.previewTimeLimit = previewTimeLimit
    }
}
#endif

/// Quick Look owns request lifetime and response only; all inspection/rendering is shared.
final class PreviewViewController: SharedPreviewViewController, @preconcurrency QLPreviewingController {
    private let requestLogger = Logger(subsystem: "com.glimt.app", category: "preview")
    private var pending: Task<Void, Never>?
    private var activeRequest = UUID()
#if DEBUG
    /// Shown only while General › Build marker is on (configuration.showsDebugBuildMarker).
    private var debugBuildMarker: NSView?
#endif
#if DEBUG || GLIMT_TESTING
    private let debugDependencies: PreviewProviderDebugDependencies
    /// Creates the Quick Look preview controller with injectable logging and marker dependencies.
    init(debugDependencies: PreviewProviderDebugDependencies = .init(),
         vcsProviders: [any VCSProvider] = [SVNProvider(), GitProvider()]) {
        self.debugDependencies = debugDependencies
        super.init(configuration: .init(), vcsProviders: vcsProviders,
                   renderMermaidBlocks: debugDependencies.renderMermaidBlocks,
                   makeMermaidAttachment: debugDependencies.makeMermaidAttachment,
                   requestedMermaidWidth: debugDependencies.requestedMermaidWidth,
                   mermaidResultObserver: debugDependencies.mermaidResultObserver)
    }
    /// Adapts the AppKit initializer to the debug dependency defaults.
    convenience init(nibName: NSNib.Name?, bundle: Bundle?) { self.init(debugDependencies: .init()) }
    /// Rejects storyboard construction because Quick Look owns the extension request lifecycle.
    required init?(coder: NSCoder) {
        debugDependencies = .init()
        super.init(coder: coder)
        configuration = .init()
    }
#else
    /// Creates the production provider with the saved render configuration.
    override init(configuration: RenderConfiguration = .init()) {
        super.init(configuration: configuration)
    }
    /// Adapts the AppKit initializer to the shared default render configuration.
    convenience init(nibName: NSNib.Name?, bundle: Bundle?) { self.init(configuration: .init()) }
    /// Rejects storyboard construction because Quick Look owns the extension request lifecycle.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configuration = .init()
    }
#endif

    /// Installs the shared preview and optional debug-only build marker after view creation.
    override func viewDidLoad() {
        super.viewDidLoad()
#if DEBUG
        let identity = QuickLookProviderRuntimeIdentity.from(extensionBundle: Bundle(for: PreviewViewController.self))
        // A small icon keeps the footer free for status; the build identity is in the tooltip.
        let marker = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil) ?? NSImage())
        marker.identifier = NSUserInterfaceItemIdentifier("QuickLookDebugBuildMarker")
        marker.symbolConfiguration = .init(textStyle: .footnote)
        marker.contentTintColor = .secondaryLabelColor
        marker.toolTip = identity.debugBuildTooltip
        marker.setAccessibilityLabel(identity.debugBuildTooltip)
        debugBuildMarker = marker
        updateDebugBuildMarker()
#endif
    }

#if DEBUG
    /// Shows the marker only when current settings enable it for this Debug build.
    private func updateDebugBuildMarker() {
        let wanted = configuration.showsDebugBuildMarker ? debugBuildMarker : nil
        if footerStrip.trailingAccessory !== wanted { footerStrip.trailingAccessory = wanted }
    }
#endif

    /// Loads read-only shared settings away from the main actor, falling back to factory values.
    nonisolated static func savedConfiguration(
        homeDirectory: URL = SettingsStore.realHomeDirectory
    ) -> RenderConfiguration {
        do {
            let settings = try SettingsStore.shared(readOnly: true, homeDirectory: homeDirectory).loadV3().settings
            GlimtDebugLog.shared.setEnabled(settings.general.debugLoggingEnabled)
            return RenderConfiguration(settings: settings)
        } catch {
            Logger(subsystem: "com.glimt.app", category: "settings").warning("Shared settings unavailable; using factory render configuration.")
            GlimtDebugLog.shared.setEnabled(false)
            return RenderConfiguration()
        }
    }

    /// Cancels the outstanding Finder request if the provider controller is released.
    deinit { pending?.cancel() }

    /// Starts a cancellable preview request and completes only the newest Finder request.
    /// A request still inspecting after the loading delay replies early so Quick Look shows the
    /// loading indicator (ADR-040); a later failure is then shown in the view instead of the reply.
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // A newer Finder request supersedes the previous one; its task is cancelled before identity changes.
        pending?.cancel()
        let id = UUID()
        activeRequest = id
        let requestLogger = self.requestLogger
        let startTime = DispatchTime.now().uptimeNanoseconds
#if DEBUG || GLIMT_TESTING
        let dependencies = debugDependencies
#endif
        let reply = PreviewRequestReply(handler)
#if DEBUG || GLIMT_TESTING
        scheduleLoadingIndicator(after: dependencies.loadingIndicatorDelay) { reply.send(nil) }
#else
        scheduleLoadingIndicator { reply.send(nil) }
#endif
        pending = Task { @MainActor [weak self] in
            do {
                self?.cancelVCSInspection()
#if DEBUG || GLIMT_TESTING
                let token = await Task.detached(priority: .userInitiated) { dependencies.tokenReader(url) }.value
                if let token, PreviewProviderMarkerSerializer.isCanonicalToken(token) {
                    requestLogger.info("GLIMT_PREVIEW_BEGIN token=\(token, privacy: .public)")
                    if let marker = QuickLookProviderProvenanceMarker.serialize(
                        token: token,
                        provider: .preview,
                        phase: .requestReceived,
                        identity: dependencies.runtimeIdentity()
                    ) {
                        if let observer = dependencies.provenanceObserver { observer(marker) }
                        else { requestLogger.info("\(marker, privacy: .public)") }
                    }
                }
                let configuration = await Task.detached { dependencies.configurationLoader() }.value
                let prepared = try await SharedPreviewPipeline.preview(for: url, configuration: configuration,
                    timeLimit: dependencies.previewTimeLimit, contentTypeIdentifier: dependencies.contentTypeIdentifier)
#else
                let configuration = await Task.detached { Self.savedConfiguration() }.value
                let prepared = try await SharedPreviewPipeline.preview(for: url, configuration: configuration)
#endif
                guard let self, self.activeRequest == id, !Task.isCancelled else {
                    requestLogger.debug("Preview request discarded after cancellation or supersession")
                    GlimtDebugLog.shared.info("Preview request superseded or cancelled.")
                    reply.send(CancellationError())
                    return
                }
                self.configuration = prepared.configuration
#if DEBUG
                self.updateDebugBuildMarker()
#endif
                self.display(prepared.inspection, inspecting: url)
                requestLogger.debug("Preview prepared; type=\(prepared.inspection.resolution.typeID, privacy: .private) sampleBytes=\(prepared.inspection.sampleByteCount, privacy: .private) complete=\(prepared.inspection.sampleIsComplete, privacy: .private)")
                // Catalog type ID, counts and timing only; never the file's name, path or content.
                GlimtDebugLog.shared.info("Preview prepared; type=\(prepared.inspection.resolution.typeID) sampleBytes=\(prepared.inspection.sampleByteCount) complete=\(prepared.inspection.sampleIsComplete) elapsedMs=\((DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000)")
#if DEBUG || GLIMT_TESTING
                let preparation = prepared.inspection
                if let token, let marker = PreviewProviderMarkerSerializer.serialize(token: token, provider: "preview",
                    phase: "display-prepared", typeID: preparation.resolution.typeID,
                    confidence: preparation.resolution.confidence.value,
                    scores: preparation.resolution.evidence.map { ($0.signalKind, $0.score.value) },
                    sampleByteCount: preparation.sampleByteCount, sampleIsComplete: preparation.sampleIsComplete) {
                    if let observer = dependencies.markerObserver { observer(marker) }
                    else { requestLogger.info("\(marker, privacy: .public)") }
                }
#endif
                reply.send(nil)
            } catch {
                let wasCancelled = self == nil || Task.isCancelled
                if wasCancelled {
                    requestLogger.debug("Preview request cancelled")
                    GlimtDebugLog.shared.info("Preview request cancelled.")
                } else {
                    // Log only the error type; localized errors may embed the user's path or filename.
                    requestLogger.error("Preview request failed; errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                    GlimtDebugLog.shared.error("Preview request failed; errorType=\(String(reflecting: type(of: error)))")
                }
                // Cancellation means a newer request owns the view; leave its loading state alone.
                if !wasCancelled, let self, self.activeRequest == id {
                    if reply.hasReplied { self.showLoadFailure() } else { self.hideLoadingIndicator() }
                }
                reply.send(wasCancelled ? CancellationError() : error)
            }
        }
    }
}

/// Completes one Quick Look request exactly once, whether early for the loading indicator or at the end.
@MainActor
private final class PreviewRequestReply {
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }

    var hasReplied: Bool { handler == nil }

    func send(_ error: Error?) {
        let pending = handler
        handler = nil
        pending?(error)
    }
}
