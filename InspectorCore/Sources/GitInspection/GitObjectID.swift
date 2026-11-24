import CryptoKit
import Foundation

/// A SHA-1 object name. SHA-256 repositories are rejected before any ID is parsed.
struct GitObjectID: Hashable, Sendable {
    static let byteCount = 20
    /// The hardcoded empty blob and tree, which Git treats as present even when not stored.
    static let emptyBlob = GitObjectID(trusted: [
        0xe6, 0x9d, 0xe2, 0x9b, 0xb2, 0xd1, 0xd6, 0x43, 0x4b, 0x8b,
        0x29, 0xae, 0x77, 0x5a, 0xd8, 0xc2, 0xe4, 0x8c, 0x53, 0x91,
    ])
    static let emptyTree = GitObjectID(trusted: [
        0x4b, 0x82, 0x5d, 0xc6, 0x42, 0xcb, 0x6e, 0xb9, 0xa0, 0x60,
        0xe5, 0x4b, 0xf8, 0xd6, 0x92, 0x88, 0xfb, 0xee, 0x49, 0x04,
    ])

    let bytes: [UInt8]

    private init(trusted bytes: [UInt8]) {
        self.bytes = bytes
    }

    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Array(bytes)
    }

    init?(hex: some StringProtocol) {
        let digits = Array(hex.utf8)
        guard digits.count == Self.byteCount * 2 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Self.nibble(digits[index]), let low = Self.nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self.bytes = bytes
    }

    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(Self.byteCount * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// The name Git gives `data` stored as a blob: SHA-1 over `blob <length>\0` and the bytes.
    static func blob(hashing data: Data) -> GitObjectID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return GitObjectID(trusted: Array(hasher.finalize()))
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
