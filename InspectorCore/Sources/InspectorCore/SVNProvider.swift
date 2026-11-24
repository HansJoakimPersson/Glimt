import CSQLite
import CryptoKit
import Darwin
import Foundation

/// Reads one local Subversion working-copy entry from `wc.db` and its existing pristine file.
/// It deliberately does not invoke libsvn: the current working-copy API can hydrate metadata
/// depending on the working-copy policy, while this provider never opens SQLite for writing.
public struct SVNProvider: VCSProvider {
    public let repositoryType: VCSRepositoryType = .svn
    private let maximumLookupDepth: Int

    /// Creates a provider with a capped parent-directory search depth.
    public init(maximumLookupDepth: Int = 64) {
        // Repository discovery is intentionally capped even when a caller supplies a larger depth.
        self.maximumLookupDepth = min(maximumLookupDepth, 64)
    }

    /// Reads local working-copy metadata only; it never invokes svn or opens the SQLite database for writing.
    public func inspect(fileURL: URL) async -> VCSProviderInspection {
        guard !Task.isCancelled else { return .notRepository }
        guard fileURL.isFileURL else { return .notRepository }
        switch VCSFileSystem.locateSVNRoot(for: fileURL, maximumDepth: maximumLookupDepth) {
        case .none:
            return .notRepository
        case .unsafe:
            return .inspected(unavailable(.unsafePath))
        case .root(let root):
            do { return .inspected(try inspect(fileURL: fileURL, root: root)) }
            catch VCSProviderError.unsafePath { return .inspected(unavailable(.unsafePath)) }
            catch VCSProviderError.missingMetadata { return .inspected(unavailable(.repositoryMetadataMissing)) }
            catch VCSProviderError.resourceLimit { return .inspected(unavailable(.resourceLimitReached)) }
            catch VCSLineDiffError.binaryContent, VCSLineDiffError.unsupportedEncoding {
                return .inspected(unavailable(.unsupportedContent))
            }
            catch VCSLineDiffError.inputTooLarge, VCSLineDiffError.comparisonTooLarge, VCSLineDiffError.timeLimitReached {
                return .inspected(unavailable(.resourceLimitReached))
            }
            catch { return .inspected(unavailable(.repositoryNotReadable)) }
        }
    }

    /// Compares one validated working-copy path with its verified pristine base and maps its status.
    private func inspect(fileURL: URL, root: URL) throws -> VCSInspectionResult {
        // Refuse paths that escape the discovered worktree or traverse a symlink before reading metadata.
        guard let relativePath = VCSFileSystem.relativePath(of: fileURL, under: root),
              !VCSFileSystem.hasSymlinkComponent(fileURL, stoppingAt: root) else { throw VCSProviderError.unsafePath }

        let databaseURL = root.appendingPathComponent(".svn", isDirectory: true).appendingPathComponent("wc.db")
        guard VCSFileSystem.kind(databaseURL) == .regular else { throw VCSProviderError.unsafePath }
        let database = try SVNDatabase(url: databaseURL, workingCopyRoot: root)
        let node = try database.node(relativePath: relativePath)
        guard let node else {
            guard VCSFileSystem.kind(fileURL) == .regular else { return unavailable(.comparisonUnavailable) }
            return .init(repositoryType: .svn, fileStatus: .untracked, comparison: nil)
        }
        if node.conflicted {
            return .init(repositoryType: .svn, fileStatus: .conflicted, comparison: nil)
        }

        let base = node.base
        let working = node.working
        if let working, working.presence == "base-deleted" {
            guard let base, let checksum = base.checksum else {
                return unavailable(.comparisonUnavailable)
            }
            let pristine = try database.pristine(checksum: checksum)
            let diff = try VCSLineDiff.compare(baseline: pristine, working: Data())
            return .init(repositoryType: .svn, fileStatus: .deleted,
                         comparison: .init(base: .svnBase, lineDiff: diff))
        }
        if let working, working.presence == "normal" {
            let status: VCSFileStatus = base == nil ? .added : .replaced
            if base != nil, try database.hasKeywordTranslation(wcID: node.wcID, relativePath: relativePath) {
                return unavailable(.comparisonUnavailable)
            }
            guard let current = try VCSFileSystem.readRegularFile(fileURL) else {
                return unavailable(.comparisonUnavailable)
            }
            let baseline = try base.flatMap { $0.checksum }.map { try database.pristine(checksum: $0) } ?? Data()
            let diff = try VCSLineDiff.compare(baseline: baseline, working: current)
            return .init(repositoryType: .svn, fileStatus: status,
                         comparison: .init(base: .svnBase, lineDiff: diff))
        }
        guard let base, base.presence == "normal", base.kind == "file", let checksum = base.checksum else {
            return unavailable(.repositoryMetadataMissing)
        }
        guard try !database.hasKeywordTranslation(wcID: node.wcID, relativePath: relativePath) else {
            return unavailable(.comparisonUnavailable)
        }
        guard let current = try VCSFileSystem.readRegularFile(fileURL) else {
            return unavailable(.comparisonUnavailable)
        }
        let pristine = try database.pristine(checksum: checksum)
        let diff = try VCSLineDiff.compare(baseline: pristine, working: current)
        return .init(repositoryType: .svn, fileStatus: diff.changes.isEmpty ? .clean : .modified,
                     comparison: .init(base: .svnBase, lineDiff: diff))
    }

    /// Constructs a result that distinguishes unavailable metadata from a clean working copy.
    private func unavailable(_ diagnostic: VCSDiagnostic) -> VCSInspectionResult {
        .init(repositoryType: .svn, fileStatus: .unavailable, comparison: nil, diagnostics: [diagnostic])
    }
}

/// Internal failures mapped to safe unavailable statuses by the provider boundary.
private enum VCSProviderError: Error { case unsafePath, missingMetadata, resourceLimit }

/// Non-following filesystem checks used to contain repository lookup and file reads.
private enum VCSFileSystem {
    /// `lstat` classification for entries that may be absent, regular, directories, or unsafe.
    enum EntryKind { case regular, directory, other }
    /// Result of the bounded parent walk for a Subversion working-copy root.
    enum SVNRoot { case none, unsafe, root(URL) }

    /// Uses `lstat` so symlinks are classified as unsafe entries rather than followed.
    static func kind(_ url: URL) -> EntryKind? {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in path.map { lstat($0, &info) == 0 } ?? false }) else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFDIR: return .directory
        default: return .other
        }
    }

    /// Walks parent directories up to the configured cap and accepts only a regular `wc.db` entry.
    static func locateSVNRoot(for fileURL: URL, maximumDepth: Int) -> SVNRoot {
        // Normalize known system aliases for lookup while validating repository-internal components separately.
        let file = normalizedForLookup(fileURL)
        // System aliases such as /tmp may be symlinks; paths inside the discovered working copy
        // are checked separately before metadata or file reads.
        guard file.isFileURL, kind(file) != .directory, kind(file) != .other else { return .unsafe }
        var directory = file.deletingLastPathComponent()
        for _ in 0..<max(1, maximumDepth) {
            // Do not cross a parent symlink while searching for a repository root.
            guard kind(directory) == .directory else { return .none }
            let admin = directory.appendingPathComponent(".svn", isDirectory: true)
            if kind(admin) == .directory {
                let db = admin.appendingPathComponent("wc.db")
                if kind(db) == .regular { return .root(directory) }
                if kind(db) != nil { return .unsafe }
            } else if kind(admin) != nil { return .unsafe }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return .none }
            directory = parent
        }
        return .none
    }

    /// Produces a slash-separated lookup key only for a strict descendant without dot segments.
    static func relativePath(of fileURL: URL, under root: URL) -> String? {
        // Convert to a repository-relative SQL key only after proving strict containment under the root.
        let path = normalizedForLookup(fileURL).path
        let rootPath = root.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/")
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    /// Checks every repository-relative component so later reads cannot cross a symlink boundary.
    static func hasSymlinkComponent(_ fileURL: URL, stoppingAt root: URL) -> Bool {
        let path = normalizedForLookup(fileURL)
        let rootPath = root.path
        guard path.path.hasPrefix(rootPath + "/") else { return true }
        var current = root
        for component in path.path.dropFirst(rootPath.count + 1).split(separator: "/") {
            current.appendPathComponent(String(component))
            if kind(current) == .other { return true }
        }
        return false
    }

    /// Standardizes ordinary paths while preserving known aliases used to locate a working copy.
    private static func normalizedForLookup(_ url: URL) -> URL {
        kind(url) == nil ? url : url.standardizedFileURL
    }

    /// Returns a complete bounded read for regular files and reports oversized files as unavailable.
    static func readRegularFile(_ url: URL) throws -> Data? {
        // Use the shared bounded reader and reject a file whose retained prefix is incomplete.
        guard kind(url) == .regular else { return nil }
        let prefix = try BoundedFileReader.readPrefix(at: url, maximumBytes: 1_048_576)
        guard prefix.isComplete else { throw VCSProviderError.resourceLimit }
        return prefix.data
    }
}

/// One decoded Subversion database node layer for a path.
private struct SVNNode {
    let opDepth: Int
    let presence: String
    let kind: String
    let checksum: String?
}

/// Base and active working node layers plus conflict state for one repository entry.
private struct SVNNodeRows {
    let wcID: Int
    let base: SVNNode?
    let working: SVNNode?
    let conflicted: Bool
}

/// Read-only, query-only access to the working-copy SQLite metadata and pristine store.
private final class SVNDatabase {
    private var handle: OpaquePointer?
    private let root: URL

    /// Opens the database read-only and starts a deferred transaction for consistent queries.
    init(url: URL, workingCopyRoot: URL) throws {
        // SQLite is opened read-only and query-only so inspection cannot update WC metadata or hydrate files.
        root = workingCopyRoot
        let result = url.path.withCString { sqlite3_open_v2($0, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) }
        guard result == SQLITE_OK, handle != nil else {
            if let handle { sqlite3_close(handle); self.handle = nil }
            throw VCSProviderError.missingMetadata
        }
        guard sqlite3_exec(handle, "PRAGMA query_only=ON; BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
            throw VCSProviderError.missingMetadata
        }
    }

    /// Closes the SQLite handle owned by this inspection instance.
    deinit { if let handle { sqlite3_close(handle) } }

    /// Loads base and working layers plus conflict state for one exact relative path.
    func node(relativePath: String) throws -> SVNNodeRows? {
        // Select the base and deepest working layer for this exact relative path, then check conflict metadata.
        let wcID = try scalarInt("SELECT id FROM WCROOT WHERE local_abspath IS NULL OR local_abspath = ?1 ORDER BY local_abspath IS NOT NULL DESC LIMIT 1", text: root.path)
        guard let wcID else { throw VCSProviderError.missingMetadata }
        let rows = try queryNodes(wcID: wcID, path: relativePath)
        guard !rows.isEmpty else { return nil }
        let base = rows.first { $0.opDepth == 0 }
        let working = rows.filter { $0.opDepth > 0 }.max { $0.opDepth < $1.opDepth }
        let conflicted = try conflictExists(wcID: wcID, path: relativePath)
        return .init(wcID: wcID, base: base, working: working, conflicted: conflicted)
    }

    /// Reads a hydrated, uncompressed pristine file and verifies its content against the stored SHA-1.
    func pristine(checksum: String) throws -> Data {
        // Validate metadata, hydration state, size, and checksum before trusting the pristine bytes as a baseline.
        let clean = checksum.hasPrefix("$sha1$") ? String(checksum.dropFirst(6)) : checksum
        guard clean.count == 40, clean.allSatisfy({ $0.isHexDigit }) else { throw VCSProviderError.missingMetadata }
        let columns = try queryStrings("PRAGMA table_info(PRISTINE)", column: 1)
        let hasHydratedColumn = columns.contains("hydrated")
        let metadata = try pristineMetadata(checksum: checksum, hasHydratedColumn: hasHydratedColumn)
        guard metadata.hydrated, metadata.compressionIsNil, metadata.size >= 0, metadata.size <= 1_048_576 else {
            throw VCSProviderError.missingMetadata
        }

        let path = root.appendingPathComponent(".svn/pristine/\(clean.prefix(2))/\(clean).svn-base")
        guard VCSFileSystem.kind(path.deletingLastPathComponent()) == .directory,
              VCSFileSystem.kind(path) == .regular,
              let data = try VCSFileSystem.readRegularFile(path), data.count == metadata.size else {
            throw VCSProviderError.missingMetadata
        }
        let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(clean) == .orderedSame else { throw VCSProviderError.missingMetadata }
        return data
    }

    /// Reads schema-compatible pristine metadata before the corresponding file is opened.
    private func pristineMetadata(checksum: String, hasHydratedColumn: Bool) throws -> (size: Int, compressionIsNil: Bool, hydrated: Bool) {
        let sql = hasHydratedColumn
            ? "SELECT size, compression, hydrated FROM PRISTINE WHERE checksum = ?1 LIMIT 1"
            : "SELECT size, compression FROM PRISTINE WHERE checksum = ?1 LIMIT 1"
        return try withStatement(sql) { statement in
            try bind(checksum, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw VCSProviderError.missingMetadata }
            let size = Int(sqlite3_column_int64(statement, 0))
            let compressionIsNil = sqlite3_column_type(statement, 1) == SQLITE_NULL
            let hydrated = !hasHydratedColumn || sqlite3_column_int(statement, 2) == 1
            return (size, compressionIsNil, hydrated)
        }
    }

    /// Rejects keyword-expanded working copies because expanded bytes cannot be compared faithfully to pristine bytes.
    func hasKeywordTranslation(wcID: Int, relativePath: String) throws -> Bool {
        let baseHasKeyword = try propertyBlobContainsKeyword(
            "SELECT properties FROM NODES WHERE wc_id = ?1 AND local_relpath = ?2 AND op_depth = 0 LIMIT 1",
            wcID: wcID, path: relativePath)
        if baseHasKeyword { return true }
        return try propertyBlobContainsKeyword(
            "SELECT properties FROM ACTUAL_NODE WHERE wc_id = ?1 AND local_relpath = ?2 LIMIT 1",
            wcID: wcID, path: relativePath)
    }

    /// Detects keyword substitution metadata that would make a byte-level base comparison misleading.
    private func propertyBlobContainsKeyword(_ sql: String, wcID: Int, path: String) throws -> Bool {
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, sqlite3_int64(wcID))
            try bind(path, to: 2, in: statement)
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw VCSProviderError.missingMetadata }
            guard step == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return false }
            let length = Int(sqlite3_column_bytes(statement, 0))
            guard length <= 65_536 else { throw VCSProviderError.resourceLimit }
            guard let bytes = sqlite3_column_blob(statement, 0) else { return false }
            let properties = Data(bytes: bytes.assumingMemoryBound(to: UInt8.self), count: length)
            // The skel stores property names as bytes. Unknown expansion means no trustworthy
            // byte-to-line comparison; avoid falsely claiming a clean or modified file.
            return properties.range(of: Data("svn:keywords".utf8)) != nil
        }
    }

    /// Reads only the bounded layer rows for one exact working-copy-relative path.
    private func queryNodes(wcID: Int, path: String) throws -> [SVNNode] {
        try withStatement("SELECT op_depth, presence, kind, checksum FROM NODES WHERE wc_id = ?1 AND local_relpath = ?2 ORDER BY op_depth") { statement in
            sqlite3_bind_int64(statement, 1, sqlite3_int64(wcID))
            try bind(path, to: 2, in: statement)
            var result: [SVNNode] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                try Task.checkCancellation()
                result.append(.init(opDepth: Int(sqlite3_column_int(statement, 0)),
                                    presence: columnText(statement, 1) ?? "",
                                    kind: columnText(statement, 2) ?? "",
                                    checksum: columnText(statement, 3)))
                guard result.count <= 32 else { throw VCSProviderError.resourceLimit }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw VCSProviderError.missingMetadata }
            return result
        }
    }

    /// Treats any populated conflict column on the actual node as a repository conflict.
    private func conflictExists(wcID: Int, path: String) throws -> Bool {
        try withStatement("SELECT conflict_data, tree_conflict_data, conflict_old, conflict_new, conflict_working, prop_reject FROM ACTUAL_NODE WHERE wc_id = ?1 AND local_relpath = ?2 LIMIT 1") { statement in
            sqlite3_bind_int64(statement, 1, sqlite3_int64(wcID))
            try bind(path, to: 2, in: statement)
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw VCSProviderError.missingMetadata }
            guard step == SQLITE_ROW else { return false }
            return (0..<6).contains { sqlite3_column_type(statement, Int32($0)) != SQLITE_NULL }
        }
    }

    /// Executes a parameterized scalar query and returns its first non-null integer result.
    private func scalarInt(_ sql: String, text: String) throws -> Int? {
        try withStatement(sql) { statement in
            try bind(text, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Collects a bounded string column from a read-only query with cancellation checks between rows.
    private func queryStrings(_ sql: String, column: Int32) throws -> [String] {
        try withStatement(sql) { statement in
            var result: [String] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                try Task.checkCancellation()
                if let value = columnText(statement, column) { result.append(value) }
                guard result.count < 256 else { throw VCSProviderError.resourceLimit }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw VCSProviderError.missingMetadata }
            return result
        }
    }

    /// Prepares one parameterized read and finalizes it regardless of the query body's outcome.
    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        // Scope each prepared statement so sqlite resources are finalized on both success and failure.
        guard let handle else { throw VCSProviderError.missingMetadata }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VCSProviderError.missingMetadata
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    /// Binds a copied transient UTF-8 value so SQLite does not retain Swift string storage.
    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard result == SQLITE_OK else { throw VCSProviderError.missingMetadata }
    }

    /// Copies SQLite-owned column bytes into a Swift string before the statement advances or closes.
    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}
