import Darwin
import Foundation

/// Reads a bounded prefix from a regular file without blocking on special files such as FIFOs.
public enum BoundedFileReader {
    struct StagedReadAttempt {
        let byteCount: Int
        let errorCode: Int32?
    }
    typealias StagedReadOperation = (Int32, UnsafeMutablePointer<UInt8>?, Int, off_t) -> StagedReadAttempt
    /// Retained bytes and the observed regular-file size used to determine prefix completeness.
    public struct Prefix: Sendable {
        public let data: Data
        public let fileSize: Int

        public var isComplete: Bool { data.count == fileSize }
    }

    /// Safe failure categories returned before or during a bounded regular-file read.
    public enum ReadError: Error, Equatable {
        case notFileURL
        case fileSizeUnavailable
        case notRegularFile
        case openFailed(Int32)
        case readFailed(Int32)
    }

    /// One validated descriptor used for forward-only reads staged around route selection.
    /// The caller owns the byte budget and must advance only by bytes actually returned.
    final class StagedFile {
        let fileSize: Int
        private let descriptor: Int32
        private let readOperation: StagedReadOperation?

        init(url: URL, readOperation: StagedReadOperation? = nil) throws {
            (descriptor, fileSize) = try BoundedFileReader.openRegularFile(at: url)
            self.readOperation = readOperation
        }

        deinit { _ = Darwin.close(descriptor) }

        /// Makes one positional read. Short and zero reads are returned to the caller unchanged.
        func readOnce(offset: Int, maximumCount: Int) throws -> Data {
            guard offset >= 0, maximumCount >= 0, offset <= fileSize,
                  maximumCount <= fileSize - offset else { throw ReadError.fileSizeUnavailable }
            guard maximumCount > 0 else { return Data() }
            var buffer = [UInt8](repeating: 0, count: maximumCount)
            let attempt = buffer.withUnsafeMutableBufferPointer { storage -> StagedReadAttempt in
                if let readOperation {
                    return readOperation(descriptor, storage.baseAddress, maximumCount, off_t(offset))
                }
                let count = Darwin.pread(descriptor, storage.baseAddress, maximumCount, off_t(offset))
                return StagedReadAttempt(byteCount: count, errorCode: count < 0 ? errno : nil)
            }
            if let errorCode = attempt.errorCode { throw ReadError.readFailed(errorCode) }
            guard attempt.byteCount >= 0, attempt.byteCount <= maximumCount else {
                throw ReadError.readFailed(EIO)
            }
            return Data(buffer.prefix(attempt.byteCount))
        }
    }

    /// Reads at most `maximumBytes` from a regular file, rejecting special files before any read.
    /// The opened descriptor is validated to avoid trusting metadata that may change after lookup.
    public static func readPrefix(at url: URL, maximumBytes: Int) throws -> Prefix {
        let limit = max(0, maximumBytes)
        let opened = try openRegularFile(at: url)
        // Keep the descriptor lifetime bounded across every success and thrown read error.
        defer { _ = Darwin.close(opened.descriptor) }

        let fileSize = opened.fileSize
        let count = min(limit, fileSize)
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 64 * 1024))
        while data.count < count {
            let requested = min(buffer.count, count - data.count)
            let readCount = buffer.withUnsafeMutableBufferPointer { storage in
                Darwin.read(opened.descriptor, storage.baseAddress, requested)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw ReadError.readFailed(errno)
            }
            if readCount == 0 { break }
            data.append(contentsOf: buffer.prefix(readCount))
        }
        return Prefix(data: data, fileSize: fileSize)
    }

    /// A validated regular file read by offset, for formats whose metadata lies beyond the retained prefix.
    final class RandomAccessFile {
        let fileSize: Int
        private let descriptor: Int32

        init(url: URL) throws {
            (descriptor, fileSize) = try BoundedFileReader.openRegularFile(at: url)
        }

        deinit { _ = Darwin.close(descriptor) }

        /// Reads exactly `range`; a short read means the file shrank while it was being inspected.
        func read(_ range: Range<Int>) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: range.count)
            var filled = 0
            while filled < range.count {
                let readCount = buffer.withUnsafeMutableBufferPointer { storage in
                    Darwin.pread(descriptor, storage.baseAddress.map { $0 + filled }, range.count - filled,
                                 off_t(range.lowerBound + filled))
                }
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw ReadError.readFailed(errno)
                }
                if readCount == 0 { throw ReadError.readFailed(EIO) }
                filled += readCount
            }
            return buffer
        }
    }

    private static func openRegularFile(at url: URL) throws -> (descriptor: Int32, fileSize: Int) {
        guard url.isFileURL else { throw ReadError.notFileURL }
        return try url.withUnsafeFileSystemRepresentation { path -> (descriptor: Int32, fileSize: Int) in
            guard let path else { throw ReadError.openFailed(EINVAL) }
            // O_NONBLOCK prevents a FIFO or device path from hanging an extension before fstat.
            let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
            guard fd >= 0 else { throw ReadError.openFailed(errno) }
            var info = stat()
            guard Darwin.fstat(fd, &info) == 0 else {
                let code = errno
                _ = Darwin.close(fd)
                throw ReadError.openFailed(code)
            }
            // Inspect the descriptor itself so a path swap cannot make us read a special file.
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                _ = Darwin.close(fd)
                throw ReadError.notRegularFile
            }
            guard info.st_size >= 0, info.st_size <= Int64(Int.max) else {
                _ = Darwin.close(fd)
                throw ReadError.fileSizeUnavailable
            }
            return (fd, Int(info.st_size))
        }
    }
}
