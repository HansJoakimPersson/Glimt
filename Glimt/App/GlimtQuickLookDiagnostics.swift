import AppKit
import Foundation

/// Verification outcome for an embedded Quick Look bundle's identity and extension point.
enum GlimtQuickLookBundleCheck: Equatable, Sendable {
    case identified(bundleIdentifier: String, extensionPoint: String)
    case missing
    case metadataUnavailable
    case bundleIdentifierMismatch(actual: String)
    case extensionPointMismatch(actual: String)

    var summary: String {
        switch self {
        case let .identified(bundleIdentifier, extensionPoint):
            "Identified — \(bundleIdentifier), \(extensionPoint)"
        case .missing:
            "Missing from this app copy"
        case .metadataUnavailable:
            "Not verified — bundle metadata unavailable"
        case let .bundleIdentifierMismatch(actual):
            "Not verified — unexpected bundle ID \(actual)"
        case let .extensionPointMismatch(actual):
            "Not verified — unexpected extension point \(actual)"
        }
    }
}

/// Registration and routing facts unavailable to the sandboxed in-app diagnostic.
enum GlimtQuickLookSystemCheck: String, Equatable, Sendable {
    case notVerifiedInSandbox = "Not verified in the sandboxed app"
}

/// Provider-selection state; registration alone cannot establish a runtime winner.
enum GlimtQuickLookProviderSelection: Equatable, Sendable {
    case unknownUntilRuntimeRequest
}

/// Metadata observed for one Glimt application bundle and its embedded extensions.
struct GlimtQuickLookInstallation: Identifiable, Equatable, Sendable {
    let url: URL
    let bundleIdentifier: String?
    let version: String?
    let build: String?
    let isRunningApp: Bool
    let isLaunchServicesPreferredAppForLaunching: Bool
    let previewExtension: GlimtQuickLookBundleCheck
    let thumbnailExtension: GlimtQuickLookBundleCheck

    var id: String { url.path }
}

/// Read-only app-copy and embedded-bundle facts shown in the troubleshooting sheet.
struct GlimtQuickLookSnapshot: Equatable, Sendable {
    let runningAppURL: URL
    let runningAppBundleIdentifier: String?
    let runningAppVersion: String?
    let runningAppBuild: String?
    let launchServicesPreferredAppForLaunchingURL: URL?
    let installations: [GlimtQuickLookInstallation]
    let previewRegistration: GlimtQuickLookSystemCheck
    let thumbnailRegistration: GlimtQuickLookSystemCheck
    let previewEnabled: GlimtQuickLookSystemCheck
    let thumbnailEnabled: GlimtQuickLookSystemCheck
    let observedPreviewDuringCurrentTest: GlimtQuickLookSystemCheck
    let observedThumbnailDuringCurrentTest: GlimtQuickLookSystemCheck
    let actualPreviewProvider: GlimtQuickLookProviderSelection
    let actualThumbnailProvider: GlimtQuickLookProviderSelection
}

/// Collects sandbox-visible app bundle metadata without claiming system registration or routing.
enum GlimtQuickLookDiagnostics {
    static let appIdentifier = "com.glimt.app"
    static let previewIdentifier = "com.glimt.app.preview"
    static let thumbnailIdentifier = "com.glimt.app.thumbnail"
    static let previewExtensionPoint = "com.apple.quicklook.preview"
    static let thumbnailExtensionPoint = "com.apple.quicklook.thumbnail"

    /// Queries only LaunchServices app locations. It does not inspect PlugInKit, Finder routing or all files on disk.
    @MainActor
    static func snapshot(workspace: NSWorkspace = .shared, runningBundle: Bundle = .main) -> GlimtQuickLookSnapshot {
        makeSnapshot(
            runningAppURL: runningBundle.bundleURL,
            launchServicesAppURLs: workspace.urlsForApplications(withBundleIdentifier: appIdentifier),
            launchServicesPreferredAppForLaunchingURL: workspace.urlForApplication(withBundleIdentifier: appIdentifier)
        )
    }

    /// Builds a deterministic snapshot from the app and LaunchServices URLs supplied by the caller.
    static func makeSnapshot(
        runningAppURL: URL,
        launchServicesAppURLs: [URL],
        launchServicesPreferredAppForLaunchingURL: URL?
    ) -> GlimtQuickLookSnapshot {
        let runningURL = canonical(runningAppURL)
        let preferredURL = launchServicesPreferredAppForLaunchingURL.map(canonical)
        var seen = Set<String>()
        let candidateURLs = ([runningURL] + launchServicesAppURLs.map(canonical) + [preferredURL].compactMap { $0 })
            .filter { seen.insert($0.path).inserted }
        let installations = candidateURLs.map { url in
            installation(
                at: url,
                runningURL: runningURL,
                preferredURL: preferredURL
            )
        }
        let runningBundle = Bundle(url: runningURL)
        return GlimtQuickLookSnapshot(
            runningAppURL: runningURL,
            runningAppBundleIdentifier: runningBundle?.bundleIdentifier,
            runningAppVersion: runningBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            runningAppBuild: runningBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            launchServicesPreferredAppForLaunchingURL: preferredURL,
            installations: installations,
            previewRegistration: .notVerifiedInSandbox,
            thumbnailRegistration: .notVerifiedInSandbox,
            previewEnabled: .notVerifiedInSandbox,
            thumbnailEnabled: .notVerifiedInSandbox,
            observedPreviewDuringCurrentTest: .notVerifiedInSandbox,
            observedThumbnailDuringCurrentTest: .notVerifiedInSandbox,
            actualPreviewProvider: .unknownUntilRuntimeRequest,
            actualThumbnailProvider: .unknownUntilRuntimeRequest
        )
    }

    /// Reads version and embedded-extension metadata for one canonical app bundle URL.
    private static func installation(at url: URL, runningURL: URL, preferredURL: URL?) -> GlimtQuickLookInstallation {
        let bundle = Bundle(url: url)
        return GlimtQuickLookInstallation(
            url: url,
            bundleIdentifier: bundle?.bundleIdentifier,
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            isRunningApp: url == runningURL,
            isLaunchServicesPreferredAppForLaunching: url == preferredURL,
            previewExtension: extensionCheck(
                in: url,
                bundleName: "GlimtPreview.appex",
                expectedIdentifier: previewIdentifier,
                expectedPoint: previewExtensionPoint
            ),
            thumbnailExtension: extensionCheck(
                in: url,
                bundleName: "GlimtThumbnail.appex",
                expectedIdentifier: thumbnailIdentifier,
                expectedPoint: thumbnailExtensionPoint
            )
        )
    }

    /// Checks one embedded extension's presence, bundle identifier, and declared extension point.
    private static func extensionCheck(
        in appURL: URL,
        bundleName: String,
        expectedIdentifier: String,
        expectedPoint: String
    ) -> GlimtQuickLookBundleCheck {
        let extensionURL = appURL.appendingPathComponent("Contents/PlugIns/\(bundleName)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { return .missing }
        guard let bundle = Bundle(url: extensionURL),
              let actualIdentifier = bundle.bundleIdentifier else { return .metadataUnavailable }
        guard actualIdentifier == expectedIdentifier else {
            return .bundleIdentifierMismatch(actual: actualIdentifier)
        }
        guard let extensionInfo = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
              let actualPoint = extensionInfo["NSExtensionPointIdentifier"] as? String else {
            return .metadataUnavailable
        }
        guard actualPoint == expectedPoint else { return .extensionPointMismatch(actual: actualPoint) }
        return .identified(bundleIdentifier: actualIdentifier, extensionPoint: actualPoint)
    }

    /// Standardizes and resolves a bundle URL for stable duplicate comparison.
    private static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return URL(fileURLWithPath: path, isDirectory: false)
    }
}

/// Compact, read-only troubleshooting sheet opened from Inquiry.
@MainActor
final class GlimtQuickLookDiagnosticsViewController: NSViewController {
    static let preferredSize = NSSize(width: 640, height: 520)
    static let copyCommandsIdentifier = "QuickLookDiagnosticsCopyCommands"
    static let copyReportIdentifier = "QuickLookDiagnosticsCopyReport"
    static let reportIdentifier = "QuickLookDiagnosticsReport"

    let snapshot: GlimtQuickLookSnapshot
    private let reportView = NSTextView()
    private let commandView = NSTextView()

    /// Creates the diagnostics view from a captured snapshot, defaulting to current system state.
    init(snapshot: GlimtQuickLookSnapshot = GlimtQuickLookDiagnostics.snapshot()) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }

    /// Rejects storyboard construction because the diagnostic report is built from a snapshot.
    required init?(coder: NSCoder) { nil }

    /// Builds the read-only troubleshooting report and copyable local verification commands.
    override func loadView() {
        let title = NSTextField(labelWithString: "Quick Look Diagnostics")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "This snapshot describes Glimt app copies and embedded extension metadata. It does not identify the provider Finder selected for a file.")
        explanation.textColor = .secondaryLabelColor
        let workflow = NSTextField(wrappingLabelWithString:
            "To verify routing, request Preview with Space and a Thumbnail separately in Finder for a synthetic .swift, .ts or .md fixture. Correlate its token with GLIMT_PROVIDER_PROVENANCE_V1 and the existing FR005 marker. No callback or another provider is unverified/other-provider evidence; registration or enabled state alone does not prove routing.")
        workflow.textColor = .secondaryLabelColor
        workflow.identifier = NSUserInterfaceItemIdentifier("QuickLookDiagnosticsWorkflow")

        reportView.isEditable = false
        reportView.isSelectable = true
        reportView.drawsBackground = false
        reportView.string = reportText
        reportView.identifier = NSUserInterfaceItemIdentifier(Self.reportIdentifier)
        let reportScroll = NSScrollView()
        reportScroll.hasVerticalScroller = true
        reportScroll.autohidesScrollers = true
        reportScroll.documentView = reportView
        reportScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        let commandsHeading = NSTextField(labelWithString: "Read-only Terminal checks")
        commandsHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        commandView.isEditable = false
        commandView.isSelectable = true
        commandView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        commandView.string = Self.terminalCommands
        let commandScroll = NSScrollView()
        commandScroll.hasVerticalScroller = true
        commandScroll.autohidesScrollers = true
        commandScroll.documentView = commandView
        commandScroll.heightAnchor.constraint(equalToConstant: 82).isActive = true

        let copy = NSButton(title: "Copy Terminal Checks", target: self, action: #selector(copyCommands(_:)))
        copy.identifier = NSUserInterfaceItemIdentifier(Self.copyCommandsIdentifier)
        let copyReport = NSButton(title: "Copy Report", target: self, action: #selector(copyReport(_:)))
        copyReport.identifier = NSUserInterfaceItemIdentifier(Self.copyReportIdentifier)
        let done = NSButton(title: "Done", target: self, action: #selector(closeSheet(_:)))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, copyReport, copy, done])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, explanation, workflow, reportScroll, commandsHeading, commandScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let widthConstrainedViews: [NSView] = [explanation, workflow, reportScroll, commandScroll, buttons]
        for view in widthConstrainedViews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        self.view = stack
    }

    var reportText: String {
        var lines = [
            "Running app location: \(snapshot.runningAppURL.path)",
            "Running app bundle ID: \(snapshot.runningAppBundleIdentifier ?? "Not available")",
            "Running app version/build: \(snapshot.runningAppVersion ?? "Not available") / \(snapshot.runningAppBuild ?? "Not available")",
            "LaunchServices-preferred app for launching: \(snapshot.launchServicesPreferredAppForLaunchingURL?.path ?? "Not identified")",
            "LaunchServices app candidates (not a filesystem-wide inventory):"
        ]
        for installation in snapshot.installations {
            lines.append("  Location: \(installation.url.path)")
            lines.append("    Bundle ID: \(installation.bundleIdentifier ?? "Not available")")
            lines.append("    Version/build: \(installation.version ?? "Not available") / \(installation.build ?? "Not available")")
            lines.append("    Running app: \(installation.isRunningApp ? "Yes" : "No")")
            lines.append("    LaunchServices-preferred for launching: \(installation.isLaunchServicesPreferredAppForLaunching ? "Yes" : "No")")
            lines.append("    Embedded Preview: \(installation.previewExtension.summary)")
            lines.append("    Embedded Thumbnail: \(installation.thumbnailExtension.summary)")
        }
        lines += [
            "Quick Look Preview registered: \(snapshot.previewRegistration.rawValue)",
            "Quick Look Preview enabled: \(snapshot.previewEnabled.rawValue)",
            "Preview callback observed during this test: \(snapshot.observedPreviewDuringCurrentTest.rawValue)",
            "Actual Preview provider selected for a file: Unknown until a token-correlated runtime callback is observed.",
            "Quick Look Thumbnail registered: \(snapshot.thumbnailRegistration.rawValue)",
            "Quick Look Thumbnail enabled: \(snapshot.thumbnailEnabled.rawValue)",
            "Thumbnail callback observed during this test: \(snapshot.observedThumbnailDuringCurrentTest.rawValue)",
            "Actual Thumbnail provider selected for a file: Unknown until a token-correlated runtime callback is observed.",
            "Glimt does not claim it will parse a file based on installation or extension state alone."
        ]
        return lines.joined(separator: "\n")
    }

    static let terminalCommands = """
    pluginkit -m -A -D -vv -i com.glimt.app.preview
    pluginkit -m -A -D -vv -i com.glimt.app.thumbnail
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | grep -B 4 -A 6 -F 'com.glimt.app'
    log show --info --predicate 'subsystem == "com.glimt.app" AND eventMessage CONTAINS "GLIMT_PROVIDER_PROVENANCE_V1"' --last 10m
    """

    @objc private func copyCommands(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.terminalCommands, forType: .string)
    }

    @objc private func copyReport(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
    }

    @objc private func closeSheet(_ sender: Any?) {
        guard let window = view.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
