import Foundation

/// The four object kinds Git stores.
enum GitObjectType: Equatable, Sendable {
    case commit, tree, blob, tag

    init?(packCode: Int) {
        switch packCode {
        case 1: self = .commit
        case 2: self = .tree
        case 3: self = .blob
        case 4: self = .tag
        default: return nil
        }
    }

    init?(name: some StringProtocol) {
        switch name {
        case "commit": self = .commit
        case "tree": self = .tree
        case "blob": self = .blob
        case "tag": self = .tag
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .commit: "commit"
        case .tree: "tree"
        case .blob: "blob"
        case .tag: "tag"
        }
    }
}

/// An object's type and its full, decompressed content.
struct GitObject: Sendable {
    let type: GitObjectType
    let data: Data
}

/// Reads objects from packs, loose files and one level of alternates without writing anything.
final class GitObjectDatabase {
    /// Delta bases and intermediate results may exceed the caller's limit up to this size.
    private static let intermediateLimit = 16 << 20
    private static let maximumDeltaDepth = 4096
    private static let cacheBudget = 32 << 20

    private struct Store {
        let objects: URL
        let packs: [GitPack]
    }

    private struct PackKey: Hashable {
        let pack: Int
        let offset: Int
    }

    private let looseDirectories: [URL]
    private let packs: [GitPack]
    private var cache: [PackKey: GitObject] = [:]
    private var cachedBytes = 0

    init(objectsDirectory: URL) throws {
        var stores = [try Self.store(objectsDirectory)]
        let alternates = objectsDirectory.appendingPathComponent("info/alternates")
        if let list = try GitMetadata.read(alternates, maximumBytes: 65_536) {
            for line in String(decoding: list, as: UTF8.self).split(separator: "\n").prefix(16) {
                let path = line.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty, !path.hasPrefix("#") else { continue }
                let url = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path, isDirectory: true)
                    : objectsDirectory.appending(path: path, directoryHint: .isDirectory)
                guard VCSPath.kind(url.standardizedFileURL) == .directory else { continue }
                stores.append(try Self.store(url.standardizedFileURL))
            }
        }
        looseDirectories = stores.map(\.objects)
        packs = stores.flatMap(\.packs)
    }

    private static func store(_ objects: URL) throws -> Store {
        guard VCSPath.kind(objects) == .directory else { throw GitProviderError.invalidRepository }
        let directory = objects.appendingPathComponent("pack", isDirectory: true)
        guard VCSPath.kind(directory) == .directory else { return Store(objects: objects, packs: []) }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) } catch {
            throw GitProviderError.invalidRepository
        }
        let packs = try names.filter { $0.hasPrefix("pack-") && $0.hasSuffix(".idx") }.sorted().prefix(4096)
            .compactMap { name -> GitPack? in
                let index = directory.appendingPathComponent(name)
                let pack = index.deletingPathExtension().appendingPathExtension("pack")
                guard VCSPath.kind(pack) == .regular else { return nil }
                return try GitPack(indexURL: index, packURL: pack)
            }
        return Store(objects: objects, packs: packs)
    }

    /// Reads an object whose content may not exceed `maximumBytes`; absent objects are `missingObject`.
    func read(_ id: GitObjectID, maximumBytes: Int) throws -> GitObject {
        if id == .emptyBlob { return GitObject(type: .blob, data: Data()) }
        if id == .emptyTree { return GitObject(type: .tree, data: Data()) }
        if let (pack, offset) = try locatePacked(id) {
            return try readPacked(pack: pack, offset: offset, maximumBytes: maximumBytes)
        }
        for objects in looseDirectories {
            if let object = try readLoose(id, in: objects, maximumBytes: maximumBytes) { return object }
        }
        throw GitProviderError.missingObject
    }

    private func locatePacked(_ id: GitObjectID) throws -> (Int, Int)? {
        for (number, pack) in packs.enumerated() {
            if let offset = try pack.offset(of: id) { return (number, offset) }
        }
        return nil
    }

    private func readLoose(_ id: GitObjectID, in objects: URL, maximumBytes: Int) throws -> GitObject? {
        let hex = id.hex
        let file = objects.appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(hex.dropFirst(2)))
        guard let compressed = try GitMetadata.read(file, maximumBytes: Self.intermediateLimit * 2) else { return nil }
        // Room for the longest header, `commit <20 digits>\0`, beyond the content limit.
        let inflated = try compressed.withUnsafeBytes { try GitZlib.inflate($0, maximumBytes: maximumBytes + 32) }
        guard let space = inflated.firstIndex(of: 0x20), let terminator = inflated.firstIndex(of: 0),
              space < terminator,
              let type = GitObjectType(name: String(decoding: inflated[..<space], as: UTF8.self)),
              let size = Int(String(decoding: inflated[(space + 1)..<terminator], as: UTF8.self)),
              size == inflated.count - terminator - 1 else {
            throw GitProviderError.invalidRepository
        }
        guard size <= maximumBytes else { throw GitProviderError.resourceLimit }
        return GitObject(type: type, data: inflated.subdata(in: (terminator + 1)..<inflated.count))
    }

    /// Resolves a pack entry, following its delta chain to a whole base and applying deltas back up.
    private func readPacked(pack number: Int, offset: Int, maximumBytes: Int) throws -> GitObject {
        var deltas: [(key: PackKey, delta: Data)] = []
        var key = PackKey(pack: number, offset: offset)
        var base: GitObject?
        for _ in 0..<Self.maximumDeltaDepth {
            if let cached = cache[key] {
                base = cached
                break
            }
            let limit = deltas.isEmpty ? min(maximumBytes, Self.intermediateLimit) : Self.intermediateLimit
            switch try packs[key.pack].entry(at: key.offset) {
            case .object(let type, let size, let dataOffset):
                let object = GitObject(type: type, data: try packs[key.pack].inflate(from: dataOffset, size: size,
                                                                                      maximumBytes: limit))
                remember(object, for: key)
                base = object
            case .offsetDelta(let baseOffset, let size, let dataOffset):
                deltas.append((key, try packs[key.pack].inflate(from: dataOffset, size: size,
                                                                 maximumBytes: Self.intermediateLimit)))
                key = PackKey(pack: key.pack, offset: baseOffset)
            case .referenceDelta(let baseID, let size, let dataOffset):
                deltas.append((key, try packs[key.pack].inflate(from: dataOffset, size: size,
                                                                 maximumBytes: Self.intermediateLimit)))
                if let (pack, baseOffset) = try locatePacked(baseID) {
                    key = PackKey(pack: pack, offset: baseOffset)
                } else {
                    base = try read(baseID, maximumBytes: Self.intermediateLimit)
                }
            }
            if base != nil { break }
        }
        guard var object = base else { throw GitProviderError.invalidRepository }
        for (index, step) in deltas.enumerated().reversed() {
            let limit = index == 0 ? maximumBytes : Self.intermediateLimit
            object = GitObject(type: object.type, data: try GitDelta.apply(step.delta, to: object.data, maximumBytes: limit))
            remember(object, for: step.key)
        }
        guard object.data.count <= maximumBytes else { throw GitProviderError.resourceLimit }
        return object
    }

    /// Keeps resolved pack objects for later delta chains and history steps within a byte budget.
    private func remember(_ object: GitObject, for key: PackKey) {
        guard object.data.count <= Self.cacheBudget / 8 else { return }
        if cachedBytes + object.data.count > Self.cacheBudget {
            cache.removeAll(keepingCapacity: true)
            cachedBytes = 0
        }
        if cache.updateValue(object, forKey: key) == nil { cachedBytes += object.data.count }
    }
}

/// Bounded reads of repository metadata files that never follow a symlink.
enum GitMetadata {
    /// Returns nil when the file does not exist; any other unreadable state is invalid.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        switch VCSPath.kind(url) {
        case .missing:
            return nil
        case .regular:
            do { return try VCSPath.readRegularFile(url, maximumBytes: maximumBytes) } catch GitProviderError.unsafePath {
                throw GitProviderError.invalidRepository
            }
        case .directory, .other:
            throw GitProviderError.invalidRepository
        }
    }
}
