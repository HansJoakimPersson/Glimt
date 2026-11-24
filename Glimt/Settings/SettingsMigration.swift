import Foundation
import InspectorCore

/// Pure v1/v2 → v4 and v3 → v4 conversion (ADR-015, ADR-022). The v2 family tier is fanned out
/// to its formats (D02); per-language appearance becomes retired format data. A stored opening
/// view becomes a view-order override. The source file is never modified.
enum SettingsMigration {
    /// Fans family-level v2 values out to per-format v3 values, then normalizes all migrated data.
    /// The legacy file is read-only input so migration itself cannot destroy recovery data.
    static func migrate(_ legacy: GlimtSettings) -> GlimtSettingsV3 {
        let v2 = legacy.normalized()
        var result = GlimtSettingsV3()
        result.general = general(from: v2)
        result.general.indentationGuides = v2.source.indentationGuides
        result.customThemes = v2.source.customThemes
        result.fileAssociations = v2.fileAssociations

        for language in SourceLanguage.sourceCodeLanguages {
            let format = FormatID(rawValue: language.rawValue)
            var entry = FormatSettings()
            if let patch = v2.source.languageOverrides[language.rawValue] {
                apply(patch, defaults: v2, to: &entry)
            }
            result[format] = entry
        }

        var markdown = FormatSettings()
        let markdownOptions = markdownOptions(from: v2.markdown)
        if markdownOptions != MarkdownFormatOptions() { markdown.markdown = markdownOptions }
        if v2.markdown.defaultPresentation != .rendered { markdown.defaultRepresentation = .source }
        result[.markdown] = markdown

        let structuredOptions = StructuredFormatOptions(expandDepth: v2.structured.expandDepth, sortKeys: v2.structured.sortKeys)
        let representation = DefaultRepresentation(rawValue: v2.structured.defaultPresentation.rawValue)
        for format in RenderConfiguration.structuredFormats {
            var entry = FormatSettings()
            if structuredOptions != StructuredFormatOptions() { entry.structured = structuredOptions }
            if representation != .tree { entry.defaultRepresentation = representation }
            result[format] = entry
        }
        return migrateViews(result.normalized())
    }

    /// v3 → v4: a stored `defaultRepresentation` becomes a format override only when it differs
    /// from the view the format would inherit; the chosen view moves to the front of the
    /// inherited order. The retired field is then cleared. Idempotent.
    static func migrateViews(_ settings: GlimtSettingsV3) -> GlimtSettingsV3 {
        var result = settings
        for key in settings.formats.keys.sorted() {
            guard var entry = result.formats[key], let chosen = entry.defaultRepresentation else { continue }
            entry.defaultRepresentation = nil
            result.formats[key] = entry.isEmpty ? nil : entry
            let migratedView = key == FormatID.markdown.rawValue && chosen == .raw
                ? DefaultRepresentation.source : chosen
            guard result.formatOverrides[key] == nil,
                  let view = FormatDefinition.RepresentationID(rawValue: migratedView.rawValue) else { continue }
            let inherited = ViewResolver.resolve(result, for: FormatID(rawValue: key))
            guard inherited.supported.contains(view), inherited.defaultView != view else { continue }
            result.formatOverrides[key] = ([view] + inherited.configured.filter { $0 != view }).map(\.rawValue)
        }
        result.schemaVersion = GlimtSettingsV3.currentSchemaVersion
        return result
    }

    // MARK: - Parts

    /// Carries general v2 values into v3's normalized general settings representation.
    private static func general(from v2: GlimtSettings) -> GeneralSettingsV3 {
        var general = GeneralSettingsV3()
        general.font = .init(family: v2.textCode.fontFamily, size: v2.textCode.fontSize)
        general.wordWrap = v2.textCode.wordWrap ? .soft : .off
        general.tabsToSpaces = v2.textCode.tabWidth
        general.lineNumbers = v2.source.showLineNumbers
        general.themeAssignment = .init(light: .init(preset: v2.source.lightTheme, customThemeID: v2.source.lightCustomThemeID),
                                        dark: .init(preset: v2.source.darkTheme, customThemeID: v2.source.darkCustomThemeID))
        general.dataLimitBytes = v2.general.maximumPreviewSize.maximumBytes
        general.dataLimitDisplayUnit = general.dataLimitBytes >= DataLimitUnit.mb.bytes ? .mb : .kb
        return general
    }

    /// A language patch becomes enabled overrides holding the effective v2 value. Font and theme are
    /// atomic units (D05): any member set in the patch produces the whole unit.
    /// Materializes a language override as enabled v3 fields, using the v2 effective defaults for
    /// atomic font and theme groups so the visible result remains unchanged after migration.
    private static func apply(_ patch: SourceLanguageOverride, defaults v2: GlimtSettings, to entry: inout FormatSettings) {
        if patch.fontFamily != nil || patch.fontSize != nil {
            entry.font = .init(isEnabled: true, value: .init(family: patch.fontFamily ?? v2.textCode.fontFamily,
                                                             size: patch.fontSize ?? v2.textCode.fontSize))
        }
        if patch.lightTheme != nil || patch.darkTheme != nil || patch.lightCustomThemeID != nil || patch.darkCustomThemeID != nil {
            // Mirrors SourceSettings.resolved: a patched preset replaces the inherited custom palette.
            let lightID = patch.lightTheme != nil ? patch.lightCustomThemeID : patch.lightCustomThemeID ?? v2.source.lightCustomThemeID
            let darkID = patch.darkTheme != nil ? patch.darkCustomThemeID : patch.darkCustomThemeID ?? v2.source.darkCustomThemeID
            entry.themeAssignment = .init(isEnabled: true, value: .init(
                light: .init(preset: patch.lightTheme ?? v2.source.lightTheme, customThemeID: lightID),
                dark: .init(preset: patch.darkTheme ?? v2.source.darkTheme, customThemeID: darkID)))
        }
        if let wrap = patch.wordWrap { entry.wordWrap = .init(isEnabled: true, value: wrap ? .soft : .off) }
        if let lineNumbers = patch.showLineNumbers { entry.lineNumbers = .init(isEnabled: true, value: lineNumbers) }
        if let tabs = patch.tabWidth { entry.tabsToSpaces = .init(isEnabled: true, value: tabs) }
        if let guides = patch.indentationGuides { entry.indentationGuides = guides ? true : nil }
    }

    /// Copies supported Markdown options while leaving v3-only values at their factory defaults.
    private static func markdownOptions(from markdown: MarkdownSettings) -> MarkdownFormatOptions {
        var options = MarkdownFormatOptions()
        options.fontSize = markdown.fontSize
        options.profile = markdown.profile
        options.taskLists = markdown.taskLists
        options.strikethrough = markdown.strikethrough
        options.breakBehavior = markdown.breakBehavior
        options.frontMatter = markdown.frontMatter
        options.tableOfContents = markdown.tableOfContents
        return options
    }
}
