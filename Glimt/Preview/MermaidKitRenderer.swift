import AppKit
import InspectorCore
import MermaidLayout
import MermaidRender

@MainActor
/// Renders bounded Mermaid source using MermaidKit's offline CoreGraphics renderer.
final class MermaidKitRenderer {
    static let maximumDiagrams = 16
    static let maximumSourceBytes = 8 * 1_024
    static let maximumWidth = 640.0
    static let maximumHeight = 1_200.0
    static let maximumAggregateArea = 1_200_000.0
    static let maximumEstimatedImageBytes = 4 * 1_024 * 1_024

    /// Renders supported Mermaid blocks and preserves failures as source-code fallbacks.
    func render(_ blocks: [MarkdownMermaidBlock], maximumWidth: Double,
                onFailure: ((Int, Error) -> Void)? = nil) async throws -> [String: NSImage] {
        guard maximumWidth.isFinite, maximumWidth >= 180 else { return [:] }

        let admittedBlocks = blocks.prefix(Self.maximumDiagrams)
        let perDiagramArea = min(Self.maximumAggregateArea,
                                 Double(Self.maximumEstimatedImageBytes) / 4)
            * 0.98 / Double(max(1, admittedBlocks.count))
        var aggregateArea = 0.0
        var images: [String: NSImage] = [:]

        for (index, block) in admittedBlocks.enumerated() {
            try Task.checkCancellation()
            guard !block.source.isEmpty,
                  block.source.utf8.count <= Self.maximumSourceBytes else { continue }

            do {
                guard let diagram = block.mermaidKitDiagram else {
                    throw MermaidKitError.unsupportedSource
                }
                let theme = DiagramTheme(prefersDark: NSAppearance.currentDrawing()
                    .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                let rendered = await Self.render(diagram, theme: theme)
                try Task.checkCancellation()
                guard let rendered else { throw MermaidKitError.renderUnavailable }
                guard let boundedImage = Self.boundedImage(
                    rendered,
                    maximumWidth: min(maximumWidth, Self.maximumWidth),
                    maximumArea: perDiagramArea
                ) else {
                    throw MermaidKitError.outputExceedsBounds(
                        width: Double(rendered.size.width), height: Double(rendered.size.height),
                        maximumWidth: min(maximumWidth, Self.maximumWidth), maximumArea: perDiagramArea
                    )
                }
                try Task.checkCancellation()
                let area = Double(boundedImage.size.width * boundedImage.size.height)
                guard aggregateArea <= Self.maximumAggregateArea - area else {
                    throw MermaidKitError.outputExceedsBounds(
                        width: Double(boundedImage.size.width), height: Double(boundedImage.size.height),
                        maximumWidth: min(maximumWidth, Self.maximumWidth), maximumArea: perDiagramArea
                    )
                }
                aggregateArea += area
                boundedImage.accessibilityDescription = Self.accessibilityDescription(block.source)
                images[block.source] = boundedImage
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onFailure?(index, error)
            }
        }
        return images
    }

    private static func render(_ diagram: MermaidDiagram, theme: DiagramTheme) async -> NSImage? {
        struct Transfer: @unchecked Sendable { let image: NSImage? }
        let task = Task.detached(priority: .userInitiated) {
            Transfer(image: MermaidRenderer.image(diagram: diagram, theme: theme))
        }
        return await withTaskCancellationHandler {
            await task.value.image
        } onCancel: {
            task.cancel()
        }
    }

    private static func boundedImage(_ image: NSImage, maximumWidth: Double,
                                     maximumArea: Double) -> NSImage? {
        let sourceSize = image.size
        let sourceArea = Double(sourceSize.width * sourceSize.height)
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              sourceArea.isFinite, sourceArea > 0 else { return nil }

        var scale = min(1, min(maximumWidth / Double(sourceSize.width),
                               min(Self.maximumHeight / Double(sourceSize.height),
                                   sqrt(maximumArea / sourceArea))))
        var size = NSSize(width: min(CGFloat(maximumWidth), sourceSize.width * scale),
                          height: min(CGFloat(Self.maximumHeight), sourceSize.height * scale))
        var area = Double(size.width * size.height)
        if area > maximumArea {
            scale *= sqrt(maximumArea / area) * 0.999_999
            size = NSSize(width: min(CGFloat(maximumWidth), sourceSize.width * scale),
                          height: min(CGFloat(Self.maximumHeight), sourceSize.height * scale))
            area = Double(size.width * size.height)
        }
        let estimatedBytes = Int((area * 4).rounded(.up))
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= maximumWidth, size.height <= Self.maximumHeight,
              area <= maximumArea, estimatedBytes > 0,
              estimatedBytes <= Self.maximumEstimatedImageBytes else { return nil }

        if scale == 1 { return image }
        let bounded = NSImage(size: size)
        bounded.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: sourceSize),
                   operation: .copy, fraction: 1)
        bounded.unlockFocus()
        return bounded
    }

    private static func accessibilityDescription(_ source: String) -> String {
        let diagramType = source.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "diagram"
        let label = String(diagramType.unicodeScalars.prefix(80))
        return "Mermaid \(label) diagram"
    }
}

private enum MermaidKitError: Error {
    case unsupportedSource
    case renderUnavailable
    case outputExceedsBounds(width: Double, height: Double, maximumWidth: Double, maximumArea: Double)
}

extension MermaidKitError: CustomStringConvertible {
    var description: String {
        switch self {
        case .unsupportedSource: return "unsupportedSource"
        case .renderUnavailable: return "renderUnavailable"
        case let .outputExceedsBounds(width, height, maximumWidth, maximumArea):
            return "outputExceedsBounds width=\(width) height=\(height) maxWidth=\(maximumWidth) maxArea=\(maximumArea)"
        }
    }
}
