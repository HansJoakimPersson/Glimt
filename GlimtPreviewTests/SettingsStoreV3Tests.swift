import Foundation
import XCTest
import InspectorCore

/// F1.3/F1.4: version-safe v3 read, atomic separate-file write, downgrade and corruption handling.
final class SettingsStoreV3Tests: XCTestCase {
    private var directory: URL!
    private var v2URL: URL { directory.appendingPathComponent(SettingsStore.legacyFilename) }
    private var v3URL: URL { directory.appendingPathComponent(SettingsStore.v3Filename) }
    private var corruptURL: URL { directory.appendingPathComponent(SettingsStore.v3CorruptFilename) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtSettingsV3Store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func legacyFile(tabs: Int = 2) throws -> Data {
        var legacy = GlimtSettings.factoryDefaults
        legacy.textCode.tabWidth = tabs
        legacy.source.languageOverrides["swift"] = .init(showLineNumbers: false)
        try SettingsStore(directory: directory).save(legacy)
        return try Data(contentsOf: v2URL)
    }

    // MARK: - Read

    func testNoFilesYieldFactoryDefaults() throws {
        let snapshot = try SettingsStore(directory: directory).loadV3()
        XCTAssertEqual(snapshot.settings, .factoryDefaults)
        XCTAssertEqual(snapshot.origin, .factoryDefaults)
        XCTAssertNil(snapshot.fileContents)
    }

    func testSharedStoreUsesOneSettingsFileUnderCurrentUsersApplicationSupport() throws {
        let home = directory.appendingPathComponent("test-home", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent("Library/Application Support/Glimt", isDirectory: true)
        var settings = GlimtSettingsV3()
        settings.general.lineLength = 173

        let writer = try SettingsStore.shared(homeDirectory: home)
        let saved = try writer.saveV3(settings, replacing: writer.loadV3())
        let settingsFile = settingsDirectory.appendingPathComponent("settings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFile.path))
        XCTAssertEqual(saved.settings.general.lineLength, 173)

        let reader = try SettingsStore.shared(readOnly: true, homeDirectory: home)
        XCTAssertEqual(try reader.loadV3().settings.general.lineLength, 173)
        XCTAssertThrowsError(try reader.saveV3(.factoryDefaults, replacing: reader.loadV3())) { error in
            guard case SettingsStoreError.readOnly = error else { return XCTFail("Expected read-only error") }
        }
    }

    func testPreviewAdapterReadsTheCanonicalSettingsFile() throws {
        let home = directory.appendingPathComponent("adapter-home", isDirectory: true)
        let writer = try SettingsStore.shared(homeDirectory: home)
        var settings = GlimtSettingsV3()
        settings.general.lineNumbers = false
        settings.general.wordWrap = .hard
        _ = try writer.saveV3(settings, replacing: writer.loadV3())
        let settingsURL = home.appendingPathComponent("Library/Application Support/Glimt/settings.json")
        let bytesBeforeRead = try Data(contentsOf: settingsURL)

        let preview = PreviewViewController.savedConfiguration(homeDirectory: home)
        XCTAssertFalse(preview.source(for: .swift).showLineNumbers)
        XCTAssertEqual(preview.source(for: .swift).wrapMode, WordWrapMode.hard)
        XCTAssertEqual(try Data(contentsOf: settingsURL), bytesBeforeRead, "the preview adapter never rewrites settings")

        var replacement = settings
        replacement.general.lineLength = 211
        _ = try writer.saveV3(replacement, replacing: writer.loadV3())
        XCTAssertEqual(PreviewViewController.savedConfiguration(homeDirectory: home).source(for: .swift).lineLength, 211)
    }

    /// ADR-020/ADR-023: the shared paths come from the account's home, never a sandbox container.
    func testRealHomeComesFromThePasswordDatabase() throws {
        let entry = try XCTUnwrap(getpwuid(getuid()))
        let expected = String(cString: try XCTUnwrap(entry.pointee.pw_dir))
        XCTAssertEqual(SettingsStore.realHomeDirectory.path, expected)
        XCTAssertFalse(SettingsStore.realHomeDirectory.path.contains("/Library/Containers/"))
    }

    func testReadOnlyAdaptersUseFactoryValuesForMissingOrInvalidSettings() throws {
        let home = directory.appendingPathComponent("fallback-home", isDirectory: true)
        let settingsURL = home.appendingPathComponent("Library/Application Support/Glimt/settings.json")
        let missingPreview = PreviewViewController.savedConfiguration(homeDirectory: home)
        XCTAssertEqual(missingPreview, RenderConfiguration())
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))

        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptBytes = Data("not-json".utf8)
        try corruptBytes.write(to: settingsURL)
        XCTAssertEqual(PreviewViewController.savedConfiguration(homeDirectory: home), RenderConfiguration())
        XCTAssertEqual(try Data(contentsOf: settingsURL), corruptBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: settingsURL.deletingLastPathComponent().path), ["settings.json"])
    }

    func testHostMigratesV2ToCanonicalFileAndKeepsLegacySource() throws {
        let original = try legacyFile()
        let store = SettingsStore(directory: directory)
        let snapshot = try store.loadV3()
        XCTAssertEqual(snapshot.origin, .v3File)
        XCTAssertEqual(snapshot.settings.general.tabsToSpaces, 2)
        XCTAssertEqual(snapshot.settings[.swift].lineNumbers, .init(isEnabled: true, value: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v3URL.path), "the host writes migrated settings to the shared file")
        XCTAssertEqual(try Data(contentsOf: v2URL), original, "v2 file stays byte-identical")
    }

    func testV3FileTakesPrecedenceOverV2() throws {
        _ = try legacyFile(tabs: 2)
        let store = SettingsStore(directory: directory)
        var settings = GlimtSettingsV3()
        settings.general.tabsToSpaces = 6
        try store.saveV3(settings, replacing: try store.loadV3())
        let snapshot = try store.loadV3()
        XCTAssertEqual(snapshot.origin, .v3File)
        XCTAssertEqual(snapshot.settings.general.tabsToSpaces, 6)
    }

    func testDeletingV3FileFallsBackToV2() throws {
        _ = try legacyFile(tabs: 2)
        let store = SettingsStore(directory: directory)
        var settings = GlimtSettingsV3()
        settings.general.tabsToSpaces = 6
        try store.saveV3(settings, replacing: try store.loadV3())
        try FileManager.default.removeItem(at: v3URL)
        let snapshot = try store.loadV3()
        XCTAssertEqual(snapshot.origin, .v3File)
        XCTAssertEqual(snapshot.settings.general.tabsToSpaces, 2)
    }

    func testNewerSchemaIsReadButNeverOverwritten() throws {
        let future = Data(#"{"schemaVersion":5,"general":{"tabsToSpaces":8},"futureOnly":{"x":1}}"#.utf8)
        try future.write(to: v3URL)
        let store = SettingsStore(directory: directory)
        let snapshot = try store.loadV3()
        XCTAssertEqual(snapshot.origin, .newerSchema(5))
        XCTAssertFalse(snapshot.isWritable)
        XCTAssertEqual(snapshot.settings.general.tabsToSpaces, 8, "known fields still render")
        XCTAssertThrowsError(try store.saveV3(.factoryDefaults, replacing: snapshot)) { error in
            guard case SettingsStoreError.newerSchema = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try store.resetV3(replacing: snapshot))
        XCTAssertEqual(try Data(contentsOf: v3URL), future)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    func testCorruptFileIsBackedUpOnceAndFallsBackToV2() throws {
        _ = try legacyFile(tabs: 2)
        let first = Data(#"{"schemaVersion":3,"general":"#.utf8)
        try first.write(to: v3URL)
        let store = SettingsStore(directory: directory)
        let snapshot = try store.loadV3()
        XCTAssertEqual(snapshot.origin, .recoveredFromCorruptFile)
        XCTAssertEqual(snapshot.settings.general.tabsToSpaces, 2)
        XCTAssertEqual(try Data(contentsOf: corruptURL), first)
        XCTAssertEqual(try Data(contentsOf: v3URL), first, "corrupt file stays until an explicit save")

        try Data("garbage".utf8).write(to: v3URL)
        _ = try store.loadV3()
        XCTAssertEqual(try Data(contentsOf: corruptURL), first, "first backup is kept")

        let saved = try store.saveV3(snapshot.settings, replacing: try store.loadV3())
        XCTAssertEqual(saved.origin, .v3File)
        XCTAssertEqual(try store.loadV3().origin, .v3File)
    }

    func testOlderOrMissingSchemaVersionInV3FileIsTreatedAsCorrupt() throws {
        for contents in [#"{"schemaVersion":2}"#, #"{"general":{}}"#, "[]", ""] {
            try Data(contents.utf8).write(to: v3URL)
            XCTAssertEqual(try SettingsStore(directory: directory).loadV3().origin, .recoveredFromCorruptFile, contents)
        }
    }

    func testOversizedV3FileIsTreatedAsCorrupt() throws {
        try Data(repeating: 0x20, count: 300_000).write(to: v3URL)
        XCTAssertEqual(try SettingsStore(directory: directory).loadV3().origin, .recoveredFromCorruptFile)
    }

    func testSymbolicLinkV3FileIsRejected() throws {
        let target = directory.appendingPathComponent("elsewhere.json")
        try JSONEncoder().encode(GlimtSettingsV3()).write(to: target)
        try FileManager.default.createSymbolicLink(at: v3URL, withDestinationURL: target)
        XCTAssertThrowsError(try SettingsStore(directory: directory).loadV3())
    }

    func testReadOnlyStoreNeverWritesOrBacksUp() throws {
        try Data("garbage".utf8).write(to: v3URL)
        let store = SettingsStore(directory: directory, readOnly: true)
        let snapshot = try store.loadV3()
        XCTAssertEqual(snapshot.origin, .recoveredFromCorruptFile)
        XCTAssertEqual(snapshot.settings, .factoryDefaults, "read-only consumers do not migrate legacy settings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertThrowsError(try store.saveV3(.factoryDefaults, replacing: snapshot)) { error in
            guard case SettingsStoreError.readOnly = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: v3URL), Data("garbage".utf8))
    }

    // MARK: - Write

    func testInterruptedWriteLeavesPreviousFileReadable() throws {
        let store = SettingsStore(directory: directory)
        var settings = GlimtSettingsV3()
        settings.general.lineLength = 88
        try store.saveV3(settings, replacing: try store.loadV3())
        // A writer that died mid-way leaves only a stray temporary file; atomic replace never truncates the target.
        try Data(#"{"schemaVersion":3,"gen"#.utf8).write(to: directory.appendingPathComponent(".settings.json.partial"))
        XCTAssertEqual(try store.loadV3().settings.general.lineLength, 88)
    }

    func testSaveIsAtomicReplacementWithSortedKeys() throws {
        let store = SettingsStore(directory: directory)
        try store.saveV3(.factoryDefaults, replacing: try store.loadV3())
        let before = try FileManager.default.attributesOfItem(atPath: v3URL.path)[.systemFileNumber] as? Int
        var settings = GlimtSettingsV3()
        settings.general.wordWrap = .hard
        try store.saveV3(settings, replacing: try store.loadV3())
        let after = try FileManager.default.attributesOfItem(atPath: v3URL.path)[.systemFileNumber] as? Int
        XCTAssertNotEqual(before, after, "atomic write replaces the file rather than writing in place")
        let text = try String(contentsOf: v3URL, encoding: .utf8)
        XCTAssertTrue(text.contains(#""schemaVersion":4"#))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "customThemes")).lowerBound, try XCTUnwrap(text.range(of: "general")).lowerBound)
    }

    func testExternalChangeIsDetectedInsteadOfOverwritten() throws {
        let store = SettingsStore(directory: directory)
        let snapshot = try store.loadV3()
        var other = GlimtSettingsV3()
        other.general.tabsToSpaces = 3
        let otherSnapshot = try SettingsStore(directory: directory).saveV3(other, replacing: snapshot)
        XCTAssertThrowsError(try store.saveV3(.factoryDefaults, replacing: snapshot)) { error in
            guard case SettingsStoreError.changedExternally = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try store.loadV3().settings.general.tabsToSpaces, 3)
        XCTAssertNoThrow(try store.saveV3(.factoryDefaults, replacing: otherSnapshot))
    }

    func testExternalDeletionAfterLoadIsDetected() throws {
        let store = SettingsStore(directory: directory)
        let saved = try store.saveV3(.factoryDefaults, replacing: try store.loadV3())
        try FileManager.default.removeItem(at: v3URL)
        XCTAssertThrowsError(try store.saveV3(.factoryDefaults, replacing: saved))
    }

    func testConcurrentSavesNeverProduceAnUnreadableFile() throws {
        let store = SettingsStore(directory: directory)
        try store.saveV3(.factoryDefaults, replacing: try store.loadV3())
        let directory: URL = directory
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let writer = SettingsStore(directory: directory)
            guard let snapshot = try? writer.loadV3() else { return }
            var settings = snapshot.settings
            settings.general.lineLength = 20 + index
            _ = try? writer.saveV3(settings, replacing: snapshot)
        }
        let final = try store.loadV3()
        XCTAssertEqual(final.origin, .v3File)
        XCTAssertTrue((20..<60).contains(final.settings.general.lineLength))
    }

    func testResetWritesFactoryV3AndKeepsV2() throws {
        let original = try legacyFile()
        let store = SettingsStore(directory: directory)
        let reset = try store.resetV3(replacing: try store.loadV3())
        XCTAssertEqual(reset.settings, .factoryDefaults)
        XCTAssertEqual(try store.loadV3().settings, .factoryDefaults)
        XCTAssertEqual(try Data(contentsOf: v2URL), original)
    }

    func testSavedFileRoundTripsThroughRenderConfiguration() throws {
        let store = SettingsStore(directory: directory)
        var settings = GlimtSettingsV3()
        settings.general.wordWrap = .hard
        settings.formatOverrides["swift"] = ["raw", "source", "hex"]
        try store.saveV3(settings, replacing: try store.loadV3())
        let configuration = RenderConfiguration(settings: try SettingsStore(directory: directory, readOnly: true).loadV3().settings)
        XCTAssertEqual(configuration.source(for: .swift).wrapMode, .hard)
        XCTAssertEqual(configuration.configuredViews(for: .swift), [.raw, .source, .hex])
    }
}
