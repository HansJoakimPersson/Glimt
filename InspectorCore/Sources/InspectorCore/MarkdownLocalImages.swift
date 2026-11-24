import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Resolves Markdown image references against local files while enforcing preview-safe bounds.
enum MarkdownLocalImages {
    static let maximumCount = 4
    private static let maximumReferences = 128
    static let maximumBytesPerImage = 4 * 1_024 * 1_024
    static let maximumTotalBytes = 8 * 1_024 * 1_024
    static let maximumDimension = 4_096
    static let maximumPixels = 16_000_000
    static let maximumTotalPixels = 24_000_000
    private static let maximumAttempts = 8

    enum RootPolicy {
        case documentDirectory
        case textBundle
    }

    /// Finds a capped subset of supported inline image references and maps alt text into rendered UTF-16 ranges.
    static func references(in source: String, renderedText: String, bodyStart: Int,
                           checkpoint: () throws -> Void) -> [MarkdownImageReference] {
        // Scan only the supported inline-image subset, ignoring code fences, code spans, and escaped markers.
        let text = source as NSString
        let output = renderedText as NSString
        var found: [(alt: String, destination: String)] = []
        var index = 0
        var fence: unichar = 0
        var inlineTicks = 0
        while index < text.length, found.count < maximumReferences {
            do { try checkpoint() } catch { break }
            let lineStart = index == 0 || text.character(at: index - 1) == 10
            if lineStart {
                var first = index
                while first < text.length && (text.character(at: first) == 32 || text.character(at: first) == 9) { first += 1 }
                if first + 2 < text.length {
                    let marker = text.character(at: first)
                    if marker == 96 || marker == 126 {
                        var end = first
                        while end < text.length && text.character(at: end) == marker { end += 1 }
                        if end - first >= 3 {
                            if fence == 0 { fence = marker }
                            else if fence == marker { fence = 0 }
                            index = end
                            continue
                        }
                    }
                }
            }
            if fence != 0 { index += 1; continue }
            let unit = text.character(at: index)
            if unit == 96 {
                var end = index
                while end < text.length && text.character(at: end) == 96 { end += 1 }
                let count = end - index
                if inlineTicks == 0 { inlineTicks = count }
                else if inlineTicks == count { inlineTicks = 0 }
                index = end
                continue
            }
            guard inlineTicks == 0, unit == 33, index + 2 < text.length,
                  text.character(at: index + 1) == 91,
                  (index == 0 || !isEscaped(text, at: index)) else { index += 1; continue }
            var close = index + 2
            while close < text.length && close - index <= 512 {
                let current = text.character(at: close)
                if current == 10 || current == 13 || current == 91 || current == 93 { break }
                close += 1
            }
            guard close < text.length, text.character(at: close) == 93,
                  close + 1 < text.length, text.character(at: close + 1) == 40 else { index += 1; continue }
            let destinationStart = close + 2
            var destinationEnd = destinationStart
            while destinationEnd < text.length, destinationEnd - destinationStart <= 1_024 {
                let current = text.character(at: destinationEnd)
                if current == 41 || current == 32 || current == 9 || current == 10 || current == 13 { break }
                destinationEnd += 1
            }
            guard destinationEnd < text.length, text.character(at: destinationEnd) == 41,
                  destinationEnd > destinationStart else { index = close + 1; continue }
            let alt = text.substring(with: NSRange(location: index + 2, length: close - index - 2))
            let destination = text.substring(with: NSRange(location: destinationStart, length: destinationEnd - destinationStart))
            guard !alt.isEmpty, !alt.contains("&"), !alt.contains("*"), !alt.contains("_"),
                  !alt.contains("~"), !alt.contains("<"), !alt.contains("\\") else {
                index = destinationEnd + 1
                continue
            }
            found.append((alt, destination))
            index = destinationEnd + 1
        }

        var cursor = min(max(bodyStart, 0), output.length)
        return found.compactMap { item in
            let range = output.range(of: item.alt, options: [], range: NSRange(location: cursor, length: output.length - cursor))
            guard range.location != NSNotFound else { return nil }
            cursor = NSMaxRange(range)
            return MarkdownImageReference(range: range, destination: item.destination)
        }
    }

    /// Resolves only local descendants through descriptor-relative reads; failed references remain unchanged.
    static func resolve(_ images: [MarkdownImageReference], relativeTo documentURL: URL) -> [MarkdownImageReference] {
        // Resolve only a handful of local images under aggregate byte/pixel limits; all other links stay text.
        guard documentURL.isFileURL, !images.isEmpty,
              let directory = canonicalDirectory(for: documentURL.deletingLastPathComponent()) else { return images }
        let rootFD = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFD >= 0 else { return images }
        defer { _ = Darwin.close(rootFD) }

        return resolve(images, rootDescriptor: rootFD, policy: .documentDirectory)
    }

    /// Resolves images beneath a borrowed, already-validated directory descriptor.
    static func resolve(_ images: [MarkdownImageReference], rootDescriptor: Int32,
                        policy: RootPolicy) -> [MarkdownImageReference] {
        var totalBytes = 0
        var totalPixels = 0
        var accepted = 0
        var attempts = 0
        return images.map { image in
            guard !Task.isCancelled,
                  accepted < maximumCount, attempts < maximumAttempts,
                  totalBytes < maximumTotalBytes else { return image }
            attempts += 1
            guard let bytes = read(image.destination, rootFD: rootDescriptor, policy: policy,
                                   maximumBytes: min(maximumBytesPerImage, maximumTotalBytes - totalBytes)) else { return image }
            totalBytes += bytes.count
            guard let decoded = validate(bytes, maximumPixels: min(maximumPixels, maximumTotalPixels - totalPixels)),
                  decoded.width > 0, decoded.height > 0 else { return image }
            accepted += 1
            totalPixels += decoded.width * decoded.height
            var resolved = image
            resolved.data = bytes
            resolved.pixelWidth = decoded.width
            resolved.pixelHeight = decoded.height
            return resolved
        }
    }

    /// Resolves the containing directory once so later reads can remain relative to a trusted root descriptor.
    private static func canonicalDirectory(for url: URL) -> URL? {
        // Resolve the document directory once, then use descriptor-relative opens beneath that root.
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil)
    }

    /// Reads one bounded regular-file descendant without following symlinks at any path component.
    private static func read(_ destination: String, rootFD: Int32, policy: RootPolicy,
                             maximumBytes: Int) -> Data? {
        // Reject absolute, encoded traversal, and platform-specific path syntax before walking components.
        guard maximumBytes > 0, !destination.isEmpty, !destination.hasPrefix("/"),
              !destination.contains("\\"), !destination.contains(":"), !destination.contains("?"),
              !destination.contains("#"), destination.utf8.count <= 1_024,
              let decoded = destination.removingPercentEncoding, !decoded.isEmpty,
              decoded.utf8.count <= 1_024 else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 8,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        if case .textBundle = policy {
            guard components.count >= 2, components[0] == "assets" else { return nil }
        }
        var directoryFD = Darwin.dup(rootFD)
        guard directoryFD >= 0 else { return nil }
        for component in components.dropLast() {
            // O_NOFOLLOW on each directory prevents a nested symlink from escaping the document folder.
            let next = Darwin.openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY)
            _ = Darwin.close(directoryFD)
            guard next >= 0 else { return nil }
            directoryFD = next
        }
        defer { _ = Darwin.close(directoryFD) }
        // Open the final component without following links or blocking on a substituted special file.
        let fileFD = Darwin.openat(directoryFD, components[components.count - 1], O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY)
        guard fileFD >= 0 else { return nil }
        defer { _ = Darwin.close(fileFD) }
        var info = stat()
        guard Darwin.fstat(fileFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { return nil }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        while data.count < Int(info.st_size) {
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                Darwin.read(fileFD, bytes.baseAddress, min(bytes.count, Int(info.st_size) - data.count))
            }
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    /// Verifies one supported image frame and pixel dimensions before decoding its bitmap.
    private static func validate(_ data: Data, maximumPixels: Int) -> (width: Int, height: Int)? {
        // Read metadata first and decode only one image frame after dimensions, type, and pixel budget pass.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height,
              let type = CGImageSourceGetType(source),
              let uniformType = UTType(type as String), uniformType.conforms(to: .image),
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
        else { return nil }
        return (width, height)
    }

    /// Applies Markdown's odd/even preceding-backslash rule to delimiter positions.
    private static func isEscaped(_ text: NSString, at index: Int) -> Bool {
        // Markdown escaping depends on odd/even backslash parity immediately before a delimiter.
        var cursor = index - 1
        var slashes = 0
        while cursor >= 0, text.character(at: cursor) == 92 { slashes += 1; cursor -= 1 }
        return slashes % 2 == 1
    }
}
