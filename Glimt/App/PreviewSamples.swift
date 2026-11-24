import Foundation
import InspectorCore

/// Selection is session UI state. Product examples are the catalog's canonical Showcase files.
enum PreviewSamples {
    /// A bundled preview document identified by its display title and resource path.
    struct Example { let title: String; let path: String }
    /// Selects fixture examples from the catalog, falling back to Markdown for unknown sections.
    static func examples(for section: String) -> [Example] {
        let settingsSection = ["sourceThemes", "sourceLanguages"].contains(section) ? "source" : section
        let matches = FormatCatalog.supported.filter { $0.settingsSection == settingsSection }
        let formats = section == "rendering" ? FormatCatalog.supported
            : matches.isEmpty ? FormatCatalog.supported.filter { $0.id == .markdown } : matches
        return formats.flatMap { format in
            (format.showcaseFixture.map { [Example(title: format.displayName, path: $0)] } ?? [])
                + (format.showcaseVariants ?? []).map { Example(title: $0.title, path: $0.path) }
        }.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            return titleOrder == .orderedSame
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : titleOrder == .orderedAscending
        }
    }
    /// Resolves the first catalog example for a settings section, if it is bundled or available in a debug checkout.
    static func url(for section: String, bundle: Bundle = .main) -> URL? { examples(for: section).first.flatMap { url(for: $0, bundle: bundle) } }
    /// Resolves a fixture by its preserved relative path and rejects traversal outside fixture roots.
    static func url(for example: Example, bundle: Bundle = .main) -> URL? {
        // A folder reference preserves relative paths; basenames are not globally unique.
        guard !example.path.contains(".."), !example.path.hasPrefix("/") else { return nil }
        if example.path.hasPrefix("Showcase/"), let resources = bundle.resourceURL {
            let bundled = resources.appendingPathComponent(example.path)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
#if DEBUG
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let url = directory.appendingPathComponent("Fixtures/" + example.path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            directory.deleteLastPathComponent()
        }
#endif
        return nil
    }
}
