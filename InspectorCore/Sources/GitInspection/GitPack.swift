import Foundation

/// One `pack-*.pack` with its version 2 `.idx`, both memory-mapped and validated before use.
final class GitPack {
    /// How a pack entry stores its object: whole, or as a delta against a base.
    enum Entry {
        case object(GitObjectType, size: Int, dataOffset: Int)
        case offsetDelta(baseOffset: Int, size: Int, dataOffset: Int)
        case referenceDelta(base: GitObjectID, size: Int, dataOffset: Int)
    }

    private static let fanoutOffset = 8
    private static let namesOffset = fanoutOffset + 256 * 4
    private static let trailerBytes = 2 * GitObjectID.byteCount

    private let index: Data
    let pack: Data
    private let count: Int

    init(indexURL: URL, packURL: URL) throws {
        guard VCSPath.kind(indexURL) == .regular, VCSPath.kind(packURL) == .regular else {
            throw GitProviderError.invalidRepository
        }
        do {
            index = try Data(contentsOf: indexURL, options: .alwaysMapped)
            pack = try Data(contentsOf: packURL, options: .alwaysMapped)
        } catch {
            throw GitProviderError.invalidRepository
        }
        count = try index.withUnsafeBytes { raw -> Int in
            guard raw.count >= Self.namesOffset + Self.trailerBytes,
                  raw.uint32(at: 0) == 0xff74_4f63, raw.uint32(at: 4) == 2 else {
                throw GitProviderError.invalidRepository
            }
            var previous: UInt32 = 0
            for bucket in 0..<256 {
                let value = raw.uint32(at: Self.fanoutOffset + bucket * 4)
                guard value >= previous else { throw GitProviderError.invalidRepository }
                previous = value
            }
            let count = Int(previous)
            // Names, CRCs and 32-bit offsets, then optional 64-bit offsets, then two checksums.
            guard raw.count >= Self.namesOffset + count * 28 + Self.trailerBytes else {
                throw GitProviderError.invalidRepository
            }
            return count
        }
        try pack.withUnsafeBytes { raw in
            guard raw.count >= 12 + GitObjectID.byteCount, raw.uint32(at: 0) == 0x5041_434b,
                  [2, 3].contains(raw.uint32(at: 4)), Int(raw.uint32(at: 8)) == count else {
                throw GitProviderError.invalidRepository
            }
        }
    }

    /// Finds the pack offset of an object through the sorted name table.
    func offset(of id: GitObjectID) throws -> Int? {
        try index.withUnsafeBytes { raw -> Int? in
            guard let names = raw.baseAddress.map({ $0 + Self.namesOffset }) else { return nil }
            let first = Int(id.bytes[0])
            var low = first == 0 ? 0 : Int(raw.uint32(at: Self.fanoutOffset + (first - 1) * 4))
            var high = Int(raw.uint32(at: Self.fanoutOffset + first * 4))
            while low < high {
                let middle = (low + high) / 2
                let order = id.bytes.withUnsafeBytes { key in
                    key.baseAddress.map { memcmp(names + middle * GitObjectID.byteCount, $0, GitObjectID.byteCount) } ?? -1
                }
                if order == 0 { return try packOffset(at: middle, raw) }
                if order < 0 { low = middle + 1 } else { high = middle }
            }
            return nil
        }
    }

    private func packOffset(at position: Int, _ raw: UnsafeRawBufferPointer) throws -> Int {
        let smallOffsets = Self.namesOffset + count * 24
        let value = raw.uint32(at: smallOffsets + position * 4)
        guard value & 0x8000_0000 != 0 else { return Int(value) }
        let large = smallOffsets + count * 4 + Int(value & 0x7fff_ffff) * 8
        guard large + 8 <= raw.count - Self.trailerBytes else { throw GitProviderError.invalidRepository }
        let offset = UInt64(raw.uint32(at: large)) << 32 | UInt64(raw.uint32(at: large + 4))
        guard offset < UInt64(Int.max) else { throw GitProviderError.invalidRepository }
        return Int(offset)
    }

    /// Decodes the variable-length entry header at `offset`.
    func entry(at offset: Int) throws -> Entry {
        try pack.withUnsafeBytes { raw -> Entry in
            let end = raw.count - GitObjectID.byteCount
            guard offset >= 12, offset < end else { throw GitProviderError.invalidRepository }
            var position = offset
            var byte = raw[position]
            let typeCode = Int(byte >> 4 & 0x07)
            var size = Int(byte & 0x0f)
            var shift = 4
            while byte & 0x80 != 0 {
                position += 1
                guard position < end, shift <= 56 else { throw GitProviderError.invalidRepository }
                byte = raw[position]
                size |= Int(byte & 0x7f) << shift
                shift += 7
            }
            position += 1
            switch typeCode {
            case 6:
                guard position < end else { throw GitProviderError.invalidRepository }
                byte = raw[position]
                var distance = Int(byte & 0x7f)
                while byte & 0x80 != 0 {
                    position += 1
                    guard position < end, distance < Int.max >> 8 else { throw GitProviderError.invalidRepository }
                    byte = raw[position]
                    distance = (distance + 1) << 7 | Int(byte & 0x7f)
                }
                guard distance > 0, distance < offset else { throw GitProviderError.invalidRepository }
                return .offsetDelta(baseOffset: offset - distance, size: size, dataOffset: position + 1)
            case 7:
                guard position + GitObjectID.byteCount <= end,
                      let base = GitObjectID(bytes: UnsafeRawBufferPointer(rebasing: raw[position..<position + 20]))
                else { throw GitProviderError.invalidRepository }
                return .referenceDelta(base: base, size: size, dataOffset: position + 20)
            default:
                guard let type = GitObjectType(packCode: typeCode) else { throw GitProviderError.invalidRepository }
                return .object(type, size: size, dataOffset: position)
            }
        }
    }

    /// Inflates the entry data that starts at `dataOffset`, which must produce exactly `size` bytes.
    func inflate(from dataOffset: Int, size: Int, maximumBytes: Int) throws -> Data {
        guard size <= maximumBytes else { throw GitProviderError.resourceLimit }
        return try pack.withUnsafeBytes { raw in
            let end = raw.count - GitObjectID.byteCount
            guard dataOffset < end else { throw GitProviderError.invalidRepository }
            return try GitZlib.inflate(UnsafeRawBufferPointer(rebasing: raw[dataOffset..<end]),
                                       expectedBytes: size, maximumBytes: maximumBytes)
        }
    }
}

/// Git's copy/insert delta format, applied with every offset and length checked against its buffers.
enum GitDelta {
    static func apply(_ delta: Data, to base: Data, maximumBytes: Int) throws -> Data {
        try delta.withUnsafeBytes { instructions -> Data in
            var position = 0
            func size() throws -> Int {
                var value = 0
                var shift = 0
                while true {
                    guard position < instructions.count, shift <= 56 else { throw GitProviderError.invalidRepository }
                    let byte = instructions[position]
                    position += 1
                    value |= Int(byte & 0x7f) << shift
                    shift += 7
                    if byte & 0x80 == 0 { return value }
                }
            }
            guard try size() == base.count else { throw GitProviderError.invalidRepository }
            let resultSize = try size()
            guard resultSize <= maximumBytes else { throw GitProviderError.resourceLimit }
            var result = Data()
            result.reserveCapacity(resultSize)
            while position < instructions.count {
                let opcode = instructions[position]
                position += 1
                if opcode & 0x80 != 0 {
                    var offset = 0
                    var length = 0
                    for bit in 0..<7 where opcode & (1 << bit) != 0 {
                        guard position < instructions.count else { throw GitProviderError.invalidRepository }
                        let value = Int(instructions[position])
                        position += 1
                        if bit < 4 { offset |= value << (bit * 8) } else { length |= value << ((bit - 4) * 8) }
                    }
                    if length == 0 { length = 0x10000 }
                    guard offset <= base.count - length, result.count <= resultSize - length else {
                        throw GitProviderError.invalidRepository
                    }
                    result.append(base[base.startIndex + offset..<base.startIndex + offset + length])
                } else if opcode != 0 {
                    let length = Int(opcode)
                    guard length <= instructions.count - position, result.count <= resultSize - length else {
                        throw GitProviderError.invalidRepository
                    }
                    result.append(contentsOf: UnsafeRawBufferPointer(rebasing: instructions[position..<position + length]))
                    position += length
                } else {
                    throw GitProviderError.invalidRepository
                }
            }
            guard result.count == resultSize else { throw GitProviderError.invalidRepository }
            return result
        }
    }
}

extension UnsafeRawBufferPointer {
    /// Reads a big-endian 32-bit value; callers bound `offset` against the buffer first.
    func uint32(at offset: Int) -> UInt32 {
        loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
    }
}
