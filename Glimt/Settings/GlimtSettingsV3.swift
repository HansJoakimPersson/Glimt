import Foundation
import InspectorCore

// MARK: - Persisted v3 model (ADR-015)

/// Persisted settings, schema 4. General appearance applies to every format; per-format
/// appearance overrides are retired (ADR-022) and kept only as data. Formats & Views stores
/// ordered view lists per customized category and format. Decoding is lenient per field so one
/// invalid value never discards the file.
struct GlimtSettingsV3: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4
    static let maximumFormatEntries = 512
    static let maximumViewListLength = 32

    var schemaVersion = GlimtSettingsV3.currentSchemaVersion
    var general = GeneralSettingsV3()
    var customThemes: [CustomSourceTheme] = []
    /// Keyed by `FormatID.rawValue`. Unknown or planned identifiers are preserved, never resolved.
    var formats: [String: FormatSettings] = [:]
    var fileAssociations: [FileAssociation] = []
    /// Ordered active view IDs keyed by `ViewCategoryID.rawValue`; present only when customized.
    /// Unknown IDs are preserved and ignored by `ViewResolver`.
    var categoryProfiles: [String: [String]] = [:]
    /// Ordered active view IDs keyed by `FormatID.rawValue`; present only when customized.
    var formatOverrides: [String: [String]] = [:]

    static let factoryDefaults = GlimtSettingsV3()

    subscript(format: FormatID) -> FormatSettings {
        // Empty per-format records are represented by absence so resets restore inheritance cleanly.
        get { formats[format.rawValue] ?? FormatSettings() }
        set { formats[format.rawValue] = newValue.isEmpty ? nil : newValue }
    }

    /// Formats that still hold retired per-format appearance values, sorted by identifier.
    var formatsWithRetiredAppearance: [String] {
        formats.filter { $0.value.hasRetiredAppearance }.keys.sorted()
    }

    /// Explicit user action only: drops retired appearance data and keeps every other value.
    mutating func discardRetiredAppearance() {
        for key in formatsWithRetiredAppearance {
            let kept = formats[key]?.withoutRetiredAppearance()
            formats[key] = kept?.isEmpty == false ? kept : nil
        }
    }

    /// Clamps every value to its documented range. Idempotent; never changes `schemaVersion`.
    func normalized() -> GlimtSettingsV3 {
        // Bound collections and normalize every nested value before decoding results reach renderers.
        var result = self
        result.general = general.normalized()
        result.customThemes = customThemes.prefix(16).filter { !$0.id.isEmpty && $0.appearance != .system }.map { theme in
            var theme = theme; theme.name = String(theme.name.prefix(48)); theme.palette = theme.palette.normalized(); return theme
        }
        let kept = formats.keys.sorted().prefix(Self.maximumFormatEntries)
        result.formats = Dictionary(uniqueKeysWithValues: kept.compactMap { key in
            guard let value = formats[key]?.normalized(), !value.isEmpty else { return nil }
            return (key, value)
        })
        result.fileAssociations = fileAssociations.prefix(64).compactMap { $0.validated() }
        result.categoryProfiles = Self.normalizedViewLists(categoryProfiles)
        result.formatOverrides = Self.normalizedViewLists(formatOverrides)
        return result
    }

    /// Bounds entry count and list length and collapses duplicates; order and unknown IDs are kept.
    private static func normalizedViewLists(_ lists: [String: [String]]) -> [String: [String]] {
        let kept = lists.keys.sorted().prefix(maximumFormatEntries)
        return Dictionary(uniqueKeysWithValues: kept.compactMap { key in
            var seen = Set<String>()
            let views = (lists[key] ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(maximumViewListLength)
            return (key, Array(views))
        })
    }

    /// JSON keys used to decode the current settings document.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, general, customThemes, formats, fileAssociations, categoryProfiles, formatOverrides
    }

    /// Creates settings with the current schema version and factory defaults.
    init() {}

    /// Decodes each persisted preference independently, falling back to defaults for invalid fields.
    init(from decoder: Decoder) throws {
        // Decode fields independently: one invalid preference must not discard otherwise usable settings.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
        general = (try? c.decodeIfPresent(GeneralSettingsV3.self, forKey: .general)) ?? GeneralSettingsV3()
        customThemes = (try? c.decodeIfPresent(LenientArray<CustomSourceTheme>.self, forKey: .customThemes))?.elements ?? []
        formats = (try? c.decodeIfPresent([String: LenientFormatSettings].self, forKey: .formats))?.mapValues(\.value) ?? [:]
        fileAssociations = (try? c.decodeIfPresent(LenientArray<FileAssociation>.self, forKey: .fileAssociations))?.elements ?? []
        categoryProfiles = (try? c.decodeIfPresent(LenientDictionary<[String]>.self, forKey: .categoryProfiles))?.entries ?? [:]
        formatOverrides = (try? c.decodeIfPresent(LenientDictionary<[String]>.self, forKey: .formatOverrides))?.entries ?? [:]
    }
}

/// Supported wrapping behavior for source and plain-text previews.
enum WordWrapMode: String, Codable, CaseIterable, Sendable {
    case off, soft, hard
    var displayName: String {
        switch self { case .off: "Off"; case .soft: "Soft wrap"; case .hard: "Hard wrap" }
    }
}

/// Binary display units used to present the persisted byte limit.
enum DataLimitUnit: String, Codable, CaseIterable, Sendable {
    case kb, mb
    /// Binary units, labelled as such (D07, D54): 1 KiB = 1 024 bytes, 1 MiB = 1 048 576 bytes.
    var displayName: String { self == .kb ? "KiB" : "MiB" }
    var bytes: Int { self == .kb ? 1_024 : 1_048_576 }
}

/// Family and size form one override unit (D05).
struct FontSetting: Codable, Equatable, Sendable {
    static let families = GlimtSettings.fontFamilies
    static let sizeRange: ClosedRange<Double> = 9...32
    static let defaultSize = 12.0
    var family = "System Monospaced"
    var size: Double = Self.defaultSize

    /// Replaces unsupported font families and clamps point size to the persisted control range.
    func normalized() -> FontSetting {
        .init(family: Self.families.contains(family) ? family : "System Monospaced",
              size: size.isFinite ? min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) : Self.defaultSize)
    }
    var displayName: String {
        let points = size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)
        return "\(family), \(points) pt"
    }
}

/// One appearance's theme: the preset plus an optional custom palette that takes precedence when
/// it exists. Mirrors the v2 shape so migration is lossless.
struct ThemeChoice: Codable, Equatable, Sendable {
    var preset: SourceThemePreset = .glimtDefault
    var customThemeID: String?
}

/// Light and dark themes form one override unit (D05).
struct ThemeAssignment: Codable, Equatable, Sendable {
    var light = ThemeChoice()
    var dark = ThemeChoice()
}

/// Persisted general rendering preferences shared by the host and Quick Look extensions.
struct GeneralSettingsV3: Codable, Equatable, Sendable {
    static let lineLengthRange = 20...400
    static let tabsToSpacesRange = 0...16
    static let dataLimitRange = 65_536...1_048_576
    /// Tab stop used when `tabsToSpaces == 0` keeps tab characters (D06).
    static let keptTabStop = 4
    /// Prose families for rendered Markdown; code keeps `font` (the monospace font).
    static let textFontFamilies = ["System", "New York", "Helvetica Neue", "Georgia", "Avenir Next"]

    var themeAssignment = ThemeAssignment()
    /// App, preview and Quick Look appearance (D51). `.system` follows macOS; additive v3 field.
    var colorScheme: PreviewAppearance = .system
    var font = FontSetting()
    /// Text font for rendered prose; additive v3 field, missing or unknown values mean "System".
    var textFont = "System"
    var wordWrap: WordWrapMode = .soft
    var lineLength = 120
    var lineNumbers = true
    /// Repository inspection is opt-in; Quick Look performs no VCS reads while this is false.
    var vcsSupportEnabled = false
    var tabsToSpaces = 4
    /// Vertical guides at each indentation level in source previews; additive v3 field, on by default.
    var indentationGuides = true
    var dataLimitBytes = 1_048_576
    var dataLimitDisplayUnit: DataLimitUnit = .mb
    /// Opt-in local troubleshooting log shared by the app and both extensions (ADR-023); additive field.
    var debugLoggingEnabled = false
    /// Debug builds only: show the extension build time in Quick Look and thumbnails; additive field.
    var debugBuildMarker = true

    /// Returns settings with numeric values in their valid ranges.
    func normalized() -> GeneralSettingsV3 {
        // Keep every persisted numeric setting within the same bounds enforced by its UI control.
        var result = self
        result.font = font.normalized()
        if !Self.textFontFamilies.contains(textFont) { result.textFont = "System" }
        result.lineLength = Self.clampLineLength(lineLength)
        result.tabsToSpaces = Self.clampTabs(tabsToSpaces)
        result.dataLimitBytes = Self.clampDataLimit(dataLimitBytes)
        return result
    }
    /// Clamps the source line-length preference to the range exposed by settings controls.
    static func clampLineLength(_ value: Int) -> Int { min(max(value, lineLengthRange.lowerBound), lineLengthRange.upperBound) }
    /// Clamps tab replacement width; zero remains the sentinel for preserving tab characters.
    static func clampTabs(_ value: Int) -> Int { min(max(value, tabsToSpacesRange.lowerBound), tabsToSpacesRange.upperBound) }
    /// Rounds down to whole KiB, then clamps to 64 KiB … 1 MiB.
    static func clampDataLimit(_ value: Int) -> Int {
        // Store whole KiB values so display conversion and preview byte limits remain deterministic.
        min(max(value / 1_024 * 1_024, dataLimitRange.lowerBound), dataLimitRange.upperBound)
    }

    /// Creates the general rendering preference set with factory values.
    init() {}

    /// Accepted current-schema keys; retired fields are intentionally omitted and discarded.
    private enum CodingKeys: String, CodingKey {
        case themeAssignment, colorScheme, font, textFont, wordWrap, lineLength, lineNumbers, vcsSupportEnabled, tabsToSpaces, indentationGuides, dataLimitBytes, dataLimitDisplayUnit, debugLoggingEnabled, debugBuildMarker
    }
    /// Keys outside `CodingKeys`, such as the retired `thumbnails` group (D62), are read past and dropped on the next save.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /// Uses a decoded preference only when that field is valid; otherwise preserves its factory value.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        themeAssignment = value(.themeAssignment, themeAssignment)
        colorScheme = value(.colorScheme, colorScheme)
        font = value(.font, font)
        textFont = value(.textFont, textFont)
        wordWrap = value(.wordWrap, wordWrap)
        lineLength = value(.lineLength, lineLength)
        lineNumbers = value(.lineNumbers, lineNumbers)
        vcsSupportEnabled = value(.vcsSupportEnabled, vcsSupportEnabled)
        tabsToSpaces = value(.tabsToSpaces, tabsToSpaces)
        indentationGuides = value(.indentationGuides, indentationGuides)
        dataLimitBytes = value(.dataLimitBytes, dataLimitBytes)
        dataLimitDisplayUnit = value(.dataLimitDisplayUnit, dataLimitDisplayUnit)
        debugLoggingEnabled = value(.debugLoggingEnabled, debugLoggingEnabled)
        debugBuildMarker = value(.debugBuildMarker, debugBuildMarker)
    }
}

/// A per-format value with explicit enablement. `isEnabled == false` inherits General while the
/// value stays dormant so re-enabling restores it; enabled `false` is distinct from inheriting.
struct Override<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var value: Value
}

/// Representation identifiers that settings may select as a format's opening view.
enum DefaultRepresentation: String, Codable, CaseIterable, Sendable {
    case tree, pretty, raw, rendered, hex, source, table, diff
    var displayName: String { rawValue.capitalized }
}

/// Persisted per-format Markdown display and interpretation options.
struct MarkdownFormatOptions: Codable, Equatable, Sendable {
    var fontSize: Double = 13
    var profile: MarkdownProfile = .default
    var taskLists = true
    var strikethrough = true
    var breakBehavior: MarkdownBreakBehavior = .standard
    var frontMatter: MarkdownFrontMatterMode = .show
    var tableOfContents = false

    /// Clamps Markdown font size while preserving every boolean and enum option.
    func normalized() -> MarkdownFormatOptions {
        var result = self
        result.fontSize = fontSize.isFinite ? min(max(fontSize, 10), 28) : 13
        return result
    }
    /// Creates empty Markdown overrides that use the documented defaults.
    init() {}
    /// Keys decoded independently so one malformed option does not discard its siblings.
    private enum CodingKeys: String, CodingKey { case fontSize, profile, taskLists, strikethrough, breakBehavior, frontMatter, tableOfContents }
    /// Decodes Markdown preferences independently so malformed values do not discard valid siblings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /// Allows one malformed Markdown field to fall back without discarding its siblings.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        fontSize = value(.fontSize, fontSize); profile = value(.profile, profile)
        taskLists = value(.taskLists, taskLists); strikethrough = value(.strikethrough, strikethrough)
        breakBehavior = value(.breakBehavior, breakBehavior); frontMatter = value(.frontMatter, frontMatter)
        tableOfContents = value(.tableOfContents, tableOfContents)
    }
}

/// Persisted per-format tree expansion and key-order preferences.
struct StructuredFormatOptions: Codable, Equatable, Sendable {
    static let expandDepthRange = 1...3
    var expandDepth = 1
    var sortKeys = false
    /// Keeps tree expansion within its supported depth while preserving sort preference.
    func normalized() -> StructuredFormatOptions {
        .init(expandDepth: min(max(expandDepth, Self.expandDepthRange.lowerBound), Self.expandDepthRange.upperBound), sortKeys: sortKeys)
    }
    /// Creates structured preview options with bounded expansion and key ordering choices.
    init(expandDepth: Int = 1, sortKeys: Bool = false) { self.expandDepth = expandDepth; self.sortKeys = sortKeys }
    /// Stored keys accepted by the structured-options decoder.
    private enum CodingKeys: String, CodingKey { case expandDepth, sortKeys }
    /// Decodes known structured options and uses safe defaults for malformed or absent fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expandDepth = ((try? c.decodeIfPresent(Int.self, forKey: .expandDepth)) ?? nil) ?? 1
        sortKeys = ((try? c.decodeIfPresent(Bool.self, forKey: .sortKeys)) ?? nil) ?? false
    }
}

/// Stored data for one format. `nil` fields were never set and inherit General or use the
/// format's factory option values.
struct FormatSettings: Codable, Equatable, Sendable {
    var font: Override<FontSetting>?
    var themeAssignment: Override<ThemeAssignment>?
    var wordWrap: Override<WordWrapMode>?
    var lineLength: Override<Int>?
    var lineNumbers: Override<Bool>?
    var tabsToSpaces: Override<Int>?
    var defaultRepresentation: DefaultRepresentation?
    /// Overrides General when present; `nil` inherits. Kept as a plain value so earlier v3 files,
    /// which stored only `true`, read unchanged.
    var indentationGuides: Bool?
    var markdown: MarkdownFormatOptions?
    var structured: StructuredFormatOptions?

    var isEmpty: Bool { self == FormatSettings() }

    /// Per-format appearance values retired by ADR-022: kept as data, never applied.
    var hasRetiredAppearance: Bool {
        font != nil || themeAssignment != nil || wordWrap != nil || lineLength != nil
            || lineNumbers != nil || tabsToSpaces != nil || indentationGuides != nil
    }

    /// Removes retired appearance values and keeps Markdown and Structured options.
    func withoutRetiredAppearance() -> FormatSettings {
        FormatSettings(defaultRepresentation: defaultRepresentation, markdown: markdown, structured: structured)
    }

    /// Normalizes all present override values without changing their enabled or dormant state.
    func normalized() -> FormatSettings {
        var result = self
        result.font = font.map { .init(isEnabled: $0.isEnabled, value: $0.value.normalized()) }
        result.lineLength = lineLength.map { .init(isEnabled: $0.isEnabled, value: GeneralSettingsV3.clampLineLength($0.value)) }
        result.tabsToSpaces = tabsToSpaces.map { .init(isEnabled: $0.isEnabled, value: GeneralSettingsV3.clampTabs($0.value)) }
        result.markdown = markdown?.normalized()
        result.structured = structured?.normalized()
        return result
    }
}

// MARK: - Lenient decoding helpers

/// Decodes each `FormatSettings` field independently; an invalid field falls back to `nil`.
/// Retired per-format `thumbnail*` overrides (D62) are not keys here and are ignored.
private struct LenientFormatSettings: Decodable {
    let value: FormatSettings
    /// Current per-format fields; retired thumbnail overrides are excluded.
    private enum CodingKeys: String, CodingKey {
        case font, themeAssignment, wordWrap, lineLength, lineNumbers, tabsToSpaces
        case defaultRepresentation, indentationGuides, markdown, structured
    }
    /// Decodes format overrides field by field, preserving all valid values.
    init(from decoder: Decoder) throws {
        var value = FormatSettings()
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            /// Drops only an invalid field, retaining any independently decodable format values.
            func field<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
            value.font = field(.font); value.themeAssignment = field(.themeAssignment)
            value.wordWrap = field(.wordWrap); value.lineLength = field(.lineLength)
            value.lineNumbers = field(.lineNumbers); value.tabsToSpaces = field(.tabsToSpaces)
            value.defaultRepresentation = field(.defaultRepresentation)
            value.indentationGuides = field(.indentationGuides)
            value.markdown = field(.markdown); value.structured = field(.structured)
        }
        self.value = value
    }
}

/// Keeps every string-keyed entry whose value decodes; drops only the invalid ones.
private struct LenientDictionary<Value: Decodable>: Decodable {
    let entries: [String: Value]
    /// String-only coding key used to decode format entries with arbitrary identifiers.
    private struct Key: CodingKey {
        let stringValue: String
        /// Creates a key for an arbitrary persisted format identifier.
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        /// Rejects integer keys because settings dictionaries use string identifiers.
        init?(intValue: Int) { nil }
    }
    /// Decodes every individually valid dictionary entry and skips invalid values.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var entries: [String: Value] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) { entries[key.stringValue] = value }
        }
        self.entries = entries
    }
}

/// Keeps every element that decodes; drops only the invalid ones.
private struct LenientArray<Element: Decodable>: Decodable {
    let elements: [Element]
    /// Accepts any JSON value so the unkeyed container advances past an invalid element.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
    /// Decodes each individually valid array element while advancing past malformed values.
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) { elements.append(element) }
            else if (try? container.decode(Skip.self)) == nil { break }
        }
        self.elements = elements
    }
}
