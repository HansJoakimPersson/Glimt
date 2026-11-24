import Foundation
import XCTest
import InspectorCore

/// F1.2 gate (ADR-015, ADR-022): a migrated file resolves to the same effective rendering values
/// as the v2 file for every supported format. Preview appearance is excepted (D09); per-language
/// appearance is retired and kept only as data, so source formats are compared with the v2 base.
final class SettingsMigrationTests: XCTestCase {
    private let supported = FormatID.allCases.filter { FormatCatalog.definition(for: $0)?.status == .supported }

    // MARK: - Projection

    /// What a renderer observes for one format.
    private struct Projection: Equatable {
        var maximumPreviewBytes: Int
        var fileAssociations: [FileAssociation]
        var source: SourceRenderConfiguration?
        var text: TextRenderConfiguration?
        var markdown: MarkdownRenderConfiguration?
        var markdownCodeTheme: [String]?
        var structured: StructuredRenderConfiguration?
        var views: [FormatDefinition.RepresentationID] = []
    }

    private func projection(_ configuration: RenderConfiguration, _ format: FormatID, legacy: Bool = false) -> Projection {
        var result = Projection(maximumPreviewBytes: configuration.maximumPreviewBytes, fileAssociations: configuration.fileAssociations)
        result.views = configuration.configuredViews(for: format)
        // A format the catalog renders with its own inspector (dotenv) never observes source settings.
        if let language = SourceLanguage(rawValue: format.rawValue), FormatCatalog.definition(for: format)?.sourceLanguage != nil {
            result.source = legacy ? configuration.source : configuration.source(for: language)
        }
        if format == .text { result.text = configuration.text }
        if format == .markdown {
            let base = configuration.source
            result.markdown = configuration.markdown
            // Markdown code blocks use the base theme, palettes and font; not guides or wrap.
            result.markdownCodeTheme = [base.lightTheme.rawValue, base.darkTheme.rawValue, String(describing: base.lightPalette),
                                        String(describing: base.darkPalette), base.fontFamily, String(base.fontSize)]
        }
        if RenderConfiguration.structuredFormats.contains(format) {
            result.structured = configuration.structured(for: format)
        }
        return result
    }

    private func assertEquivalent(_ legacy: GlimtSettings, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let before = RenderConfiguration(settings: legacy, appearance: .system)
        let after = RenderConfiguration(settings: SettingsMigration.migrate(legacy))
        for format in supported {
            XCTAssertEqual(projection(after, format), projection(before, format, legacy: true), "\(label) / \(format.rawValue)", file: file, line: line)
        }
    }

    // MARK: - Corpus

    private static let palette: SourceThemePalette = {
        let component = SourceThemeColor(red: 0.2, green: 0.3, blue: 0.4)
        return SourceThemePalette(background: component, foreground: component, comment: component,
            keyword: component, string: component, number: component, type: component, directive: component)
    }()
    private static let themes: [CustomSourceTheme] = [
        .init(id: "l", name: "L", appearance: .light, basePreset: .neutral, palette: palette),
        .init(id: "d", name: "D", appearance: .dark, basePreset: .highContrast, palette: palette),
    ]

    private func everyGeneralVariant() -> [(String, GlimtSettings)] {
        var cases: [(String, GlimtSettings)] = [("factory", .factoryDefaults)]
        func add(_ label: String, _ change: (inout GlimtSettings) -> Void) {
            var settings = GlimtSettings.factoryDefaults; change(&settings); cases.append((label, settings))
        }
        for size in PreviewSizePreference.allCases { add("size \(size)") { $0.general.maximumPreviewSize = size } }
        for appearance in PreviewAppearance.allCases { add("appearance \(appearance)") { $0.general.appearance = appearance } }
        for family in GlimtSettings.fontFamilies + ["Papyrus"] { add("family \(family)") { $0.textCode.fontFamily = family } }
        for size in [1.0, 9, 12.5, 32, 99] { add("font size \(size)") { $0.textCode.fontSize = size } }
        for wrap in [true, false] { add("wrap \(wrap)") { $0.textCode.wordWrap = wrap } }
        for tabs in [-3, 0, 1, 2, 4, 8, 12] { add("tabs \(tabs)") { $0.textCode.tabWidth = tabs } }
        for preset in SourceThemePreset.allCases {
            add("light \(preset)") { $0.source.lightTheme = preset }
            add("dark \(preset)") { $0.source.darkTheme = preset }
        }
        add("custom themes") { $0.source.customThemes = Self.themes; $0.source.lightCustomThemeID = "l"; $0.source.darkCustomThemeID = "d" }
        add("dangling custom id") { $0.source.lightCustomThemeID = "missing" }
        add("guides") { $0.source.indentationGuides = true }
        add("no line numbers") { $0.source.showLineNumbers = false }
        for mode in MarkdownPresentation.allCases { add("md \(mode)") { $0.markdown.defaultPresentation = mode } }
        for profile in MarkdownProfile.allCases { add("md profile \(profile)") { $0.markdown.profile = profile } }
        for size in [4.0, 13, 20, 40] { add("md size \(size)") { $0.markdown.fontSize = size } }
        for behavior in MarkdownBreakBehavior.allCases { add("md break \(behavior)") { $0.markdown.breakBehavior = behavior } }
        for mode in MarkdownFrontMatterMode.allCases { add("md front \(mode)") { $0.markdown.frontMatter = mode } }
        add("md toggles") { $0.markdown.taskLists = false; $0.markdown.strikethrough = false; $0.markdown.tableOfContents = true }
        for mode in StructuredPresentation.allCases { add("structured \(mode)") { $0.structured.defaultPresentation = mode } }
        for depth in [0, 1, 2, 3, 9] { add("depth \(depth)") { $0.structured.expandDepth = depth } }
        add("sort keys") { $0.structured.sortKeys = true }
        add("associations") {
            $0.fileAssociations = [.init(kind: .fileExtension, value: "foo", target: .yaml), .init(kind: .filename, value: "Makefile", target: .shell)]
        }
        return cases
    }

    private func everyPatchVariant() -> [(String, GlimtSettings)] {
        let patches: [(String, SourceLanguageOverride)] = [
            ("light preset", .init(lightTheme: .highContrast)),
            ("dark preset", .init(darkTheme: .neutral)),
            ("light custom", .init(lightCustomThemeID: "d")),
            ("dark custom", .init(darkCustomThemeID: "l")),
            ("preset replaces inherited custom", .init(lightTheme: .neutral)),
            ("guides on", .init(indentationGuides: true)),
            ("guides off", .init(indentationGuides: false)),
            ("family", .init(fontFamily: "Monaco")),
            ("bad family", .init(fontFamily: "Papyrus")),
            ("size", .init(fontSize: 18)),
            ("huge size", .init(fontSize: 400)),
            ("line numbers", .init(showLineNumbers: false)),
            ("wrap on", .init(wordWrap: true)),
            ("wrap off", .init(wordWrap: false)),
            ("tabs", .init(tabWidth: 2)),
            ("tabs out of range", .init(tabWidth: 30)),
            ("everything", .init(lightTheme: .neutral, darkTheme: .highContrast, lightCustomThemeID: "l", darkCustomThemeID: "d",
                                 indentationGuides: true, fontFamily: "Menlo", fontSize: 10, showLineNumbers: false, wordWrap: false, tabWidth: 8)),
        ]
        var cases: [(String, GlimtSettings)] = []
        for language in SourceLanguage.allCases {
            for (label, patch) in patches {
                for familyGuides in [false, true] {
                    var settings = GlimtSettings.factoryDefaults
                    settings.source.customThemes = Self.themes
                    settings.source.lightCustomThemeID = "l"
                    settings.source.indentationGuides = familyGuides
                    settings.textCode.wordWrap = false
                    settings.source.languageOverrides[language.rawValue] = patch
                    settings.source.languageOverrides["cobol"] = .init(showLineNumbers: false)
                    cases.append(("\(language) \(label) guides:\(familyGuides)", settings))
                }
            }
        }
        return cases
    }

    // MARK: - Gates

    func testEveryGeneralValueMigratesEquivalently() {
        for (label, settings) in everyGeneralVariant() { assertEquivalent(settings, label) }
    }

    func testEveryLanguagePatchMigratesEquivalently() {
        for (label, settings) in everyPatchVariant() { assertEquivalent(settings, label) }
    }

    func testNewSourceFormatLanguageOverridesMigrateToTheirFormatIDs() {
        let languages: [SourceLanguage] = [.terraform, .scss, .tsx, .vue, .svelte, .asciidoc]
        var legacy = GlimtSettings.factoryDefaults
        for language in languages {
            legacy.source.languageOverrides[language.rawValue] = .init(wordWrap: false)
        }

        let migrated = SettingsMigration.migrate(legacy)
        let rendering = RenderConfiguration(settings: migrated)
        for language in languages {
            let id = FormatID(rawValue: language.rawValue)
            XCTAssertEqual(FormatCatalog.definition(for: id)?.status, .supported, language.rawValue)
            XCTAssertTrue(migrated.formats[id.rawValue]?.hasRetiredAppearance == true, language.rawValue)
            XCTAssertEqual(rendering.source(for: language).wrapMode, .soft, language.rawValue)
        }
    }

    func testSeededRandomCorpusMigratesEquivalently() {
        var generator = SplitMix(seed: 0x6C696D74)
        for index in 0..<400 { assertEquivalent(randomSettings(&generator), "random \(index)") }
    }

    func testVersionOneFileMigratesEquivalently() throws {
        let v1 = """
        {"schemaVersion":1,"general":{"maximumPreviewSize":"medium"},
         "text":{"fontFamily":"Menlo","fontSize":14,"wordWrap":false,"tabWidth":2},
         "source":{"fontSize":16,"tabWidth":8,"showLineNumbers":false,"lightTheme":"neutral",
                   "languageOverrides":{"swift":{"wordWrap":true}}}}
        """
        let legacy = try JSONDecoder().decode(GlimtSettings.self, from: Data(v1.utf8))
        assertEquivalent(legacy, "v1")
        let migrated = SettingsMigration.migrate(legacy)
        XCTAssertEqual(migrated.general.font, .init(family: "Menlo", size: 16))
        XCTAssertEqual(migrated.general.tabsToSpaces, 8)
        XCTAssertEqual(migrated.general.dataLimitBytes, 262_144)
        XCTAssertEqual(migrated.general.dataLimitDisplayUnit, .kb)
    }

    func testUnsupportedSchemaVersionMigratesAsFactory() {
        var future = GlimtSettings.factoryDefaults
        future.schemaVersion = 9
        future.textCode.tabWidth = 2
        XCTAssertEqual(SettingsMigration.migrate(future), SettingsMigration.migrate(.factoryDefaults))
    }

    func testProjectionDetectsAnyEffectiveDifference() {
        let legacy = RenderConfiguration(settings: GlimtSettings.factoryDefaults, appearance: .system)
        let mutations: [(FormatID, (inout GlimtSettingsV3) -> Void)] = [
            (.python, { $0.general.tabsToSpaces = 2 }),
            (.python, { $0.formatOverrides["python"] = ["raw", "source"] }),
            (.json, { $0.categoryProfiles["structuredData"] = ["pretty", "tree", "raw"] }),
            (.text, { $0.general.wordWrap = .hard }),
            (.markdown, { $0.general.font.size = 15 }),
            (.markdown, { $0.formatOverrides["markdown"] = ["source", "rendered"] }),
            (.plist, { $0[.plist] = FormatSettings(structured: .init(expandDepth: 2)) }),
            (.json, { $0.general.dataLimitBytes = 65_536 }),
        ]
        for (format, mutate) in mutations {
            var settings = SettingsMigration.migrate(.factoryDefaults)
            mutate(&settings)
            XCTAssertNotEqual(projection(RenderConfiguration(settings: settings), format), projection(legacy, format, legacy: true), format.rawValue)
        }
    }

    // MARK: - Shape

    func testFactoryV2MigratesToFactoryV3() {
        // Migration preserves v2 rendering, so v2's guides-off default stays off after the v3 default turned on.
        var expected = GlimtSettingsV3.factoryDefaults
        expected.general.indentationGuides = false
        XCTAssertEqual(SettingsMigration.migrate(.factoryDefaults), expected)
    }

    func testFamilyValuesAreFannedOutToFormats() {
        var legacy = GlimtSettings.factoryDefaults
        legacy.source.indentationGuides = true
        legacy.structured.sortKeys = true
        let migrated = SettingsMigration.migrate(legacy)
        XCTAssertTrue(migrated.general.indentationGuides, "The v2 family switch maps to General")
        for language in SourceLanguage.allCases { XCTAssertNil(migrated.formats[language.rawValue]?.indentationGuides) }
        for format in RenderConfiguration.structuredFormats { XCTAssertEqual(migrated[format].structured?.sortKeys, true) }
        XCTAssertNil(migrated.formats["text"])
    }

    func testLanguagePatchesBecomeEnabledAtomicOverrides() {
        var legacy = GlimtSettings.factoryDefaults
        legacy.textCode.fontFamily = "Menlo"
        legacy.source.languageOverrides["python"] = .init(darkTheme: .highContrast, fontSize: 15, showLineNumbers: false)
        let python = SettingsMigration.migrate(legacy)[.python]
        XCTAssertEqual(python.font, .init(isEnabled: true, value: .init(family: "Menlo", size: 15)))
        XCTAssertEqual(python.themeAssignment, .init(isEnabled: true, value: .init(light: .init(), dark: .init(preset: .highContrast))))
        XCTAssertEqual(python.lineNumbers, .init(isEnabled: true, value: false))
        XCTAssertNil(python.wordWrap)
        XCTAssertNil(python.tabsToSpaces)
    }

    func testMigrationIsDeterministicAndEncodable() throws {
        for (label, settings) in everyPatchVariant().prefix(40) {
            let first = SettingsMigration.migrate(settings)
            XCTAssertEqual(first, SettingsMigration.migrate(settings), label)
            XCTAssertEqual(try JSONDecoder().decode(GlimtSettingsV3.self, from: JSONEncoder().encode(first)), first, label)
        }
    }

    // MARK: - Schema 3 → 4 (ADR-022)

    func testStoredDefaultViewBecomesAnOverrideOnlyWhenItDiffers() {
        var v3 = GlimtSettingsV3.factoryDefaults
        v3.schemaVersion = 3
        v3[.json] = FormatSettings(defaultRepresentation: .raw, structured: .init(expandDepth: 2))
        v3[.yaml] = FormatSettings(defaultRepresentation: .tree)
        v3[.markdown] = FormatSettings(defaultRepresentation: .raw)
        v3[.swift] = FormatSettings(defaultRepresentation: .hex)
        v3[.csv] = FormatSettings(defaultRepresentation: .rendered)
        let migrated = SettingsMigration.migrateViews(v3)
        XCTAssertEqual(migrated.schemaVersion, 4)
        XCTAssertEqual(migrated.formatOverrides["json"], ["raw", "tree", "pretty"], "The chosen view moves to the front")
        XCTAssertNil(migrated.formatOverrides["yaml"], "Equal to the inherited default: no override")
        XCTAssertEqual(migrated.formatOverrides["markdown"], ["source", "rendered"])
        XCTAssertEqual(migrated.formatOverrides["swift"], ["hex", "source", "raw"], "A supported view outside the profile is kept")
        XCTAssertNil(migrated.formatOverrides["csv"], "An unsupported stored view is dropped")
        XCTAssertEqual(migrated[.json], FormatSettings(structured: .init(expandDepth: 2)), "Other format data is kept")
        XCTAssertNil(migrated.formats["yaml"])
        XCTAssertTrue(migrated.formats.values.allSatisfy { $0.defaultRepresentation == nil })
        XCTAssertEqual(SettingsMigration.migrateViews(migrated), migrated, "Idempotent")
        XCTAssertEqual(ViewResolver.resolve(migrated, for: .json).defaultView, .raw)
    }

    func testV2OpeningViewsSurviveMigration() {
        var legacy = GlimtSettings.factoryDefaults
        legacy.markdown.defaultPresentation = .raw
        legacy.structured.defaultPresentation = .pretty
        let migrated = SettingsMigration.migrate(legacy)
        XCTAssertEqual(ViewResolver.resolve(migrated, for: .markdown).defaultView, .source)
        for format in RenderConfiguration.structuredFormats {
            XCTAssertEqual(ViewResolver.resolve(migrated, for: format).defaultView, .pretty, format.rawValue)
        }
        XCTAssertEqual(migrated.schemaVersion, GlimtSettingsV3.currentSchemaVersion)
    }

    func testRetiredAppearanceIsKeptReportedAndDiscardedOnlyOnRequest() {
        var legacy = GlimtSettings.factoryDefaults
        legacy.source.languageOverrides["python"] = .init(fontSize: 15, showLineNumbers: false)
        legacy.structured.sortKeys = true
        var migrated = SettingsMigration.migrate(legacy)
        XCTAssertEqual(migrated.formatsWithRetiredAppearance, ["python"])
        XCTAssertEqual(RenderConfiguration(settings: migrated).source(for: .python).showLineNumbers, true, "Retired values are not applied")
        migrated.discardRetiredAppearance()
        XCTAssertEqual(migrated.formatsWithRetiredAppearance, [])
        XCTAssertNil(migrated.formats["python"])
        XCTAssertEqual(migrated[.json].structured?.sortKeys, true, "Format options survive the discard")
    }

    // MARK: - Random corpus

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
        mutating func maybe<T>(_ values: [T]) -> T? { next() % 3 == 0 ? pick(values) : nil }
    }

    private func randomSettings(_ g: inout SplitMix) -> GlimtSettings {
        var s = GlimtSettings.factoryDefaults
        s.general.maximumPreviewSize = g.pick(PreviewSizePreference.allCases)
        s.general.appearance = g.pick(PreviewAppearance.allCases)
        s.textCode = .init(fontFamily: g.pick(GlimtSettings.fontFamilies + ["Bogus"]), fontSize: g.pick([8, 11, 12, 17, 40]),
                           wordWrap: g.pick([true, false]), tabWidth: g.pick([0, 2, 4, 8, 9]))
        s.source.customThemes = g.pick([[], Self.themes])
        s.source.lightCustomThemeID = g.maybe(["l", "d", "missing"])
        s.source.darkCustomThemeID = g.maybe(["l", "d", "missing"])
        s.source.lightTheme = g.pick(SourceThemePreset.allCases)
        s.source.darkTheme = g.pick(SourceThemePreset.allCases)
        s.source.indentationGuides = g.pick([true, false])
        s.source.showLineNumbers = g.pick([true, false])
        for language in SourceLanguage.allCases where g.next() % 2 == 0 {
            s.source.languageOverrides[language.rawValue] = .init(
                lightTheme: g.maybe(SourceThemePreset.allCases), darkTheme: g.maybe(SourceThemePreset.allCases),
                lightCustomThemeID: g.maybe(["l", "d", "missing"]), darkCustomThemeID: g.maybe(["l", "d"]),
                indentationGuides: g.maybe([true, false]), fontFamily: g.maybe(GlimtSettings.fontFamilies + ["Bogus"]),
                fontSize: g.maybe([9, 14, 50]), showLineNumbers: g.maybe([true, false]), wordWrap: g.maybe([true, false]),
                tabWidth: g.maybe([1, 3, 8, 20]))
        }
        s.markdown = .init(defaultPresentation: g.pick(MarkdownPresentation.allCases), fontSize: g.pick([9, 13, 16, 30]),
                           profile: g.pick(MarkdownProfile.allCases), taskLists: g.pick([true, false]), strikethrough: g.pick([true, false]),
                           breakBehavior: g.pick(MarkdownBreakBehavior.allCases), frontMatter: g.pick(MarkdownFrontMatterMode.allCases),
                           tableOfContents: g.pick([true, false]))
        s.structured = .init(defaultPresentation: g.pick(StructuredPresentation.allCases), expandDepth: g.pick([0, 1, 2, 3, 5]), sortKeys: g.pick([true, false]))
        return s
    }
}
