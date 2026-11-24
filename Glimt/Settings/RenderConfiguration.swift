import Foundation
import InspectorCore

/// Appearance resolved for a preview surface.
enum PreviewAppearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

/// Validated source-view options consumed by the AppKit renderer.
struct SourceRenderConfiguration: Equatable, Sendable {
    let showLineNumbers: Bool
    let wrapMode: WordWrapMode
    let lineLength: Int
    /// `0` keeps tab characters at the default stop (D06); `N > 0` sets tab stops every N columns.
    let tabsToSpaces: Int
    let fontFamily: String
    let fontSize: Double
    let lightPalette: SourceThemePalette?
    let darkPalette: SourceThemePalette?
    let indentationGuides: Bool
    let lightTheme: SourceThemePreset
    let darkTheme: SourceThemePreset
    var wrapLines: Bool { wrapMode != .off }
    /// Visual tab interval in columns.
    var tabWidth: Int { tabsToSpaces == 0 ? GeneralSettingsV3.keptTabStop : tabsToSpaces }

    /// Builds source options from the compact legacy shape and normalizes its values.
    init(showLineNumbers: Bool = true, wrapLines: Bool = false, tabWidth: Int = 4,
         fontFamily: String = "System Monospaced", fontSize: Double = 12,
         lightTheme: SourceThemePreset = .glimtDefault, darkTheme: SourceThemePreset = .glimtDefault,
         lightPalette: SourceThemePalette? = nil, darkPalette: SourceThemePalette? = nil, indentationGuides: Bool = false) {
        self.init(showLineNumbers: showLineNumbers, wrapMode: wrapLines ? .soft : .off, lineLength: 120,
                  tabsToSpaces: min(max(tabWidth, 1), 8), fontFamily: fontFamily, fontSize: fontSize,
                  lightTheme: lightTheme, darkTheme: darkTheme, lightPalette: lightPalette, darkPalette: darkPalette,
                  indentationGuides: indentationGuides)
    }

    /// Creates the complete source-render configuration, clamping persisted numeric values.
    init(showLineNumbers: Bool, wrapMode: WordWrapMode, lineLength: Int, tabsToSpaces: Int,
         fontFamily: String, fontSize: Double, lightTheme: SourceThemePreset, darkTheme: SourceThemePreset,
         lightPalette: SourceThemePalette?, darkPalette: SourceThemePalette?, indentationGuides: Bool) {
        // Resolve and clamp at construction so renderers consume a complete, trusted value object.
        self.lightPalette = lightPalette?.normalized(); self.darkPalette = darkPalette?.normalized()
        self.indentationGuides = indentationGuides
        self.showLineNumbers = showLineNumbers; self.wrapMode = wrapMode
        self.lineLength = GeneralSettingsV3.clampLineLength(lineLength)
        self.lightTheme = lightTheme; self.darkTheme = darkTheme
        self.tabsToSpaces = GeneralSettingsV3.clampTabs(tabsToSpaces)
        let font = FontSetting(family: fontFamily, size: fontSize).normalized()
        self.fontFamily = font.family
        self.fontSize = font.size
    }
}
/// Validated text-view options for documents without source-language styling.
struct TextRenderConfiguration: Equatable, Sendable {
    let fontFamily: String
    let fontSize: Double
    let wrapMode: WordWrapMode
    let lineLength: Int
    let tabsToSpaces: Int
    var wrapLines: Bool { wrapMode != .off }
    var tabWidth: Int { tabsToSpaces == 0 ? GeneralSettingsV3.keptTabStop : tabsToSpaces }
    /// Creates text options with normalized line length and tab behavior.
    init(fontFamily: String, fontSize: Double, wrapMode: WordWrapMode, lineLength: Int = 120, tabsToSpaces: Int) {
        self.fontFamily = fontFamily; self.fontSize = fontSize; self.wrapMode = wrapMode
        self.lineLength = GeneralSettingsV3.clampLineLength(lineLength)
        self.tabsToSpaces = GeneralSettingsV3.clampTabs(tabsToSpaces)
    }
}
/// Rendering options for prose and code in a Markdown document.
struct MarkdownRenderConfiguration: Equatable, Sendable {
    let fontSize: Double
    /// Prose family from `GeneralSettingsV3.textFontFamilies`; code spans use the source font.
    let textFont: String
    let options: MarkdownOptions
    let profile: MarkdownProfile
    /// Creates Markdown rendering options and replaces unsupported prose fonts with the default.
    init(fontSize: Double = 13, textFont: String = "System", profile: MarkdownProfile = .default, options: MarkdownOptions = .init()) {
        self.options = options
        self.textFont = GeneralSettingsV3.textFontFamilies.contains(textFont) ? textFont : "System"
        self.fontSize = fontSize.isFinite ? min(max(fontSize, 10), 28) : 13
        self.profile = profile
    }
}
/// Tree presentation options for a structured document.
struct StructuredRenderConfiguration: Equatable, Sendable {
    let sortKeys: Bool
    let expandDepth: Int
}

/// Resolved values only; no store, inheritance policy or preference lookup belongs to a renderer.
struct RenderConfiguration: Equatable, Sendable {
    static let structuredFormats: [FormatID] = [.json, .yaml, .xml, .plist]

    var appearance: PreviewAppearance
    let maximumPreviewBytes: Int
    let vcsSupportEnabled: Bool
    /// Whether Debug Quick Look shows its build marker; Release builds never draw one.
    let showsDebugBuildMarker: Bool
    /// General source values; used for Markdown code blocks and unknown languages.
    let source: SourceRenderConfiguration
    private let languageSources: [String: SourceRenderConfiguration]
    let fileAssociations: [FileAssociation]
    let text: TextRenderConfiguration
    let markdown: MarkdownRenderConfiguration
    private let structuredByFormat: [String: StructuredRenderConfiguration]
    /// Configured views per supported format, in order (ADR-022). Availability is decided per
    /// document by the preview; the first effective view opens.
    private let viewsByFormat: [String: [FormatDefinition.RepresentationID]]

    /// Legacy v2 resolution, retained as the reference for the migration equivalence gate.
    init(settings: GlimtSettings, appearance: PreviewAppearance? = nil) {
        let s = settings.normalized()
        self.appearance = appearance ?? s.general.appearance
        maximumPreviewBytes = s.general.maximumPreviewSize.maximumBytes
        vcsSupportEnabled = false
        showsDebugBuildMarker = true
        source = s.source.resolved(defaults: s.textCode)
        languageSources = Dictionary(uniqueKeysWithValues: SourceLanguage.sourceCodeLanguages.map { ($0.rawValue, s.source.resolved(defaults: s.textCode, for: $0)) })
        fileAssociations = s.fileAssociations
        text = .init(fontFamily: s.textCode.fontFamily, fontSize: s.textCode.fontSize,
                     wrapMode: s.textCode.wordWrap ? .soft : .off, tabsToSpaces: s.textCode.tabWidth)
        markdown = .init(fontSize: s.markdown.fontSize, profile: s.markdown.profile,
                         options: .init(taskLists: s.markdown.taskLists, strikethrough: s.markdown.strikethrough, breakBehavior: s.markdown.breakBehavior, frontMatter: s.markdown.frontMatter, tableOfContents: s.markdown.tableOfContents))
        let structured = StructuredRenderConfiguration(sortKeys: s.structured.sortKeys, expandDepth: s.structured.expandDepth)
        structuredByFormat = Dictionary(uniqueKeysWithValues: Self.structuredFormats.map { ($0.rawValue, structured) })
        // v2 chose only an opening view; it moves to the front of the factory order.
        var views = Self.factoryViews
    /// Replaces the current document with raw content inspected as the requested format.
    func open(_ format: FormatID, with raw: String) {
            guard let view = FormatDefinition.RepresentationID(rawValue: raw), let order = views[format.rawValue], order.contains(view) else { return }
            views[format.rawValue] = [view] + order.filter { $0 != view }
        }
        // The factory Tree expressed no choice; migration leaves those formats on the category order.
        if s.structured.defaultPresentation != .tree {
            Self.structuredFormats.forEach { open($0, with: s.structured.defaultPresentation.rawValue) }
        }
        open(.markdown, with: s.markdown.defaultPresentation == .rendered ? "rendered" : "source")
        viewsByFormat = views
    }

    /// v3 resolution (ADR-015). Appearance comes from the persisted Color scheme (D51) unless a
    /// caller forces one.
    init(settings: GlimtSettingsV3 = .factoryDefaults, appearance: PreviewAppearance? = nil) {
        // Resolve inheritance before crossing into renderers; no view performs preference lookup.
        let s = settings.normalized()
        self.appearance = appearance ?? s.general.colorScheme
        maximumPreviewBytes = s.general.dataLimitBytes
        vcsSupportEnabled = s.general.vcsSupportEnabled
        showsDebugBuildMarker = s.general.debugBuildMarker
        let general = GlimtSettingsV3(general: s.general, themes: s.customThemes)
        source = EffectiveSettingsResolver.sourceConfiguration(EffectiveSettingsResolver.resolve(general, for: .swift), themes: s.customThemes)
        languageSources = Dictionary(uniqueKeysWithValues: SourceLanguage.sourceCodeLanguages.map { language in
            (language.rawValue, EffectiveSettingsResolver.sourceConfiguration(
                EffectiveSettingsResolver.resolve(s, for: FormatID(rawValue: language.rawValue)), themes: s.customThemes))
        })
        fileAssociations = s.fileAssociations
        let plain = EffectiveSettingsResolver.resolve(s, for: .text)
        text = .init(fontFamily: plain.font.value.family, fontSize: plain.font.value.size, wrapMode: plain.wordWrap.value,
                     lineLength: plain.lineLength.value, tabsToSpaces: plain.tabsToSpaces.value)
        let md = EffectiveSettingsResolver.resolve(s, for: .markdown)
        markdown = .init(fontSize: md.markdown.fontSize, textFont: s.general.textFont, profile: md.markdown.profile,
                         options: .init(taskLists: md.markdown.taskLists, strikethrough: md.markdown.strikethrough, breakBehavior: md.markdown.breakBehavior, frontMatter: md.markdown.frontMatter, tableOfContents: md.markdown.tableOfContents))
        let structured = Self.structuredFormats.map { EffectiveSettingsResolver.resolve(s, for: $0) }
        structuredByFormat = Dictionary(uniqueKeysWithValues: structured.map {
            ($0.format.rawValue, StructuredRenderConfiguration(sortKeys: $0.structured.sortKeys, expandDepth: $0.structured.expandDepth))
        })
        viewsByFormat = Dictionary(uniqueKeysWithValues: FormatCatalog.supported.map {
            ($0.id.rawValue, ViewResolver.resolve(s, for: $0.id).configured)
        })
    }

    private static let factoryViews = Dictionary(uniqueKeysWithValues: FormatCatalog.supported.map {
        ($0.id.rawValue, ViewResolver.resolve(.factoryDefaults, for: $0.id).configured)
    })

    /// JSON values; kept for callers without a specific structured format.
    var structured: StructuredRenderConfiguration { structured(for: .json) }
    /// Returns format-specific structured settings, with stable defaults for unknown formats.
    func structured(for format: FormatID) -> StructuredRenderConfiguration {
        structuredByFormat[format.rawValue] ?? .init(sortKeys: false, expandDepth: 1)
    }
    /// Configured views for a document's format. A document without a format is binary or
    /// unknown and uses Hex; an unsupported format falls back to Raw.
    func configuredViews(for format: FormatID?) -> [FormatDefinition.RepresentationID] {
        guard let format else { return ViewCategoryID.binaryAndUnknown.factoryProfile }
        return viewsByFormat[format.rawValue] ?? [.raw]
    }
    /// Returns language-specific source settings, falling back to global source settings.
    func source(for language: SourceLanguage) -> SourceRenderConfiguration { languageSources[language.rawValue] ?? source }
    /// Routes exact filename mappings before extension mappings, preserving deterministic precedence.
    func association(for filename: String) -> FileAssociation? {
        // Exact filename mappings win over extension mappings when both are configured.
        fileAssociations.first { $0.kind == .filename && $0.matches(filename) }
            ?? fileAssociations.first { $0.matches(filename) }
    }
}

private extension GlimtSettingsV3 {
    /// Same General and themes, no format data: the base source values.
    init(general: GeneralSettingsV3, themes: [CustomSourceTheme]) {
        self.init(); self.general = general; customThemes = themes
    }
}
