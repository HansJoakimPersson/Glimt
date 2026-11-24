/// The type selected by the resolver, its confidence, and the complete ordered
/// detector evidence vector, including unsuccessful and losing detector results.
public struct ResolvedContentType: Equatable, Sendable {
    public let typeID: String
    public let confidence: DetectionConfidence
    public let evidence: [DetectionEvidence]
    public let byteEvidence: [ByteDetectionEvidence]

    /// Resolver-only construction keeps the selected type and complete evidence vector in sync.
    internal init(
        typeID: String,
        confidence: DetectionConfidence,
        evidence: [DetectionEvidence],
        byteEvidence: [ByteDetectionEvidence] = []
    ) {
        self.typeID = typeID
        self.confidence = confidence
        self.evidence = evidence
        self.byteEvidence = byteEvidence
    }
}
