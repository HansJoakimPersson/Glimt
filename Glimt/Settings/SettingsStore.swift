import Foundation
import os

/// The only persistence boundary for settings. Every process resolves the user's same Application
/// Support file; Quick Look receives a read-only store and cannot save or reset it.
struct SettingsStore: Sendable {
    private let directory: URL
    private let migratesLegacy: Bool
    let readOnly: Bool
    static let legacyFilename = "Settings-v2.json"
    private static let maximumBytes = 65_536
    private static let logger = Logger(subsystem: "com.glimt.app", category: "settings")

    /// Creates a store rooted at `directory`; read-only stores cannot mutate persisted settings.
    init(directory: URL, readOnly: Bool = false, migratesLegacy: Bool = true) {
        self.directory = directory
        self.readOnly = readOnly
        self.migratesLegacy = migratesLegacy
    }

    /// The real user home from the password database. Inside the App Sandbox,
    /// `FileManager.homeDirectoryForCurrentUser` returns the process's private container, which
    /// differs between the host and each extension, so the home-relative exceptions would not apply.
    static var realHomeDirectory: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    /// Resolves the same real user home in the host and extensions, outside their private containers.
    static func shared(readOnly: Bool = false,
                       homeDirectory: URL = SettingsStore.realHomeDirectory) throws -> SettingsStore {
        let container = homeDirectory.appendingPathComponent("Library/Application Support/Glimt", isDirectory: true)
        logger.debug("Shared settings store configured; readOnly=\(readOnly, privacy: .public)")
        return .init(directory: container, readOnly: readOnly, migratesLegacy: false)
    }

    /// Legacy v2 file. Missing or invalid data yields factory values without rewriting the original file.
    func load() throws -> GlimtSettings {
        guard let data = try read(Self.legacyFilename, limit: Self.maximumBytes),
              let decoded = try? JSONDecoder().decode(GlimtSettings.self, from: data) else {
            Self.logger.debug("Legacy settings unavailable or invalid; using in-memory defaults")
            return .factoryDefaults
        }
        return decoded.normalized()
    }

    /// `nil` for an absent file or one over `limit`; other I/O failures are thrown.
    private func read(_ filename: String, limit: Int) throws -> Data? {
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let handle: FileHandle
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            // Do not follow a substituted symlink or accept a non-file where settings are expected.
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnknown)
            }
            handle = try FileHandle(forReadingFrom: url)
        }
        catch let error as CocoaError where Self.isMissingFile(error) { return nil }
        catch { throw SettingsStoreError.readFailed(error) }
        defer { try? handle.close() }
        let data: Data
        // The extra byte distinguishes a valid bounded document from an oversized one.
        do { data = try handle.read(upToCount: limit + 1) ?? Data() }
        catch { throw SettingsStoreError.readFailed(error) }
        return data.count <= limit ? data : Data()
    }

    /// Distinguishes absent files from permission and I/O failures that must remain visible.
    private static func isMissingFile(_ error: CocoaError) -> Bool {
        // Only absence means "not configured yet"; permission and I/O errors remain actionable failures.
        guard error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile else { return false }
        // FileHandle uses Cocoa code 4 for absent files on macOS; retain other I/O failures.
        if let cause = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return cause.domain == NSPOSIXErrorDomain && cause.code == Int(POSIXErrorCode.ENOENT.rawValue)
        }
        return error.code == .fileReadNoSuchFile
    }

    /// Atomically writes normalized legacy settings; read-only extension stores cannot write.
    func save(_ settings: GlimtSettings) throws {
        guard !readOnly else { throw SettingsStoreError.readOnly }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(settings.normalized())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic replacement prevents extensions from observing partially encoded settings.
            try data.write(to: directory.appendingPathComponent(Self.legacyFilename, isDirectory: false), options: .atomic)
            Self.logger.debug("Legacy settings saved atomically")
        } catch { throw SettingsStoreError.writeFailed(error) }
    }

    /// Replaces legacy settings with factory defaults and returns the value written.
    @discardableResult
    func reset() throws -> GlimtSettings {
        try save(.factoryDefaults)
        return .factoryDefaults
    }

    // MARK: - Schema 3 and 4 (ADR-015, ADR-022)

    static let v3Filename = "settings.json"
    static let v3CorruptFilename = "settings.corrupt.json"
    private static let v3MaximumBytes = 262_144
    /// Schema 3 files are read and migrated; anything older is not a `settings.json` this app wrote.
    static let oldestReadableSchemaVersion = 3

    /// `settings.json` when valid; otherwise the in-memory migration of the legacy v2 file, which
    /// is never rewritten. A newer schema is read leniently but marked read-only so a save can
    /// never downgrade it. A corrupt file is copied once to `settings.corrupt.json` only in
    /// migration-enabled stores; the production store stays within its exact-file entitlement.
    func loadV3() throws -> SettingsSnapshot {
        let data = try read(Self.v3Filename, limit: Self.v3MaximumBytes)
        guard let data else {
            let canMigrate = migratesLegacy && !readOnly
            let origin = canMigrate ? try legacyOrigin() : .factoryDefaults
            let settings = origin == .factoryDefaults ? GlimtSettingsV3.factoryDefaults : try migratedLegacy()
            if origin == .migratedFromV2, !readOnly {
                // Leave the legacy source intact; the new canonical file is atomically validated below.
                let legacySnapshot = SettingsSnapshot(settings: settings, origin: origin, fileContents: nil)
                return try saveV3(settings, replacing: legacySnapshot)
            }
            Self.logger.debug("V3 settings loaded from fallback; origin=\(String(describing: origin), privacy: .public)")
            return .init(settings: settings, origin: origin, fileContents: nil)
        }
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data), let version = probe.schemaVersion,
           version >= Self.oldestReadableSchemaVersion,
           let decoded = try? JSONDecoder().decode(GlimtSettingsV3.self, from: data) {
            let origin: SettingsSnapshot.Origin = version > GlimtSettingsV3.currentSchemaVersion ? .newerSchema(version) : .v3File
            // Schema 3 is migrated in memory and written as schema 4 on the next save (ADR-022).
            let settings = version < GlimtSettingsV3.currentSchemaVersion ? SettingsMigration.migrateViews(decoded) : decoded
            Self.logger.debug("V3 settings decoded; schema=\(version, privacy: .public) origin=\(String(describing: origin), privacy: .public)")
            return .init(settings: settings.normalized(), origin: origin, fileContents: data)
        }
        if !readOnly && migratesLegacy { backUpCorruptFile() }
        Self.logger.error("V3 settings were invalid; preserving the source and using safe fallback settings")
        let fallback = migratesLegacy && !readOnly ? try migratedLegacy() : GlimtSettingsV3.factoryDefaults
        return .init(settings: fallback, origin: .recoveredFromCorruptFile, fileContents: data)
    }

    /// Atomically replaces `settings.json`. `expected` is the snapshot the edit was based on;
    /// if the file changed since (another process or an external edit), nothing is written.
    @discardableResult
    func saveV3(_ settings: GlimtSettingsV3, replacing expected: SettingsSnapshot) throws -> SettingsSnapshot {
        guard !readOnly else { throw SettingsStoreError.readOnly }
        if case .newerSchema = expected.origin { throw SettingsStoreError.newerSchema }
        let current = try read(Self.v3Filename, limit: Self.v3MaximumBytes)
        // Compare exact bytes before writing so another process's edit cannot be silently overwritten.
        guard current == expected.fileContents else {
            Self.logger.notice("Settings save skipped because the persisted snapshot changed externally")
            throw SettingsStoreError.changedExternally
        }
        var normalized = settings.normalized()
        normalized.schemaVersion = GlimtSettingsV3.currentSchemaVersion
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(normalized)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(Self.v3Filename, isDirectory: false), options: .atomic)
            Self.logger.debug("V3 settings saved atomically; schema=\(normalized.schemaVersion, privacy: .public)")
        } catch { throw SettingsStoreError.writeFailed(error) }
        return .init(settings: normalized, origin: .v3File, fileContents: data)
    }

    /// Factory values written to the v3 file; the legacy v2 file is left untouched.
    @discardableResult
    func resetV3(replacing expected: SettingsSnapshot) throws -> SettingsSnapshot {
        try saveV3(.factoryDefaults, replacing: expected)
    }

    /// Converts the legacy model in memory; migration never rewrites its source file.
    private func migratedLegacy() throws -> GlimtSettingsV3 { SettingsMigration.migrate(try load()) }

    /// Identifies whether v3 loading will use defaults or migrate an existing v2 file.
    private func legacyOrigin() throws -> SettingsSnapshot.Origin {
        try read(Self.legacyFilename, limit: Self.maximumBytes) == nil ? .factoryDefaults : .migratedFromV2
    }

    /// Preserves the first corrupt v3 file once so recovery never destroys the source evidence.
    private func backUpCorruptFile() {
        let source = directory.appendingPathComponent(Self.v3Filename, isDirectory: false)
        let backup = directory.appendingPathComponent(Self.v3CorruptFilename, isDirectory: false)
        // copyItem never overwrites, so the first corrupt file is the one kept.
        // A best-effort copy preserves evidence for recovery without preventing readable fallback settings.
        try? FileManager.default.copyItem(at: source, to: backup)
    }

    private struct SchemaProbe: Decodable { let schemaVersion: Int? }
}

/// The settings a session works from, plus the exact v3 bytes they were read from so a later
/// save can detect a concurrent or external change.
struct SettingsSnapshot: Equatable, Sendable {
    /// Describes whether the snapshot came from disk, migration, defaults, or recovery.
    enum Origin: Equatable, Sendable {
        case v3File, migratedFromV2, factoryDefaults, recoveredFromCorruptFile
        case newerSchema(Int)
    }
    let settings: GlimtSettingsV3
    let origin: Origin
    let fileContents: Data?
    var isWritable: Bool { if case .newerSchema = origin { false } else { true } }
}

/// User-facing failure cases for loading and saving shared settings.
enum SettingsStoreError: LocalizedError {
    case unavailable
    case readOnly
    case readFailed(Error)
    case writeFailed(Error)
    case newerSchema
    case changedExternally

    var errorDescription: String? {
        switch self {
        case .unavailable: "Shared settings are unavailable. Check the settings file location and access."
        case .readOnly: "Settings cannot be changed from this preview."
        case .readFailed: "Unable to read shared settings."
        case .writeFailed: "Unable to save shared settings."
        case .newerSchema: "These settings were saved by a newer version of Glimt and cannot be changed here."
        case .changedExternally: "Settings were changed elsewhere. The latest settings have been loaded; apply your change again."
        }
    }
}
