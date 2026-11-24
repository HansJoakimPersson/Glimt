import Darwin
import Foundation

/// Reads the Markdown payload from a TextBundle without walking its asset tree.
public enum TextBundleInspector {
    static let maximumManifestBytes = 64 * 1_024
    private static let maximumMarkdownBytes = 1_048_576
    private static let maximumReadCount = 32 * 1_024
    private static let markdownType = "net.daringfireball.markdown"

    /// Reads a bounded TextBundle Markdown payload for preview or thumbnail inspection.
    /// Only root `info.json` and `text.md` are opened; linked files and unsupported content types fail.
    public static func readMarkdown(at url: URL, maximumBytes: Int) throws -> BoundedFileReader.Prefix {
        try Task.checkCancellation()
        let package = try openPackage(at: url)
        defer { _ = Darwin.close(package.descriptor) }

        let manifestFD = try openChild("info.json", directoryFD: package.descriptor)
        defer { _ = Darwin.close(manifestFD.descriptor) }
        guard manifestFD.fileSize <= maximumManifestBytes else { throw TextBundleError.limitExceeded }
        var ignoredOffsets: [TextBundleReadChild: Set<Int>]?
        let manifest = try readFully(manifestFD.descriptor, fileSize: manifestFD.fileSize,
                                     maximumBytes: maximumManifestBytes, child: .manifest,
                                     readOperation: nil, observe: { _ in }, requestedOffsets: &ignoredOffsets)
        try validateManifest(manifest.data)
        try Task.checkCancellation()

        let markdownFD = try openChild("text.md", directoryFD: package.descriptor)
        defer { _ = Darwin.close(markdownFD.descriptor) }
        let limit = min(max(maximumBytes, 0), maximumMarkdownBytes)
        let count = min(markdownFD.fileSize, limit)
        let payload = try readFully(markdownFD.descriptor, fileSize: markdownFD.fileSize,
                                    maximumBytes: count, child: .markdown,
                                    readOperation: nil, observe: { _ in }, requestedOffsets: &ignoredOffsets)
        return .init(data: payload.data, fileSize: markdownFD.fileSize)
    }

    /// Reads and validates the manifest, samples Markdown within the shared package budget, then
    /// continues on the same descriptor without revising the caller's selection.
    static func readMarkdownStaged<Selection: Sendable>(
        at url: URL,
        maximumBytes: Int,
        transferPackageDescriptor: Bool = false,
        readOperation: TextBundleReadOperation? = nil,
        observe: (TextBundleReadEvent) -> Void = { _ in },
        onSnapshot: (Selection, Data) -> Void = { _, _ in },
        select: (Data, Int) throws -> Selection
    ) throws -> (prefix: BoundedFileReader.Prefix, selection: Selection,
                 identity: PackageIdentity, packageDescriptor: Int32?) {
        try Task.checkCancellation()
        let package = try openPackage(at: url)
        var transferredPackageDescriptor = false
        defer {
            if !transferredPackageDescriptor { _ = Darwin.close(package.descriptor) }
        }

        let manifestFD = try openChild("info.json", directoryFD: package.descriptor)
        defer {
            _ = Darwin.close(manifestFD.descriptor)
            observe(.descriptorClosed(child: .manifest, descriptor: manifestFD.descriptor))
        }
        guard manifestFD.fileSize <= maximumManifestBytes else { throw TextBundleError.limitExceeded }
        var requested: [TextBundleReadChild: Set<Int>]? = [:]
        let manifest = try readFully(manifestFD.descriptor, fileSize: manifestFD.fileSize,
                                     maximumBytes: maximumManifestBytes, child: .manifest,
                                     readOperation: readOperation, observe: observe,
                                     requestedOffsets: &requested)
        try validateManifest(manifest.data)
        try Task.checkCancellation()

        let markdownFD = try openChild("text.md", directoryFD: package.descriptor)
        defer {
            _ = Darwin.close(markdownFD.descriptor)
            observe(.descriptorClosed(child: .markdown, descriptor: markdownFD.descriptor))
        }
        let retainedLimit = min(markdownFD.fileSize, max(0, maximumBytes))
        let routingLimit = max(0, 65_536 - manifest.data.count)
        let sampleLimit = min(retainedLimit, routingLimit)
        let sample = try readFully(markdownFD.descriptor, fileSize: markdownFD.fileSize,
                                   maximumBytes: sampleLimit, child: .markdown,
                                   readOperation: readOperation, observe: observe,
                                   requestedOffsets: &requested)
        try Task.checkCancellation()
        let selection = try select(sample.data, markdownFD.fileSize)
        try Task.checkCancellation()
        let distinctCount = requested?.values.reduce(0) { $0 + $1.count } ?? 0
        requested = nil
        var retained = sample.data
        try Task.checkCancellation()
        onSnapshot(selection, retained)
        observe(.selectionCommitted(routingByteCount: manifest.data.count + sample.data.count,
                                    distinctRequestedOffsets: distinctCount))
        while retained.count < retainedLimit {
            try Task.checkCancellation()
            let amount = min(maximumReadCount, retainedLimit - retained.count)
            let result = try readChunk(markdownFD.descriptor, child: .markdown,
                                       offset: retained.count, requestedCount: amount,
                                       readOperation: readOperation, observe: observe,
                                       requestedOffsets: &requested)
            guard result.byteCount > 0 else { throw TextBundleError.readFailed }
            try Task.checkCancellation()
            retained.append(contentsOf: result.bytes)
            onSnapshot(selection, retained)
            observe(.continuationAppended(retainedByteCount: retained.count))
        }
        try Task.checkCancellation()
        let packageDescriptor: Int32?
        if transferPackageDescriptor {
            transferredPackageDescriptor = true
            packageDescriptor = package.descriptor
        } else {
            packageDescriptor = nil
        }
        return (.init(data: retained, fileSize: markdownFD.fileSize), selection,
                package.identity, packageDescriptor)
    }

    // MARK: - Safe package reads

    static func openPackage(at url: URL) throws -> OpenPackageDirectory {
        guard url.isFileURL, url.pathExtension.lowercased() == "textbundle" else {
            throw TextBundleError.invalidPackage
        }
        try Task.checkCancellation()
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY)
        }
        guard descriptor >= 0 else { throw TextBundleError.invalidPackage }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(descriptor)
            throw TextBundleError.invalidPackage
        }
        return OpenPackageDirectory(descriptor: descriptor,
            identity: PackageIdentity(device: info.st_dev, inode: info.st_ino))
    }

    private static func openChild(_ name: String, directoryFD: Int32) throws -> (descriptor: Int32, fileSize: Int) {
        try Task.checkCancellation()
        let descriptor = Darwin.openat(directoryFD, name,
                                       O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY)
        guard descriptor >= 0 else { throw TextBundleError.invalidPackage }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(Int.max) else {
            _ = Darwin.close(descriptor)
            throw TextBundleError.invalidPackage
        }
        return (descriptor, Int(info.st_size))
    }

    private static func readFully(_ descriptor: Int32, fileSize: Int, maximumBytes: Int,
                                  child: TextBundleReadChild, readOperation: TextBundleReadOperation?,
                                  observe: (TextBundleReadEvent) -> Void,
                                  requestedOffsets: inout [TextBundleReadChild: Set<Int>]?) throws -> BoundedFileReader.Prefix {
        let count = min(fileSize, maximumBytes)
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            try Task.checkCancellation()
            let amount = min(maximumReadCount, count - data.count)
            let result = try readChunk(descriptor, child: child, offset: data.count,
                                       requestedCount: amount, readOperation: readOperation,
                                       observe: observe, requestedOffsets: &requestedOffsets)
            guard result.byteCount > 0 else { throw TextBundleError.readFailed }
            data.append(contentsOf: result.bytes)
        }
        return .init(data: data, fileSize: fileSize)
    }

    private static func readChunk(_ descriptor: Int32, child: TextBundleReadChild, offset: Int,
                                  requestedCount: Int, readOperation: TextBundleReadOperation?,
                                  observe: (TextBundleReadEvent) -> Void,
                                  requestedOffsets: inout [TextBundleReadChild: Set<Int>]?) throws -> (byteCount: Int, bytes: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: requestedCount)
        while true {
            try Task.checkCancellation()
            if requestedOffsets != nil {
                for byteOffset in offset..<(offset + requestedCount) {
                    requestedOffsets?[child, default: []].insert(byteOffset)
                }
            }
            observe(.readDescriptor(child: child, offset: offset, descriptor: descriptor))
            let attempt = buffer.withUnsafeMutableBufferPointer { storage -> TextBundleReadAttempt in
                if let readOperation {
                    return readOperation(descriptor, storage.baseAddress, requestedCount)
                }
                let count = Darwin.read(descriptor, storage.baseAddress, requestedCount)
                return TextBundleReadAttempt(byteCount: count, errorCode: count < 0 ? errno : nil)
            }
            observe(.read(child: child, offset: offset, requestedCount: requestedCount,
                          returnedCount: attempt.byteCount < 0 ? 0 : attempt.byteCount,
                          errorCode: attempt.errorCode))
            if let errorCode = attempt.errorCode {
                if errorCode == EINTR { continue }
                throw TextBundleError.readFailed
            }
            guard attempt.byteCount >= 0, attempt.byteCount <= requestedCount else {
                throw TextBundleError.readFailed
            }
            return (attempt.byteCount, Array(buffer.prefix(attempt.byteCount)))
        }
    }

    // MARK: - Manifest validation

    private static func validateManifest(_ data: Data) throws {
        let parsed = try JSONInspector.inspect(bytes: data, fileSize: data.count)
        guard parsed.diagnostics.isEmpty, case .object(let members)? = parsed.content,
              let versionText = number("version", in: members), let version = Int(versionText),
              version == 1 || version == 2 else { throw TextBundleError.invalidManifest }
        if let typeMember = members.first(where: { $0.key == "type" }) {
            guard case .string(let type) = typeMember.value else { throw TextBundleError.invalidManifest }
            guard type == markdownType else { throw TextBundleError.unsupportedContentType }
        }
    }

    private static func number(_ name: String, in members: [StructuredMember]) -> String? {
        guard case .number(let value)? = members.first(where: { $0.key == name })?.value else { return nil }
        return value
    }
}

struct PackageIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

struct OpenPackageDirectory {
    let descriptor: Int32
    let identity: PackageIdentity
}

public enum TextBundleReadChild: Sendable, Hashable {
    case manifest
    case markdown
}

public enum TextBundleReadEvent: Sendable {
    case read(child: TextBundleReadChild, offset: Int, requestedCount: Int, returnedCount: Int, errorCode: Int32?)
    case readDescriptor(child: TextBundleReadChild, offset: Int, descriptor: Int32)
    case selectionCommitted(routingByteCount: Int, distinctRequestedOffsets: Int)
    case descriptorClosed(child: TextBundleReadChild, descriptor: Int32)
    case continuationAppended(retainedByteCount: Int)
    case dispatchAttempt(inspectorID: InspectorID)
    case assetResolutionStarted
}

struct TextBundleReadAttempt {
    let byteCount: Int
    let errorCode: Int32?
}

/// Synchronous read seam; implementations must not retain the descriptor buffer after returning.
typealias TextBundleReadOperation = (Int32, UnsafeMutablePointer<UInt8>?, Int) -> TextBundleReadAttempt

enum TextBundleError: Error, Equatable {
    case invalidPackage
    case invalidManifest
    case unsupportedContentType
    case limitExceeded
    case readFailed
}
