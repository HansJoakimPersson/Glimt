import Foundation

/// Produces a thumbnail-safe summary from a parsed Xcode string catalog without showing localized text.
public enum AppleStringCatalogSummary {
    /// Returns a count-only summary for structurally recognizable `.xcstrings` JSON.
    public static func make(from value: StructuredValue) -> String? {
        guard case .object(let root) = value,
              !containsDuplicateKeys(value),
              case .string(let version)? = root.first(where: { $0.key == "version" })?.value,
              version == "1.0",
              case .string(let sourceLanguage)? = root.first(where: { $0.key == "sourceLanguage" })?.value,
              !sourceLanguage.isEmpty, sourceLanguage.utf8.count <= 128,
              case .object(let strings)? = root.first(where: { $0.key == "strings" })?.value else { return nil }
        var languages = Set<String>()
        for entry in strings {
            guard case .object(let properties) = entry.value else { return nil }
            if case .object(let localizations)? = properties.first(where: { $0.key == "localizations" })?.value {
                languages.formUnion(localizations.map(\.key))
            } else if properties.contains(where: { $0.key == "localizations" }) {
                return nil
            }
        }
        return "String catalog · \(strings.count) \(strings.count == 1 ? "string" : "strings") · \(languages.count) \(languages.count == 1 ? "language" : "languages")"
    }

    private static func containsDuplicateKeys(_ value: StructuredValue) -> Bool {
        switch value {
        case .object(let members):
            var keys = Set<String>()
            for member in members where !keys.insert(member.key).inserted || containsDuplicateKeys(member.value) {
                return true
            }
            return false
        case .array(let values): return values.contains(where: containsDuplicateKeys)
        default: return false
        }
    }
}
