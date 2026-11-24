import CZlib
import Foundation

/// Bounded inflation of the zlib streams Git uses for loose objects and pack entries.
enum GitZlib {
    private static let chunkSize = 65_536

    /// Inflates the zlib stream at the start of `input`. Output beyond `maximumBytes` is a resource
    /// limit; a truncated or corrupt stream, or a length other than `expectedBytes`, is invalid.
    static func inflate(_ input: UnsafeRawBufferPointer, expectedBytes: Int? = nil, maximumBytes: Int) throws -> Data {
        guard let source = input.baseAddress, !input.isEmpty, input.count <= Int(UInt32.max) else {
            throw GitProviderError.invalidRepository
        }
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GitProviderError.invalidRepository
        }
        defer { inflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: source.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(input.count)

        var output = Data()
        output.reserveCapacity(min(expectedBytes ?? chunkSize, maximumBytes))
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let (status, produced) = chunk.withUnsafeMutableBytes { buffer -> (Int32, Int) in
                guard let address = buffer.baseAddress else { return (Z_MEM_ERROR, 0) }
                stream.next_out = address.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(buffer.count)
                let status = CZlib.inflate(&stream, Z_NO_FLUSH)
                return (status, buffer.count - Int(stream.avail_out))
            }
            guard output.count <= maximumBytes - produced else { throw GitProviderError.resourceLimit }
            output.append(contentsOf: chunk.prefix(produced))
            if status == Z_STREAM_END { break }
            // Z_BUF_ERROR with no input left, or no progress at all, means the stream was cut short.
            guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { throw GitProviderError.invalidRepository }
        }
        if let expectedBytes, output.count != expectedBytes { throw GitProviderError.invalidRepository }
        return output
    }
}
