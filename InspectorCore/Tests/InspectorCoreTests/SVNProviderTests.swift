import CSQLite
import CryptoKit
import Foundation
import XCTest
@testable import InspectorCore

final class SVNProviderTests: XCTestCase {
    func testCleanAndModifiedFilesUseBASEPristine() async throws {
        let clean = try SVNFixture()
        try clean.addBaseFile("source.swift", content: "one\ntwo\n", working: "one\ntwo\n")
        let cleanResult = await SVNProvider().inspect(fileURL: clean.fileURL("source.swift"))
        XCTAssertEqual(inspection(cleanResult)?.fileStatus, .clean)
        XCTAssertEqual(inspection(cleanResult)?.comparison?.base, .svnBase)
        XCTAssertEqual(inspection(cleanResult)?.comparison?.lineDiff.changes, [])

        let modified = try SVNFixture()
        try modified.addBaseFile("source.swift", content: "one\ntwo\n", working: "one\r\ntwo changed\r\n")
        let result = await SVNProvider().inspect(fileURL: modified.fileURL("source.swift"))
        XCTAssertEqual(inspection(result)?.fileStatus, .modified)
        XCTAssertEqual(inspection(result)?.comparison?.lineDiff.changes.first?.workingLines, 1..<2)
    }

    func testAddedDeletedConflictedAndUnversionedStatuses() async throws {
        let added = try SVNFixture()
        try added.addWorkingFile("new.txt", content: "added\n", opDepth: 1, presence: "normal")
        let addedResult = await SVNProvider().inspect(fileURL: added.fileURL("new.txt"))
        XCTAssertEqual(inspection(addedResult)?.fileStatus, .added)

        let deleted = try SVNFixture()
        try deleted.addBaseFile("gone.txt", content: "gone\n", working: nil)
        try deleted.addNode(path: "gone.txt", opDepth: 1, presence: "base-deleted", kind: "file", checksum: nil)
        let deletedResult = await SVNProvider().inspect(fileURL: deleted.fileURL("gone.txt"))
        XCTAssertEqual(inspection(deletedResult)?.fileStatus, .deleted, String(describing: inspection(deletedResult)?.diagnostics))
        XCTAssertEqual(inspection(deletedResult)?.comparison?.lineDiff.changes.first?.kind, .deleted)

        let replaced = try SVNFixture()
        try replaced.addBaseFile("replaced.txt", content: "base\n", working: "replacement\n")
        try replaced.addNode(path: "replaced.txt", opDepth: 1, presence: "normal", kind: "file", checksum: nil)
        let replacedResult = await SVNProvider().inspect(fileURL: replaced.fileURL("replaced.txt"))
        XCTAssertEqual(inspection(replacedResult)?.fileStatus, .replaced)

        let conflict = try SVNFixture()
        try conflict.addBaseFile("conflict.txt", content: "base\n", working: "work\n")
        try conflict.addConflict(path: "conflict.txt")
        let conflictResult = await SVNProvider().inspect(fileURL: conflict.fileURL("conflict.txt"))
        XCTAssertEqual(inspection(conflictResult)?.fileStatus, .conflicted)

        let unversioned = try SVNFixture()
        try unversioned.writeWorkingFile("loose.txt", text: "loose")
        let unversionedResult = await SVNProvider().inspect(fileURL: unversioned.fileURL("loose.txt"))
        XCTAssertEqual(inspection(unversionedResult)?.fileStatus, .untracked)
    }

    func testMissingPristineAndUnsafeSymlinkFailClosed() async throws {
        let missing = try SVNFixture()
        try missing.addNode(path: "source.txt", opDepth: 0, presence: "normal", kind: "file", checksum: String(repeating: "a", count: 40))
        try missing.writeWorkingFile("source.txt", text: "working\n")
        let missingResult = await SVNProvider().inspect(fileURL: missing.fileURL("source.txt"))
        XCTAssertEqual(inspection(missingResult)?.fileStatus, .unavailable)

        let outside = try SVNFixture()
        try outside.addBaseFile("target.txt", content: "base\n", working: "working\n")
        let link = outside.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.fileURL("target.txt"))
        let linked = await SVNProvider().inspect(fileURL: link)
        XCTAssertEqual(inspection(linked)?.fileStatus, .unavailable)
        XCTAssertEqual(inspection(linked)?.diagnostics, [.unsafePath])
    }

    func testBinaryAndKeywordTranslatedFilesDoNotClaimMisleadingLineChanges() async throws {
        let keyword = try SVNFixture()
        try keyword.addBaseFile("keyword.txt", content: "$Rev$\n", working: "$Rev: 7 $\n")
        try keyword.setBaseProperties(path: "keyword.txt", bytes: Data("svn:keywords".utf8))
        let keywordResult = await SVNProvider().inspect(fileURL: keyword.fileURL("keyword.txt"))
        XCTAssertEqual(inspection(keywordResult)?.fileStatus, .unavailable)
        XCTAssertEqual(inspection(keywordResult)?.diagnostics, [.comparisonUnavailable])

        let binary = try SVNFixture()
        try binary.addBaseFile("image.bin", content: Data([0, 1, 2, 3]), working: Data([0, 1, 2, 4]))
        let binaryResult = await SVNProvider().inspect(fileURL: binary.fileURL("image.bin"))
        XCTAssertEqual(inspection(binaryResult)?.fileStatus, .unavailable)
        XCTAssertEqual(inspection(binaryResult)?.diagnostics, [.unsupportedContent])
    }

    func testAbsentRepositoryIsNotAMatch() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plain.txt")
        try Data("text".utf8).write(to: file)
        let result = await SVNProvider().inspect(fileURL: file)
        if case .notRepository = result { } else { XCTFail("Expected no provider match") }
    }

    func testInspectionLeavesWorkingCopyMetadataAndPristineBytesUntouched() async throws {
        let fixture = try SVNFixture()
        try fixture.addBaseFile("source.txt", content: "before\n", working: "after\n")
        let metadataBefore = try Data(contentsOf: fixture.databaseURL)
        let pristineBefore = try Data(contentsOf: fixture.pristineURL(for: Insecure.SHA1.hash(data: Data("before\n".utf8))))
        let result = await SVNProvider().inspect(fileURL: fixture.fileURL("source.txt"))
        XCTAssertEqual(inspection(result)?.fileStatus, .modified)
        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.pristineURL(for: Insecure.SHA1.hash(data: Data("before\n".utf8)))), pristineBefore)
    }

    private func inspection(_ result: VCSProviderInspection) -> VCSInspectionResult? {
        guard case .inspected(let value) = result else { return nil }
        return value
    }

}

private final class SVNFixture {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("Glimt-SVN-\(UUID().uuidString)", isDirectory: true)
    var databaseURL: URL { root.appendingPathComponent(".svn/wc.db") }
    private var database: OpaquePointer?

    init() throws {
        let admin = root.appendingPathComponent(".svn", isDirectory: true)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        let pristine = admin.appendingPathComponent("pristine", isDirectory: true)
        try FileManager.default.createDirectory(at: pristine, withIntermediateDirectories: true)
        let path = databaseURL.path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
        try execute("""
            CREATE TABLE WCROOT (id INTEGER PRIMARY KEY, local_abspath TEXT);
            INSERT INTO WCROOT (id, local_abspath) VALUES (1, NULL);
            CREATE TABLE NODES (wc_id INTEGER, local_relpath TEXT, op_depth INTEGER, presence TEXT, kind TEXT, checksum TEXT, properties BLOB);
            CREATE TABLE ACTUAL_NODE (wc_id INTEGER, local_relpath TEXT, properties BLOB, conflict_data BLOB, tree_conflict_data TEXT, conflict_old TEXT, conflict_new TEXT, conflict_working TEXT, prop_reject TEXT);
            CREATE TABLE PRISTINE (checksum TEXT PRIMARY KEY, compression INTEGER, size INTEGER, refcount INTEGER, md5_checksum TEXT, hydrated INTEGER);
            """)
    }

    deinit {
        if let database { sqlite3_close(database) }
        try? FileManager.default.removeItem(at: root)
    }

    func fileURL(_ path: String) -> URL { root.appendingPathComponent(path) }
    func pristineURL(for digest: Insecure.SHA1.Digest) -> URL {
        let checksum = digest.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(".svn/pristine/\(checksum.prefix(2))/\(checksum).svn-base")
    }

    func addBaseFile(_ path: String, content: String, working: String?) throws {
        try addBaseFile(path, content: Data(content.utf8), working: working.map { Data($0.utf8) })
    }

    func addBaseFile(_ path: String, content: Data, working: Data?) throws {
        let checksum = Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let correctlyBucketedPath = root.appendingPathComponent(".svn/pristine/\(checksum.prefix(2))/\(checksum).svn-base")
        try FileManager.default.createDirectory(at: correctlyBucketedPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: correctlyBucketedPath)
        try execute("INSERT INTO PRISTINE (checksum, compression, size, refcount, md5_checksum, hydrated) VALUES ('\(checksum)', NULL, \(content.count), 1, 'md5', 1)")
        try addNode(path: path, opDepth: 0, presence: "normal", kind: "file", checksum: checksum)
        if let working { try writeWorkingFile(path, data: working) }
    }

    func addWorkingFile(_ path: String, content: String, opDepth: Int, presence: String) throws {
        try addNode(path: path, opDepth: opDepth, presence: presence, kind: "file", checksum: nil)
        try writeWorkingFile(path, text: content)
    }

    func addNode(path: String, opDepth: Int, presence: String, kind: String, checksum: String?) throws {
        let checksumSQL = checksum.map { "'\($0)'" } ?? "NULL"
        try execute("INSERT INTO NODES (wc_id, local_relpath, op_depth, presence, kind, checksum) VALUES (1, '\(path)', \(opDepth), '\(presence)', '\(kind)', \(checksumSQL))")
    }

    func addConflict(path: String) throws {
        try execute("INSERT INTO ACTUAL_NODE (wc_id, local_relpath, conflict_data) VALUES (1, '\(path)', X'01')")
    }

    func setBaseProperties(path: String, bytes: Data) throws {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try execute("UPDATE NODES SET properties = X'\(hex)' WHERE local_relpath = '\(path)' AND op_depth = 0")
    }

    func writeWorkingFile(_ path: String, text: String) throws {
        try writeWorkingFile(path, data: Data(text.utf8))
    }

    func writeWorkingFile(_ path: String, data: Data) throws {
        let url = fileURL(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
    }

    private enum FixtureError: Error { case sqlite }
}
