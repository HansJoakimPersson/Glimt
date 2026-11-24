import Foundation
import InspectorCore

// MARK: - Applicability (D04)

/// General properties a format may inherit and override. One typed table drives both the
/// resolver and the Format pane, so a row is never shown for a property without behavior.
enum InheritableProperty: String, CaseIterable, Sendable {
    case themeAssignment, font, wordWrap, lineLength, lineNumbers, tabsToSpaces, indentationGuides
}

/// Declares which format-specific controls are supported by the current catalog entry.
enum FormatSettingsCapabilities {
    /// Per-format appearance overrides are retired (ADR-022): every format uses General. Stored
    /// values are kept as data and reported in Settings, never applied.
    static func inheritable(for format: FormatID) -> [InheritableProperty] { [] }

    /// Real representations offered for documents of this format; a single representation has no control.
    static func representations(for format: FormatID) -> [DefaultRepresentation] {
        // Hide stale planned representations until the format is fully supported.
        guard let definition = FormatCatalog.definition(for: format), definition.status == .supported else { return [] }
        return definition.availableRepresentations.compactMap { DefaultRepresentation(rawValue: $0.rawValue) }
    }

    /// Limits indentation guide settings to supported source formats.
    static func hasIndentationGuides(_ format: FormatID) -> Bool {
        FormatCatalog.definition(for: format).map { $0.status == .supported && $0.sourceLanguage != nil } ?? false
    }
    /// Markdown options apply only when the format offers rendered and inspectable source views.
    static func hasMarkdownOptions(_ format: FormatID) -> Bool {
        let values = representations(for: format)
        return values.contains(.rendered) && (values.contains(.source) || values.contains(.raw))
    }
    /// Structured options apply only when raw, pretty and tree representations are all available.
    static func hasStructuredOptions(_ format: FormatID) -> Bool {
        let values = representations(for: format)
        return values.contains(.tree) && values.contains(.pretty) && values.contains(.raw)
    }

    /// The view a format opens with at factory settings: the first view of its category profile.
    static func factoryDefaultRepresentation(for format: FormatID) -> DefaultRepresentation? {
        ViewResolver.resolve(.factoryDefaults, for: format).defaultView.flatMap { DefaultRepresentation(rawValue: $0.rawValue) }
    }
}

// MARK: - Resolution

/// Identifies the settings scope that supplied a resolved value.
enum SettingOrigin: String, Sendable { case general, format }

/// A resolved preference value paired with its source scope.
struct Resolved<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let origin: SettingOrigin
}

/// Effective values for one format plus where each came from. Values are clamped.
struct ResolvedFormatSettings: Equatable, Sendable {
    let format: FormatID
    let inheritable: [InheritableProperty]
    let themeAssignment: Resolved<ThemeAssignment>
    let font: Resolved<FontSetting>
    let wordWrap: Resolved<WordWrapMode>
    let lineLength: Resolved<Int>
    let lineNumbers: Resolved<Bool>
    let tabsToSpaces: Resolved<Int>
    let indentationGuides: Resolved<Bool>
    let markdown: MarkdownFormatOptions
    let structured: StructuredFormatOptions
    let defaultRepresentation: DefaultRepresentation?
}

/// Pure, synchronous and I/O-free (ADR-015). Renderers never see inheritance.
enum EffectiveSettingsResolver {
    /// Appearance comes from General only; format data contributes Markdown and Structured
    /// options, and the default view comes from `ViewResolver`.
    static func resolve(_ settings: GlimtSettingsV3, for format: FormatID) -> ResolvedFormatSettings {
        let general = settings.general.normalized()
        let stored = settings[format].normalized()
        /// Retired per-format overrides are never consulted.
        func pick<V>(_ value: V) -> Resolved<V> { .init(value: value, origin: .general) }
        let defaultView = ViewResolver.resolve(settings, for: format).defaultView
        return .init(
            format: format, inheritable: [],
            themeAssignment: pick(general.themeAssignment), font: pick(general.font),
            wordWrap: pick(general.wordWrap), lineLength: pick(general.lineLength),
            lineNumbers: pick(general.lineNumbers), tabsToSpaces: pick(general.tabsToSpaces),
            indentationGuides: pick(FormatSettingsCapabilities.hasIndentationGuides(format) && general.indentationGuides),
            markdown: stored.markdown ?? MarkdownFormatOptions(),
            structured: stored.structured ?? StructuredFormatOptions(),
            defaultRepresentation: defaultView.flatMap { DefaultRepresentation(rawValue: $0.rawValue) })
    }

    /// Source rendering values for a resolved format, including custom palette lookup.
    static func sourceConfiguration(_ resolved: ResolvedFormatSettings, themes: [CustomSourceTheme]) -> SourceRenderConfiguration {
        // Resolve custom palette IDs at the adapter boundary; persisted IDs may reference a deleted theme.
        let theme = resolved.themeAssignment.value
        /// Ignores missing theme IDs so rendering can fall back to the built-in preset.
        func palette(_ id: String?) -> SourceThemePalette? { themes.first { $0.id == id }?.palette }
        return .init(showLineNumbers: resolved.lineNumbers.value, wrapMode: resolved.wordWrap.value,
                     lineLength: resolved.lineLength.value, tabsToSpaces: resolved.tabsToSpaces.value,
                     fontFamily: resolved.font.value.family, fontSize: resolved.font.value.size,
                     lightTheme: theme.light.preset, darkTheme: theme.dark.preset,
                     lightPalette: palette(theme.light.customThemeID), darkPalette: palette(theme.dark.customThemeID),
                     indentationGuides: resolved.indentationGuides.value)
    }
}
