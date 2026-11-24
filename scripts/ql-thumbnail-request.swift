import AppKit
import Foundation
import QuickLookThumbnailing

@main
struct ThumbnailRequest {
    @MainActor
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw RequestError.usage
            }

            let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let request = QLThumbnailGenerator.Request(
                fileAt: inputURL,
                size: CGSize(width: 256, height: 256),
                scale: 1,
                representationTypes: .thumbnail
            )
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.cgImage
            guard image.width == 256, image.height == 256 else {
                throw RequestError.unexpectedDimensions(image.width, image.height)
            }

            let bitmap = NSBitmapImageRep(cgImage: image)
            guard containsInk(bitmap) else {
                throw RequestError.blankImage
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw RequestError.pngEncodingFailed
            }
            try png.write(to: outputURL, options: .atomic)
        } catch {
            fputs("ql-thumbnail-request: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func containsInk(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) else {
            return false
        }

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(color.redComponent - background.redComponent) > 0.02
                    || abs(color.greenComponent - background.greenComponent) > 0.02
                    || abs(color.blueComponent - background.blueComponent) > 0.02 {
                    return true
                }
            }
        }
        return false
    }
}

private enum RequestError: Error, CustomStringConvertible {
    case usage
    case unexpectedDimensions(Int, Int)
    case blankImage
    case pngEncodingFailed

    var description: String {
        switch self {
        case .usage:
            "usage: ql-thumbnail-request INPUT OUTPUT.png"
        case let .unexpectedDimensions(width, height):
            "thumbnail dimensions were \(width)x\(height), expected 256x256"
        case .blankImage:
            "thumbnail contains no pixels that differ from the semantic background"
        case .pngEncodingFailed:
            "could not encode thumbnail as PNG"
        }
    }
}
