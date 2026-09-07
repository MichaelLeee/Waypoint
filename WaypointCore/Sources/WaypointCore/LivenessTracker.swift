/// Consecutive-failure counter for API liveness polling. Success resets the
/// count; a failure returns whether the threshold is now reached (the caller
/// then treats the monitored process as dead).
public struct LivenessTracker: Sendable {
    public let maxConsecutiveFailures: Int
    public private(set) var failureCount = 0

    public init(maxConsecutiveFailures: Int) {
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    public mutating func registerSuccess() {
        failureCount = 0
    }

    /// Returns true once `maxConsecutiveFailures` failures have accumulated
    /// without an intervening success.
    public mutating func registerFailure() -> Bool {
        failureCount += 1
        return failureCount >= maxConsecutiveFailures
    }
}
