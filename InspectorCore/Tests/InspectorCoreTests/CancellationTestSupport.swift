import Foundation

/// Runs `work` inside a task that is already cancelled, so cooperative checks fire deterministically.
func runCancelled<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
    await Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return Result { try work() }
    }.value
}
