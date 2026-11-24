/// A normalized confidence score between zero and one.
public struct DetectionConfidence: Equatable, Sendable {
    public let value: Double

    /// Creates a confidence only when `value` is finite and lies in `0...1`.
    public init?(value: Double) {
        guard value.isFinite, (0...1).contains(value) else { return nil }
        self.value = value
    }

    /// Internal scores come from fixed resolver policy constants already constrained to the public range.
    internal init(trustedValue: Double) {
        self.value = trustedValue
    }
}
