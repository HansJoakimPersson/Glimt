import Foundation
@testable import GitInspection
import InspectorCore
import XCTest

/// Differential tests: the native reader must agree with the `git` CLI on the same repository.
final class GitReaderTests: XCTestCase {
    private var fixture: GitFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try GitFixture()
    }

    override func tearDownWithError() throws {
        fixture.remove()
        try super.tearDownWithError()
    }

    // MARK: - Objects

    func testEveryLooseAndPackedObjectMatchesCatFile() throws {
        let repository = try historyRepository(named: "objects")
        try assertEveryObjectMatchesCatFile(repository, label: "loose")

        try fixture.git(["gc", "-q", "--aggressive", "--prune=now"], in: repository)
        try assertEveryObjectMatchesCatFile(repository, label: "ofs-delta pack")

        try fixture.git(["-c", "repack.useDeltaBaseOffset=false", "repack", "-adf", "-q"], in: repository)
        try assertEveryObjectMatchesCatFile(repository, label: "ref-delta pack")
    }

    func testObjectsAreReadThroughAlternates() throws {
        let origin = try historyRepository(named: "alternates-origin")
        try fixture.git(["gc", "-q"], in: origin)
        let shared = fixture.root.appendingPathComponent("alternates-shared", isDirectory: true)
        try fixture.git(["clone", "-q", "--shared", origin.path, shared.path], in: fixture.root)
        try assertEveryObjectMatchesCatFile(shared, label: "alternates")
        try assertLastCommitMatchesGit(shared.appendingPathComponent("src/nested/sample.txt"), in: shared)
    }

    // MARK: - Status

    func testStatusMatchesGitPorcelainAcrossIndexVersions() async throws {
        for version in [2, 3, 4] {
            let repository = try fixture.makeRepository(named: "status-v\(version)")
            try write("tracked\n", "clean.txt", in: repository)
            try write("one\n", "src/modified.txt", in: repository)
            try write("one\n", "staged.txt", in: repository)
            try write("one\n", "both.txt", in: repository)
            try write("one\n", "mode.sh", in: repository)
            try fixture.commit(repository, message: "base")

            try write("two\n", "src/modified.txt", in: repository)
            try write("two\n", "staged.txt", in: repository)
            try fixture.git(["add", "staged.txt"], in: repository)
            try write("two\n", "both.txt", in: repository)
            try fixture.git(["add", "both.txt"], in: repository)
            try write("three\n", "both.txt", in: repository)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: repository.appendingPathComponent("mode.sh").path)
            try write("new\n", "added.txt", in: repository)
            try fixture.git(["add", "added.txt"], in: repository)
            try write("intent\n", "intent.txt", in: repository)
            try fixture.git(["add", "-N", "intent.txt"], in: repository)
            try write("loose\n", "deep/untracked.txt", in: repository)
            try write("*.log\nbuild/\n", ".gitignore", in: repository)
            try write("ignored\n", "debug.log", in: repository)
            try write("ignored\n", "build/out.txt", in: repository)
            try fixture.git(["update-index", "--index-version", "\(version)"], in: repository)

            for path in ["clean.txt", "src/modified.txt", "staged.txt", "both.txt", "mode.sh", "added.txt",
                         "intent.txt", "deep/untracked.txt", "debug.log", "build/out.txt"] {
                let file = repository.appendingPathComponent(path)
                let expected = try expectedStatus(path, in: repository)
                let actual = try await fixture.inspect(file).fileStatus
                XCTAssertEqual(actual, expected, "index v\(version): \(path)")
            }
        }
    }

    func testUnbornAndDetachedHeadsMatchGit() async throws {
        let unborn = try fixture.makeRepository(named: "unborn")
        try write("staged\n", "sample.txt", in: unborn)
        try fixture.git(["add", "sample.txt"], in: unborn)
        let unbornResult = try await fixture.inspect(unborn.appendingPathComponent("sample.txt"))
        XCTAssertEqual(unbornResult.fileStatus, .added)
        XCTAssertNil(unbornResult.lastCommit)

        let detached = try historyRepository(named: "detached")
        try fixture.git(["checkout", "-q", "--detach", "HEAD~1"], in: detached)
        let sample = detached.appendingPathComponent("src/nested/sample.txt")
        try assertLastCommitMatchesGit(sample, in: detached)
        let detachedStatus = try await fixture.inspect(sample).fileStatus
        XCTAssertEqual(detachedStatus, .clean)
    }

    // MARK: - History

    func testLastCommitMatchesGitLogForPackedAndShallowHistories() async throws {
        let repository = try historyRepository(named: "history")
        let sample = repository.appendingPathComponent("src/nested/sample.txt")
        try assertLastCommitMatchesGit(sample, in: repository)
        try assertLastCommitMatchesGit(repository.appendingPathComponent("top.txt"), in: repository)

        try fixture.git(["gc", "-q", "--aggressive", "--prune=now"], in: repository)
        try assertLastCommitMatchesGit(sample, in: repository)
        try assertLastCommitMatchesGit(repository.appendingPathComponent("top.txt"), in: repository)

        let shallow = fixture.root.appendingPathComponent("shallow", isDirectory: true)
        try fixture.git(["clone", "-q", "--depth", "2", "file://\(repository.path)", shallow.path], in: fixture.root)
        try assertLastCommitMatchesGit(shallow.appendingPathComponent("top.txt"), in: shallow)
        let shallowStatus = try await fixture.inspect(shallow.appendingPathComponent("top.txt")).fileStatus
        XCTAssertEqual(shallowStatus, .clean)
    }

    func testCommitSummaryJoinsTheFirstParagraph() throws {
        let repository = try fixture.makeRepository(named: "summary")
        try write("one\n", "sample.txt", in: repository)
        try fixture.git(["add", "-A"], in: repository)
        try fixture.git(["-c", "commit.gpgsign=false", "commit", "-q", "--cleanup=verbatim",
                         "-m", "\n  First line\nsecond line  \n\nBody"], in: repository)
        let reader = try GitRepository.open(worktree: repository)
        let commit = try XCTUnwrap(reader.lastCommit(relativePath: "sample.txt"))
        let expected = try fixture.gitText(["log", "-1", "--format=%s"], in: repository)
        XCTAssertEqual(commit.summary, String(expected.dropLast()))
    }

    // MARK: - Ignore rules

    func testIgnoreDecisionsMatchGitCheckIgnore() throws {
        let repository = try fixture.makeRepository(named: "ignore")
        try write("""
            # comment
            *.log
            !keep.log
            /rooted.txt
            build/
            docs/**/draft-*.md
            **/cache/*
            a?c.txt
            [xy]z.txt
            \\#hash.txt
            trailing.txt\u{20}\u{20}
            sub/only/
            """, ".gitignore", in: repository)
        try write("nested.txt\n!/again.txt\n", "pkg/.gitignore", in: repository)
        try write("excluded.txt\n", ".git/info/exclude", in: repository)
        let paths = [
            "app.log", "keep.log", "pkg/app.log", "rooted.txt", "pkg/rooted.txt", "build/a.txt",
            "pkg/build/b.txt", "build.txt", "docs/draft-1.md", "docs/a/b/draft-2.md", "docs/final.md",
            "cache/x.txt", "deep/cache/y.txt", "cache.txt", "abc.txt", "abbc.txt", "xz.txt", "zz.txt",
            "#hash.txt", "trailing.txt", "sub/only/file.txt", "sub/file.txt", "pkg/nested.txt",
            "nested.txt", "pkg/again.txt", "excluded.txt", "pkg/excluded.txt", "plain.txt",
        ]
        for path in paths { try write("x\n", path, in: repository) }

        let ignored = Set(try fixture.gitText(["check-ignore", "--"] + paths, in: repository, allowing: [0, 1])
            .split(separator: "\n").map(String.init))
        let reader = try GitRepository.open(worktree: repository)
        for path in paths {
            XCTAssertEqual(try reader.isIgnored(relativePath: path), ignored.contains(path), path)
        }
    }

    // MARK: - Fail closed

    func testUnsupportedRepositoryFormatsFailClosed() async throws {
        for (name, arguments) in [("sha256", ["--object-format=sha256"]), ("reftable", ["--ref-format=reftable"])] {
            let repository = fixture.root.appendingPathComponent(name, isDirectory: true)
            try fixture.git(["init", "-q", "--initial-branch=main"] + arguments + [repository.path], in: fixture.root)
            try fixture.configure(repository)
            try write("one\n", "sample.txt", in: repository)
            try fixture.commit(repository, message: "base")
            let result = try await fixture.inspect(repository.appendingPathComponent("sample.txt"))
            XCTAssertEqual(result.fileStatus, .unavailable, name)
            XCTAssertEqual(result.diagnostics, [.repositoryNotReadable], name)
        }

        let split = try historyRepository(named: "split-index")
        try fixture.git(["update-index", "--split-index"], in: split)
        let splitResult = try await fixture.inspect(split.appendingPathComponent("top.txt"))
        XCTAssertEqual(splitResult.fileStatus, .unavailable)
    }

    func testCorruptObjectStoresFailClosedWithoutCrashing() async throws {
        let loose = try historyRepository(named: "corrupt-loose")
        let blob = try fixture.gitText(["rev-parse", "HEAD:top.txt"], in: loose)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objectFile = loose.appendingPathComponent(".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: objectFile.path)
        try Data("not zlib".utf8).write(to: objectFile)
        let looseResult = try await fixture.inspect(loose.appendingPathComponent("top.txt"))
        XCTAssertEqual(looseResult.fileStatus, .unavailable)

        let packed = try historyRepository(named: "corrupt-pack")
        try fixture.git(["gc", "-q", "--aggressive", "--prune=now"], in: packed)
        let packDirectory = packed.appendingPathComponent(".git/objects/pack", isDirectory: true)
        let pack = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: packDirectory,
                                                                             includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "pack" })
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pack.path)
        let original = try Data(contentsOf: pack)
        var generator = SystemRandomNumberGenerator()
        for round in 0..<40 {
            var damaged = original
            for _ in 0..<8 {
                let offset = Int.random(in: 12..<(damaged.count - 20), using: &generator)
                damaged[offset] = UInt8.random(in: 0...255, using: &generator)
            }
            try damaged.write(to: pack)
            // Any classification is acceptable; the reader must return rather than trap or hang.
            _ = try await fixture.inspect(packed.appendingPathComponent("src/nested/sample.txt"))
            _ = round
        }
        try original.prefix(original.count / 2).write(to: pack)
        let truncated = try await fixture.inspect(packed.appendingPathComponent("src/nested/sample.txt"))
        XCTAssertEqual(truncated.fileStatus, .unavailable)
    }

    func testDeltaChainsAreBounded() throws {
        var target = Data()
        // Base size 4, result size 4, insert 4 literal bytes.
        target.append(contentsOf: [4, 4, 4] + Array("abcd".utf8))
        XCTAssertEqual(try GitDelta.apply(target, to: Data("wxyz".utf8), maximumBytes: 16), Data("abcd".utf8))
        // Copy past the base end.
        XCTAssertThrowsError(try GitDelta.apply(Data([4, 4, 0x91, 2, 4]), to: Data("wxyz".utf8), maximumBytes: 16))
        // Result larger than permitted.
        XCTAssertThrowsError(try GitDelta.apply(Data([4, 0x7F, 4] + Array("abcd".utf8)),
                                                to: Data("wxyz".utf8), maximumBytes: 16))
        // Base size mismatch.
        XCTAssertThrowsError(try GitDelta.apply(Data([5, 4, 4] + Array("abcd".utf8)),
                                                to: Data("wxyz".utf8), maximumBytes: 16))
    }

    // MARK: - Helpers

    /// A repository whose nested file changes across several commits, so gc produces delta chains.
    private func historyRepository(named name: String) throws -> URL {
        let repository = try fixture.makeRepository(named: name)
        var body = (1...200).map { "line \($0) of a reasonably long body so deltas pay off" }
        try write(body.joined(separator: "\n") + "\n", "src/nested/sample.txt", in: repository)
        try write("top\n", "top.txt", in: repository)
        try fixture.commit(repository, message: "base")
        for revision in 1...6 {
            body[revision * 20] = "changed in revision \(revision)"
            try write(body.joined(separator: "\n") + "\n", "src/nested/sample.txt", in: repository)
            if revision % 2 == 0 { try write("top \(revision)\n", "top.txt", in: repository) }
            try fixture.commit(repository, message: "revision \(revision)\n\nDetails.")
        }
        try write("other\n", "src/other.txt", in: repository)
        try fixture.commit(repository, message: "unrelated")
        return repository
    }

    private func write(_ text: String, _ path: String, in repository: URL) throws {
        let file = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func assertEveryObjectMatchesCatFile(_ repository: URL, label: String,
                                                 line: UInt = #line) throws {
        let listing = try fixture.gitText(["cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)"],
                                          in: repository)
        let reader = try GitRepository.open(worktree: repository)
        var count = 0
        for entry in listing.split(separator: "\n") {
            let parts = entry.split(separator: " ")
            let id = try XCTUnwrap(GitObjectID(hex: String(parts[0])), line: line)
            let object = try reader.objects.read(id, maximumBytes: 16 << 20)
            XCTAssertEqual(object.type.name, String(parts[1]), "\(label) \(parts[0])", line: line)
            XCTAssertEqual(object.data, try fixture.git(["cat-file", String(parts[1]), String(parts[0])], in: repository),
                           "\(label) \(parts[0])", line: line)
            count += 1
        }
        XCTAssertGreaterThan(count, 10, label, line: line)
    }

    private func assertLastCommitMatchesGit(_ file: URL, in repository: URL, line: UInt = #line) throws {
        let relativePath = String(file.path.dropFirst(repository.path.count + 1))
        let expected = try fixture.gitText(["log", "-1", "--format=%H", "--", relativePath], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try GitRepository.open(worktree: repository).lastCommit(relativePath: relativePath)
        XCTAssertEqual(commit?.id, expected, relativePath, line: line)
    }

    /// Maps Git's own porcelain status to the provider's single-file classification.
    private func expectedStatus(_ path: String, in repository: URL) throws -> VCSFileStatus {
        let porcelain = try fixture.gitText(["status", "--porcelain=v1", "--ignored", "--", path], in: repository)
        let code = porcelain.split(separator: "\n").first.map { String($0.prefix(2)) } ?? "  "
        let index = code.first ?? " ", worktree = code.last ?? " "
        switch code {
        case "??": return .untracked
        case "!!", "  ": return .clean
        case "DD", "AA": return .conflicted
        default:
            if index == "U" || worktree == "U" { return .conflicted }
            if index == "A" || worktree == "A" { return .added }
            return .modified
        }
    }
}

/// Temporary repositories driven by the `git` CLI with global and system configuration disabled.
struct GitFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlimtGitReaderTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeRepository(named name: String) throws -> URL {
        let repository = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q", "--initial-branch=main"], in: repository)
        try configure(repository)
        return repository
    }

    func configure(_ repository: URL) throws {
        try git(["config", "core.hooksPath", "/dev/null"], in: repository)
        try git(["config", "user.name", "Glimt Fixture"], in: repository)
        try git(["config", "user.email", "fixture@example.invalid"], in: repository)
    }

    func commit(_ repository: URL, message: String) throws {
        try git(["add", "-A"], in: repository)
        try git(["-c", "commit.gpgsign=false", "commit", "-qm", message], in: repository)
    }

    func inspect(_ file: URL) async throws -> VCSInspectionResult {
        guard case .inspected(let result) = await GitProvider().inspect(fileURL: file) else {
            throw FixtureError.notInspected
        }
        return result
    }

    func gitText(_ arguments: [String], in directory: URL, allowing codes: Set<Int32> = [0]) throws -> String {
        String(decoding: try git(arguments, in: directory, allowing: codes), as: UTF8.self)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL, allowing codes: Set<Int32> = [0]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // The reader does not consult global excludes, so the reference must not either.
        environment["XDG_CONFIG_HOME"] = root.path
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard codes.contains(process.terminationStatus) else {
            throw FixtureError.command(arguments.first ?? "git", process.terminationStatus)
        }
        return data
    }

    enum FixtureError: Error {
        case notInspected
        case command(String, Int32)
    }
}
