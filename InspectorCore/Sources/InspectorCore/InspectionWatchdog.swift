import Dispatch
import Foundation
import Synchronization

/// The single wall-clock guard for a preview or thumbnail request (ADR-040).
///
/// Inspectors own deterministic work limits (bytes, lines, values, cells) and check
/// `Task.isCancelled`; they never own time limits. The watchdog races the work against one
/// deadline, returns `nil` the moment the deadline passes, and cancels the work so it stops at
/// its next cancellation check. A caller is therefore never held past the limit, even by an
/// inspector that does not check cancellation often.
public enum InspectionWatchdog {
    /// Final limit for an interactive preview request, measured from the start of the read.
    public static let previewLimit: Duration = .seconds(2)
    /// Final limit for a Finder thumbnail request, which has no loading state to show.
    public static let thumbnailLimit: Duration = .seconds(1)

    /// Thrown when the limit passed before any bytes were available to show as a fallback.
    public struct TimeoutError: Error, Equatable {
        public init() {}
    }

    // MARK: Async

    /// Runs synchronous `work` off the caller's executor and returns its value, or `nil` when
    /// `limit` passes first. Caller cancellation cancels the work and throws `CancellationError`.
    /// `sleep` is injectable so tests can expire the deadline deterministically.
    public static func run<T: Sendable>(
        limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        work: @escaping @Sendable () throws -> T
    ) async throws -> T? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try work() }
        let race = Race<T?>()
        defer { worker.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                Task.detached {
                    do { race.finish(.success(try await worker.value)) } catch { race.finish(.failure(error)) }
                }
                let timer = Task.detached {
                    // A cancelled timer means the work won; only an elapsed deadline reports a timeout.
                    guard (try? await sleep(limit)) != nil, !Task.isCancelled else { return }
                    race.finish(.success(nil))
                }
                race.onFinish { timer.cancel() }
            }
        } onCancel: {
            worker.cancel()
            race.finish(.failure(CancellationError()))
        }
    }

    // MARK: Blocking

    /// Blocking variant for synchronous Quick Look entry points such as thumbnail requests.
    /// It must not be called from Swift concurrency's cooperative pool.
    public static func runBlocking<T: Sendable>(
        limit: Duration,
        work: @escaping @Sendable () throws -> T
    ) throws -> T? {
        try runBlocking(limit: limit, onTimeout: {}, work: work)
    }

    /// Blocking variant with a synchronous timeout hook. The hook runs after the deadline wins
    /// and before worker cancellation, so callers can close publication at the same cutoff.
    public static func runBlocking<T: Sendable>(
        limit: Duration,
        onTimeout: @escaping @Sendable () -> Void,
        work: @escaping @Sendable () throws -> T
    ) throws -> T? {
        let finished = DispatchSemaphore(value: 0)
        let outcome = Outcome<T>()
        let worker = Task.detached(priority: .userInitiated) {
            outcome.store(Result { try work() })
            finished.signal()
        }
        guard finished.wait(timeout: .now() + limit.dispatchInterval) == .success else {
            onTimeout()
            worker.cancel()
            return nil
        }
        return try outcome.load()?.get()
    }
}

// MARK: - Helpers

/// Resumes one continuation exactly once, whichever of work, timer or cancellation finishes first.
private final class Race<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var pending: Result<Value, Error>?
        var finished = false
        var cleanup: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        // Cancellation can arrive before the continuation exists; resume with that earlier result.
        let early = state.withLock { state -> Result<Value, Error>? in
            if let pending = state.pending { return pending }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { state -> Bool in
            if state.finished { return true }
            state.cleanup = cleanup
            return false
        }
        if runNow { cleanup() }
    }

    func finish(_ result: Result<Value, Error>) {
        let (continuation, cleanup) = state.withLock { state -> (CheckedContinuation<Value, Error>?, (@Sendable () -> Void)?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            guard let continuation = state.continuation else {
                state.pending = result
                return (nil, state.cleanup)
            }
            state.continuation = nil
            return (continuation, state.cleanup)
        }
        continuation?.resume(with: result)
        cleanup?()
    }
}

/// Hands the blocking worker's result to the waiting Quick Look thread.
private final class Outcome<Value: Sendable>: Sendable {
    private let result = Mutex<Result<Value, Error>?>(nil)

    func store(_ value: Result<Value, Error>) { result.withLock { $0 = value } }
    func load() -> Result<Value, Error>? { result.withLock { $0 } }
}

private extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(clamping: seconds.multipliedReportingOverflow(by: 1_000_000_000).partialValue
            + attoseconds / 1_000_000_000))
    }
}
