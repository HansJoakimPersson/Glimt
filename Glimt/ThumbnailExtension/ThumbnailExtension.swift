import AppKit
import Darwin
import Foundation
import InspectorCore
import os
import QuickLookThumbnailing
import UniformTypeIdentifiers

#if DEBUG
/// Produces the privacy-safe diagnostic marker stored in thumbnail provider metadata.
enum ThumbnailProviderMarkerSerializer {
    private static let requiredSignals: [DetectionEvidence.SignalKind] = [
        .filename, .multiExtension, .singleExtension, .shebang,
        .yamlMapping, .yamlDocumentMarker, .systemUTI
    ]
    private static let nonCatalogTypeIDs: Set<String> = [
        "unknown", "typescript-declaration", "makefile", "dockerfile", "generic-local"
    ]

    /// Emits smoke-test evidence only for a canonical fixture token and a known provider result shape.
    static func serialize(
        token: String,
        provider: String,
        phase: String,
        typeID: String,
        confidence: Double,
        scores: [(DetectionEvidence.SignalKind, Double)],
        sampleByteCount: Int,
        sampleIsComplete: Bool,
        elapsedMilliseconds: Int
    ) -> String? {
        let catalogType = FormatCatalog.definition(for: FormatID(rawValue: typeID)) != nil
        guard isCanonicalToken(token), catalogType || nonCatalogTypeIDs.contains(typeID),
              ((provider == "preview" && phase == "display-prepared")
                || (provider == "thumbnail" && phase == "reply-prepared")),
              confidence.isFinite, (0...1).contains(confidence),
              (0...65_536).contains(sampleByteCount),
              (0...60_000).contains(elapsedMilliseconds) else {
            return nil
        }

        var selected: [Double?] = Array(repeating: nil, count: requiredSignals.count)
        for (signal, score) in scores {
            guard signal != .utiConflict else { continue }
            guard let index = requiredSignals.firstIndex(of: signal),
                  selected[index] == nil,
                  score.isFinite, (0...1).contains(score) else {
                return nil
            }
            selected[index] = score
        }
        guard selected.allSatisfy({ $0 != nil }) else { return nil }

        let formattedScores = selected.compactMap { $0 }.map(formatHundredths).joined(separator: ",")
        return "FR005_PROVIDER_V1 token=\(token) provider=\(provider) phase=\(phase) type=\(typeID) confidence=\(formatHundredths(confidence)) scores=\(formattedScores) sampleBytes=\(sampleByteCount) complete=\(sampleIsComplete ? 1 : 0) elapsedMs=\(elapsedMilliseconds)"
    }

    /// Reads only the test correlation xattr and rejects values outside the fixed UUID format.
    static func readToken(from url: URL) -> String? {
        // The xattr is a test-only correlation token; preview bytes and file names are not consulted.
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            return "com.glimt.fr005-evidence".withCString { name in
                var bytes = [UInt8](repeating: 0, count: 37)
                let count = bytes.withUnsafeMutableBufferPointer { buffer in
                    getxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
                }
                guard count == 36 else { return nil }
                let tokenBytes = bytes.prefix(36)
                guard let token = String(bytes: tokenBytes, encoding: .ascii), isCanonicalToken(token) else {
                    return nil
                }
                return token
            }
        }
    }

    /// Rejects unexpected xattr values before they can be written into an Info-level marker.
    private static func isCanonicalToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count == 36 else { return false }
        for index in 0..<36 {
            if [8, 13, 18, 23].contains(index) {
                guard bytes[index] == 0x2D else { return false }
            } else {
                let byte = bytes[index]
                guard (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) else { return false }
            }
        }
        return true
    }

    /// Formats confidence values consistently with the preview-provider evidence marker.
    private static func formatHundredths(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded(.toNearestOrAwayFromZero))
        return "\(hundredths / 100).\(hundredths % 100 < 10 ? "0" : "")\(hundredths % 100)"
    }
}

/// Injectable logging and marker dependencies used by the thumbnail provider.
struct ThumbnailProviderDebugDependencies {
    let tokenReader: @Sendable (URL) -> String?
    let contentTypeIdentifier: @Sendable (URL) throws -> String?
    let renderer: @Sendable (TextAnalysis, SourceDocument?, String?, CGSize, CGFloat) -> CGImage?
    let markerObserver: ((String, QLThumbnailReply) -> Void)?
    let provenanceObserver: (@Sendable (String) -> Void)?
    let runtimeIdentity: @Sendable () -> QuickLookProviderRuntimeIdentity
    let buildMarkerEnabled: @Sendable () -> Bool

    /// Creates thumbnail debug dependencies, defaulting to the process-wide logger and marker writer.
    init(
        tokenReader: @escaping @Sendable (URL) -> String? = ThumbnailProviderMarkerSerializer.readToken,
        contentTypeIdentifier: @escaping @Sendable (URL) throws -> String? = { url in
            try url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        },
        renderer: @escaping @Sendable (TextAnalysis, SourceDocument?, String?, CGSize, CGFloat) -> CGImage? = { analysis, sourceDocument, semanticText, maximumSize, scale in
            ThumbnailRenderer.render(
                analysis: analysis,
                sourceDocument: sourceDocument,
                semanticText: semanticText,
                maximumSize: maximumSize,
                scale: scale
            )
        },
        markerObserver: ((String, QLThumbnailReply) -> Void)? = nil,
        provenanceObserver: (@Sendable (String) -> Void)? = nil,
        runtimeIdentity: @escaping @Sendable () -> QuickLookProviderRuntimeIdentity = {
            QuickLookProviderRuntimeIdentity.from(extensionBundle: Bundle(for: ThumbnailProvider.self))
        },
        buildMarkerEnabled: @escaping @Sendable () -> Bool = { ThumbnailProvider.debugBuildMarkerSetting.withLock { $0 } }
    ) {
        self.tokenReader = tokenReader
        self.contentTypeIdentifier = contentTypeIdentifier
        self.renderer = renderer
        self.markerObserver = markerObserver
        self.provenanceObserver = provenanceObserver
        self.runtimeIdentity = runtimeIdentity
        self.buildMarkerEnabled = buildMarkerEnabled
    }
}
#endif

/// Result of inspecting a requested file before its thumbnail is drawn.
typealias ThumbnailTextBundleTestRunner = @Sendable (
    Duration,
    @Sendable () -> Void,
    @escaping @Sendable () throws -> PreviewInspectionResult
) throws -> PreviewInspectionResult?

struct ThumbnailPreparation: Sendable {
    static let maximumPrefixBytes = 262_144

    let analysis: TextAnalysis
    let sourceLanguage: SourceLanguage?
    let sourceDocument: SourceDocument?
    let csvInspection: CSVInspectionResult?
    let thumbnailText: String?
    let resolution: ResolvedContentType
    let formatID: FormatID?
    let sampleByteCount: Int
    let sampleIsComplete: Bool
    let systemUTI: String?
    let readByteCount: Int
    let selectedInspectorID: InspectorID

    /// Resolves bounded thumbnail input and semantic content without touching AppKit drawing state.
    nonisolated static func prepare(
        bytes: Data,
        fileSize: Int,
        fileName: String,
        systemUTI: String?,
        fileURL: URL? = nil,
        runsInspector: Bool = true
    ) -> ThumbnailPreparation {
        // Detection uses the 64 KiB evidence sample while the shared inspection retains only its configured prefix.
        let sample = Data(bytes.prefix(65_536))
        let sampleIsComplete = fileSize >= 0 && bytes.count == fileSize && sample.count == bytes.count
        let extensionName = (fileName as NSString).pathExtension.lowercased()
        let lowercasedName = fileName.lowercased()
        let isSBOM = lowercasedName.hasSuffix(".cdx.json") || lowercasedName == "bom.json"
            || lowercasedName.hasSuffix(".spdx.json") || lowercasedName.hasSuffix(".cdx.xml")
            || lowercasedName == "bom.xml" || lowercasedName.hasSuffix(".spdx")
        let boundedMetadataCandidate = isSBOM
            || ["zip", "pem", "crt", "der", "cer", "mobileprovision", "jwt", "jwk", "jwks", "p7b", "p7c", "p12", "pfx"].contains(extensionName)
        let retainedBytes = boundedMetadataCandidate ? Data(bytes.prefix(maximumPrefixBytes)) : bytes
        let inspection = runsInspector
            ? PreviewInspectionResult.prepare(bytes: retainedBytes, fileSize: fileSize, fileName: fileName,
                                              systemUTI: systemUTI, markdownOptions: .init(frontMatter: .hide),
                                              fileURL: fileURL)
            : PreviewInspectionResult.timeoutFallback(bytes: retainedBytes, fileSize: fileSize, fileName: fileName,
                                                      systemUTI: systemUTI, markdownOptions: .init(frontMatter: .hide),
                                                      fileURL: fileURL)
        let thumbnailText = ThumbnailRenderer.semanticText(for: inspection)
        return ThumbnailPreparation(
            analysis: inspection.analysis,
            sourceLanguage: inspection.sourceDocument?.language,
            sourceDocument: inspection.sourceDocument,
            csvInspection: inspection.csvInspection,
            thumbnailText: thumbnailText,
            resolution: inspection.resolution,
            formatID: inspection.formatDefinition?.id,
            sampleByteCount: sample.count,
            sampleIsComplete: sampleIsComplete,
            systemUTI: systemUTI,
            readByteCount: retainedBytes.count,
            selectedInspectorID: inspection.selectedInspectorID
        )
    }

    /// Reads the thumbnail-sized prefix and optional file type metadata on a non-UI executor.
    nonisolated static func read(
        at url: URL,
        contentTypeIdentifier: @Sendable (URL) throws -> String? = { fileURL in
            try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        },
        observe: @Sendable (RegularFileReadEvent) -> Void = { _ in },
        textBundleObserve: @Sendable (TextBundleReadEvent) -> Void = { _ in },
        inspectionObserver: (@Sendable (PreviewInspectionResult) -> Void)? = nil
    ) throws -> ThumbnailPreparation {
        guard url.pathExtension.lowercased() == "textbundle" else {
            let inspection = try PreviewInspectionResult.readRegularFile(at: url,
                maximumBytes: maximumPrefixBytes, markdownOptions: .init(frontMatter: .hide),
                resolveLocalMarkdownImages: false, contentTypeIdentifier: contentTypeIdentifier,
                observe: observe)
            inspectionObserver?(inspection)
            return makePreparation(from: inspection)
        }
        let inspection = try PreviewInspectionResult.readThumbnailTextBundle(at: url,
            maximumBytes: maximumPrefixBytes, markdownOptions: .init(frontMatter: .hide),
            contentTypeIdentifier: contentTypeIdentifier, observe: textBundleObserve)
        inspectionObserver?(inspection)
        return makePreparation(from: inspection)
    }

    /// Reads under the thumbnail watchdog (ADR-040). A timed-out inspector yields the Raw fallback for
    /// the prefix already read; a read that cannot finish in time throws `InspectionWatchdog.TimeoutError`.
    /// Blocks the calling thread, so it must not run on Swift concurrency's cooperative pool.
    nonisolated static func read(
        at url: URL,
        timeLimit: Duration,
        contentTypeIdentifier: @escaping @Sendable (URL) throws -> String? = { fileURL in
            try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        },
        prepare replacement: (@Sendable (BoundedFileReader.Prefix, String?) throws -> ThumbnailPreparation)? = nil,
        observe: @escaping @Sendable (RegularFileReadEvent) -> Void = { _ in },
        textBundleObserve: @escaping @Sendable (TextBundleReadEvent) -> Void = { _ in },
        inspectionObserver: (@Sendable (PreviewInspectionResult) -> Void)? = nil,
        snapshotObserver: @escaping @Sendable (RegularFileReadSnapshot) -> Void = { _ in },
        packageRunner: ThumbnailTextBundleTestRunner? = nil
    ) throws -> ThumbnailPreparation {
        if url.pathExtension.lowercased() != "textbundle", replacement == nil {
            let latest = ThumbnailSnapshotBox()
            let completed = try InspectionWatchdog.runBlocking(limit: timeLimit) {
                let inspection = try PreviewInspectionResult.readRegularFile(at: url,
                    maximumBytes: maximumPrefixBytes, markdownOptions: .init(frontMatter: .hide),
                    resolveLocalMarkdownImages: false, contentTypeIdentifier: contentTypeIdentifier,
                    onSnapshot: { snapshot in
                        latest.publish(snapshot)
                        snapshotObserver(snapshot)
                    }, observe: observe)
                inspectionObserver?(inspection)
                return makePreparation(from: inspection)
            }
            if let completed { return completed }
            guard let snapshot = latest.closeAndLoad(), !snapshot.retainedBytes.isEmpty else {
                throw InspectionWatchdog.TimeoutError()
            }
            let fallback = PreviewInspectionResult.timeoutFallback(snapshot: snapshot,
                fileName: url.lastPathComponent, markdownOptions: .init(frontMatter: .hide))
            inspectionObserver?(fallback)
            return makePreparation(from: fallback)
        }
        if url.pathExtension.lowercased() == "textbundle", replacement == nil {
            let snapshots = ThumbnailTextBundleSnapshotBox()
            let onTimeout: @Sendable () -> Void = { snapshots.close() }
            let work: @Sendable () throws -> PreviewInspectionResult = {
                try PreviewInspectionResult.readThumbnailTextBundle(at: url,
                    maximumBytes: maximumPrefixBytes, markdownOptions: .init(frontMatter: .hide),
                    contentTypeIdentifier: contentTypeIdentifier, observe: textBundleObserve,
                    onCompletedRead: { _ = snapshots.publish($0) })
            }
            let completed: PreviewInspectionResult?
            if let packageRunner {
                completed = try packageRunner(timeLimit, onTimeout, work)
            } else {
                completed = try InspectionWatchdog.runBlocking(limit: timeLimit, onTimeout: onTimeout, work: work)
            }
            if let completed {
                snapshots.close()
                inspectionObserver?(completed)
                return makePreparation(from: completed)
            }
            snapshots.close()
            guard let snapshot = snapshots.load() else { throw InspectionWatchdog.TimeoutError() }
            let fallback = PreviewInspectionResult.timeoutFallback(snapshot: snapshot,
                fileName: url.lastPathComponent, markdownOptions: .init(frontMatter: .hide))
            inspectionObserver?(fallback)
            return makePreparation(from: fallback)
        }
        let retained = OSAllocatedUnfairLock<(BoundedFileReader.Prefix, String?)?>(initialState: nil)
        let completed = try InspectionWatchdog.runBlocking(limit: timeLimit) {
            let evidence = try readEvidence(at: url, contentTypeIdentifier: contentTypeIdentifier)
            retained.withLock { $0 = evidence }
            try Task.checkCancellation()
            if let replacement { return try replacement(evidence.0, evidence.1) }
            return prepare(bytes: evidence.0.data, fileSize: evidence.0.fileSize, fileName: url.lastPathComponent,
                           systemUTI: evidence.1, fileURL: url)
        }
        if let completed { return completed }
        guard let (prefix, systemUTI) = retained.withLock({ $0 }) else { throw InspectionWatchdog.TimeoutError() }
        return prepare(bytes: prefix.data, fileSize: prefix.fileSize, fileName: url.lastPathComponent,
                       systemUTI: systemUTI, fileURL: url, runsInspector: false)
    }

    private nonisolated static func makePreparation(from inspection: PreviewInspectionResult) -> ThumbnailPreparation {
        ThumbnailPreparation(
            analysis: inspection.analysis,
            sourceLanguage: inspection.sourceDocument?.language,
            sourceDocument: inspection.sourceDocument,
            csvInspection: inspection.csvInspection,
            thumbnailText: ThumbnailRenderer.semanticText(for: inspection),
            resolution: inspection.resolution,
            formatID: inspection.formatDefinition?.id,
            sampleByteCount: inspection.sampleByteCount,
            sampleIsComplete: inspection.sampleIsComplete,
            systemUTI: inspection.systemUTI,
            readByteCount: inspection.originalBytes.count,
            selectedInspectorID: inspection.selectedInspectorID
        )
    }

    /// Reads the thumbnail-sized prefix; an unreadable content type degrades to name/content detection.
    private nonisolated static func readEvidence(
        at url: URL,
        contentTypeIdentifier: @Sendable (URL) throws -> String?
    ) throws -> (BoundedFileReader.Prefix, String?) {
        // Finder thumbnails use a smaller read ceiling than full document previews.
        let prefix: BoundedFileReader.Prefix
        if url.pathExtension.lowercased() == "textbundle" {
            prefix = try TextBundleInspector.readMarkdown(at: url, maximumBytes: maximumPrefixBytes)
        } else {
            prefix = try BoundedFileReader.readPrefix(at: url, maximumBytes: maximumPrefixBytes)
        }
        return (prefix, try? contentTypeIdentifier(url))
    }
}

private final class ThumbnailSnapshotBox: Sendable {
    private struct State {
        var value: RegularFileReadSnapshot?
        var isOpen = true
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func publish(_ value: RegularFileReadSnapshot) {
        state.withLock { state in
            guard state.isOpen else { return }
            state.value = value
        }
    }

    func closeAndLoad() -> RegularFileReadSnapshot? {
        state.withLock { state in
            state.isOpen = false
            return state.value
        }
    }
}

final class ThumbnailTextBundleSnapshotBox: Sendable {
    private struct State {
        var value: ThumbnailTextBundleReadSnapshot?
        var isOpen = true
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    @discardableResult
    func publish(_ value: ThumbnailTextBundleReadSnapshot) -> Bool {
        state.withLock { state in
            guard state.isOpen else { return false }
            state.value = value
            return true
        }
    }

    func close() {
        state.withLock { $0.isOpen = false }
    }

    func load() -> ThumbnailTextBundleReadSnapshot? {
        state.withLock { $0.value }
    }
}

final class ThumbnailProvider: QLThumbnailProvider {
    private let logger = Logger(subsystem: "com.glimt.app", category: "thumbnail")
    /// General › Build marker, refreshed together with the debug-logging flag.
    static let debugBuildMarkerSetting = OSAllocatedUnfairLock(initialState: true)
#if DEBUG
    private let debugDependencies: ThumbnailProviderDebugDependencies

    override convenience init() {
        self.init(debugDependencies: ThumbnailProviderDebugDependencies())
    }

    /// Creates the provider and captures the dependencies used for diagnostics and preparation.
    init(debugDependencies: ThumbnailProviderDebugDependencies = ThumbnailProviderDebugDependencies()) {
        self.debugDependencies = debugDependencies
        super.init()
    }

#endif

    /// Adapts Quick Look's request object to the shared bounded rendering path.
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        provideThumbnail(
            at: request.fileURL,
            maximumSize: request.maximumSize,
            minimumSize: request.minimumSize,
            scale: request.scale,
            handler: handler
        )
    }

    /// Builds one reply from a bounded read and returns failures through Quick Look's completion.
    func provideThumbnail(
        at fileURL: URL,
        maximumSize: CGSize,
        minimumSize: CGSize = .zero,
        scale: CGFloat,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // Measure only the request duration; do not include a URL, filename, or file contents in logs.
        let startTime = DispatchTime.now().uptimeNanoseconds
        // Only the two debug flags are read here; thumbnails still render with fixed defaults (D62).
        GlimtDebugLog.shared.refreshEnabled { Self.refreshDebugSettings() }
#if DEBUG
        let runtimeIdentity = debugDependencies.runtimeIdentity()
        let buildLabel = debugDependencies.buildMarkerEnabled() ? runtimeIdentity.debugThumbnailStamp : nil
        // Read only the synthetic correlation xattr at request receipt, off the main thread.
        // Reuse this token for FR005 if rendering succeeds; no file content is read here.
        let diagnosticToken = Thread.isMainThread ? nil : debugDependencies.tokenReader(fileURL)
        if let diagnosticToken,
           let marker = QuickLookProviderProvenanceMarker.serialize(
            token: diagnosticToken,
            provider: .thumbnail,
            phase: .requestReceived,
            identity: runtimeIdentity
           ) {
            if let observer = debugDependencies.provenanceObserver { observer(marker) }
            else { logger.info("\(marker, privacy: .public)") }
        }
#endif

        do {
            guard let contextSize = ThumbnailRenderer.replyContextSize(
                maximumSize: maximumSize, minimumSize: minimumSize, scale: scale
            ) else { throw ThumbnailReadError.invalidGeometry }
#if DEBUG
            let preparation = try ThumbnailPreparation.read(
                at: fileURL,
                timeLimit: InspectionWatchdog.thumbnailLimit,
                contentTypeIdentifier: debugDependencies.contentTypeIdentifier
            )
            let renderer = debugDependencies.renderer
#else
            let preparation = try ThumbnailPreparation.read(at: fileURL, timeLimit: InspectionWatchdog.thumbnailLimit)
#endif
            let analysis = preparation.analysis
            // Fixed defaults only (D62): the thumbnail never reads the shared settings file.
#if DEBUG
            let renderedImage = renderer(
                analysis,
                preparation.sourceDocument,
                preparation.thumbnailText,
                maximumSize,
                scale
            )
#else
            let renderedImage = ThumbnailRenderer.render(
                analysis: analysis,
                sourceDocument: preparation.sourceDocument,
                semanticText: preparation.thumbnailText,
                maximumSize: maximumSize,
                scale: scale
            )
#endif
            guard let image = renderedImage else {
                throw ThumbnailReadError.renderingFailed
            }
            let reply = QLThumbnailReply(contextSize: contextSize) { context in
                context.draw(image, in: CGRect(origin: .zero, size: contextSize))
#if DEBUG
                if let buildLabel { ThumbnailRenderer.drawDebugBuildMarker(buildLabel, in: context, size: contextSize) }
#endif
                return true
            }

            let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000)
            logger.debug(
                "Thumbnail prepared; file-derived metadata is private type=\(preparation.systemUTI ?? "unknown", privacy: .private) encoding=\(analysis.encoding?.displayName ?? "none", privacy: .private) sizeBytes=\(analysis.fileSize, privacy: .private) prefixBytes=\(preparation.readByteCount, privacy: .private) elapsedMs=\(elapsedMilliseconds, privacy: .private)"
            )
            GlimtDebugLog.shared.info("Thumbnail prepared; type=\(preparation.resolution.typeID) prefixBytes=\(preparation.readByteCount) elapsedMs=\(elapsedMilliseconds)")
#if DEBUG
            if !Thread.isMainThread,
               let token = diagnosticToken,
               let marker = ThumbnailProviderMarkerSerializer.serialize(
                token: token,
                provider: "thumbnail",
                phase: "reply-prepared",
                typeID: preparation.resolution.typeID,
                confidence: preparation.resolution.confidence.value,
                scores: preparation.resolution.evidence.map { ($0.signalKind, $0.score.value) },
                sampleByteCount: preparation.sampleByteCount,
                sampleIsComplete: preparation.sampleIsComplete,
                elapsedMilliseconds: elapsedMilliseconds
               ) {
                if let observer = debugDependencies.markerObserver {
                    observer(marker, reply)
                } else {
                    logger.info("\(marker, privacy: .public)")
                }
            }
#endif
            handler(reply, nil)
        } catch {
            // Error descriptions can include a local path, so log only the stable error type.
            logger.error("Thumbnail request failed; errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            GlimtDebugLog.shared.error("Thumbnail request failed; errorType=\(String(reflecting: type(of: error)))")
            handler(nil, error)
        }
    }

    /// Reads only the debug flags: stores Build marker and returns Debug logging. A read or decode
    /// failure leaves logging off and the build marker at its default.
    private static func refreshDebugSettings() -> Bool {
        let general = try? SettingsStore.shared(readOnly: true).loadV3().settings.general
        debugBuildMarkerSetting.withLock { $0 = general?.debugBuildMarker ?? GeneralSettingsV3().debugBuildMarker }
        return general?.debugLoggingEnabled ?? false
    }
}

private enum ThumbnailReadError: Error {
    case fileSizeUnavailable
    case renderingFailed
    case invalidGeometry
}
