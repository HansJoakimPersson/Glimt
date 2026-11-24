import AppKit
import Foundation
import XCTest

final class GlimtQuickLookDiagnosticsTests: XCTestCase {
    @MainActor
    func testSnapshotDeduplicatesCopiesAndSeparatesLaunchPreferenceFromProviderSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let running = try makeApp(at: root.appendingPathComponent("Running.app"))
        let other = try makeApp(at: root.appendingPathComponent("Other Copy.app"))
        let snapshot = GlimtQuickLookDiagnostics.makeSnapshot(
            runningAppURL: running,
            launchServicesAppURLs: [other, other.appendingPathComponent("Contents/.."), running],
            launchServicesPreferredAppForLaunchingURL: other
        )

        XCTAssertEqual(snapshot.installations.count, 2)
        XCTAssertEqual(snapshot.installations.filter(\.isRunningApp).count, 1)
        XCTAssertEqual(snapshot.installations.filter(\.isLaunchServicesPreferredAppForLaunching).map(\.url), [other])
        XCTAssertEqual(snapshot.launchServicesPreferredAppForLaunchingURL, other)
        XCTAssertEqual(snapshot.actualPreviewProvider, .unknownUntilRuntimeRequest)
        XCTAssertEqual(snapshot.actualThumbnailProvider, .unknownUntilRuntimeRequest)
        XCTAssertEqual(snapshot.previewRegistration, .notVerifiedInSandbox)
        XCTAssertEqual(snapshot.observedPreviewDuringCurrentTest, .notVerifiedInSandbox)
    }

    @MainActor
    func testSnapshotReportsValidEmbeddedExtensionsForMultipleCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let running = try makeApp(at: root.appendingPathComponent("Glimt.app"))
        let other = try makeApp(at: root.appendingPathComponent("Glimt Copy.app"))
        let snapshot = GlimtQuickLookDiagnostics.makeSnapshot(
            runningAppURL: running,
            launchServicesAppURLs: [other],
            launchServicesPreferredAppForLaunchingURL: nil
        )

        XCTAssertEqual(snapshot.installations.count, 2)
        for installation in snapshot.installations {
            XCTAssertEqual(installation.bundleIdentifier, GlimtQuickLookDiagnostics.appIdentifier)
            XCTAssertEqual(installation.version, "2.4")
            XCTAssertEqual(installation.build, "204")
            XCTAssertEqual(installation.previewExtension, .identified(
                bundleIdentifier: GlimtQuickLookDiagnostics.previewIdentifier,
                extensionPoint: GlimtQuickLookDiagnostics.previewExtensionPoint
            ))
            XCTAssertEqual(installation.thumbnailExtension, .identified(
                bundleIdentifier: GlimtQuickLookDiagnostics.thumbnailIdentifier,
                extensionPoint: GlimtQuickLookDiagnostics.thumbnailExtensionPoint
            ))
        }
    }

    @MainActor
    func testSnapshotReportsInconsistentExtensionIdentityAndPoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root.appendingPathComponent("Glimt.app"),
                              previewID: "com.example.other.preview",
                              thumbnailPoint: "com.example.wrong-point")
        let snapshot = GlimtQuickLookDiagnostics.makeSnapshot(
            runningAppURL: app, launchServicesAppURLs: [], launchServicesPreferredAppForLaunchingURL: nil
        )
        let installation = try XCTUnwrap(snapshot.installations.first)
        XCTAssertEqual(installation.previewExtension, .bundleIdentifierMismatch(actual: "com.example.other.preview"))
        XCTAssertEqual(installation.thumbnailExtension, .extensionPointMismatch(actual: "com.example.wrong-point"))
        XCTAssertEqual(snapshot.actualPreviewProvider, .unknownUntilRuntimeRequest)
    }

    @MainActor
    func testSnapshotKeepsCandidateWithMissingBundleMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Glimt Missing Metadata.app", isDirectory: true)
        try FileManager.default.createDirectory(at: missing.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let snapshot = GlimtQuickLookDiagnostics.makeSnapshot(
            runningAppURL: missing,
            launchServicesAppURLs: [],
            launchServicesPreferredAppForLaunchingURL: nil
        )
        let installation = try XCTUnwrap(snapshot.installations.first)
        XCTAssertNil(installation.bundleIdentifier)
        XCTAssertNil(installation.version)
        XCTAssertEqual(installation.previewExtension, .missing)
        XCTAssertEqual(installation.thumbnailExtension, .missing)
        XCTAssertEqual(snapshot.actualPreviewProvider, .unknownUntilRuntimeRequest)
    }

    func testRuntimeProvenanceMarkerIsTokenCorrelatedAndContainsExtensionBundleIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glimt path with spaces", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApp(at: root.appendingPathComponent("Glimt.app"))
        let extensionURL = appURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex", isDirectory: true)
        let bundle = try XCTUnwrap(Bundle(url: extensionURL))
        let identity = QuickLookProviderRuntimeIdentity.from(extensionBundle: bundle)
        let token = "01234567-89ab-cdef-0123-456789abcdef"
        let marker = try XCTUnwrap(QuickLookProviderProvenanceMarker.serialize(
            token: token, provider: .preview, phase: .requestReceived, identity: identity
        ))

        XCTAssertTrue(marker.hasPrefix("GLIMT_PROVIDER_PROVENANCE_V1 token=\(token) provider=preview phase=request-received "))
        XCTAssertTrue(marker.contains("extensionID=com.glimt.app.preview"))
        XCTAssertTrue(marker.contains("appID=com.glimt.app appVersion=2.4 appBuild=204"))
        XCTAssertTrue(marker.contains("extensionURL=file://"))
        XCTAssertTrue(marker.contains("Glimt%20path%20with%20spaces"))
        XCTAssertFalse(marker.contains("inspected-file"))
        XCTAssertEqual(identity.debugBuildLabel, "DEBUG · 2.4 (204)")
    }

    func testDebugBuildLabelsShowTheExtensionExecutableLinkTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApp(at: root.appendingPathComponent("Glimt.app"))
        let extensionURL = appURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex", isDirectory: true)
        let executable = extensionURL.appendingPathComponent("Contents/MacOS/GlimtThumbnail")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let linked = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9, minute: 5, second: 7)))
        try FileManager.default.setAttributes([.modificationDate: linked], ofItemAtPath: executable.path)

        let identity = QuickLookProviderRuntimeIdentity.from(extensionBundle: try XCTUnwrap(Bundle(url: extensionURL)))

        XCTAssertEqual(identity.builtAt, linked)
        XCTAssertEqual(identity.debugBuildLabel, "DEBUG · 2026-11-18 09:05:07")
        XCTAssertEqual(identity.debugThumbnailStamp, "11-18 09:05:07")
        XCTAssertEqual(identity.debugBuildTooltip, "Debug build 2026-11-18 09:05:07 · Glimt 2.4 (204)")
    }

    func testRuntimeProvenanceRejectsInvalidTokens() throws {
        let identity = QuickLookProviderRuntimeIdentity(
            extensionBundleURL: URL(fileURLWithPath: "/Applications/Glimt.app/Contents/PlugIns/GlimtPreview.appex"),
            extensionBundleIdentifier: GlimtQuickLookDiagnostics.previewIdentifier,
            appBundleIdentifier: GlimtQuickLookDiagnostics.appIdentifier,
            appVersion: "1.0",
            appBuild: "1"
        )
        XCTAssertNil(QuickLookProviderProvenanceMarker.serialize(
            token: "user-file-name", provider: .preview, phase: .requestReceived, identity: identity
        ))
        XCTAssertNil(QuickLookProviderProvenanceMarker.serialize(
            token: "01234567-89ab-cdef-0123-456789ABCDEF", provider: .preview, phase: .requestReceived, identity: identity
        ))
    }

    @MainActor
    func testDiagnosticsReportSeparatesRegistryEvidenceFromActualProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root.appendingPathComponent("Glimt.app"))
        let snapshot = GlimtQuickLookDiagnostics.makeSnapshot(
            runningAppURL: app, launchServicesAppURLs: [], launchServicesPreferredAppForLaunchingURL: app
        )
        let controller = GlimtQuickLookDiagnosticsViewController(snapshot: snapshot)
        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.reportText.contains("LaunchServices-preferred app for launching:"))
        XCTAssertTrue(controller.reportText.contains("Quick Look Preview registered: Not verified in the sandboxed app"))
        XCTAssertTrue(controller.reportText.contains("Actual Preview provider selected for a file: Unknown"))
        XCTAssertTrue(controller.reportText.contains("does not claim it will parse a file"))
        XCTAssertTrue(allViews(beneath: controller.view).compactMap { $0 as? NSTextField }.contains {
            $0.identifier?.rawValue == "QuickLookDiagnosticsWorkflow"
                && $0.stringValue.contains("No callback or another provider")
        })
        XCTAssertTrue(GlimtQuickLookDiagnosticsViewController.terminalCommands.contains("pluginkit -m -A -D -vv"))
        let copyReport = try XCTUnwrap(allViews(beneath: controller.view).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == GlimtQuickLookDiagnosticsViewController.copyReportIdentifier
        })
        _ = copyReport.sendAction(copyReport.action, to: copyReport.target)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("Actual Preview provider selected") == true)
    }

    @MainActor
    private func allViews(beneath view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(beneath: $0) }
    }

    private func makeApp(at url: URL, previewID: String = GlimtQuickLookDiagnostics.previewIdentifier,
                         thumbnailPoint: String = GlimtQuickLookDiagnostics.thumbnailExtensionPoint) throws -> URL {
        let appInfo: [String: Any] = [
            "CFBundleIdentifier": GlimtQuickLookDiagnostics.appIdentifier,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "2.4",
            "CFBundleVersion": "204"
        ]
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try makeExtension(app: url, name: "GlimtPreview.appex", identifier: previewID,
                          point: GlimtQuickLookDiagnostics.previewExtensionPoint)
        try makeExtension(app: url, name: "GlimtThumbnail.appex", identifier: GlimtQuickLookDiagnostics.thumbnailIdentifier,
                          point: thumbnailPoint)
        return url
    }

    private func makeExtension(app: URL, name: String, identifier: String, point: String) throws {
        let contents = app.appendingPathComponent("Contents/PlugIns/\(name)/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundlePackageType": "XPC!",
            "NSExtension": ["NSExtensionPointIdentifier": point]
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
}
