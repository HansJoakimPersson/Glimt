import AppKit
import Foundation

/// Glimt's version as built into a bundle's Info.plist from `Config/Version.xcconfig`.
///
/// `CFBundleShortVersionString` holds the SemVer core, `CFBundleVersion` the build number and
/// `GlimtPrerelease` the pre-release identifier (`alpha.N`, `beta.N`, `rc.N`; empty when stable).
struct GlimtVersion: Equatable {
    static let prereleaseKey = "GlimtPrerelease"

    let marketingVersion: String
    let buildNumber: String
    let prerelease: String?

    init?(infoDictionary: [String: Any]?) {
        guard let marketing = infoDictionary?["CFBundleShortVersionString"] as? String,
              let build = infoDictionary?["CFBundleVersion"] as? String else { return nil }
        marketingVersion = marketing
        buildNumber = build
        let prerelease = (infoDictionary?[Self.prereleaseKey] as? String) ?? ""
        self.prerelease = prerelease.isEmpty ? nil : prerelease
    }

    /// The running app's version, or nil when its Info.plist lacks version keys.
    static var current: GlimtVersion? { GlimtVersion(infoDictionary: Bundle.main.infoDictionary) }

    var isPrerelease: Bool { prerelease != nil }

    /// SemVer 2.0 string, for example `0.1.0-beta.1`; it matches the release tag without its `v`.
    var semanticVersion: String {
        guard let prerelease else { return marketingVersion }
        return "\(marketingVersion)-\(prerelease)"
    }

    /// Human-readable version for the About window, for example `0.1.0 Beta 1`.
    var displayVersion: String {
        guard let prerelease else { return marketingVersion }
        let parts = prerelease.split(separator: ".", maxSplits: 1)
        let stages = ["alpha": "Alpha", "beta": "Beta", "rc": "RC"]
        guard parts.count == 2, let stage = stages[String(parts[0])] else {
            return "\(marketingVersion) \(prerelease)"
        }
        return "\(marketingVersion) \(stage) \(parts[1])"
    }

    /// Options for the standard About panel, which shows them as "Version 0.1.0 Beta 1 (1)".
    var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [.applicationVersion: displayVersion, .version: buildNumber]
    }
}
