import Foundation

#if DEBUG || GLIMT_TESTING
/// Quick Look extension kind associated with one provider lifecycle marker.
enum QuickLookProviderKind: String, Sendable {
    case preview
    case thumbnail
}

/// Lifecycle phase recorded for a Preview or Thumbnail provider request.
enum QuickLookRequestPhase: String, Sendable {
    case requestReceived = "request-received"
}

/// Runtime bundle identity for a synthetic, token-correlated Quick Look request.
struct QuickLookProviderRuntimeIdentity: Equatable, Sendable {
    let extensionBundleURL: URL
    let extensionBundleIdentifier: String?
    let appBundleIdentifier: String?
    let appVersion: String?
    let appBuild: String?
    /// When the running extension executable was last linked; local Debug builds share one version
    /// and build number, so this is what tells one build from the next.
    var builtAt: Date? = nil

    /// Tooltip for the Quick Look footer's debug icon, e.g.
    /// `Debug build 2026-11-18 11:42:07 · Glimt 1.0.0 (1)`.
    var debugBuildTooltip: String {
        let version = "Glimt \(appVersion ?? "?") (\(appBuild ?? "?"))"
        guard let builtAt else { return "Debug build · \(version)" }
        return "Debug build " + Self.format(builtAt, "yyyy-MM-dd HH:mm:ss") + " · " + version
    }

    /// Label form of the build identity, e.g. `DEBUG · 2026-11-18 11:42:07`.
    var debugBuildLabel: String {
        guard let builtAt else { return "DEBUG · \(appVersion ?? "?") (\(appBuild ?? "?"))" }
        return "DEBUG · " + Self.format(builtAt, "yyyy-MM-dd HH:mm:ss")
    }

    /// Compact badge for Finder thumbnails, e.g. `11-18 11:42:07`, small enough for a 128 pt icon.
    var debugThumbnailStamp: String {
        guard let builtAt else { return debugBuildLabel }
        return Self.format(builtAt, "MM-dd HH:mm:ss")
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Reads only bundle metadata from the extension and its containing app bundle.
    static func from(extensionBundle: Bundle) -> QuickLookProviderRuntimeIdentity {
        let extensionURL = extensionBundle.bundleURL.standardizedFileURL
        let appURL = extensionURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appBundle = appURL.pathExtension == "app" ? Bundle(url: appURL) : nil
        return QuickLookProviderRuntimeIdentity(
            extensionBundleURL: extensionURL,
            extensionBundleIdentifier: extensionBundle.bundleIdentifier,
            appBundleIdentifier: appBundle?.bundleIdentifier,
            appVersion: appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: appBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            builtAt: try? extensionBundle.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
    }
}

/// Emits no marker unless the request carries the UUID xattr used by explicit synthetic-fixture diagnostics.
enum QuickLookProviderProvenanceMarker {
    static func serialize(
        token: String,
        provider: QuickLookProviderKind,
        phase: QuickLookRequestPhase,
        identity: QuickLookProviderRuntimeIdentity
    ) -> String? {
        guard isCanonicalToken(token), identity.extensionBundleURL.isFileURL else { return nil }
        let extensionURL = identity.extensionBundleURL.absoluteString
        guard extensionURL.utf8.count <= 2_048 else { return nil }
        return "GLIMT_PROVIDER_PROVENANCE_V1 token=\(token) provider=\(provider.rawValue) phase=\(phase.rawValue) "
            + "extensionID=\(safeField(identity.extensionBundleIdentifier)) "
            + "appID=\(safeField(identity.appBundleIdentifier)) "
            + "appVersion=\(safeField(identity.appVersion)) appBuild=\(safeField(identity.appBuild)) "
            + "extensionURL=\(extensionURL)"
    }

    static func isCanonicalToken(_ token: String) -> Bool {
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

    private static func safeField(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 80,
              value.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
                    || (0x61...0x7A).contains($0) || [0x2D, 0x2E, 0x2B, 0x5F].contains($0)
              }) else { return "unknown" }
        return value
    }
}
#endif
