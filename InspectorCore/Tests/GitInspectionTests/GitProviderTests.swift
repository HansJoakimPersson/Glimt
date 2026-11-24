import CryptoKit
import Darwin
import Foundation
import GitInspection
import InspectorCore
import XCTest

final class GitProviderTests: XCTestCase {
    private let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlimtGitProviderTests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testStagedAndUnstagedChangesUseTheirOwnBasesWithoutRunningRepositoryCommands() async throws {
        let repository = try makeRepository(named: "staged-unstaged")
        let sample = repository.appendingPathComponent("sample.txt")
        try Data("one\ntwo\nthree\n".utf8).write(to: sample)
        try commit(repository, message: "base")

        try Data("one staged\ntwo\nthree\n".utf8).write(to: sample)
        try git(["add", "sample.txt"], in: repository)
        try Data("one staged\ntwo working\nthree\n".utf8).write(to: sample)

        let filterMarker = temporaryDirectory.appendingPathComponent("filter-ran")
        let fsmonitorMarker = temporaryDirectory.appendingPathComponent("fsmonitor-ran")
        let filterScript = temporaryDirectory.appendingPathComponent("filter.sh")
        let fsmonitorScript = temporaryDirectory.appendingPathComponent("fsmonitor.sh")
        try Data("sample.txt filter=proof\n".utf8)
            .write(to: repository.appendingPathComponent(".gitattributes"))
        try Data("#!/bin/sh\n/usr/bin/touch \"\(filterMarker.path)\"\n/bin/cat\n".utf8)
            .write(to: filterScript)
        try Data("#!/bin/sh\n/usr/bin/touch \"\(fsmonitorMarker.path)\"\nprintf 'token\\n'\n".utf8)
            .write(to: fsmonitorScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filterScript.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fsmonitorScript.path)
        try git(["config", "filter.proof.clean", filterScript.path], in: repository)
        try git(["config", "filter.proof.smudge", filterScript.path], in: repository)
        try git(["config", "core.fsmonitor", fsmonitorScript.path], in: repository)

        let before = try repositorySnapshot(repository, workingFile: sample)
        let inspection = try await inspectedResult(for: sample)

        XCTAssertEqual(inspection.fileStatus, .modified)
        XCTAssertEqual(inspection.comparison?.base, .head)
        XCTAssertEqual(inspection.stagedInformation?.stagedChanges?.base, .head)
        XCTAssertEqual(inspection.stagedInformation?.unstagedChanges?.base, .index)
        XCTAssertEqual(inspection.stagedInformation?.stagedChanges?.lineDiff.changes.first?.kind, .modified)
        XCTAssertEqual(inspection.stagedInformation?.stagedChanges?.lineDiff.changes.first?.baselineLines, 0..<1)
        XCTAssertEqual(inspection.stagedInformation?.stagedChanges?.lineDiff.changes.first?.workingLines, 0..<1)
        XCTAssertEqual(inspection.stagedInformation?.unstagedChanges?.lineDiff.changes.first?.kind, .modified)
        XCTAssertEqual(inspection.stagedInformation?.unstagedChanges?.lineDiff.changes.first?.baselineLines, 1..<2)
        XCTAssertEqual(inspection.stagedInformation?.unstagedChanges?.lineDiff.changes.first?.workingLines, 1..<2)
        XCTAssertEqual(try repositorySnapshot(repository, workingFile: sample), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filterMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fsmonitorMarker.path))
    }

    /// The gutter's hunks must be the ones Git itself reports. Each case is unambiguous, so Git's Myers
    /// diff and `VCSLineDiff`'s LCS agree; `git diff -U0` gives the expected half-open ranges.
    func testWorkingTreeLineDiffMatchesGitsOwnHunks() async throws {
        let cases: [(name: String, base: String, working: String)] = [
            ("modify", "a\nb\nc\n", "a\nB\nc\n"),
            ("insert-first", "a\nb\n", "new\na\nb\n"),
            ("append", "a\nb\n", "a\nb\nc\nd\n"),
            ("delete-first", "a\nb\nc\n", "b\nc\n"),
            ("delete-last", "a\nb\nc\n", "a\nb\n"),
            ("mixed", "a\nb\nc\nd\ne\nf\n", "a\nB\nc\ne\nf\ng\nh\n"),
            ("replace-block", "a\nb\nc\nd\n", "a\nx\ny\nz\nd\n"),
            ("no-final-newline", "a\nb", "a\nB"),
        ]
        for testCase in cases {
            let repository = try makeRepository(named: "parity-\(testCase.name)")
            let sample = repository.appendingPathComponent("sample.txt")
            try Data(testCase.base.utf8).write(to: sample)
            try commit(repository, message: "base")
            try Data(testCase.working.utf8).write(to: sample)

            let expected = try gitHunks(repository)
            let actual = try await inspectedResult(for: sample).comparison?.lineDiff.changes ?? []
            XCTAssertFalse(expected.isEmpty, testCase.name)
            XCTAssertEqual(actual, expected, testCase.name)
        }
    }

    /// The status bar names the commit that last changed the file, which must be the one `git log -1` reports.
    func testLastCommitMatchesGitLogForTheFile() async throws {
        let repository = try makeRepository(named: "last-commit")
        let sample = repository.appendingPathComponent("sample.txt")
        let other = repository.appendingPathComponent("other.txt")
        try Data("one\n".utf8).write(to: sample)
        try commit(repository, message: "add sample")
        try Data("one\ntwo\n".utf8).write(to: sample)
        try commit(repository, message: "change sample\n\nBody text.")
        try Data("unrelated\n".utf8).write(to: other)
        try commit(repository, message: "touch other")
        try await assertLastCommit(of: sample, in: repository, summary: "change sample")

        try Data("one\ntwo\nworking\n".utf8).write(to: sample)
        try await assertLastCommit(of: sample, in: repository, summary: "change sample")

        try git(["checkout", "-q", "--", "sample.txt"], in: repository)
        try git(["checkout", "-q", "-b", "side"], in: repository)
        try Data("one\ntwo\nside\n".utf8).write(to: sample)
        try commit(repository, message: "side change")
        try git(["checkout", "-q", "main"], in: repository)
        try Data("main\n".utf8).write(to: other)
        try commit(repository, message: "main change")
        try git(["-c", "commit.gpgsign=false", "merge", "-q", "--no-edit", "side"], in: repository)
        try await assertLastCommit(of: sample, in: repository, summary: "side change")

        let loose = repository.appendingPathComponent("loose.txt")
        try Data("new\n".utf8).write(to: loose)
        let untracked = try await inspectedResult(for: loose)
        XCTAssertNil(untracked.lastCommit, "An untracked file has no commit")
    }

    func testUntrackedFileIsReportedAsAnAddition() async throws {
        let repository = try makeRepository(named: "untracked")
        let sample = repository.appendingPathComponent("sample.txt")
        try Data("tracked\n".utf8).write(to: repository.appendingPathComponent("base.txt"))
        try commit(repository, message: "base")
        try Data("loose\n".utf8).write(to: sample)

        let inspection = try await inspectedResult(for: sample)

        XCTAssertEqual(inspection.fileStatus, .untracked)
        XCTAssertEqual(inspection.comparison?.lineDiff.changes.first?.kind, .added)
    }

    func testLinkedWorktreePointerIsReadAsTheContainingRepository() async throws {
        let repository = try makeRepository(named: "linked-worktree")
        let sample = repository.appendingPathComponent("sample.txt")
        try Data("one\ntwo\nthree\n".utf8).write(to: sample)
        try commit(repository, message: "base")

        let linkedWorktree = temporaryDirectory.appendingPathComponent("linked", isDirectory: true)
        try git(["worktree", "add", "-q", "-b", "linked-test", linkedWorktree.path], in: repository)
        try Data("linked change\ntwo\nthree\n".utf8).write(to: linkedWorktree.appendingPathComponent("sample.txt"))

        let inspection = try await inspectedResult(for: linkedWorktree.appendingPathComponent("sample.txt"))

        XCTAssertEqual(inspection.fileStatus, .modified)
        XCTAssertEqual(inspection.comparison?.base, .head)
        XCTAssertEqual(inspection.comparison?.lineDiff.changes.first?.workingLines, 0..<1)
    }

    func testConflictIsReportedWithoutACombinedLineDiff() async throws {
        let repository = try makeRepository(named: "conflict")
        let sample = repository.appendingPathComponent("conflict.txt")
        try Data("base\n".utf8).write(to: sample)
        try commit(repository, message: "base")

        try git(["checkout", "-q", "-b", "side"], in: repository)
        try Data("side\n".utf8).write(to: sample)
        try commit(repository, message: "side")
        try git(["checkout", "-q", "main"], in: repository)
        try Data("main\n".utf8).write(to: sample)
        try commit(repository, message: "main")
        _ = try git(["merge", "side"], in: repository, expectedExitCode: 1)

        let inspection = try await inspectedResult(for: sample)

        XCTAssertEqual(inspection.fileStatus, .conflicted)
        XCTAssertNil(inspection.comparison)
    }

    func testMalformedRepositoryFailsClosed() async throws {
        let repository = temporaryDirectory.appendingPathComponent("malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data("not a repository\n".utf8).write(to: repository.appendingPathComponent(".git"))
        let sample = repository.appendingPathComponent("sample.txt")
        try Data("plain\n".utf8).write(to: sample)

        let inspection = try await inspectedResult(for: sample)

        XCTAssertEqual(inspection.fileStatus, .unavailable)
        XCTAssertEqual(inspection.diagnostics, [.repositoryNotReadable])
    }

    func testMissingObjectFailsClosed() async throws {
        let repository = try makeRepository(named: "missing-object")
        let sample = repository.appendingPathComponent("sample.txt")
        try Data("base\n".utf8).write(to: sample)
        try commit(repository, message: "base")
        try git(["update-index", "--cacheinfo", "100644,deadbeefdeadbeefdeadbeefdeadbeefdeadbeef,sample.txt"], in: repository)

        let inspection = try await inspectedResult(for: sample)

        XCTAssertEqual(inspection.fileStatus, .unavailable)
        XCTAssertEqual(inspection.diagnostics, [.repositoryMetadataMissing])
    }

    func testOversizedWorkingFileFailsClosed() async throws {
        let repository = try makeRepository(named: "over-limit")
        let sample = repository.appendingPathComponent("large.txt")
        try Data(repeating: 0, count: 1_048_577).write(to: sample)

        let inspection = try await inspectedResult(for: sample)

        XCTAssertEqual(inspection.fileStatus, .unavailable)
        XCTAssertEqual(inspection.diagnostics, [.resourceLimitReached])
    }

    func testUnreadableRepositoryMetadataFailsClosed() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission checks are ineffective when tests run as root.") }
        let repository = try makeRepository(named: "inaccessible")
        let sample = repository.appendingPathComponent("sample.txt")
        try Data("tracked\n".utf8).write(to: sample)
        try commit(repository, message: "base")
        let objects = repository.appendingPathComponent(".git/objects", isDirectory: true)
        let originalPermissions = try FileManager.default.attributesOfItem(atPath: objects.path)[.posixPermissions] as? NSNumber
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: objects.path)
        defer {
            if let originalPermissions {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: objects.path)
            }
        }

        let inspection = try await inspectedResult(for: sample)

        XCTAssertEqual(inspection.fileStatus, .unavailable)
        XCTAssertTrue(
            inspection.diagnostics.first.map { [.repositoryMetadataMissing, .repositoryNotReadable].contains($0) } ?? false
        )
    }

    func testSymlinkedFileFailsClosedAsUnsafe() async throws {
        let repository = try makeRepository(named: "symlink")
        let outside = temporaryDirectory.appendingPathComponent("outside.txt")
        try Data("outside\n".utf8).write(to: outside)
        let link = repository.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let inspection = try await inspectedResult(for: link)

        XCTAssertEqual(inspection.fileStatus, .unavailable)
        XCTAssertEqual(inspection.diagnostics, [.unsafePath])
    }

    func testPrecancelledRegistryInspectionThrowsCancellation() async throws {
        let repository = try makeRepository(named: "cancelled")
        let sample = repository.appendingPathComponent("sample.txt")
        try Data("base\n".utf8).write(to: sample)
        try commit(repository, message: "base")
        let task = Task {
            try await VCSProviderRegistry(providers: [GitProvider()]).inspect(fileURL: sample)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A pre-cancelled repository inspection must not return a result.")
        } catch is CancellationError {
            // Expected: the registry checks cancellation before invoking the provider.
        }
    }

    private func makeRepository(named name: String) throws -> URL {
        let repository = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main"], in: repository)
        try git(["config", "core.hooksPath", "/dev/null"], in: repository)
        try git(["config", "user.name", "Glimt Fixture"], in: repository)
        try git(["config", "user.email", "fixture@example.invalid"], in: repository)
        return repository
    }

    private func commit(_ repository: URL, message: String) throws {
        try git(["add", "-A"], in: repository)
        try git(["-c", "commit.gpgsign=false", "commit", "-qm", message], in: repository)
    }

    @discardableResult
    private func git(_ arguments: [String], in repository: URL, expectedExitCode: Int32 = 0) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repository.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        _ = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == expectedExitCode else {
            throw GitFixtureError.unexpectedCommandStatus(
                expected: expectedExitCode,
                actual: process.terminationStatus,
                command: arguments.first ?? "git"
            )
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Git's zero-context hunks for `sample.txt` as zero-based, half-open line changes. An empty side
    /// is reported by Git as the line before the boundary, which is the zero-based boundary itself.
    private func gitHunks(_ repository: URL) throws -> [VCSLineChange] {
        let diff = try git(["diff", "-U0", "--no-color", "--no-ext-diff", "HEAD", "--", "sample.txt"], in: repository)
        let header = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#, options: .anchorsMatchLines)
        let text = diff as NSString
        return header.matches(in: diff, range: NSRange(location: 0, length: text.length)).map { match in
            func number(_ index: Int, default value: Int) -> Int {
                let range = match.range(at: index)
                return range.location == NSNotFound ? value : Int(text.substring(with: range)) ?? value
            }
            func lines(start: Int, count: Int) -> Range<Int> { count == 0 ? start..<start : (start - 1)..<(start - 1 + count) }
            let baseline = lines(start: number(1, default: 0), count: number(2, default: 1))
            let working = lines(start: number(3, default: 0), count: number(4, default: 1))
            let kind: VCSLineChange.Kind = baseline.isEmpty ? .added : working.isEmpty ? .deleted : .modified
            return VCSLineChange(kind: kind, baselineLines: baseline, workingLines: working)
        }
    }

    private func assertLastCommit(of file: URL, in repository: URL, summary: String,
                                  line: UInt = #line) async throws {
        let expected = try git(["log", "-1", "--format=%H %at", "--", file.lastPathComponent], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let commit = try await inspectedResult(for: file).lastCommit
        XCTAssertEqual(commit?.id, expected.first.map(String.init), line: line)
        XCTAssertEqual(commit?.shortID, expected.first.map { String($0.prefix(7)) }, line: line)
        XCTAssertEqual(commit?.summary, summary, line: line)
        XCTAssertEqual(commit?.authorDate, expected.last.flatMap { TimeInterval(String($0)) }
            .map(Date.init(timeIntervalSince1970:)), line: line)
    }

    private func inspectedResult(for fileURL: URL) async throws -> VCSInspectionResult {
        guard case .inspected(let result) = await GitProvider().inspect(fileURL: fileURL) else {
            throw GitFixtureError.repositoryNotRecognized
        }
        return result
    }

    private func repositorySnapshot(_ repository: URL, workingFile: URL) throws -> [String: String] {
        let metadata = repository.appendingPathComponent(".git", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: metadata, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw GitFixtureError.repositoryMetadataUnavailable
        }
        var snapshot: [String: String] = [:]
        for case let fileURL as URL in enumerator {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relativePath = String(fileURL.path.dropFirst(metadata.path.count + 1))
            snapshot[relativePath] = Self.sha256(try Data(contentsOf: fileURL))
        }
        snapshot["working/sample.txt"] = Self.sha256(try Data(contentsOf: workingFile))
        return snapshot
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum GitFixtureError: Error {
    case repositoryMetadataUnavailable
    case repositoryNotRecognized
    case unexpectedCommandStatus(expected: Int32, actual: Int32, command: String)
}
