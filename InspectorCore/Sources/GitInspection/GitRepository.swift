import Darwin
import Foundation
import InspectorCore

/// A read-only view of one repository's on-disk state, opened from its worktree root.
///
/// Only the files format is read: SHA-1 objects, loose and packed refs, loose objects and version 2
/// pack indexes. Anything else (SHA-256, reftable, unknown extensions) fails closed as invalid.
final class GitRepository {
    /// A tree entry's mode and object name.
    struct TreeEntry: Equatable {
        let mode: UInt32
        let id: GitObjectID

        var isTree: Bool { mode == 0o040000 }
        /// Regular files and symlinks are blobs; gitlinks (submodules) are commits in another repository.
        var isBlob: Bool { !isTree && mode != 0o160000 }
    }

    /// A commit's tree, parents, author time and raw message.
    struct Commit {
        let tree: GitObjectID
        let parents: [GitObjectID]
        let time: Int64
        let message: Data
    }

    static let maximumBlobBytes = 1_048_576
    private static let maximumMetadataBytes = 16 << 20
    /// History steps examined for the last commit; deeper files show no commit instead of blocking.
    private static let maximumHistoryCommits = 10_000

    let worktree: URL
    let gitDirectory: URL
    let commonDirectory: URL
    let config: GitConfig
    let objects: GitObjectDatabase
    private let shallowCommits: Set<GitObjectID>
    private lazy var ignore = Result {
        var sources: [URL] = []
        if let path = config.string("core.excludesfile"), !path.isEmpty { sources.append(Self.expandHome(path)) }
        sources.append(commonDirectory.appendingPathComponent("info/exclude"))
        return try GitIgnore(worktree: worktree, sources: sources)
    }

    private init(worktree: URL, gitDirectory: URL, commonDirectory: URL, config: GitConfig) throws {
        self.worktree = worktree
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
        self.config = config
        objects = try GitObjectDatabase(objectsDirectory: commonDirectory.appendingPathComponent("objects",
                                                                                                 isDirectory: true))
        let shallow = try GitMetadata.read(commonDirectory.appendingPathComponent("shallow"),
                                           maximumBytes: Self.maximumMetadataBytes)
        shallowCommits = Set(shallow.map { String(decoding: $0, as: UTF8.self) }?
            .split(separator: "\n").compactMap { GitObjectID(hex: $0) } ?? [])
    }

    // MARK: - Opening

    /// Opens the repository whose `.git` directory or `gitdir:` file sits directly in `worktree`.
    static func open(worktree: URL) throws -> GitRepository {
        let dotGit = worktree.appendingPathComponent(".git")
        let gitDirectory: URL
        switch VCSPath.kind(dotGit) {
        case .directory:
            gitDirectory = dotGit
        case .regular:
            gitDirectory = try pointedDirectory(in: dotGit, prefix: "gitdir:", relativeTo: worktree)
        default:
            throw GitProviderError.invalidRepository
        }
        guard VCSPath.kind(gitDirectory.appendingPathComponent("HEAD")) == .regular else {
            throw GitProviderError.invalidRepository
        }
        let commonFile = gitDirectory.appendingPathComponent("commondir")
        let commonDirectory = VCSPath.kind(commonFile) == .missing
            ? gitDirectory : try pointedDirectory(in: commonFile, prefix: "", relativeTo: gitDirectory)

        var config = GitConfig(parsing: try GitMetadata.read(commonDirectory.appendingPathComponent("config"),
                                                             maximumBytes: maximumMetadataBytes) ?? Data())
        try checkFormat(config)
        if config.bool("extensions.worktreeconfig") == true,
           let worktreeConfig = try GitMetadata.read(gitDirectory.appendingPathComponent("config.worktree"),
                                                     maximumBytes: maximumMetadataBytes) {
            config.merge(GitConfig(parsing: worktreeConfig))
        }
        return try GitRepository(worktree: worktree, gitDirectory: gitDirectory, commonDirectory: commonDirectory,
                                 config: config)
    }

    /// Reads a one-line pointer file such as `.git` (`gitdir: <path>`) or `commondir` (`<path>`).
    private static func pointedDirectory(in file: URL, prefix: String, relativeTo base: URL) throws -> URL {
        guard let data = try GitMetadata.read(file, maximumBytes: 4096) else { throw GitProviderError.invalidRepository }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix) else { throw GitProviderError.invalidRepository }
        let path = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains("\n") else { throw GitProviderError.invalidRepository }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
            : base.appending(path: path, directoryHint: .isDirectory)).standardizedFileURL
        guard VCSPath.kind(url) == .directory else { throw GitProviderError.invalidRepository }
        return url
    }

    /// Accepts repository format 0, and format 1 only with extensions that do not change the layout read here.
    private static func checkFormat(_ config: GitConfig) throws {
        let version = config.string("core.repositoryformatversion").map { Int($0) } ?? 0
        guard let version, version == 0 || version == 1 else { throw GitProviderError.invalidRepository }
        guard version == 1 else { return }
        for (name, value) in config.entries(inSection: "extensions") {
            switch name {
            case "noop", "noop-v1", "preciousobjects", "partialclone", "worktreeconfig":
                continue
            case "objectformat" where value.lowercased() == "sha1", "refstorage" where value.lowercased() == "files":
                continue
            default:
                throw GitProviderError.invalidRepository
            }
        }
    }

    private static func expandHome(_ path: String) -> URL {
        guard path.hasPrefix("~/"), let home = getpwuid(getuid())?.pointee.pw_dir else {
            return URL(fileURLWithPath: path)
        }
        // The real home, not the sandbox container that NSHomeDirectory reports.
        return URL(fileURLWithPath: String(cString: home)).appending(path: String(path.dropFirst(2)))
    }

    // MARK: - References

    /// The commit HEAD names, or nil while the current branch is unborn.
    func head() throws -> GitObjectID? {
        var name = "HEAD"
        for _ in 0..<8 {
            guard let value = try referenceValue(name) else { return nil }
            if value.hasPrefix("ref:") {
                name = value.dropFirst(4).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let id = GitObjectID(hex: value) else { throw GitProviderError.invalidRepository }
            return try peeledCommit(id)
        }
        throw GitProviderError.invalidRepository
    }

    /// A loose reference's content, falling back to `packed-refs` for shared refs.
    private func referenceValue(_ name: String) throws -> String? {
        guard name == "HEAD" || Self.isSafeReferenceName(name) else { throw GitProviderError.invalidRepository }
        let perWorktree = name == "HEAD" || ["refs/bisect/", "refs/worktree/", "refs/rewritten/"]
            .contains { name.hasPrefix($0) }
        let directory = perWorktree ? gitDirectory : commonDirectory
        if let data = try GitMetadata.read(directory.appending(path: name), maximumBytes: 4096) {
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !perWorktree,
              let packed = try GitMetadata.read(commonDirectory.appendingPathComponent("packed-refs"),
                                                maximumBytes: Self.maximumMetadataBytes) else { return nil }
        for line in String(decoding: packed, as: UTF8.self).split(separator: "\n") {
            guard let first = line.first, first != "#", first != "^",
                  let space = line.firstIndex(of: " "), line[line.index(after: space)...] == name else { continue }
            return String(line[..<space])
        }
        return nil
    }

    private static func isSafeReferenceName(_ name: String) -> Bool {
        name.hasPrefix("refs/") && !name.hasSuffix("/") && !name.contains("..") && !name.contains("//")
            && !name.contains("\0") && !name.contains("\\")
    }

    /// Follows annotated tags until a commit, as `git_reference_peel` did for HEAD.
    private func peeledCommit(_ id: GitObjectID) throws -> GitObjectID {
        var current = id
        for _ in 0..<8 {
            let object = try objects.read(current, maximumBytes: Self.maximumMetadataBytes)
            switch object.type {
            case .commit:
                return current
            case .tag:
                guard let target = Self.headerValue("object", in: object.data).flatMap({ GitObjectID(hex: $0) }) else {
                    throw GitProviderError.invalidRepository
                }
                current = target
            case .tree, .blob:
                throw GitProviderError.invalidRepository
            }
        }
        throw GitProviderError.invalidRepository
    }

    // MARK: - Objects

    func commit(_ id: GitObjectID) throws -> Commit {
        let object = try objects.read(id, maximumBytes: Self.maximumMetadataBytes)
        guard object.type == .commit else { throw GitProviderError.invalidRepository }
        let data = object.data
        let separator = data.firstRange(of: Data("\n\n".utf8))
        let header = String(decoding: data[..<(separator?.lowerBound ?? data.endIndex)], as: UTF8.self)
        var tree: GitObjectID?
        var parents: [GitObjectID] = []
        var authorTime: Int64?
        var committerTime: Int64?
        for line in header.split(separator: "\n") {
            if line.hasPrefix("tree ") {
                tree = GitObjectID(hex: line.dropFirst(5))
            } else if line.hasPrefix("parent ") {
                guard let parent = GitObjectID(hex: line.dropFirst(7)) else { throw GitProviderError.invalidRepository }
                parents.append(parent)
            } else if line.hasPrefix("author ") {
                authorTime = Self.signatureTime(line)
            } else if line.hasPrefix("committer ") {
                committerTime = Self.signatureTime(line)
            }
        }
        guard let tree else { throw GitProviderError.invalidRepository }
        let message = separator.map { data[$0.upperBound...] } ?? Data()
        return Commit(tree: tree, parents: parents, time: authorTime ?? committerTime ?? 0, message: Data(message))
    }

    /// Walks the path's components from `tree`; nil when any component is absent or not a directory.
    func entry(in tree: GitObjectID, relativePath: String) throws -> TreeEntry? {
        let components = relativePath.split(separator: "/")
        guard !components.isEmpty else { return nil }
        var current = tree
        for (index, component) in components.enumerated() {
            let object = try objects.read(current, maximumBytes: Self.maximumMetadataBytes)
            guard object.type == .tree else { throw GitProviderError.invalidRepository }
            guard let entry = try Self.treeEntry(named: Array(component.utf8), in: object.data) else { return nil }
            if index == components.count - 1 { return entry }
            guard entry.isTree else { return nil }
            current = entry.id
        }
        return nil
    }

    /// The blob at `relativePath` in HEAD's tree, or nil when HEAD is unborn or holds no blob there.
    func headEntry(relativePath: String) throws -> TreeEntry? {
        guard let head = try head() else { return nil }
        return try entry(in: try commit(head).tree, relativePath: relativePath).flatMap { $0.isBlob ? $0 : nil }
    }

    /// A bounded blob's bytes; other object types are invalid at a blob's position.
    func blob(_ id: GitObjectID) throws -> Data {
        let object = try objects.read(id, maximumBytes: Self.maximumBlobBytes)
        guard object.type == .blob else { throw GitProviderError.invalidRepository }
        return object.data
    }

    func indexLookup(relativePath: String) throws -> GitIndex.Lookup {
        guard let data = try GitMetadata.read(gitDirectory.appendingPathComponent("index"),
                                              maximumBytes: GitIndex.maximumBytes) else { return .init() }
        return try GitIndex.lookup(data, path: relativePath)
    }

    func isIgnored(relativePath: String) throws -> Bool {
        try ignore.get().isIgnored(relativePath: relativePath)
    }

    // MARK: - History

    /// Follows the history `git log -1 -- <path>` simplifies to: from HEAD, step to the first parent
    /// whose entry for the path is identical, and stop at the first commit that differs from every
    /// parent. Bounded so a long history cannot stall the preview; beyond the bound it reports nothing.
    func lastCommit(relativePath: String) throws -> VCSCommitSummary? {
        guard var currentID = try head() else { return nil }
        var current = try commit(currentID)
        guard let entry = try entry(in: current.tree, relativePath: relativePath)?.id else { return nil }

        for _ in 0..<Self.maximumHistoryCommits {
            try Task.checkCancellation()
            var sameParent: (GitObjectID, Commit)?
            // A shallow boundary's parents are not present, so it is treated as a root commit.
            for parentID in shallowCommits.contains(currentID) ? [] : current.parents {
                let parent = try commit(parentID)
                if try self.entry(in: parent.tree, relativePath: relativePath)?.id == entry {
                    sameParent = (parentID, parent)
                    break
                }
            }
            guard let (parentID, parent) = sameParent else {
                return VCSCommitSummary(id: currentID.hex, summary: Self.subject(of: current.message),
                                        authorDate: Date(timeIntervalSince1970: TimeInterval(current.time)))
            }
            currentID = parentID
            current = parent
        }
        return nil
    }

    // MARK: - Parsing

    /// Git's `%s`: the first paragraph after leading blank lines, each line right-trimmed, joined by spaces.
    static func subject(of message: Data) -> String {
        var lines: [String] = []
        for line in String(decoding: message, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line.reversed().drop { $0.isWhitespace }.reversed())
            if trimmed.isEmpty {
                if lines.isEmpty { continue }
                break
            }
            lines.append(trimmed)
        }
        return lines.joined(separator: " ")
    }

    private static func signatureTime(_ line: Substring) -> Int64? {
        guard let close = line.lastIndex(of: ">") else { return nil }
        return line[line.index(after: close)...].split(separator: " ").first.flatMap { Int64($0) }
    }

    private static func headerValue(_ name: String, in data: Data) -> String? {
        let prefix = name + " "
        let end = data.firstRange(of: Data("\n\n".utf8))?.lowerBound ?? data.endIndex
        for line in String(decoding: data[..<end], as: UTF8.self).split(separator: "\n") where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    /// Scans `<octal mode> <name>\0<20-byte id>` records for one name.
    private static func treeEntry(named name: [UInt8], in tree: Data) throws -> TreeEntry? {
        try tree.withUnsafeBytes { raw -> TreeEntry? in
            var position = 0
            while position < raw.count {
                guard let space = raw[position...].firstIndex(of: 0x20),
                      let terminator = raw[space...].firstIndex(of: 0),
                      terminator + GitObjectID.byteCount < raw.count + 1 else {
                    throw GitProviderError.invalidRepository
                }
                var mode: UInt32 = 0
                for digit in raw[position..<space] {
                    guard (0x30...0x37).contains(digit), mode < 0o1000000 else { throw GitProviderError.invalidRepository }
                    mode = mode << 3 | UInt32(digit - 0x30)
                }
                let next = terminator + 1 + GitObjectID.byteCount
                if raw[(space + 1)..<terminator].elementsEqual(name) {
                    guard let id = GitObjectID(bytes: UnsafeRawBufferPointer(rebasing: raw[(terminator + 1)..<next])) else {
                        throw GitProviderError.invalidRepository
                    }
                    return TreeEntry(mode: mode, id: id)
                }
                position = next
            }
            return nil
        }
    }
}
