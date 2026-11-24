import Foundation

/// Reads the entries for one path from a version 2, 3 or 4 index file. Split and sparse indexes
/// keep entries elsewhere, so they fail closed rather than report a tracked file as untracked.
enum GitIndex {
    struct Entry: Equatable {
        let mode: UInt32
        let id: GitObjectID
        let assumeUnchanged: Bool
        let skipWorktree: Bool
        let intentToAdd: Bool
    }

    /// The stage 0 entry, if any, and whether conflict stages 1–3 exist for the path.
    struct Lookup: Equatable {
        var entry: Entry?
        var conflicted = false
    }

    static let maximumBytes = 64 << 20
    private static let checksumBytes = GitObjectID.byteCount

    static func lookup(_ data: Data, path: String) throws -> Lookup {
        let target = Array(path.utf8)
        return try data.withUnsafeBytes { raw -> Lookup in
            let end = raw.count - checksumBytes
            guard end >= 12, raw.uint32(at: 0) == 0x4449_5243 else { throw GitProviderError.invalidRepository }
            let version = raw.uint32(at: 4)
            guard (2...4).contains(version) else { throw GitProviderError.invalidRepository }
            let count = Int(raw.uint32(at: 8))
            var lookup = Lookup()
            var position = 12
            var previousName: [UInt8] = []
            for _ in 0..<count {
                // 40 bytes of cached stat data with the mode at 24, the object name, then 16 flag bits.
                guard position <= end - 62 else { throw GitProviderError.invalidRepository }
                let mode = raw.uint32(at: position + 24)
                guard let id = GitObjectID(bytes: UnsafeRawBufferPointer(rebasing: raw[(position + 40)..<(position + 60)]))
                else { throw GitProviderError.invalidRepository }
                let flags = UInt16(raw[position + 60]) << 8 | UInt16(raw[position + 61])
                var cursor = position + 62
                var extended: UInt16 = 0
                if flags & 0x4000 != 0 {
                    guard version >= 3, cursor <= end - 2 else { throw GitProviderError.invalidRepository }
                    extended = UInt16(raw[cursor]) << 8 | UInt16(raw[cursor + 1])
                    cursor += 2
                }
                var name: [UInt8]
                if version == 4 {
                    var strip = 0
                    var byte: UInt8
                    repeat {
                        guard cursor < end, strip < Int.max >> 8 else { throw GitProviderError.invalidRepository }
                        byte = raw[cursor]
                        cursor += 1
                        strip = strip << 7 | Int(byte & 0x7f)
                        if byte & 0x80 != 0 { strip += 1 }
                    } while byte & 0x80 != 0
                    guard strip <= previousName.count,
                          let terminator = raw[cursor..<end].firstIndex(of: 0) else { throw GitProviderError.invalidRepository }
                    name = Array(previousName.dropLast(strip)) + raw[cursor..<terminator]
                    cursor = terminator + 1
                } else {
                    guard let terminator = raw[cursor..<end].firstIndex(of: 0) else {
                        throw GitProviderError.invalidRepository
                    }
                    name = Array(raw[cursor..<terminator])
                    // Entries are NUL-padded to a multiple of eight bytes, with at least one NUL.
                    cursor = position + ((terminator - position + 8) & ~7)
                }
                guard cursor <= end else { throw GitProviderError.invalidRepository }
                // A directory entry only exists in a sparse index.
                guard mode & 0o170000 != 0o040000 else { throw GitProviderError.invalidRepository }
                if name == target {
                    let stage = flags >> 12 & 0x3
                    if stage == 0 {
                        lookup.entry = Entry(mode: mode, id: id, assumeUnchanged: flags & 0x8000 != 0,
                                             skipWorktree: extended & 0x4000 != 0, intentToAdd: extended & 0x2000 != 0)
                    } else {
                        lookup.conflicted = true
                    }
                }
                previousName = name
                position = cursor
            }
            try checkExtensions(raw, from: position, to: end)
            return lookup
        }
    }

    private static func checkExtensions(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int) throws {
        var position = start
        while position < end {
            guard position <= end - 8 else { throw GitProviderError.invalidRepository }
            let signature = raw.uint32(at: position)
            let size = Int(raw.uint32(at: position + 4))
            // `link` (split index) and `sdir` (sparse index) mean this file is not the whole index.
            guard signature != 0x6c69_6e6b, signature != 0x7364_6972 else { throw GitProviderError.invalidRepository }
            guard size <= end - position - 8 else { throw GitProviderError.invalidRepository }
            position += 8 + size
        }
    }
}
