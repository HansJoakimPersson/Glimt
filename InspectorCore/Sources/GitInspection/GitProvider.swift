import Darwin
import Foundation
import InspectorCore

/// Reads local Git state for Quick Look from the repository files without modifying the repository.
public struct GitProvider: VCSProvider {
    public let repositoryType: VCSRepositoryType = .git
    private let maximumLookupDepth = 64

    /// Creates the read-only provider without opening any repository.
    public init() {}

    /// Finds the containing repository and compares bounded HEAD/index/working bytes without launching Git.
    public func inspect(fileURL: URL) async -> VCSProviderInspection {
        guard !Task.isCancelled, fileURL.isFileURL else { return .notRepository }
        switch locateRepository(for: fileURL) {
        case .none:
            return .notRepository
        case .unsafe:
            return .inspected(unavailable(.unsafePath))
        case .repository(let root, let relativePath):
            do {
                let snapshot = try GitSnapshot.read(repositoryURL: root, relativePath: relativePath)
                try Task.checkCancellation()
                return .inspected(try snapshot.inspection())
            } catch is CancellationError {
                return .notRepository
            } catch GitProviderError.resourceLimit {
                return .inspected(unavailable(.resourceLimitReached))
            } catch GitProviderError.unsafePath {
                return .inspected(unavailable(.unsafePath))
            } catch GitProviderError.missingObject {
                return .inspected(unavailable(.repositoryMetadataMissing))
            } catch VCSLineDiffError.inputTooLarge, VCSLineDiffError.comparisonTooLarge,
                    VCSLineDiffError.timeLimitReached {
                return .inspected(unavailable(.resourceLimitReached))
            } catch VCSLineDiffError.binaryContent, VCSLineDiffError.unsupportedEncoding {
                return .inspected(unavailable(.unsupportedContent))
            } catch {
                return .inspected(unavailable(.repositoryNotReadable))
            }
        }
    }

    /// Keeps failed repository reads distinct from a valid clean result.
    private func unavailable(_ diagnostic: VCSDiagnostic) -> VCSInspectionResult {
        .init(repositoryType: .git, fileStatus: .unavailable, comparison: nil, diagnostics: [diagnostic])
    }

    private enum RepositoryLocation {
        case none
        case unsafe
        case repository(URL, String)
    }

    /// Finds a bounded containing repository and validates containment and every path component.
    private func locateRepository(for fileURL: URL) -> RepositoryLocation {
        // Walk a bounded number of parents and reject symlink traversal before opening repository metadata.
        guard VCSPath.kind(fileURL) == .regular else { return .unsafe }
        var directory = fileURL.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<maximumLookupDepth {
            guard VCSPath.kind(directory) == .directory else { return .unsafe }
            let gitEntry = directory.appendingPathComponent(".git")
            if VCSPath.kind(gitEntry) == .directory || VCSPath.kind(gitEntry) == .regular {
                let root = directory.standardizedFileURL
                let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
                let filePath = fileURL.standardizedFileURL.path
                guard filePath.hasPrefix(rootPath) else { return .unsafe }
                let relativePath = String(filePath.dropFirst(rootPath.count))
                let components = relativePath.split(separator: "/")
                guard !components.isEmpty,
                      components.allSatisfy({ $0 != "." && $0 != ".." }),
                      !VCSPath.hasUnsafeComponent(fileURL, under: root) else { return .unsafe }
                return .repository(root, relativePath)
            }
            if VCSPath.kind(gitEntry) != .missing { return .unsafe }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return .none }
            directory = parent
        }
        return .none
    }
}

enum GitProviderError: Error {
    case unsafePath
    case resourceLimit
    case missingObject
    case invalidRepository
}

enum VCSPath {
    /// Classifies a repository path without following unsupported filesystem objects.
    enum Kind { case missing, regular, directory, other }

    /// Uses `lstat` so repository discovery never follows a symlink while classifying entries.
    static func kind(_ url: URL) -> Kind {
        var info = stat()
        let exists = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) == 0 } ?? false
        }
        guard exists else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFDIR: return .directory
        default: return .other
        }
    }

    /// Rejects paths outside the worktree and any intermediate symlink or non-directory component.
    static func hasUnsafeComponent(_ fileURL: URL, under root: URL) -> Bool {
        let path = fileURL.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return true }
        var current = root
        for component in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            current.appendPathComponent(String(component))
            if kind(current) == .other { return true }
        }
        return false
    }

    /// Reads one bounded regular file through a no-follow descriptor to resist path substitution.
    static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        // O_NOFOLLOW plus fstat prevents a repository path swap from redirecting reads through a symlink.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else { throw GitProviderError.unsafePath }
        defer { _ = close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw GitProviderError.unsafePath
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw GitProviderError.resourceLimit }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let address = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, address, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw GitProviderError.unsafePath
            }
            guard data.count <= maximumBytes - count else { throw GitProviderError.resourceLimit }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

/// The per-file subset of `git status`: how the index differs from HEAD and the worktree from the index.
private struct GitStatus: OptionSet {
    let rawValue: UInt16

    static let indexNew = Self(rawValue: 1 << 0)
    static let indexModified = Self(rawValue: 1 << 1)
    static let indexDeleted = Self(rawValue: 1 << 2)
    static let worktreeNew = Self(rawValue: 1 << 3)
    static let worktreeModified = Self(rawValue: 1 << 4)
    static let worktreeDeleted = Self(rawValue: 1 << 5)
    static let ignored = Self(rawValue: 1 << 6)
    static let conflicted = Self(rawValue: 1 << 7)

    static let index: Self = [.indexNew, .indexModified, .indexDeleted]
    static let worktree: Self = [.worktreeNew, .worktreeModified, .worktreeDeleted]
}

private struct GitSnapshot {
    let flags: GitStatus
    let headBytes: Data?
    let indexBytes: Data?
    let workingBytes: Data?
    let lastCommit: VCSCommitSummary?

    /// Captures status plus HEAD, index and working bytes from one read-only repository view.
    static func read(repositoryURL: URL, relativePath: String) throws -> Self {
        let repository = try GitRepository.open(worktree: repositoryURL)
        guard let safeWorkingURL = safeWorkingURL(relativePath, workdir: repository.worktree) else {
            throw GitProviderError.unsafePath
        }
        let workingBytes: Data?
        let workingMode: mode_t?
        switch VCSPath.kind(safeWorkingURL) {
        case .regular:
            workingBytes = try VCSPath.readRegularFile(safeWorkingURL, maximumBytes: GitRepository.maximumBlobBytes)
            workingMode = try fileMode(safeWorkingURL)
        case .missing:
            workingBytes = nil
            workingMode = nil
        default:
            throw GitProviderError.unsafePath
        }

        let head = try repository.headEntry(relativePath: relativePath)
        let lookup = try repository.indexLookup(relativePath: relativePath)
        let entry = lookup.entry
        var status: GitStatus = lookup.conflicted ? .conflicted : []
        if let entry, !entry.intentToAdd {
            if let head {
                if head.id != entry.id || head.mode != entry.mode { status.insert(.indexModified) }
            } else {
                status.insert(.indexNew)
            }
        } else if head != nil, !lookup.conflicted {
            status.insert(.indexDeleted)
        }
        if let entry {
            if entry.intentToAdd {
                status.insert(.worktreeNew)
            } else if entry.skipWorktree || entry.assumeUnchanged {
                // Git trusts the index for these entries and does not look at the file.
            } else if let workingBytes, let workingMode {
                let checksModes = repository.config.bool("core.filemode") ?? true
                let executableChanged = checksModes && (entry.mode == 0o100755) != (workingMode & S_IXUSR != 0)
                if entry.mode == 0o120000 || executableChanged || GitObjectID.blob(hashing: workingBytes) != entry.id {
                    status.insert(.worktreeModified)
                }
            } else {
                status.insert(.worktreeDeleted)
            }
        } else if workingBytes != nil, !lookup.conflicted {
            status.insert(try repository.isIgnored(relativePath: relativePath) ? .ignored : .worktreeNew)
        }

        // An intent-to-add entry records the empty blob, which is what Git compares the file against.
        let indexBytes = try entry.map { try repository.blob($0.intentToAdd ? .emptyBlob : $0.id) }
        return .init(flags: status,
                     headBytes: try head.map { try repository.blob($0.id) },
                     indexBytes: indexBytes, workingBytes: workingBytes,
                     lastCommit: try repository.lastCommit(relativePath: relativePath))
    }

    private static func fileMode(_ url: URL) throws -> mode_t {
        var info = stat()
        let found = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &info) == 0 } ?? false }
        guard found else { throw GitProviderError.unsafePath }
        return info.st_mode
    }

    /// Derives aggregate and staged/unstaged comparisons from the captured three-way snapshot.
    func inspection() throws -> VCSInspectionResult {
        // Report merge conflicts without presenting a misleading single baseline diff.
        if flags.contains(.conflicted) {
            return .init(repositoryType: .git, fileStatus: .conflicted, comparison: nil, lastCommit: lastCommit)
        }

        let hasIndexChanges = !flags.isDisjoint(with: .index)
        let hasWorkingChanges = !flags.isDisjoint(with: .worktree)
        let isUntracked = flags.contains(.worktreeNew) && indexBytes == nil && headBytes == nil
        let status: VCSFileStatus
        if isUntracked {
            status = .untracked
        } else if workingBytes == nil && (headBytes != nil || indexBytes != nil) {
            status = .deleted
        } else if flags.contains(.indexNew) || (headBytes == nil && indexBytes != nil) {
            status = .added
        } else if hasIndexChanges || hasWorkingChanges {
            status = .modified
        } else {
            status = .clean
        }

        let empty = Data()
        let combined = try VCSLineDiff.compare(baseline: headBytes ?? empty, working: workingBytes ?? empty)
        let stagedDiff = hasIndexChanges
            ? try VCSLineDiff.compare(baseline: headBytes ?? empty, working: indexBytes ?? empty) : nil
        let unstagedDiff = hasWorkingChanges
            ? try VCSLineDiff.compare(baseline: indexBytes ?? empty, working: workingBytes ?? empty) : nil
        return .init(
            repositoryType: .git,
            fileStatus: status,
            comparison: .init(base: .head, lineDiff: combined),
            stagedInformation: .init(
                stagedChanges: stagedDiff.map { .init(base: .head, lineDiff: $0) },
                unstagedChanges: unstagedDiff.map { .init(base: .index, lineDiff: $0) }
            ),
            lastCommit: lastCommit
        )
    }

    /// Resolves a normalized repository-relative path and rejects any candidate outside the worktree.
    private static func safeWorkingURL(_ relativePath: String, workdir: URL) -> URL? {
        // Require a normalized descendant path before reading the working-tree file.
        let components = relativePath.split(separator: "/")
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        let candidate = workdir.appending(path: relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(workdir.standardizedFileURL.path + "/") else { return nil }
        return candidate
    }
}
