/// A detector result in a type resolution's fixed evidence vector.
///
/// Evidence reports one best candidate per detector class, including zero-score
/// `no-match` results; a required UTType conflict may follow as an eighth entry.
public struct DetectionEvidence: Equatable, Sendable {
    /// Detector family responsible for the reported filename or system-type evidence.
    public enum SignalKind: String, Equatable, Sendable {
        case filename
        case multiExtension
        case singleExtension
        case shebang
        case yamlMapping
        case yamlDocumentMarker
        case systemUTI
        case utiConflict
    }

    public let signalKind: SignalKind
    public let value: String
    public let score: DetectionConfidence

    /// Keeps evidence construction inside the resolver so its fixed ordering and signal semantics stay consistent.
    internal init(signalKind: SignalKind, value: String, score: DetectionConfidence) {
        self.signalKind = signalKind
        self.value = value
        self.score = score
    }
}

/// Evidence from bounded byte-level checks; BOM matches report encoding without changing type.
public struct ByteDetectionEvidence: Equatable, Sendable {
    /// Byte-level detector family that produced the evidence record.
    public enum SignalKind: String, Equatable, Sendable {
        case magicSignature
        case bom
    }

    /// Whether the signature was present, absent, incomplete, or not available to inspect.
    public enum Status: String, Equatable, Sendable {
        case matched
        case noMatch
        case incomplete
        case unavailable
    }

    public let signalKind: SignalKind
    public let status: Status
    public let value: String?
    public let typeID: String?
    public let encoding: TextEncoding?
    public let score: DetectionConfidence
    public let isWinningTypeEvidence: Bool

    /// Resolver-only construction preserves byte evidence ordering and winning-signal attribution.
    internal init(
        signalKind: SignalKind,
        status: Status,
        value: String?,
        typeID: String?,
        encoding: TextEncoding?,
        score: DetectionConfidence,
        isWinningTypeEvidence: Bool
    ) {
        self.signalKind = signalKind
        self.status = status
        self.value = value
        self.typeID = typeID
        self.encoding = encoding
        self.score = score
        self.isWinningTypeEvidence = isWinningTypeEvidence
    }
}
