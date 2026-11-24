import AppKit
import InspectorCore

typealias MermaidBlockRenderOperation = @MainActor ([MarkdownMermaidBlock], Double) async throws -> [String: NSImage]
typealias MermaidAttachmentFactory = @MainActor (MarkdownMermaidBlock, NSAppearance, CGFloat, NSImage?) -> NSTextAttachment?
typealias MermaidRenderResultObserver = @MainActor (UUID, Int) -> Void
typealias MermaidRequestedWidthProvider = @MainActor () -> Int?

@MainActor
/// Builds native text attachments from the shared MermaidKit render result.
enum MermaidDiagramRenderer {
    static let maximumDiagrams = 16
    static let maximumAggregateArea = 1_200_000.0
    static let maximumEstimatedImageBytes = 4 * 1_024 * 1_024

    static func attachment(for block: MarkdownMermaidBlock, appearance: NSAppearance,
                           maximumWidth: CGFloat, renderedImage: NSImage? = nil) -> NSTextAttachment? {
        _ = block
        _ = appearance
        guard let renderedImage else { return nil }
        return attachment(for: renderedImage, maximumWidth: maximumWidth)
    }

    static func attachment(for image: NSImage, maximumWidth: CGFloat) -> NSTextAttachment? {
        let size = image.size
        guard maximumWidth.isFinite, maximumWidth >= 180,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= maximumWidth, size.width <= 640, size.height <= 1_200,
              size.width * size.height <= maximumAggregateArea else { return nil }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: size)
        return attachment
    }
}
