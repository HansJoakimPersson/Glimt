import AppKit
import XCTest
import InspectorCore

/// F1.6–F1.8: the settings window model — persistence, overrides, filtering, data limit, themes.
@MainActor
final class SettingsSessionTests: XCTestCase {
    private var directory: URL!

    // The async variants run on the test class's main actor, where `directory` is isolated.
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtSettingsSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeSession() async -> SettingsSession {
        await SettingsSession.load(store: SettingsStore(directory: directory))
    }

    // MARK: Persistence

    func testEditsPersistAsV3() async throws {
        let session = await makeSession()
        session.update { $0.general.lineNumbers = false }
        await session.waitForPersistence()
        XCTAssertFalse(try SettingsStore(directory: directory).loadV3().settings.general.lineNumbers)
        XCTAssertEqual(session.statusMessage, "")
    }

    func testExternalChangeIsAdoptedInsteadOfOverwritten() async throws {
        let session = await makeSession()
        let other = SettingsStore(directory: directory)
        var external = GlimtSettingsV3.factoryDefaults
        external.general.tabsToSpaces = 8
        _ = try other.saveV3(external, replacing: try other.loadV3())

        session.update { $0.general.lineNumbers = false }
        await session.waitForPersistence()
        XCTAssertEqual(session.settings.general.tabsToSpaces, 8)
        XCTAssertTrue(session.settings.general.lineNumbers)
        XCTAssertEqual(session.statusMessage, SettingsStoreError.changedExternally.errorDescription)
        XCTAssertEqual(try other.loadV3().settings.general.tabsToSpaces, 8)
    }

    func testNewerSchemaIsReadOnlyAndUntouched() async throws {
        let future = Data(#"{"schemaVersion":5,"general":{"tabsToSpaces":8}}"#.utf8)
        let url = directory.appendingPathComponent(SettingsStore.v3Filename)
        try future.write(to: url)
        let session = await makeSession()
        XCTAssertFalse(session.canEdit)
        session.update { $0.general.lineNumbers = false }
        await session.waitForPersistence()
        XCTAssertTrue(session.settings.general.lineNumbers)
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertEqual(session.statusMessage, SettingsStoreError.newerSchema.errorDescription)
    }

    func testUnconfiguredStoreIsPreviewOnly() {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertTrue(session.canEdit)
        XCTAssertFalse(session.isPersistent)
        XCTAssertEqual(session.statusMessage, SettingsSession.unconfiguredMessage)
        session.update { $0.general.lineNumbers = false }
        XCTAssertFalse(session.settings.general.lineNumbers)
    }

    func testLoadFailureKeepsSettingsEditableInPreviewMode() async {
        let session = await SettingsSession.load(store: SettingsStore(directory: URL(fileURLWithPath: "/dev/null")))
        XCTAssertTrue(session.canEdit)
        XCTAssertFalse(session.isPersistent)
        XCTAssertEqual(session.statusMessage, SettingsStoreError.readFailed(CocoaError(.fileReadUnknown)).errorDescription)
        session.update { $0.general.lineNumbers = false }
        XCTAssertFalse(session.settings.general.lineNumbers)
    }

    /// D51: Color scheme is persisted and resolves into the render appearance.
    func testColorSchemeIsPersistedAndDrivesRenderAppearance() async throws {
        let session = await makeSession()
        session.update { $0.general.colorScheme = .dark }
        await session.waitForPersistence()
        XCTAssertEqual(session.renderConfiguration.appearance, .dark)
        let reloaded = await makeSession()
        XCTAssertEqual(reloaded.settings.general.colorScheme, .dark)
    }

    // MARK: Overrides

    func testRetiredOverridesCannotBeCreated() {
        let session = SettingsSession(store: nil, snapshot: nil)
        session.update { $0.general.lineNumbers = false }
        XCTAssertTrue(InheritableProperty.allCases.allSatisfy { FormatSettingsCapabilities.inheritable(for: .swift).contains($0) == false },
                      "ADR-022 retires every per-format appearance property")
        XCTAssertNil(session.settings.formats["swift"])
        XCTAssertFalse(EffectiveSettingsResolver.resolve(session.settings, for: .swift).lineNumbers.value)
    }

    func testStoredRetiredOverrideIsKeptButGeneralApplies() {
        let session = SettingsSession(store: nil, snapshot: nil)
        session.updateFormat(.swift) { $0.lineNumbers = .init(isEnabled: true, value: false) }
        XCTAssertTrue(EffectiveSettingsResolver.resolve(session.settings, for: .swift).lineNumbers.value)
        XCTAssertEqual(session.settings[.swift].lineNumbers, .init(isEnabled: true, value: false))
        XCTAssertEqual(session.settings.formatsWithRetiredAppearance, ["swift"])
    }

    // MARK: Data limit (D07)

    func testDataLimitConversionAndClampFeedback() {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.setDataLimit(amount: 512, unit: .kb))
        XCTAssertEqual(session.settings.general.dataLimitBytes, 524_288)
        XCTAssertEqual(session.settings.general.dataLimitDisplayUnit, .kb)
        XCTAssertEqual(session.setDataLimit(amount: 4, unit: .mb), "The maximum is 1 MiB (1024 KiB).")
        XCTAssertEqual(session.settings.general.dataLimitBytes, 1_048_576)
        XCTAssertEqual(session.setDataLimit(amount: 10, unit: .kb), "The minimum is 64 KiB.")
        XCTAssertEqual(session.settings.general.dataLimitBytes, 65_536)
        XCTAssertEqual(SettingsSession.formatDataLimit(65_536, unit: .mb), "0.0625")
        XCTAssertEqual(SettingsSession.formatDataLimit(1_048_576, unit: .kb), "1024")
        session.setDataLimitUnit(.mb)
        XCTAssertEqual(session.settings.general.dataLimitBytes, 65_536)
    }

    // MARK: Themes and mappings

    func testDeletingThemeClearsEveryAssignment() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let theme = try XCTUnwrap(session.duplicateTheme(.init(preset: .neutral), appearance: .dark, named: "Mine"))
        XCTAssertEqual(theme.basePreset, .neutral)
        session.update { $0.general.themeAssignment.dark.customThemeID = theme.id }
        // A retired per-format assignment is kept as data, so deletion must still clear it.
        let assignment = session.settings.general.themeAssignment
        session.updateFormat(.swift) { $0.themeAssignment = .init(isEnabled: true, value: assignment) }
        XCTAssertEqual(session.settings[.swift].themeAssignment?.value.dark.customThemeID, theme.id)

        session.deleteTheme(id: theme.id)
        XCTAssertTrue(session.settings.customThemes.isEmpty)
        XCTAssertNil(session.settings.general.themeAssignment.dark.customThemeID)
        XCTAssertNil(session.settings[.swift].themeAssignment?.value.dark.customThemeID)
    }

    func testThemeLimitAndRename() {
        let session = SettingsSession(store: nil, snapshot: nil)
        for index in 0..<16 { XCTAssertNotNil(session.duplicateTheme(.init(preset: .glimtDefault), appearance: .light, named: "T\(index)")) }
        XCTAssertNil(session.duplicateTheme(.init(preset: .glimtDefault), appearance: .light, named: "Extra"))
        let id = session.settings.customThemes[0].id
        session.renameTheme(id: id, to: "   ")
        XCTAssertEqual(session.settings.customThemes[0].name, "T0")
        session.renameTheme(id: id, to: "Renamed")
        XCTAssertEqual(session.themeName(for: .init(preset: .glimtDefault, customThemeID: id)), "Renamed")
    }

    func testInvalidMappingGivesFeedback() {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertEqual(session.addMapping(kind: .filename, value: "a/b", target: .yaml), SettingsSession.mappingInvalidMessage)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "conf", target: .yaml))
        XCTAssertEqual(session.settings.fileAssociations.count, 1)
        session.removeMapping(.init(kind: .fileExtension, value: "conf", target: .yaml))
        XCTAssertTrue(session.settings.fileAssociations.isEmpty)
    }

    // MARK: File mappings (D68)

    func testMappingsAreFilteredByTarget() {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "conf", target: .yaml))
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "customjson", target: .json))
        XCTAssertNil(session.addMapping(kind: .filename, value: "Brewfile", target: .yaml))
        XCTAssertEqual(session.mappings(for: .yaml).map(\.value), ["conf", "Brewfile"])
        XCTAssertEqual(session.mappings(for: .json).map(\.value), ["customjson"])
        XCTAssertTrue(session.mappings(for: .xml).isEmpty)
    }

    func testAddNormalizesAndRejectsConflictsAndDuplicatesWithoutReplacing() {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: " *.CustomJSON ", target: .json))
        XCTAssertEqual(session.settings.fileAssociations, [.init(kind: .fileExtension, value: "customjson", target: .json)])
        XCTAssertEqual(session.addMapping(kind: .fileExtension, value: ".customjson", target: .yaml),
                       "This extension is already mapped to JSON.")
        XCTAssertEqual(session.addMapping(kind: .fileExtension, value: "customjson", target: .json),
                       "This extension is already in the list.")
        XCTAssertNil(session.addMapping(kind: .filename, value: "Brewfile", target: .yaml))
        XCTAssertEqual(session.addMapping(kind: .filename, value: "Brewfile", target: .json),
                       "This filename is already mapped to YAML.")
        XCTAssertEqual(session.settings.fileAssociations, [.init(kind: .fileExtension, value: "customjson", target: .json),
                                                           .init(kind: .filename, value: "Brewfile", target: .yaml)],
                       "A conflict never replaces the existing mapping")
    }

    func testAddStopsAtTheStoredLimit() {
        let session = SettingsSession(store: nil, snapshot: nil)
        for index in 0..<SettingsSession.mappingLimit { XCTAssertNil(session.addMapping(kind: .fileExtension, value: "x\(index)", target: .text)) }
        XCTAssertEqual(session.addMapping(kind: .fileExtension, value: "extra", target: .text), SettingsSession.mappingLimitMessage)
        XCTAssertEqual(session.settings.fileAssociations.count, 64)
    }

    func testRemoveUsesTheFullKey() {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "conf", target: .yaml))
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "customjson", target: .json))
        session.removeMapping(.init(kind: .fileExtension, value: "conf", target: .json))
        session.removeMapping(.init(kind: .filename, value: "conf", target: .yaml))
        XCTAssertEqual(session.settings.fileAssociations.count, 2, "A key that differs in target or kind removes nothing")
        session.removeMapping(.init(kind: .fileExtension, value: "conf", target: .yaml))
        XCTAssertEqual(session.settings.fileAssociations, [.init(kind: .fileExtension, value: "customjson", target: .json)])
    }

    /// Mappings persist in the existing schema and never create view overrides.
    func testMappingsPersistWithoutSchemaChangeOrViewOverrides() async throws {
        let session = await makeSession()
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "customjson", target: .json))
        await session.waitForPersistence()
        let stored = try SettingsStore(directory: directory).loadV3().settings
        XCTAssertEqual(stored.schemaVersion, 4)
        XCTAssertEqual(GlimtSettingsV3.currentSchemaVersion, 4)
        XCTAssertEqual(stored.fileAssociations, [.init(kind: .fileExtension, value: "customjson", target: .json)])
        XCTAssertTrue(stored.formatOverrides.isEmpty)
        XCTAssertTrue(stored.categoryProfiles.isEmpty)
        let reloaded = await makeSession()
        XCTAssertEqual(reloaded.mappings(for: .json), stored.fileAssociations)
    }
}
