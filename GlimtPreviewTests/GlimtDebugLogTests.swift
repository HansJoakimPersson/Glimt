import Foundation
import XCTest

/// ADR-023: the opt-in debug log writes nothing while off, appends single privacy-safe lines while
/// on, rotates at its size cap and never writes through a substituted symlink.
final class GlimtDebugLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtDebugLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lines(_ log: GlimtDebugLog) throws -> [String] {
        log.flush()
        return try String(contentsOf: log.logFileURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testDisabledByDefaultAndWritesNothing() {
        let log = GlimtDebugLog(directory: directory, role: .preview)
        XCTAssertFalse(log.isEnabled)
        log.info("ignored")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.logFileURL.path))
    }

    func testEnabledWritesRoleLevelAndSingleLineMessages() throws {
        let log = GlimtDebugLog(directory: directory, role: .thumbnail)
        log.setEnabled(true)
        log.info("Thumbnail prepared; type=json")
        log.error("forged\n2026 [app] [INFO] line")
        let written = try lines(log)
        XCTAssertEqual(written.count, 3)
        XCTAssertTrue(written[0].hasSuffix("[thumbnail] [INFO] Debug logging enabled."))
        XCTAssertTrue(written[1].hasSuffix("[thumbnail] [INFO] Thumbnail prepared; type=json"))
        XCTAssertTrue(written[2].hasSuffix("[thumbnail] [ERROR] forged 2026 [app] [INFO] line"), "Line breaks cannot forge records")
        let permissions = try FileManager.default.attributesOfItem(atPath: log.logFileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testDisablingLogsTheBoundaryAndStopsWriting() throws {
        let log = GlimtDebugLog(directory: directory, role: .app)
        log.setEnabled(true)
        log.setEnabled(true)
        log.setEnabled(false)
        log.info("ignored")
        let written = try lines(log)
        XCTAssertEqual(written.count, 2, "Repeated enabling is not logged twice")
        XCTAssertTrue(written[1].hasSuffix("Debug logging disabled."))
    }

    func testRotatesAtTheSizeCap() throws {
        let log = GlimtDebugLog(directory: directory, role: .app, maximumFileBytes: 200)
        log.setEnabled(true)
        for index in 0..<10 { log.info("message \(index) " + String(repeating: "x", count: 40)) }
        log.flush()
        let rotated = directory.appendingPathComponent(GlimtDebugLog.rotatedFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.logFileURL.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 200)
        XCTAssertTrue(try lines(log).last?.contains("message 9") == true)
    }

    func testDoesNotWriteThroughASymlink() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.txt")
        try Data("original".utf8).write(to: target)
        let log = GlimtDebugLog(directory: directory, role: .app)
        try FileManager.default.createSymbolicLink(at: log.logFileURL, withDestinationURL: target)
        log.setEnabled(true)
        log.info("must not land in the target")
        log.flush()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }

    func testRefreshIsThrottled() {
        let log = GlimtDebugLog(directory: directory, role: .thumbnail)
        let start = Date()
        var loads = 0
        log.refreshEnabled(every: 5, now: start) { loads += 1; return true }
        log.refreshEnabled(every: 5, now: start.addingTimeInterval(1)) { loads += 1; return false }
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(log.isEnabled)
        log.refreshEnabled(every: 5, now: start.addingTimeInterval(6)) { loads += 1; return false }
        XCTAssertEqual(loads, 2)
        XCTAssertFalse(log.isEnabled)
    }
}
