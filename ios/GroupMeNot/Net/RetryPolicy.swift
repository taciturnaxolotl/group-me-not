import Foundation

/// Exponential backoff with full jitter.
///
/// The official Android client gives most requests two attempts over 7.5 seconds
/// with no jitter, which is the main reason it falls over on a congested cell.
/// This is the opposite: a wider budget, and randomised delays so a fleet of
/// clients does not retry in lockstep.
nonisolated struct RetryPolicy: Sendable {
    var maxAttempts: Int
    var base: TimeInterval
    var cap: TimeInterval

    /// Foreground reads and writes. Roughly 25 seconds of budget.
    static let interactive = RetryPolicy(maxAttempts: 4, base: 0.5, cap: 8)
    /// Background sync and outbox drains. Patient.
    static let background = RetryPolicy(maxAttempts: 6, base: 1, cap: 60)
    /// One shot, for calls where a stale answer is worse than none.
    static let none = RetryPolicy(maxAttempts: 1, base: 0, cap: 0)

    /// Full jitter: sleep uniformly in `0..<min(cap, base * 2^attempt)`.
    /// Sleeping a random amount up to the backoff beats sleeping exactly the
    /// backoff, because it spreads a thundering herd instead of preserving it.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        let ceiling = min(cap, base * pow(2, Double(attempt)))
        return ceiling <= 0 ? 0 : Double.random(in: 0..<ceiling)
    }

    func shouldRetry(_ error: APIError, attempt: Int) -> Bool {
        attempt + 1 < maxAttempts && error.isRetryable
    }

    /// Honour the server's `Retry-After` when it sends one, otherwise back off.
    func wait(after error: APIError, attempt: Int) -> TimeInterval {
        if let advised = error.retryAfter { return min(advised, cap) }
        return delay(forAttempt: attempt)
    }
}
