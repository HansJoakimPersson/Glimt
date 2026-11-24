import Foundation
import InspectorCore
import os
import UniformTypeIdentifiers

/// Inspection output and resolved presentation choices shared by host and Quick Look previews.
struct PreparedPreview: Sendable {
    let inspection: PreviewPreparation
    let configuration: RenderConfiguration
}

/// Both entry points load through this bounded Core path and render the same concrete view.
enum SharedPreviewPipeline {
    private static let logger = Logger(subsystem: "com.glimt.app", category: "inspection")

    /// Reads and inspects a document off the caller's executor under the shared preview watchdog
    /// (ADR-040). Caller cancellation stops the underlying read/inspection; a timed-out inspector
    /// yields the Raw/Hex fallback instead of holding the request.
    static func preview(for url: URL, configuration: RenderConfiguration,
                        timeLimit: Duration = InspectionWatchdog.previewLimit,
                        contentTypeIdentifier: @escaping @Sendable (URL) throws -> String? = {
                            try $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
                        }) async throws -> PreparedPreview {
        try Task.checkCancellation()
        let association = configuration.association(for: url.lastPathComponent)
        logger.debug("Bounded inspection started")
        let inspection = try await PreviewPreparation.read(at: url, timeLimit: timeLimit,
            maximumBytes: configuration.maximumPreviewBytes, markdownOptions: configuration.markdown.options,
            formatOverride: association?.target.inspectionOverride,
            overrideDescription: association.map { "User override (\($0.displayPattern))" },
            contentTypeIdentifier: contentTypeIdentifier)
        try Task.checkCancellation()
        logger.debug("Bounded inspection completed; type=\(inspection.resolution.typeID, privacy: .private) diagnostics=\(inspection.inspectionDiagnostics.count, privacy: .private) truncated=\(inspection.analysis.truncated, privacy: .private)")
        return PreparedPreview(inspection: inspection, configuration: configuration)
    }
}
