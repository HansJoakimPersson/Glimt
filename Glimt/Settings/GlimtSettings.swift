import InspectorCore

/// Factory behavior is a pure value, independent of preferences or filesystem state.
struct GlimtSettings: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var general = GeneralSettings()
    var textCode = TextCodeSettings()
    var source = SourceSettings()
    var markdown = MarkdownSettings()
    var structured = StructuredSettings()
    var fileAssociations: [FileAssociation] = []
    static let factoryDefaults = GlimtSettings()

    /// Sanitizes the legacy schema before it can reach a renderer or be persisted again.
    func normalized() -> GlimtSettings {
        guard schemaVersion == 2 else { return .factoryDefaults }
        var result = self
        /// Converts malformed sizes to a safe default and clamps valid values to the UI range.
        func size(_ value: Double, minimum: Double = 9, maximum: Double = 32) -> Double {
            // Replace non-finite persisted values before clamping to the corresponding control range.
            value.isFinite ? min(max(value, minimum), maximum) : 12
        }
        result.textCode.fontSize = size(textCode.fontSize)
        result.markdown.fontSize = size(markdown.fontSize, minimum: 10, maximum: 28)
        result.textCode.tabWidth = min(max(textCode.tabWidth, 1), 8)
        result.structured.expandDepth = min(max(structured.expandDepth, 1), 3)
        if !Self.fontFamilies.contains(textCode.fontFamily) { result.textCode.fontFamily = "System Monospaced" }
        result.fileAssociations = fileAssociations.prefix(64).compactMap { $0.validated() }
        result.source.customThemes = source.customThemes.prefix(16).filter { !$0.id.isEmpty && $0.appearance != .system }.map { theme in
            var theme = theme; theme.name = String(theme.name.prefix(48)); theme.palette = theme.palette.normalized(); return theme
        }
        result.source.languageOverrides = Dictionary(uniqueKeysWithValues: SourceLanguage.sourceCodeLanguages.compactMap { language in
            let key = language.rawValue
            guard var value = source.languageOverrides[key] else { return nil }
            if let font = value.fontFamily, !Self.fontFamilies.contains(font) { value.fontFamily = nil }
            if let pointSize = value.fontSize { value.fontSize = size(pointSize) }
            if let tabs = value.tabWidth { value.tabWidth = min(max(tabs, 1), 8) }
            return value.isEmpty ? nil : (key, value)
        })
        return result
    }
    static let fontFamilies = ["System Monospaced", "Menlo", "Monaco"]
}

/// User-selectable preview size presets, always bounded by the Core inspection ceiling.
enum PreviewSizePreference: String, Codable, CaseIterable, Sendable {
    case automatic, small, medium, maximum
    var maximumBytes: Int {
        switch self { case .small: 65_536; case .medium: 262_144; case .automatic, .maximum: 1_048_576 }
    }
}
/// Legacy schema settings for application appearance and preview-size preference.
struct GeneralSettings: Codable, Equatable, Sendable {
    var appearance: PreviewAppearance = .system
    var maximumPreviewSize: PreviewSizePreference = .automatic
}
/// Legacy shared typography and wrapping settings migrated into schema 3.
struct TextCodeSettings: Codable, Equatable, Sendable {
    var fontFamily = "System Monospaced"
    var fontSize: Double = 12
    var wordWrap = true
    var tabWidth = 4
}
/// Source presentation preferences and persisted custom palette assignments.
struct SourceSettings: Codable, Equatable, Sendable {
    var customThemes: [CustomSourceTheme] = []
    var lightCustomThemeID: String?
    var darkCustomThemeID: String?
    var indentationGuides = false
    var lightTheme: SourceThemePreset = .glimtDefault
    var darkTheme: SourceThemePreset = .glimtDefault
    var languageOverrides: [String: SourceLanguageOverride] = [:]
    var showLineNumbers = true
}
/// Legacy Markdown view choices retained for settings migration and compatibility.
enum MarkdownPresentation: String, Codable, CaseIterable, Sendable { case rendered, raw }
/// Legacy named Markdown layout profiles retained while decoding prior settings.
enum MarkdownProfile: String, Codable, CaseIterable, Sendable { case `default`, compact, reading }
/// Legacy Markdown defaults and interpretation options retained by schema migration.
struct MarkdownSettings: Codable, Equatable, Sendable {
    var defaultPresentation: MarkdownPresentation = .rendered
    var fontSize: Double = 13
    var profile: MarkdownProfile = .default
    var taskLists = true
    var strikethrough = true
    var breakBehavior: MarkdownBreakBehavior = .standard
    var frontMatter: MarkdownFrontMatterMode = .show
    var tableOfContents = false
}
/// Legacy structured-data representation choices retained for decoding older settings.
enum StructuredPresentation: String, Codable, CaseIterable, Sendable { case tree, pretty, raw }
/// Legacy structured-data view and tree-expansion settings.
struct StructuredSettings: Codable, Equatable, Sendable {
    var defaultPresentation: StructuredPresentation = .tree
    var expandDepth = 1
    var sortKeys = false
}

// Missing fields retain defaults. Version 1 had separate Text and Source typography values;
// migration uses saved Source values when present, falling back field-by-field to Text values.
extension GlimtSettings {
    /// Decodes schema 1 or 2 and applies field-by-field typography migration for schema 1.
    init(from decoder: Decoder) throws {
        // Decode both v1 and v2 layouts, applying field-by-field fallback for v1's split typography.
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = storedVersion == 1 ? 2 : storedVersion
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? general
        source = try c.decodeIfPresent(SourceSettings.self, forKey: .source) ?? source
        if storedVersion == 1 {
            let text = try c.decodeIfPresent(TextCodeSettings.self, forKey: .text)
            let legacySource = try c.decodeIfPresent(LegacySourceTextSettings.self, forKey: .source)
            var migrated = text ?? TextCodeSettings()
            migrated.fontFamily = legacySource?.fontFamily ?? migrated.fontFamily
            migrated.fontSize = legacySource?.fontSize ?? migrated.fontSize
            migrated.wordWrap = legacySource?.wordWrap ?? migrated.wordWrap
            migrated.tabWidth = legacySource?.tabWidth ?? migrated.tabWidth
            textCode = migrated
        } else {
            textCode = try c.decodeIfPresent(TextCodeSettings.self, forKey: .textCode) ?? textCode
        }
        markdown = try c.decodeIfPresent(MarkdownSettings.self, forKey: .markdown) ?? markdown
        structured = try c.decodeIfPresent(StructuredSettings.self, forKey: .structured) ?? structured
        fileAssociations = try c.decodeIfPresent([FileAssociation].self, forKey: .fileAssociations) ?? fileAssociations
    }
    /// Writes only the current v2 storage shape; legacy v1 compatibility is decode-only.
    func encode(to encoder: Encoder) throws {
        // Always write the current legacy schema shape; compatibility is handled on read only.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(general, forKey: .general)
        try c.encode(textCode, forKey: .textCode)
        try c.encode(source, forKey: .source)
        try c.encode(markdown, forKey: .markdown)
        try c.encode(structured, forKey: .structured)
        try c.encode(fileAssociations, forKey: .fileAssociations)
    }
    /// Stored keys accepted by the legacy settings decoder and current encoder.
    private enum CodingKeys: String, CodingKey { case schemaVersion, general, text, textCode, source, markdown, structured, fileAssociations }
}
extension GeneralSettings {
    /// Decodes available fields while retaining factory defaults for missing legacy values.
    init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try c.decodeIfPresent(PreviewAppearance.self, forKey: .appearance) ?? appearance
        maximumPreviewSize = try c.decodeIfPresent(PreviewSizePreference.self, forKey: .maximumPreviewSize) ?? maximumPreviewSize
    }
}
extension TextCodeSettings {
    /// Decodes typography fields while supplying defaults for settings files that omit them.
    init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? fontFamily
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        wordWrap = try c.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? wordWrap
        tabWidth = try c.decodeIfPresent(Int.self, forKey: .tabWidth) ?? tabWidth
    }
}
extension SourceSettings {
    /// Decodes source preferences and custom palette data with defaults for absent keys.
    init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        customThemes = try c.decodeIfPresent([CustomSourceTheme].self, forKey: .customThemes) ?? customThemes
        lightCustomThemeID = try c.decodeIfPresent(String.self, forKey: .lightCustomThemeID)
        darkCustomThemeID = try c.decodeIfPresent(String.self, forKey: .darkCustomThemeID)
        indentationGuides = try c.decodeIfPresent(Bool.self, forKey: .indentationGuides) ?? indentationGuides
        lightTheme = try c.decodeIfPresent(SourceThemePreset.self, forKey: .lightTheme) ?? lightTheme
        darkTheme = try c.decodeIfPresent(SourceThemePreset.self, forKey: .darkTheme) ?? darkTheme
        languageOverrides = try c.decodeIfPresent([String: SourceLanguageOverride].self, forKey: .languageOverrides) ?? languageOverrides
        showLineNumbers = try c.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? showLineNumbers
    }
}

/// Schema-1 source typography keys used only during migration into shared text settings.
private struct LegacySourceTextSettings: Decodable {
    var fontFamily: String?
    var fontSize: Double?
    var wordWrap: Bool?
    var tabWidth: Int?
}
extension MarkdownSettings {
    /// Decodes Markdown values independently so older partial settings keep safe defaults.
    init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultPresentation = try c.decodeIfPresent(MarkdownPresentation.self, forKey: .defaultPresentation) ?? defaultPresentation
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        profile = try c.decodeIfPresent(MarkdownProfile.self, forKey: .profile) ?? profile
        taskLists = try c.decodeIfPresent(Bool.self, forKey: .taskLists) ?? taskLists
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? strikethrough
        breakBehavior = try c.decodeIfPresent(MarkdownBreakBehavior.self, forKey: .breakBehavior) ?? breakBehavior
        frontMatter = try c.decodeIfPresent(MarkdownFrontMatterMode.self, forKey: .frontMatter) ?? frontMatter
        tableOfContents = try c.decodeIfPresent(Bool.self, forKey: .tableOfContents) ?? tableOfContents

    }
}
extension StructuredSettings {
    /// Decodes structured-view settings while retaining defaults for absent keys.
    init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultPresentation = try c.decodeIfPresent(StructuredPresentation.self, forKey: .defaultPresentation) ?? defaultPresentation
        expandDepth = try c.decodeIfPresent(Int.self, forKey: .expandDepth) ?? expandDepth
        sortKeys = try c.decodeIfPresent(Bool.self, forKey: .sortKeys) ?? sortKeys
    }
}


extension SourceSettings {
    /// Resolves only the custom palette assigned to this slot; preset rendering remains separate.
    private func palette(id: String?, appearance: PreviewAppearance) -> SourceThemePalette? {
        // Assignment chooses where to use a palette; its legacy appearance is only a preview hint.
        customThemes.first { $0.id == id }?.palette
    }
    /// Combines legacy source defaults with one optional language patch without mutating storage.
    func resolved(defaults: TextCodeSettings = .init(), for language: SourceLanguage? = nil) -> SourceRenderConfiguration {
        // Language-specific values override their corresponding source defaults without mutating storage.
        let patch = language.flatMap { languageOverrides[$0.rawValue] }
        return .init(showLineNumbers: patch?.showLineNumbers ?? showLineNumbers,
                     wrapLines: patch?.wordWrap ?? defaults.wordWrap, tabWidth: patch?.tabWidth ?? defaults.tabWidth,
                     fontFamily: patch?.fontFamily ?? defaults.fontFamily, fontSize: patch?.fontSize ?? defaults.fontSize,
                     lightTheme: patch?.lightTheme ?? lightTheme, darkTheme: patch?.darkTheme ?? darkTheme,
                     lightPalette: palette(id: patch?.lightTheme != nil ? patch?.lightCustomThemeID : patch?.lightCustomThemeID ?? lightCustomThemeID, appearance: .light),
                     darkPalette: palette(id: patch?.darkTheme != nil ? patch?.darkCustomThemeID : patch?.darkCustomThemeID ?? darkCustomThemeID, appearance: .dark),
                     indentationGuides: patch?.indentationGuides ?? indentationGuides)
    }
}

/// Persisted user-authored source palette retained in the settings schema.
struct CustomSourceTheme: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Retained for decoding existing settings and choosing a library preview, not assignment eligibility.
    var appearance: PreviewAppearance
    var basePreset: SourceThemePreset
    var palette: SourceThemePalette
}
