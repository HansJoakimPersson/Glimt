import Foundation
import XCTest
import InspectorCore

/// F1.1: persisted v3 model, lenient decoding, clamps and the pure effective-value resolver (ADR-015).
final class SettingsV3Tests: XCTestCase {
    private let supported = FormatID.allCases.filter { FormatCatalog.definition(for: $0)?.status == .supported }

    // MARK: - Codable

    func testFactoryDefaultsMatchAcceptedDecisions() {
        let general = GlimtSettingsV3.factoryDefaults.general
        XCTAssertEqual(GlimtSettingsV3.factoryDefaults.schemaVersion, 4)
        XCTAssertEqual(general.font, FontSetting(family: "System Monospaced", size: 12))
        XCTAssertEqual(general.wordWrap, .soft)
        XCTAssertEqual(general.lineLength, 120, "D10")
        XCTAssertTrue(general.lineNumbers)
        XCTAssertFalse(general.vcsSupportEnabled, "Repository reads are opt-in")
        XCTAssertFalse(general.debugLoggingEnabled, "Debug logging is opt-in (ADR-023)")
        XCTAssertTrue(general.debugBuildMarker, "Debug builds show their build time until it is turned off")
        XCTAssertEqual(general.tabsToSpaces, 4, "D06")
        XCTAssertEqual(general.dataLimitBytes, 1_048_576, "D07")
        XCTAssertEqual(general.themeAssignment, ThemeAssignment())
        XCTAssertTrue(GlimtSettingsV3.factoryDefaults.formats.isEmpty)
    }

    /// D62: files written before thumbnail settings were retired still decode. The retired general
    /// `thumbnails` group and per-format `thumbnail*` overrides are read past, every other value is kept,
    /// and the next save omits them.
    func testRetiredThumbnailKeysDecodeAreIgnoredAndDroppedOnSave() throws {
        let data = Data(#"{"schemaVersion":3,"general":{"lineNumbers":false,"wordWrap":"off","thumbnails":{"textScale":1.1,"lineNumbers":true,"maximumLines":40}},"formats":{"python":{"lineNumbers":{"isEnabled":true,"value":true},"thumbnailTextScale":{"isEnabled":true,"value":1.2},"thumbnailLineNumbers":{"isEnabled":true,"value":false},"thumbnailMaximumLines":{"isEnabled":false,"value":30}},"json":{"thumbnailMaximumLines":{"isEnabled":true,"value":12},"defaultRepresentation":"raw"}}}"#.utf8)
        let decoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: data)
        XCTAssertFalse(decoded.general.lineNumbers)
        XCTAssertEqual(decoded.general.wordWrap, .off)
        XCTAssertEqual(decoded[.python], FormatSettings(lineNumbers: .init(isEnabled: true, value: true)))
        XCTAssertEqual(decoded[.json], FormatSettings(defaultRepresentation: .raw))

        let reencoded = try XCTUnwrap(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        XCTAssertFalse(reencoded.contains("thumbnail"), "Retired thumbnail keys are not written back")
        XCTAssertEqual(try JSONDecoder().decode(GlimtSettingsV3.self, from: Data(reencoded.utf8)), decoded)
    }

    func testRoundTripPreservesEveryField() throws {
        var settings = GlimtSettingsV3()
        settings.general.wordWrap = .hard
        settings.general.lineLength = 80
        settings.general.tabsToSpaces = 0
        settings.general.vcsSupportEnabled = true
        settings.general.debugLoggingEnabled = true
        settings.general.debugBuildMarker = false
        settings.general.dataLimitBytes = 262_144
        settings.general.dataLimitDisplayUnit = .kb
        settings[.swift] = FormatSettings(
            font: .init(isEnabled: false, value: .init(family: "Menlo", size: 14)),
            themeAssignment: .init(isEnabled: true, value: .init(light: .init(preset: .neutral), dark: .init(preset: .highContrast))),
            lineNumbers: .init(isEnabled: true, value: false),
            indentationGuides: true)
        settings[.json] = FormatSettings(defaultRepresentation: .raw, structured: .init(expandDepth: 3, sortKeys: true))
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(GlimtSettingsV3.self, from: data), settings)
    }

    func testInvalidFieldsFallBackIndividuallyWithoutDiscardingTheFile() throws {
        let json = """
        {"schemaVersion":3,
         "general":{"wordWrap":"diagonal","lineLength":90,"lineNumbers":"yes","vcsSupportEnabled":"yes","debugLoggingEnabled":"yes","debugBuildMarker":"no","tabsToSpaces":2},
         "customThemes":[42,{"bogus":true}],
         "formats":{"swift":{"wordWrap":{"isEnabled":true,"value":"hard"},"lineNumbers":{"isEnabled":"x"}},
                    "json":{"defaultRepresentation":"sideways","structured":{"expandDepth":2}}},
         "fileAssociations":"nope"}
        """
        let decoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.general.wordWrap, .soft)
        XCTAssertEqual(decoded.general.lineLength, 90)
        XCTAssertTrue(decoded.general.lineNumbers)
        XCTAssertFalse(decoded.general.vcsSupportEnabled)
        XCTAssertFalse(decoded.general.debugLoggingEnabled)
        XCTAssertTrue(decoded.general.debugBuildMarker)
        XCTAssertEqual(decoded.general.tabsToSpaces, 2)
        XCTAssertTrue(decoded.customThemes.isEmpty)
        XCTAssertEqual(decoded[.swift].wordWrap, .init(isEnabled: true, value: .hard))
        XCTAssertNil(decoded[.swift].lineNumbers)
        XCTAssertNil(decoded[.json].defaultRepresentation)
        XCTAssertEqual(decoded[.json].structured, .init(expandDepth: 2))
        XCTAssertTrue(decoded.fileAssociations.isEmpty)
    }

    /// Text font is additive: missing decodes to System, unknown families normalize to System,
    /// and the value reaches the Markdown render configuration.
    func testTextFontIsAdditiveAndReachesMarkdownConfiguration() throws {
        let legacy = try JSONDecoder().decode(GlimtSettingsV3.self, from: Data(#"{"schemaVersion":3,"general":{"tabsToSpaces":2}}"#.utf8))
        XCTAssertEqual(legacy.general.textFont, "System")
        var settings = GlimtSettingsV3.factoryDefaults
        settings.general.textFont = "Comic Sans"
        XCTAssertEqual(settings.normalized().general.textFont, "System")
        settings.general.textFont = "Georgia"
        let decoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.general.textFont, "Georgia")
        XCTAssertEqual(RenderConfiguration(settings: decoded).markdown.textFont, "Georgia")
    }

    func testNewerSchemaVersionIsDecodedAsIsAndNotRewritten() throws {
        let decoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: Data("{\"schemaVersion\":7}".utf8))
        XCTAssertEqual(decoded.schemaVersion, 7)
        XCTAssertEqual(decoded.normalized().schemaVersion, 7)
    }

    func testUnknownFormatKeysArePreservedButNeverResolved() throws {
        let json = "{\"formats\":{\"rust\":{\"lineNumbers\":{\"isEnabled\":true,\"value\":false}}}}"
        let decoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: Data(json.utf8)).normalized()
        XCTAssertNotNil(decoded.formats["rust"])
        let encoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(encoded.formats["rust"], decoded.formats["rust"])
    }

    // MARK: - Clamps

    func testClampsCoverDocumentedRanges() {
        var general = GeneralSettingsV3()
        general.lineLength = 5; general.tabsToSpaces = 99; general.dataLimitBytes = 10
        general.font = .init(family: "Comic Sans", size: 200)
        let low = general.normalized()
        XCTAssertEqual(low.lineLength, 20)
        XCTAssertEqual(low.tabsToSpaces, 16)
        XCTAssertEqual(low.dataLimitBytes, 65_536)
        XCTAssertEqual(low.font, .init(family: "System Monospaced", size: 32))
        general.lineLength = 9_999; general.tabsToSpaces = -1; general.dataLimitBytes = 50_000_000
        let high = general.normalized()
        XCTAssertEqual(high.lineLength, 400)
        XCTAssertEqual(high.tabsToSpaces, 0)
        XCTAssertEqual(high.dataLimitBytes, 1_048_576)
        XCTAssertEqual(GeneralSettingsV3.clampDataLimit(300_000), 299_008, "rounds down to whole KiB")
        XCTAssertEqual(general.normalized(), general.normalized().normalized())
    }

    func testDataLimitUsesBinaryUnits() {
        XCTAssertEqual(DataLimitUnit.kb.bytes, 1_024)
        XCTAssertEqual(DataLimitUnit.mb.bytes, 1_048_576)
    }

    func testVCSSettingReachesPreviewConfigurationAndDefaultsOff() {
        var settings = GlimtSettingsV3()
        XCTAssertFalse(RenderConfiguration(settings: settings).vcsSupportEnabled)
        settings.general.vcsSupportEnabled = true
        XCTAssertTrue(RenderConfiguration(settings: settings).vcsSupportEnabled)
    }

    func testEmptyFormatEntryIsRemovedThroughSubscript() {
        var settings = GlimtSettingsV3()
        settings[.swift] = FormatSettings(lineNumbers: .init(isEnabled: true, value: false))
        XCTAssertNotNil(settings.formats["swift"])
        settings[.swift] = FormatSettings()
        XCTAssertNil(settings.formats["swift"])
    }

    func testFormatEntryCountIsBounded() {
        var settings = GlimtSettingsV3()
        for index in 0..<600 { settings.formats["f\(index)"] = FormatSettings(indentationGuides: true) }
        XCTAssertEqual(settings.normalized().formats.count, GlimtSettingsV3.maximumFormatEntries)
    }

    // MARK: - Applicability

    func testFormatCapabilitiesMatchTheVerifiedInventory() {
        for format in supported {
            XCTAssertTrue(FormatSettingsCapabilities.inheritable(for: format).isEmpty, "ADR-022 retires per-format appearance: \(format.rawValue)")
            switch format {
            case _ where FormatCatalog.definition(for: format)?.sourceLanguage != nil:
                XCTAssertTrue(FormatSettingsCapabilities.hasIndentationGuides(format))
                let expected = FormatCatalog.definition(for: format)!.availableRepresentations.compactMap {
                    DefaultRepresentation(rawValue: $0.rawValue)
                }
                XCTAssertEqual(FormatSettingsCapabilities.representations(for: format), expected)
            case .text:
                XCTAssertFalse(FormatSettingsCapabilities.hasIndentationGuides(format))
            case .markdown:
                XCTAssertEqual(FormatSettingsCapabilities.representations(for: format), [.rendered, .source])
                XCTAssertTrue(FormatSettingsCapabilities.hasMarkdownOptions(format))
            case .json, .yaml, .xml, .plist:
                let expected: [DefaultRepresentation] = format == .json ? [.tree, .pretty, .raw, .hex]
                    : format == .xml ? [.table, .tree, .pretty, .raw] : [.tree, .pretty, .raw]
                XCTAssertEqual(FormatSettingsCapabilities.representations(for: format), expected)
                XCTAssertTrue(FormatSettingsCapabilities.hasStructuredOptions(format))
            case .csv, .tsv:
                XCTAssertEqual(FormatSettingsCapabilities.representations(for: format), [.table, .raw, .hex])
            case .diff, .jsonl, .log:
                let expected: [DefaultRepresentation] = format == .diff ? [.diff, .raw] : format == .log ? [.table, .tree, .raw] : [.tree, .raw]
                XCTAssertEqual(FormatSettingsCapabilities.representations(for: format), expected)
            default:
                let expected = FormatCatalog.definition(for: format)?.availableRepresentations.compactMap {
                    DefaultRepresentation(rawValue: $0.rawValue)
                } ?? []
                XCTAssertEqual(FormatSettingsCapabilities.representations(for: format), expected, format.rawValue)
            }
        }
        XCTAssertEqual(supported.count, FormatCatalog.supported.count)
    }

    // MARK: - Resolver

    func testFactoryResolutionInheritsGeneralEverywhere() {
        for format in supported {
            let resolved = EffectiveSettingsResolver.resolve(.factoryDefaults, for: format)
            XCTAssertEqual(resolved.font.origin, .general)
            XCTAssertEqual(resolved.wordWrap.value, .soft)
            XCTAssertEqual(resolved.tabsToSpaces.value, 4)
            XCTAssertEqual(resolved.indentationGuides.value, FormatSettingsCapabilities.hasIndentationGuides(format), "guides on by default for source only")
            XCTAssertEqual(resolved.defaultRepresentation, FormatSettingsCapabilities.factoryDefaultRepresentation(for: format))
        }
    }

    /// ADR-022: stored per-format appearance is kept as data but never applied.
    func testRetiredOverridesAreKeptButNotApplied() {
        var settings = GlimtSettingsV3()
        settings.general.lineNumbers = true
        settings.general.font = .init(family: "Menlo", size: 11)
        settings[.python] = FormatSettings(lineNumbers: .init(isEnabled: true, value: false))
        settings[.c] = FormatSettings(font: .init(isEnabled: true, value: .init(family: "Monaco", size: 16)))
        settings[.shell] = FormatSettings(lineLength: .init(isEnabled: true, value: 1), tabsToSpaces: .init(isEnabled: true, value: 50))
        XCTAssertEqual(EffectiveSettingsResolver.resolve(settings, for: .python).lineNumbers, .init(value: true, origin: .general))
        XCTAssertEqual(EffectiveSettingsResolver.resolve(settings, for: .c).font.value, .init(family: "Menlo", size: 11))
        XCTAssertEqual(settings[.python].lineNumbers?.value, false, "The retired value is kept")
        XCTAssertEqual(settings.normalized()[.shell].lineLength?.value, 20, "Kept values stay clamped")
        XCTAssertEqual(settings.normalized()[.shell].tabsToSpaces?.value, 16)
        XCTAssertEqual(settings.formatsWithRetiredAppearance, ["c", "python", "shell"])
    }

    func testGeneralChangesPropagateToEveryFormat() {
        var settings = GlimtSettingsV3()
        settings[.swift] = FormatSettings(wordWrap: .init(isEnabled: true, value: .off))
        settings.general.wordWrap = .hard
        for format: FormatID in [.swift, .java, .text] {
            XCTAssertEqual(EffectiveSettingsResolver.resolve(settings, for: format).wordWrap.value, .hard, format.rawValue)
        }
    }

    /// Guides are a General setting drawn only by the source renderer.
    func testIndentationGuidesComeFromGeneralForSourceOnly() {
        var settings = GlimtSettingsV3()
        settings.general.indentationGuides = true
        XCTAssertEqual(EffectiveSettingsResolver.resolve(settings, for: .swift).indentationGuides, .init(value: true, origin: .general))
        settings[.python] = FormatSettings(indentationGuides: false)
        XCTAssertTrue(EffectiveSettingsResolver.resolve(settings, for: .python).indentationGuides.value, "A retired format value is ignored")
        XCTAssertFalse(EffectiveSettingsResolver.resolve(settings, for: .json).indentationGuides.value, "no guides outside source")
        let decoded = try? JSONDecoder().decode(GlimtSettingsV3.self, from: Data(#"{"schemaVersion":3,"formats":{"swift":{"indentationGuides":true}}}"#.utf8))
        XCTAssertEqual(decoded?.general.indentationGuides, true, "missing General field reads as the factory value (on)")
        XCTAssertEqual(decoded?[.swift].indentationGuides, true, "earlier format value kept as data")
    }

    func testDefaultViewComesFromTheViewResolver() {
        var settings = GlimtSettingsV3()
        settings[.json] = FormatSettings(defaultRepresentation: .rendered)
        XCTAssertEqual(EffectiveSettingsResolver.resolve(settings, for: .json).defaultRepresentation, .tree, "a stored field is not consulted")
        settings.formatOverrides["json"] = ["pretty", "raw"]
        XCTAssertEqual(EffectiveSettingsResolver.resolve(settings, for: .json).defaultRepresentation, .pretty)
    }

    func testResolverIsDeterministic() {
        var settings = GlimtSettingsV3()
        settings[.yaml] = FormatSettings(structured: .init(expandDepth: 2, sortKeys: true))
        settings.formatOverrides["yaml"] = ["pretty", "tree"]
        XCTAssertEqual(EffectiveSettingsResolver.resolve(settings, for: .yaml), EffectiveSettingsResolver.resolve(settings, for: .yaml))
    }

    // MARK: - Render configuration

    func testRenderConfigurationUsesGeneralValuesAndFormatOptions() {
        var settings = GlimtSettingsV3()
        settings.general.tabsToSpaces = 0
        settings.general.dataLimitBytes = 262_144
        settings.general.wordWrap = .hard
        settings.general.lineLength = 72
        settings.general.indentationGuides = true
        settings[.yaml] = FormatSettings(structured: .init(expandDepth: 3, sortKeys: true))
        settings.formatOverrides["yaml"] = ["raw", "tree"]
        settings.formatOverrides["markdown"] = ["source", "rendered"]
        let configuration = RenderConfiguration(settings: settings)
        XCTAssertEqual(configuration.appearance, .system)
        XCTAssertEqual(configuration.maximumPreviewBytes, 262_144)
        XCTAssertEqual(configuration.source(for: .swift).wrapMode, .hard)
        XCTAssertEqual(configuration.source(for: .swift).lineLength, 72)
        XCTAssertTrue(configuration.source(for: .swift).indentationGuides)
        XCTAssertEqual(configuration.source(for: .java), configuration.source(for: .swift))
        XCTAssertEqual(configuration.source(for: .java).tabWidth, 4, "0 keeps tabs at the default stop")
        XCTAssertEqual(configuration.text.tabsToSpaces, 0)
        XCTAssertEqual(configuration.structured(for: .yaml), .init(sortKeys: true, expandDepth: 3))
        XCTAssertEqual(configuration.configuredViews(for: .yaml), [.raw, .tree])
        XCTAssertEqual(configuration.configuredViews(for: .json), [.tree, .pretty, .raw])
        XCTAssertEqual(configuration.configuredViews(for: .markdown), [.source, .rendered])
    }

    func testCustomPaletteIsResolvedFromThemeAssignment() {
        var settings = GlimtSettingsV3()
        let component = SourceThemeColor(red: 0.2, green: 0.3, blue: 0.4)
        let palette = SourceThemePalette(background: component, foreground: component, comment: component,
            keyword: component, string: component, number: component, type: component, directive: component)
        let theme = CustomSourceTheme(id: "mine", name: "Mine", appearance: .dark, basePreset: .highContrast, palette: palette)
        settings.customThemes = [theme]
        settings.general.themeAssignment.dark = .init(preset: .highContrast, customThemeID: "mine")
        let configuration = RenderConfiguration(settings: settings)
        XCTAssertEqual(configuration.source(for: .swift).darkPalette, theme.palette.normalized())
        XCTAssertNil(configuration.source(for: .swift).lightPalette)
    }
}
