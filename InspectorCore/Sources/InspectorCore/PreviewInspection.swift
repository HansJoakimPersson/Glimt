import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Semantic results for catalog inspectors that do not have a dedicated result model.
public enum AdditionalInspectionResult: Sendable {
    case diff(DiffInspectionResult)
    case records(FormatID, StructuredValue, [InspectionDiagnostic], Bool, LogTable?)
    case archive(ZIPArchiveListing)
    case tarArchive(TARArchiveListing)
    case certificate(FormatID, X509CertificateInspection)
    case security(SecurityFormatInspection)

    public var formatID: FormatID {
        switch self {
        case .diff: .diff
        case .records(let id, _, _, _, _): id
        case .archive: .zip
        case .tarArchive: .tarArchive
        case .certificate(let id, _): id
        case .security(let inspection): inspection.formatID
        }
    }

    public var diagnostics: [InspectionDiagnostic] {
        switch self {
        case .diff(let result): result.diagnostics
        case .records(_, _, let diagnostics, _, _): diagnostics
        case .archive, .tarArchive, .certificate: []
        case .security(let inspection): inspection.diagnostics
        }
    }

    public var hasPrimaryContent: Bool {
        switch self {
        case .diff(let result): !result.files.isEmpty
        case .records(_, let value, _, _, _): if case .array(let values) = value { !values.isEmpty } else { true }
        case .archive(let listing): !listing.entries.isEmpty
        case .tarArchive(let listing): !listing.entries.isEmpty
        case .certificate(_, let result): !result.certificates.isEmpty
        case .security(let inspection): inspection.content != nil
        }
    }

    public var structuredContent: StructuredValue? {
        switch self {
        case .records(_, let value, _, _, _): return value
        case .certificate(_, let inspection):
            return .array(inspection.certificates.map { facts in
                .object([
                    .init(key: "Subject", value: .string(facts.subjectSummary)),
                    .init(key: "Issuer", value: facts.issuerSummary.map(StructuredValue.string) ?? .null),
                    .init(key: "Serial number", value: .string(facts.serialNumberHex)),
                    .init(key: "Not before", value: facts.notBefore.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null),
                    .init(key: "Not after", value: facts.notAfter.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null),
                    .init(key: "SHA-256 fingerprint", value: .string(facts.sha256Fingerprint)),
                    .init(key: "Public key algorithm", value: facts.publicKeyAlgorithm.map(StructuredValue.string) ?? .null),
                    .init(key: "Public key size", value: facts.publicKeySize.map { .number(String($0)) } ?? .null)
                ])
            })
        case .security(let inspection): return inspection.content
        case .diff, .archive, .tarArchive: return nil
        }
    }

    public var logTable: LogTable? {
        guard case .records(.log, _, _, _, let table) = self else { return nil }
        return table
    }

    public var rawIsComplete: Bool? {
        guard case .records(_, _, _, let complete, _) = self else { return nil }
        return complete
    }

    public var archiveListing: ZIPArchiveListing? {
        guard case .archive(let listing) = self else { return nil }
        return listing
    }

    public var tarArchiveListing: TARArchiveListing? {
        guard case .tarArchive(let listing) = self else { return nil }
        return listing
    }

    public var certificateInspection: X509CertificateInspection? {
        guard case .certificate(_, let result) = self else { return nil }
        return result
    }

    public var securityInspection: SecurityFormatInspection? {
        guard case .security(let result) = self else { return nil }
        return result
    }
}

extension PreviewInspectionResult {
    public var diffInspection: DiffInspectionResult? {
        guard case .diff(let result) = additionalInspection else { return nil }
        return result
    }
    public var additionalStructuredContent: StructuredValue? { additionalInspection?.structuredContent }
}

/// Immutable route metadata selected from a regular file's bounded routing sample.
public struct PreviewInspectionRoute: Sendable {
    public let inspectorID: InspectorID
    public let formatID: FormatID?
    public let sourceLanguage: SourceLanguage?
    public let formatName: String
    public let detectionReason: String
    let format: FormatDefinition?

    init(_ route: InspectionRoute) {
        inspectorID = route.inspectorID
        formatID = route.format?.id
        sourceLanguage = route.sourceLanguage
        formatName = route.formatName
        detectionReason = route.detectionReason
        format = route.format
    }

    var inspectionRoute: InspectionRoute {
        InspectionRoute(inspectorID: inspectorID, format: format, sourceLanguage: sourceLanguage,
                        formatName: formatName, detectionReason: detectionReason)
    }
}

/// Snapshot published after route selection and after every successfully appended content chunk.
public struct RegularFileReadSnapshot: Sendable {
    public let originalFileSize: Int
    public let systemUTI: String?
    public let routingSample: Data
    public let routingByteCount: Int
    public let routingIsComplete: Bool
    public let distinctRoutingOffsetsRequested: Int
    public let resolution: ResolvedContentType
    public let automaticRoute: PreviewInspectionRoute
    public let effectiveRoute: PreviewInspectionRoute
    public let retainedBytes: Data
    let formatOverride: PreviewInspectionResult.FormatOverride?
    let overrideDescription: String?
    let routingSelection: InspectionSelection

    init(originalFileSize: Int, systemUTI: String?, routingSample: Data, routingIsComplete: Bool,
         distinctRoutingOffsetsRequested: Int, resolution: ResolvedContentType,
         selection: InspectionSelection, retainedBytes: Data,
         formatOverride: PreviewInspectionResult.FormatOverride?, overrideDescription: String?) {
        self.originalFileSize = originalFileSize
        self.systemUTI = systemUTI
        self.routingSample = routingSample
        routingByteCount = routingSample.count
        self.routingIsComplete = routingIsComplete
        self.distinctRoutingOffsetsRequested = distinctRoutingOffsetsRequested
        self.resolution = resolution
        automaticRoute = PreviewInspectionRoute(selection.automatic)
        effectiveRoute = PreviewInspectionRoute(selection.effective)
        self.retainedBytes = retainedBytes
        self.formatOverride = formatOverride
        self.overrideDescription = overrideDescription
        routingSelection = selection
    }
}

/// Immutable routing evidence selected from the staged TextBundle Markdown sample.
struct TextBundleRouteSnapshot: Sendable {
    let selection: InspectionSelection
    let resolution: ResolvedContentType
    let advisoryUTI: String?
    let markdownSample: Data
    let sampleIsComplete: Bool
    let originalMarkdownSize: Int
    let formatOverride: PreviewInspectionResult.FormatOverride?
    let overrideDescription: String?
}

/// Frozen route metadata and the Markdown payload retained at the same publication point.
struct TextBundlePreviewSnapshot: Sendable {
    let route: TextBundleRouteSnapshot
    let retainedMarkdown: Data
}

/// Opaque completed TextBundle read evidence for Thumbnail watchdog fallback.
public struct ThumbnailTextBundleReadSnapshot: Sendable {
    fileprivate let value: TextBundlePreviewSnapshot

    fileprivate init(_ value: TextBundlePreviewSnapshot) {
        self.value = value
    }
}

/// Privacy-safe milestones emitted by the staged regular-file reader.
public enum RegularFileReadEvent: Sendable {
    case read(offset: Int, requestedCount: Int, returnedCount: Int, errorCode: Int32?)
    case selectionCommitted(routingByteCount: Int, distinctRequestedOffsets: Int)
    case continuationAppended(retainedByteCount: Int)
    case dispatchStarted(inspectorID: InspectorID)
}

/// Bounded file inspection shared by the host app and Quick Look. Rendering stays outside Core.
public struct PreviewInspectionResult: Sendable {
    /// Explicit user or catalog routing choices applied before automatic type resolution.
    public enum FormatOverride: Equatable, Sendable {
        case text, json, yaml, xml, plist, markdown, mermaid, diff, jsonl, log, toml, ini, dotenv, properties, windowsRegistry, email, icalendar, vcard
        case zip, tar, certificate(FormatID)
        case security(FormatID)
        case source(SourceLanguage)
        case csv(FormatID)
    }
    public let systemUTI: String?
    public let overrideDescription: String?
    public let automaticFormatName: String?
    public let analysis: TextAnalysis
    public let resolution: ResolvedContentType
    public let selectedInspectorID: InspectorID
    let selectedFormatID: FormatID?
    public let sampleByteCount: Int
    public let sampleIsComplete: Bool
    /// Original input prefix retained independently from decoded or normalized representations.
    public let originalBytes: Data
    public let jsonInspection: JSONInspectionResult?
    public let csvInspection: CSVInspectionResult?
    public let yamlInspection: YAMLInspectionResult?
    public let xmlInspection: XMLInspectionResult?
    public let plistInspection: PlistInspectionResult?
    public let sourceDocument: SourceDocument?
    public let markdownDocument: MarkdownDocument?
    public let additionalInspection: AdditionalInspectionResult?
    public let formatName: String
    public let detectionReason: String
    public let inspectionDiagnostics: [InspectionDiagnostic]

    /// Copies the immutable result while replacing only the resolved image-bearing Markdown model.
    func replacingMarkdownDocument(_ document: MarkdownDocument?) -> Self {
        .init(systemUTI: systemUTI, overrideDescription: overrideDescription,
              automaticFormatName: automaticFormatName, analysis: analysis, resolution: resolution,
              selectedInspectorID: selectedInspectorID,
              selectedFormatID: selectedFormatID, sampleByteCount: sampleByteCount,
              sampleIsComplete: sampleIsComplete, originalBytes: originalBytes,
              jsonInspection: jsonInspection, csvInspection: csvInspection, yamlInspection: yamlInspection,
              xmlInspection: xmlInspection, plistInspection: plistInspection, sourceDocument: sourceDocument,
              markdownDocument: document, additionalInspection: additionalInspection,
              formatName: formatName, detectionReason: detectionReason,
              inspectionDiagnostics: inspectionDiagnostics)
    }

    /// Runs detection and inspection over already-read bytes; callers own the read limit and may
    /// supply an explicit format override without changing the original byte sample.
    public static func prepare(bytes: Data, fileSize: Int, fileName: String,
                               systemUTI: String?, markdownOptions: MarkdownOptions = .init(), formatOverride: FormatOverride? = nil,
                               overrideDescription: String? = nil, fileURL: URL? = nil) -> PreviewInspectionResult {
        prepare(bytes: bytes, fileSize: fileSize, fileName: fileName, systemUTI: systemUTI,
                markdownOptions: markdownOptions, formatOverride: formatOverride,
                overrideDescription: overrideDescription, fileURL: fileURL, runsInspector: true)
    }

    static func prepareForTesting(bytes: Data, fileSize: Int, fileName: String, systemUTI: String?,
                                  formatOverride: FormatOverride?, registry: FormatInspectorRegistry) -> PreviewInspectionResult {
        prepare(bytes: bytes, fileSize: fileSize, fileName: fileName, systemUTI: systemUTI,
                markdownOptions: .init(), formatOverride: formatOverride, overrideDescription: nil,
                fileURL: nil, runsInspector: true, registry: registry)
    }

    /// Builds the Raw/Hex result a timed-out request shows (ADR-040): the same route as `prepare`,
    /// without running the format inspector. Used by callers that own their own watchdog.
    public static func timeoutFallback(bytes: Data, fileSize: Int, fileName: String, systemUTI: String?,
                                       markdownOptions: MarkdownOptions = .init(),
                                       fileURL: URL? = nil) -> PreviewInspectionResult {
        prepare(bytes: bytes, fileSize: fileSize, fileName: fileName, systemUTI: systemUTI,
                markdownOptions: markdownOptions, formatOverride: nil,
                overrideDescription: nil, fileURL: fileURL, runsInspector: false)
    }

    /// Reads a regular file through a frozen 64 KiB routing sample, then continues the bounded read.
    /// `onSnapshot` is called atomically at selection and after each continuation append, allowing
    /// a caller-owned watchdog to produce a Raw/Hex fallback without re-reading or re-routing.
    public static func readRegularFile(
        at url: URL,
        maximumBytes: Int = 1_048_576,
        markdownOptions: MarkdownOptions = .init(),
        formatOverride: FormatOverride? = nil,
        overrideDescription: String? = nil,
        resolveLocalMarkdownImages: Bool = true,
        contentTypeIdentifier: @Sendable (URL) throws -> String? = { fileURL in
            try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        },
        onSnapshot: @Sendable (RegularFileReadSnapshot) -> Void = { _ in },
        observe: @Sendable (RegularFileReadEvent) -> Void = { _ in }
    ) throws -> PreviewInspectionResult {
        try readRegularFileImpl(at: url, maximumBytes: maximumBytes, markdownOptions: markdownOptions,
            formatOverride: formatOverride, overrideDescription: overrideDescription,
            resolveLocalMarkdownImages: resolveLocalMarkdownImages,
            contentTypeIdentifier: contentTypeIdentifier, onSnapshot: onSnapshot, observe: observe,
            readOperation: nil, inspectionRegistry: .builtIn)
    }

    static func readRegularFileForTesting(
        at url: URL,
        maximumBytes: Int = 1_048_576,
        markdownOptions: MarkdownOptions = .init(),
        formatOverride: FormatOverride? = nil,
        overrideDescription: String? = nil,
        contentTypeIdentifier: @Sendable (URL) throws -> String? = { fileURL in
            try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        },
        onSnapshot: @Sendable (RegularFileReadSnapshot) -> Void = { _ in },
        observe: @Sendable (RegularFileReadEvent) -> Void = { _ in },
        readOperation: BoundedFileReader.StagedReadOperation? = nil,
        inspectionRegistry: FormatInspectorRegistry = .builtIn
    ) throws -> PreviewInspectionResult {
        try readRegularFileImpl(at: url, maximumBytes: maximumBytes, markdownOptions: markdownOptions,
            formatOverride: formatOverride, overrideDescription: overrideDescription,
            resolveLocalMarkdownImages: true, contentTypeIdentifier: contentTypeIdentifier,
            onSnapshot: onSnapshot, observe: observe, readOperation: readOperation,
            inspectionRegistry: inspectionRegistry)
    }

    private static func readRegularFileImpl(
        at url: URL,
        maximumBytes: Int,
        markdownOptions: MarkdownOptions,
        formatOverride: FormatOverride?,
        overrideDescription: String?,
        resolveLocalMarkdownImages: Bool,
        contentTypeIdentifier: @Sendable (URL) throws -> String?,
        onSnapshot: @Sendable (RegularFileReadSnapshot) -> Void,
        observe: @Sendable (RegularFileReadEvent) -> Void,
        readOperation: BoundedFileReader.StagedReadOperation?,
        inspectionRegistry: FormatInspectorRegistry
    ) throws -> PreviewInspectionResult {
        try Task.checkCancellation()
        let boundedMaximum = min(max(maximumBytes, 1), 1_048_576)
        let file = try BoundedFileReader.StagedFile(url: url, readOperation: readOperation)
        let fileSize = file.fileSize
        try Task.checkCancellation()
        let systemUTI: String?
        do {
            systemUTI = try contentTypeIdentifier(url)
        } catch {
            systemUTI = nil
        }
        try Task.checkCancellation()

        let routingTarget = min(fileSize, boundedMaximum, 65_536)
        var routingSample = Data()
        routingSample.reserveCapacity(routingTarget)
        var distinctOffsets = Set<Int>()
        var reachedEOF = false
        while routingSample.count < routingTarget {
            try Task.checkCancellation()
            let offset = routingSample.count
            let requestCount = routingTarget - offset
            for byteOffset in offset..<(offset + requestCount) { distinctOffsets.insert(byteOffset) }
            let chunk: Data
            do {
                chunk = try file.readOnce(offset: offset, maximumCount: requestCount)
                observe(.read(offset: offset, requestedCount: requestCount, returnedCount: chunk.count, errorCode: nil))
            } catch BoundedFileReader.ReadError.readFailed(let code) where code == EINTR {
                observe(.read(offset: offset, requestedCount: requestCount, returnedCount: 0, errorCode: code))
                continue
            } catch BoundedFileReader.ReadError.readFailed(let code) {
                observe(.read(offset: offset, requestedCount: requestCount, returnedCount: 0, errorCode: code))
                throw BoundedFileReader.ReadError.readFailed(code)
            }
            if chunk.isEmpty {
                reachedEOF = true
                break
            }
            routingSample.append(chunk)
        }

        try Task.checkCancellation()
        let routingIsComplete = routingSample.count == fileSize
        let resolution = TypeResolver().resolve(fileName: url.lastPathComponent, leadingBytes: routingSample,
            systemUTI: systemUTI, sampleIsComplete: routingIsComplete)
        let routingAnalysis = TextAnalysis.analyze(bytes: routingSample, fileSize: fileSize, maximumBytes: 65_536)
        try Task.checkCancellation()
        let selection = InspectionPipeline.select(fileName: url.lastPathComponent, systemUTI: systemUTI,
            bytes: routingSample, analysis: routingAnalysis, resolution: resolution, formatOverride: formatOverride)
        try Task.checkCancellation()
        var retained = routingSample
        var snapshot = RegularFileReadSnapshot(originalFileSize: fileSize, systemUTI: systemUTI,
            routingSample: routingSample, routingIsComplete: routingIsComplete,
            distinctRoutingOffsetsRequested: distinctOffsets.count, resolution: resolution,
            selection: selection, retainedBytes: retained, formatOverride: formatOverride,
            overrideDescription: overrideDescription)
        try Task.checkCancellation()
        onSnapshot(snapshot)
        observe(.selectionCommitted(routingByteCount: routingSample.count,
                                    distinctRequestedOffsets: distinctOffsets.count))

        let retainedTarget = min(fileSize, boundedMaximum)
        while retained.count < retainedTarget && !reachedEOF {
            try Task.checkCancellation()
            let offset = retained.count
            let requestCount = min(64 * 1024, retainedTarget - offset)
            let chunk: Data
            do {
                chunk = try file.readOnce(offset: offset, maximumCount: requestCount)
                observe(.read(offset: offset, requestedCount: requestCount, returnedCount: chunk.count, errorCode: nil))
            } catch BoundedFileReader.ReadError.readFailed(let code) where code == EINTR {
                observe(.read(offset: offset, requestedCount: requestCount, returnedCount: 0, errorCode: code))
                continue
            } catch BoundedFileReader.ReadError.readFailed(let code) {
                observe(.read(offset: offset, requestedCount: requestCount, returnedCount: 0, errorCode: code))
                throw BoundedFileReader.ReadError.readFailed(code)
            }
            if chunk.isEmpty {
                reachedEOF = true
                break
            }
            retained.append(chunk)
            snapshot = RegularFileReadSnapshot(originalFileSize: fileSize, systemUTI: systemUTI,
                routingSample: routingSample, routingIsComplete: routingIsComplete,
                distinctRoutingOffsetsRequested: distinctOffsets.count, resolution: resolution,
                selection: selection, retainedBytes: retained, formatOverride: formatOverride,
                overrideDescription: overrideDescription)
            try Task.checkCancellation()
            onSnapshot(snapshot)
            observe(.continuationAppended(retainedByteCount: retained.count))
        }

        try Task.checkCancellation()
        observe(.dispatchStarted(inspectorID: selection.effective.inspectorID))
        try Task.checkCancellation()
        let result = prepare(bytes: retained, fileSize: fileSize, fileName: url.lastPathComponent,
            systemUTI: systemUTI, markdownOptions: markdownOptions, formatOverride: formatOverride,
            overrideDescription: overrideDescription, fileURL: url, runsInspector: true,
            routingSelection: selection, resolution: resolution, routingSample: routingSample,
            routingIsComplete: routingIsComplete, registry: inspectionRegistry)
        try Task.checkCancellation()
        guard resolveLocalMarkdownImages, var markdown = result.markdownDocument, !markdown.images.isEmpty else {
            return result
        }
        markdown.images = MarkdownLocalImages.resolve(markdown.images, relativeTo: url)
        try Task.checkCancellation()
        return result.replacingMarkdownDocument(markdown)
    }

    /// Builds timeout presentation from the latest staged snapshot without further I/O or dispatch.
    public static func timeoutFallback(snapshot: RegularFileReadSnapshot, fileName: String,
                                       markdownOptions: MarkdownOptions = .init(),
                                       overrideDescription: String? = nil) -> PreviewInspectionResult {
        prepare(bytes: snapshot.retainedBytes, fileSize: snapshot.originalFileSize, fileName: fileName,
            systemUTI: snapshot.systemUTI, markdownOptions: markdownOptions, formatOverride: snapshot.formatOverride,
            overrideDescription: overrideDescription ?? snapshot.overrideDescription, fileURL: nil, runsInspector: false,
            routingSelection: snapshot.routingSelection, resolution: snapshot.resolution,
            routingSample: snapshot.routingSample, routingIsComplete: snapshot.routingIsComplete)
    }

    /// Shared preparation; `runsInspector` false yields the watchdog's Raw/Hex fallback for the same route.
    private static func prepare(bytes: Data, fileSize: Int, fileName: String, systemUTI: String?,
                                markdownOptions: MarkdownOptions, formatOverride: FormatOverride?,
                                overrideDescription: String?, fileURL: URL?,
                                runsInspector: Bool,
                                registry: FormatInspectorRegistry = .builtIn) -> PreviewInspectionResult {
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: fileSize, maximumBytes: 1_048_576)
        let sample = Data(bytes.prefix(65_536))
        let sampleIsComplete = fileSize >= 0 && bytes.count == fileSize && sample.count == bytes.count
        let resolution = TypeResolver().resolve(fileName: fileName, leadingBytes: sample,
                                                systemUTI: systemUTI, sampleIsComplete: sampleIsComplete)
        // The byte-backed API and TextBundle path retain their historical full-retained-prefix
        // content probes. Only the regular-file staged reader freezes probes to its routing sample.
        let selection = InspectionPipeline.select(fileName: fileName, systemUTI: systemUTI, bytes: bytes,
            analysis: analysis,
            resolution: resolution, formatOverride: formatOverride)
        if formatOverride != nil && runsInspector {
            // Preserve the legacy automatic inspector dispatch before applying an override.
            // Staged regular files dispatch only their effective route.
            _ = Self.prepare(bytes: bytes, fileSize: fileSize, fileName: fileName,
                systemUTI: systemUTI, markdownOptions: markdownOptions, formatOverride: nil,
                overrideDescription: nil, fileURL: nil, runsInspector: true, registry: registry)
        }
        return prepare(bytes: bytes, fileSize: fileSize, fileName: fileName, systemUTI: systemUTI,
                       markdownOptions: markdownOptions, formatOverride: formatOverride,
                       overrideDescription: overrideDescription, fileURL: fileURL, runsInspector: runsInspector,
                       routingSelection: selection, resolution: resolution, routingSample: sample,
                       routingIsComplete: sampleIsComplete, registry: registry,
                       rejectsBinaryTextRoute: false)
    }

    private static func prepare(bytes: Data, fileSize: Int, fileName: String, systemUTI: String?,
                                markdownOptions: MarkdownOptions, formatOverride: FormatOverride?,
                                overrideDescription: String?, fileURL: URL?, runsInspector: Bool,
                                routingSelection: InspectionSelection, resolution: ResolvedContentType,
                                routingSample: Data, routingIsComplete: Bool,
                                registry: FormatInspectorRegistry = .builtIn,
                                rejectsBinaryTextRoute: Bool = true) -> PreviewInspectionResult {
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: fileSize, maximumBytes: 1_048_576)
        let route = routingSelection.effective
        let (_, outcome) = InspectionPipeline.inspect(route: route, bytes: bytes, fileSize: fileSize,
            fileName: fileName, systemUTI: systemUTI, markdownOptions: markdownOptions,
            analysis: analysis, fileURL: fileURL, registry: registry,
            rejectBinaryTextRoute: rejectsBinaryTextRoute, runsInspector: runsInspector)
        let jsonInspection: JSONInspectionResult?
        let csvInspection: CSVInspectionResult?
        let yamlInspection: YAMLInspectionResult?
        let xmlInspection: XMLInspectionResult?
        let plistInspection: PlistInspectionResult?
        let sourceDocument: SourceDocument?
        let markdownDocument: MarkdownDocument?
        let additionalInspection: AdditionalInspectionResult?
        let inspectionDiagnostics: [InspectionDiagnostic]
        switch outcome {
        case .text, .cancelled:
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil; additionalInspection = nil; inspectionDiagnostics = []
        case .fallback(let diagnostics):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil; additionalInspection = nil; inspectionDiagnostics = diagnostics
        case .json(let value):
            jsonInspection = value; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil; additionalInspection = nil; inspectionDiagnostics = value.diagnostics
        case .csv(let value):
            jsonInspection = nil; csvInspection = value; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil; additionalInspection = nil; inspectionDiagnostics = value.diagnostics
        case .yaml(let value):
            jsonInspection = nil; csvInspection = nil; yamlInspection = value; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil; additionalInspection = nil; inspectionDiagnostics = value.diagnostics
        case .xml(let value):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = value
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil; additionalInspection = nil; inspectionDiagnostics = value.diagnostics
        case .plist(let value):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = value; sourceDocument = nil; markdownDocument = nil; additionalInspection = nil; inspectionDiagnostics = value.diagnostics
        case .source(let value):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = value; markdownDocument = nil; additionalInspection = nil; inspectionDiagnostics = value.diagnostics
        case .markdown(let value):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil
            sourceDocument = analysis.isBinary ? nil : try? SourceCodeInspector.inspect(analysis: analysis, language: .markdown)
            markdownDocument = value; additionalInspection = nil; inspectionDiagnostics = value.diagnostics
        case .additional(let value):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil
            additionalInspection = value; inspectionDiagnostics = value.diagnostics
        case .zip(let listing):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil
            additionalInspection = .archive(listing); inspectionDiagnostics = []
        case .tar(let listing):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil
            additionalInspection = .tarArchive(listing); inspectionDiagnostics = []
        case .certificate(let id, let inspection):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil
            additionalInspection = .certificate(id, inspection); inspectionDiagnostics = []
        case .security(let inspection):
            jsonInspection = nil; csvInspection = nil; yamlInspection = nil; xmlInspection = nil
            plistInspection = nil; sourceDocument = nil; markdownDocument = nil
            additionalInspection = .security(inspection); inspectionDiagnostics = inspection.diagnostics
        }
        let formatName = route.formatName
        let detectionReason = route.detectionReason
        let automaticFormatName = formatOverride == nil ? nil : routingSelection.automatic.formatName
        return .init(systemUTI: systemUTI, overrideDescription: formatOverride == nil ? nil : (overrideDescription ?? "User override"), automaticFormatName: automaticFormatName, analysis: analysis, resolution: resolution,
                     selectedInspectorID: route.inspectorID, selectedFormatID: route.format?.id,
                     sampleByteCount: routingSample.count,
                     sampleIsComplete: routingIsComplete, originalBytes: Data(bytes.prefix(min(bytes.count, min(1_048_576, max(0, fileSize))))), jsonInspection: jsonInspection, csvInspection: csvInspection, yamlInspection: yamlInspection,
                     xmlInspection: xmlInspection, plistInspection: plistInspection, sourceDocument: sourceDocument,
                     markdownDocument: markdownDocument, additionalInspection: additionalInspection,
                     formatName: formatName, detectionReason: detectionReason,
                     inspectionDiagnostics: inspectionDiagnostics)
    }

    /// Reads no more than 1 MiB. Metadata lookup failure does not hide readable content.
    /// Reads a bounded prefix before invoking `prepare`; the source URL is used only for local
    /// metadata and is never included in diagnostics or logs.
    public static func read(at url: URL, maximumBytes: Int = 1_048_576, markdownOptions: MarkdownOptions = .init(),
                            formatOverride: FormatOverride? = nil, overrideDescription: String? = nil,
                            contentTypeIdentifier: @Sendable (URL) throws -> String? = { fileURL in
                                try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
                            }) throws -> PreviewInspectionResult {
        guard url.pathExtension.lowercased() == "textbundle" else {
            return try readRegularFile(at: url, maximumBytes: maximumBytes, markdownOptions: markdownOptions,
                formatOverride: formatOverride, overrideDescription: overrideDescription,
                contentTypeIdentifier: contentTypeIdentifier)
        }
        return try readTextBundle(at: url, maximumBytes: maximumBytes, markdownOptions: markdownOptions,
            formatOverride: formatOverride, overrideDescription: overrideDescription,
            contentTypeIdentifier: contentTypeIdentifier)
    }

    /// Performs the bounded read under one wall-clock limit (ADR-040). When the limit passes during
    /// inspection, the inspector is cancelled and the result is the Raw/Hex fallback for the same
    /// route with a limit diagnostic. When it passes before bytes are available, this throws
    /// `InspectionWatchdog.TimeoutError`.
    public static func read(at url: URL, timeLimit: Duration, maximumBytes: Int = 1_048_576,
                            markdownOptions: MarkdownOptions = .init(), formatOverride: FormatOverride? = nil,
                            overrideDescription: String? = nil,
                            contentTypeIdentifier: @escaping @Sendable (URL) throws -> String? = { fileURL in
                                try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
                            }) async throws -> PreviewInspectionResult {
        try await read(at: url, timeLimit: timeLimit, sleep: { try await Task.sleep(for: $0) },
                       maximumBytes: maximumBytes, markdownOptions: markdownOptions, formatOverride: formatOverride,
                       overrideDescription: overrideDescription, contentTypeIdentifier: contentTypeIdentifier)
    }

    /// Test seam for the time-limited read: `sleep` expires the deadline and a non-nil `inspect`
    /// replaces parsing.
    static func read(at url: URL, timeLimit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
                     maximumBytes: Int = 1_048_576, markdownOptions: MarkdownOptions = .init(),
                     formatOverride: FormatOverride? = nil, overrideDescription: String? = nil,
                     contentTypeIdentifier: @escaping @Sendable (URL) throws -> String?,
                     inspect replacement: (@Sendable (ReadEvidence) throws -> PreviewInspectionResult)? = nil,
                     inspectionRegistry: FormatInspectorRegistry = .builtIn,
                     observe: @escaping @Sendable (RegularFileReadEvent) -> Void = { _ in },
                     snapshotObserver: @escaping @Sendable (RegularFileReadSnapshot) -> Void = { _ in },
                     textBundleReadOperation: (@Sendable (Int32, UnsafeMutablePointer<UInt8>?, Int) -> TextBundleReadAttempt)? = nil,
                     textBundleObserve: @escaping @Sendable (TextBundleReadEvent) -> Void = { _ in },
                     textBundleSnapshotObserver: @escaping @Sendable (TextBundlePreviewSnapshot) -> Void = { _ in },
                     textBundleTimerClosed: @escaping @Sendable () -> Void = {}
    ) async throws -> PreviewInspectionResult {
        if url.pathExtension.lowercased() != "textbundle", replacement == nil {
            let latest = PublishedRegularFileSnapshot()
            let completed = try await InspectionWatchdog.run(limit: timeLimit, sleep: sleep) {
                try readRegularFileForTesting(at: url, maximumBytes: maximumBytes, markdownOptions: markdownOptions,
                    formatOverride: formatOverride, overrideDescription: overrideDescription,
                    contentTypeIdentifier: contentTypeIdentifier, onSnapshot: { snapshot in
                        latest.publish(snapshot)
                        snapshotObserver(snapshot)
                    }, observe: observe, inspectionRegistry: inspectionRegistry)
            }
            if let completed { return completed }
            guard let snapshot = latest.closeAndLoad(), !snapshot.retainedBytes.isEmpty else {
                throw InspectionWatchdog.TimeoutError()
            }
            try Task.checkCancellation()
            return timeoutFallback(snapshot: snapshot, fileName: url.lastPathComponent,
                                   markdownOptions: markdownOptions, overrideDescription: overrideDescription)
        }
        if isTextBundle(url), replacement == nil {
            let published = PublishedTextBundleSnapshot()
            let packageSleep: @Sendable (Duration) async throws -> Void = { duration in
                try await sleep(duration)
                try Task.checkCancellation()
                published.close()
                textBundleTimerClosed()
            }
            defer { published.close() }
            let completed = try await InspectionWatchdog.run(limit: timeLimit, sleep: packageSleep) {
                try readTextBundle(at: url, maximumBytes: maximumBytes, markdownOptions: markdownOptions,
                    formatOverride: formatOverride, overrideDescription: overrideDescription,
                    contentTypeIdentifier: contentTypeIdentifier,
                    readOperation: textBundleReadOperation.map { operation in
                        { descriptor, buffer, count in operation(descriptor, buffer, count) }
                    }, observe: textBundleObserve,
                    onSnapshot: { snapshot in
                        if published.publish(snapshot) { textBundleSnapshotObserver(snapshot) }
                    }, inspectionRegistry: inspectionRegistry)
            }
            if let completed { return completed }
            try Task.checkCancellation()
            guard let snapshot = published.closeAndLoad(), !snapshot.retainedMarkdown.isEmpty else {
                throw InspectionWatchdog.TimeoutError()
            }
            return timeoutFallback(snapshot: snapshot, fileName: url.lastPathComponent,
                                   markdownOptions: markdownOptions, inspectionRegistry: inspectionRegistry)
        }
        let inspect = replacement ?? { evidence in
            try Self.inspect(evidence, at: url, markdownOptions: markdownOptions,
                             formatOverride: formatOverride, overrideDescription: overrideDescription)
        }
        let retained = RetainedEvidence()
        let completed = try await InspectionWatchdog.run(limit: timeLimit, sleep: sleep) {
            let evidence = try readEvidence(at: url, maximumBytes: maximumBytes, contentTypeIdentifier: contentTypeIdentifier)
            retained.store(evidence)
            return try inspect(evidence)
        }
        if let completed { return completed }
        guard let evidence = retained.load() else { throw InspectionWatchdog.TimeoutError() }
        try Task.checkCancellation()
        return prepare(bytes: evidence.prefix.data, fileSize: evidence.prefix.fileSize, fileName: url.lastPathComponent,
                       systemUTI: evidence.systemUTI, markdownOptions: markdownOptions, formatOverride: formatOverride,
                       overrideDescription: overrideDescription, fileURL: url, runsInspector: false)
    }

    /// Bytes and advisory type evidence gathered before any inspector runs.
    struct ReadEvidence: Sendable {
        let prefix: BoundedFileReader.Prefix
        let systemUTI: String?
    }

    /// Synchronously stages a TextBundle route before retaining the remaining bounded Markdown
    /// payload. The package URL is passed to inspectors only after continuation completes.
    static func readTextBundle(
        at url: URL,
        maximumBytes: Int = 1_048_576,
        markdownOptions: MarkdownOptions = .init(),
        formatOverride: FormatOverride? = nil,
        overrideDescription: String? = nil,
        contentTypeIdentifier: @Sendable (URL) throws -> String?,
        readOperation: TextBundleReadOperation? = nil,
        observe: (TextBundleReadEvent) -> Void = { _ in },
        onSnapshot: (TextBundlePreviewSnapshot) -> Void = { _ in },
        inspectionRegistry: FormatInspectorRegistry = .builtIn
    ) throws -> PreviewInspectionResult {
        let boundedMaximum = min(max(maximumBytes, 1), 1_048_576)
        let fileName = url.lastPathComponent
        let read = try TextBundleInspector.readMarkdownStaged(at: url, maximumBytes: boundedMaximum,
            transferPackageDescriptor: true,
            readOperation: readOperation, observe: observe, onSnapshot: { route, retained in
                onSnapshot(TextBundlePreviewSnapshot(route: route, retainedMarkdown: retained))
            }) { sample, markdownSize in
                try Task.checkCancellation()
                let advisoryUTI: String?
                do { advisoryUTI = try contentTypeIdentifier(url) } catch { advisoryUTI = nil }
                try Task.checkCancellation()
                let complete = sample.count == markdownSize
                let resolution = TypeResolver().resolve(fileName: fileName, leadingBytes: sample,
                    systemUTI: advisoryUTI, sampleIsComplete: complete)
                let analysis = TextAnalysis.analyze(bytes: sample, fileSize: markdownSize, maximumBytes: 65_536)
                let selection = InspectionPipeline.select(fileName: fileName, systemUTI: advisoryUTI,
                    bytes: sample, analysis: analysis, resolution: resolution, formatOverride: formatOverride)
                try Task.checkCancellation()
                return TextBundleRouteSnapshot(selection: selection, resolution: resolution,
                    advisoryUTI: advisoryUTI, markdownSample: sample, sampleIsComplete: complete,
                    originalMarkdownSize: markdownSize, formatOverride: formatOverride,
                    overrideDescription: overrideDescription)
            }

        defer {
            if let descriptor = read.packageDescriptor { _ = Darwin.close(descriptor) }
        }

        try Task.checkCancellation()
        let snapshot = read.selection
        let analysis = TextAnalysis.analyze(bytes: read.prefix.data, fileSize: snapshot.originalMarkdownSize,
                                            maximumBytes: 1_048_576)
        if snapshot.formatOverride != nil {
            try Task.checkCancellation()
            observe(.dispatchAttempt(inspectorID: snapshot.selection.automatic.inspectorID))
            try Task.checkCancellation()
            _ = InspectionPipeline.inspect(route: snapshot.selection.automatic, bytes: read.prefix.data,
                fileSize: snapshot.originalMarkdownSize, fileName: fileName, systemUTI: snapshot.advisoryUTI,
                markdownOptions: markdownOptions, analysis: analysis, fileURL: nil,
                registry: inspectionRegistry, rejectBinaryTextRoute: true)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        observe(.dispatchAttempt(inspectorID: snapshot.selection.effective.inspectorID))
        try Task.checkCancellation()
        let result = prepare(bytes: read.prefix.data, fileSize: snapshot.originalMarkdownSize,
            fileName: fileName, systemUTI: snapshot.advisoryUTI, markdownOptions: markdownOptions,
            formatOverride: snapshot.formatOverride, overrideDescription: snapshot.overrideDescription,
            fileURL: url, runsInspector: true, routingSelection: snapshot.selection,
            resolution: snapshot.resolution, routingSample: snapshot.markdownSample,
            routingIsComplete: snapshot.sampleIsComplete, registry: inspectionRegistry,
            rejectsBinaryTextRoute: true)
        try Task.checkCancellation()
        guard var markdown = result.markdownDocument, !markdown.images.isEmpty else { return result }
        guard read.packageDescriptor != nil else { return result }
        observe(.assetResolutionStarted)
        try Task.checkCancellation()
        let reopened: OpenPackageDirectory
        do {
            reopened = try TextBundleInspector.openPackage(at: url)
        } catch TextBundleError.invalidPackage {
            try Task.checkCancellation()
            return result
        }
        defer { _ = Darwin.close(reopened.descriptor) }
        guard reopened.identity == read.identity else {
            try Task.checkCancellation()
            return result
        }
        markdown.images = MarkdownLocalImages.resolve(markdown.images,
            rootDescriptor: reopened.descriptor, policy: .textBundle)
        try Task.checkCancellation()
        return result.replacingMarkdownDocument(markdown)
    }

    /// Reads a TextBundle through the shared 64 KiB staged route, then retains the bounded
    /// Markdown payload before inspection. Thumbnail never resolves package assets.
    public static func readThumbnailTextBundle(
        at url: URL,
        maximumBytes: Int,
        markdownOptions: MarkdownOptions,
        contentTypeIdentifier: @Sendable (URL) throws -> String?,
        observe: @Sendable (TextBundleReadEvent) -> Void = { _ in },
        onCompletedRead: @Sendable (ThumbnailTextBundleReadSnapshot) -> Void = { _ in }
    ) throws -> PreviewInspectionResult {
        try readThumbnailTextBundle(at: url, maximumBytes: maximumBytes, markdownOptions: markdownOptions,
            contentTypeIdentifier: contentTypeIdentifier, observe: observe, onCompletedRead: onCompletedRead,
            readOperation: nil, inspectionRegistry: .builtIn)
    }

    static func readThumbnailTextBundle(
        at url: URL,
        maximumBytes: Int,
        markdownOptions: MarkdownOptions,
        contentTypeIdentifier: @Sendable (URL) throws -> String?,
        observe: @Sendable (TextBundleReadEvent) -> Void,
        onCompletedRead: @Sendable (ThumbnailTextBundleReadSnapshot) -> Void,
        readOperation: TextBundleReadOperation?,
        inspectionRegistry: FormatInspectorRegistry
    ) throws -> PreviewInspectionResult {
        let boundedMaximum = min(max(maximumBytes, 1), 262_144)
        let fileName = url.lastPathComponent
        let read = try TextBundleInspector.readMarkdownStaged(at: url, maximumBytes: boundedMaximum,
            readOperation: readOperation, observe: observe) { sample, markdownSize in
                try Task.checkCancellation()
                let advisoryUTI: String?
                do { advisoryUTI = try contentTypeIdentifier(url) } catch { advisoryUTI = nil }
                try Task.checkCancellation()
                let complete = sample.count == markdownSize
                let resolution = TypeResolver().resolve(fileName: fileName, leadingBytes: sample,
                    systemUTI: advisoryUTI, sampleIsComplete: complete)
                let analysis = TextAnalysis.analyze(bytes: sample, fileSize: markdownSize, maximumBytes: 65_536)
                let selection = InspectionPipeline.select(fileName: fileName, systemUTI: advisoryUTI,
                    bytes: sample, analysis: analysis, resolution: resolution, formatOverride: nil)
                try Task.checkCancellation()
                return TextBundleRouteSnapshot(selection: selection, resolution: resolution,
                    advisoryUTI: advisoryUTI, markdownSample: sample, sampleIsComplete: complete,
                    originalMarkdownSize: markdownSize, formatOverride: nil, overrideDescription: nil)
            }

        let payload = TextBundlePreviewSnapshot(route: read.selection, retainedMarkdown: read.prefix.data)
        let completedSnapshot = ThumbnailTextBundleReadSnapshot(payload)
        onCompletedRead(completedSnapshot)
        try Task.checkCancellation()
        observe(.dispatchAttempt(inspectorID: read.selection.selection.effective.inspectorID))
        try Task.checkCancellation()
        return prepare(bytes: read.prefix.data, fileSize: read.selection.originalMarkdownSize,
            fileName: fileName, systemUTI: read.selection.advisoryUTI, markdownOptions: markdownOptions,
            formatOverride: nil, overrideDescription: nil, fileURL: nil, runsInspector: true,
            routingSelection: read.selection.selection, resolution: read.selection.resolution,
            routingSample: read.selection.markdownSample, routingIsComplete: read.selection.sampleIsComplete,
            registry: inspectionRegistry, rejectsBinaryTextRoute: true)
    }

    /// Builds Thumbnail's post-read timeout fallback from its frozen package route and bytes.
    public static func timeoutFallback(snapshot: ThumbnailTextBundleReadSnapshot, fileName: String,
                                       markdownOptions: MarkdownOptions) -> PreviewInspectionResult {
        let value = snapshot.value
        let route = value.route
        return prepare(bytes: value.retainedMarkdown, fileSize: route.originalMarkdownSize,
            fileName: fileName, systemUTI: route.advisoryUTI, markdownOptions: markdownOptions,
            formatOverride: nil, overrideDescription: nil, fileURL: nil, runsInspector: false,
            routingSelection: route.selection, resolution: route.resolution,
            routingSample: route.markdownSample, routingIsComplete: route.sampleIsComplete)
    }

    private static func readEvidence(at url: URL, maximumBytes: Int,
                                     contentTypeIdentifier: @Sendable (URL) throws -> String?) throws -> ReadEvidence {
        try Task.checkCancellation()
        let boundedMaximum = min(max(maximumBytes, 1), 1_048_576)
        let prefix: BoundedFileReader.Prefix
        if url.pathExtension.lowercased() == "textbundle" {
            prefix = try TextBundleInspector.readMarkdown(at: url, maximumBytes: boundedMaximum)
        } else {
            prefix = try BoundedFileReader.readPrefix(at: url, maximumBytes: boundedMaximum)
        }
        try Task.checkCancellation()
        let systemUTI: String?
        // UTType lookup is advisory: failure must not prevent inspection of bytes already read.
        do { systemUTI = try contentTypeIdentifier(url) } catch { systemUTI = nil }
        try Task.checkCancellation()
        return ReadEvidence(prefix: prefix, systemUTI: systemUTI)
    }

    private static func inspect(_ evidence: ReadEvidence, at url: URL, markdownOptions: MarkdownOptions,
                                formatOverride: FormatOverride?, overrideDescription: String?) throws -> PreviewInspectionResult {
        var result = prepare(bytes: evidence.prefix.data, fileSize: evidence.prefix.fileSize, fileName: url.lastPathComponent, systemUTI: evidence.systemUTI, markdownOptions: markdownOptions, formatOverride: formatOverride, overrideDescription: overrideDescription, fileURL: url)
        if var markdown = result.markdownDocument, !markdown.images.isEmpty {
            // Resolve images only after parsing, using the file's directory as a local base.
            markdown.images = MarkdownLocalImages.resolve(markdown.images, relativeTo: url)
            result = result.replacingMarkdownDocument(markdown)
        }
        try Task.checkCancellation()
        return result
    }

    private static func isTextBundle(_ url: URL) -> Bool { url.pathExtension.lowercased() == "textbundle" }

    private static func timeoutFallback(snapshot: TextBundlePreviewSnapshot, fileName: String,
                                        markdownOptions: MarkdownOptions,
                                        inspectionRegistry: FormatInspectorRegistry) -> PreviewInspectionResult {
        let route = snapshot.route
        return prepare(bytes: snapshot.retainedMarkdown, fileSize: route.originalMarkdownSize,
            fileName: fileName, systemUTI: route.advisoryUTI, markdownOptions: markdownOptions,
            formatOverride: route.formatOverride, overrideDescription: route.overrideDescription,
            fileURL: nil, runsInspector: false, routingSelection: route.selection,
            resolution: route.resolution, routingSample: route.markdownSample,
            routingIsComplete: route.sampleIsComplete, registry: inspectionRegistry)
    }

}

// MARK: - Helpers

/// Keeps the bounded read's evidence available after the watchdog abandons the worker.
private final class RetainedEvidence: Sendable {
    private let evidence = Mutex<PreviewInspectionResult.ReadEvidence?>(nil)

    func store(_ value: PreviewInspectionResult.ReadEvidence) { evidence.withLock { $0 = value } }
    func load() -> PreviewInspectionResult.ReadEvidence? { evidence.withLock { $0 } }
}

/// Linearizes snapshot publication against the watchdog's terminal timeout outcome.
private final class PublishedRegularFileSnapshot: Sendable {
    private struct State {
        var value: RegularFileReadSnapshot?
        var isOpen = true
    }
    private let state = Mutex(State())

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

/// Linearizes TextBundle snapshot publication against the package watchdog's timer cutoff.
private final class PublishedTextBundleSnapshot: Sendable {
    private struct State {
        var value: TextBundlePreviewSnapshot?
        var isOpen = true
    }
    private let state = Mutex(State())

    func publish(_ value: TextBundlePreviewSnapshot) -> Bool {
        state.withLock { state in
            guard state.isOpen else { return false }
            state.value = value
            return true
        }
    }

    func close() { state.withLock { $0.isOpen = false } }

    func closeAndLoad() -> TextBundlePreviewSnapshot? {
        state.withLock { state in
            state.isOpen = false
            return state.value
        }
    }
}
