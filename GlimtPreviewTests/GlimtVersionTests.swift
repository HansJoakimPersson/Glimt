import Foundation
import XCTest

final class GlimtVersionTests: XCTestCase {
    // MARK: Labels

    func testBetaLabelsSemanticAndDisplayVersion() throws {
        let version = try XCTUnwrap(GlimtVersion(infoDictionary: info("0.1.0", "1", "beta.1")))
        XCTAssertEqual(version.semanticVersion, "0.1.0-beta.1")
        XCTAssertEqual(version.displayVersion, "0.1.0 Beta 1")
        XCTAssertEqual(version.buildNumber, "1")
        XCTAssertTrue(version.isPrerelease)
    }

    func testAlphaAndReleaseCandidateLabels() throws {
        XCTAssertEqual(GlimtVersion(infoDictionary: info("0.2.0", "4", "alpha.3"))?.displayVersion, "0.2.0 Alpha 3")
        XCTAssertEqual(GlimtVersion(infoDictionary: info("1.0.0", "9", "rc.2"))?.displayVersion, "1.0.0 RC 2")
    }

    func testStableReleaseHasNoPrereleaseLabel() throws {
        for prerelease: String? in ["", nil] {
            let version = try XCTUnwrap(GlimtVersion(infoDictionary: info("1.0.0", "12", prerelease)))
            XCTAssertEqual(version.semanticVersion, "1.0.0")
            XCTAssertEqual(version.displayVersion, "1.0.0")
            XCTAssertFalse(version.isPrerelease)
        }
    }

    func testMissingVersionKeysAreRejected() {
        XCTAssertNil(GlimtVersion(infoDictionary: nil))
        XCTAssertNil(GlimtVersion(infoDictionary: ["CFBundleVersion": "1"]))
        XCTAssertNil(GlimtVersion(infoDictionary: ["CFBundleShortVersionString": "1.0.0"]))
    }

    func testUnknownPrereleaseStageIsShownVerbatim() {
        XCTAssertEqual(GlimtVersion(infoDictionary: info("1.0.0", "1", "preview.1"))?.displayVersion, "1.0.0 preview.1")
    }

    // MARK: Built bundles

    func testEveryBuiltBundleCarriesTheConfiguredVersion() throws {
        let configured = try configuredVersion()
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let plugIns = host.bundleURL.appendingPathComponent("Contents/PlugIns")
        let extensions = try ["GlimtPreview.appex", "GlimtThumbnail.appex"].map {
            try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent($0)))
        }
        for bundle in [host] + extensions {
            XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                           configured["MARKETING_VERSION"], bundle.bundleIdentifier ?? "bundle")
            XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                           configured["CURRENT_PROJECT_VERSION"], bundle.bundleIdentifier ?? "bundle")
        }
        let hostVersion = try XCTUnwrap(GlimtVersion(infoDictionary: host.infoDictionary))
        XCTAssertEqual(hostVersion.prerelease, configured["GLIMT_PRERELEASE"].flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Helpers

    private func info(_ marketing: String, _ build: String, _ prerelease: String?) -> [String: Any] {
        var info: [String: Any] = ["CFBundleShortVersionString": marketing, "CFBundleVersion": build]
        if let prerelease { info["GlimtPrerelease"] = prerelease }
        return info
    }

    /// Reads `Config/Version.xcconfig`, the single version source, from the checkout under test.
    private func configuredVersion() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Config/Version.xcconfig"), encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("//") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}
