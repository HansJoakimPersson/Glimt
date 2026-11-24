import Foundation
import XCTest
@testable import InspectorCore

final class InspectionWatchdogTests: XCTestCase {
    // MARK: Async

    func testCompletedWorkReturnsItsValue() async throws {
        let value = try await InspectionWatchdog.run(limit: .seconds(30)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testWorkThatOutlivesTheLimitTimesOutAndIsCancelled() async throws {
        let observed = CancellationProbe()
        let value: Int? = try await InspectionWatchdog.run(limit: .seconds(30), sleep: { _ in }) {
            observed.spinUntilCancelled()
            return 1
        }
        XCTAssertNil(value)
        XCTAssertTrue(observed.waitForCancellation(), "Timed-out work must observe cooperative cancellation")
    }

    func testWorkErrorsPropagate() async {
        do {
            _ = try await InspectionWatchdog.run(limit: .seconds(30)) { () throws -> Int in throw ProbeError.failed }
            XCTFail("Expected the work's error")
        } catch {
            XCTAssertEqual(error as? ProbeError, .failed)
        }
    }

    func testCallerCancellationStopsWaitingAndCancelsWork() async {
        let observed = CancellationProbe()
        let caller = Task {
            try await InspectionWatchdog.run(limit: .seconds(30)) { () -> Int in
                observed.spinUntilCancelled()
                return 1
            }
        }
        XCTAssertTrue(observed.waitForStart())
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(observed.waitForCancellation())
    }

    // MARK: Blocking

    func testBlockingCompletedWorkReturnsItsValue() throws {
        XCTAssertEqual(try InspectionWatchdog.runBlocking(limit: .seconds(30)) { "done" }, "done")
    }

    func testBlockingWorkThatOutlivesTheLimitTimesOutAndIsCancelled() throws {
        let observed = CancellationProbe()
        let value: Int? = try InspectionWatchdog.runBlocking(limit: .milliseconds(20)) {
            observed.spinUntilCancelled()
            return 1
        }
        XCTAssertNil(value)
        XCTAssertTrue(observed.waitForCancellation())
    }

    func testBlockingTimeoutHookRunsBeforeWorkerCancellation() throws {
        let ordering = TimeoutOrderingProbe()
        let value: Int? = try InspectionWatchdog.runBlocking(limit: .milliseconds(20),
            onTimeout: { ordering.markTimeout() }) {
                while !Task.isCancelled { usleep(1_000) }
                ordering.markCancellation()
                return 1
            }
        XCTAssertNil(value)
        XCTAssertTrue(ordering.waitForCancellation())
        XCTAssertTrue(ordering.cancellationSawTimeout)
    }

    func testBlockingWorkErrorsPropagate() {
        XCTAssertThrowsError(try InspectionWatchdog.runBlocking(limit: .seconds(30)) { () throws -> Int in
            throw ProbeError.failed
        }) { XCTAssertEqual($0 as? ProbeError, .failed) }
    }
}

// MARK: - Helpers

private enum ProbeError: Error { case failed }

/// Records when work starts and when it observes cancellation, without sleeping in the test thread.
private final class CancellationProbe: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let cancelled = DispatchSemaphore(value: 0)

    func spinUntilCancelled() {
        started.signal()
        while !Task.isCancelled { usleep(1_000) }
        cancelled.signal()
    }

    func waitForStart() -> Bool { started.wait(timeout: .now() + 10) == .success }
    func waitForCancellation() -> Bool { cancelled.wait(timeout: .now() + 10) == .success }
}

private final class TimeoutOrderingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelled = DispatchSemaphore(value: 0)
    private var didTimeout = false
    private var observedTimeoutBeforeCancellation = false

    var cancellationSawTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedTimeoutBeforeCancellation
    }

    func markTimeout() {
        lock.lock()
        didTimeout = true
        lock.unlock()
    }

    func markCancellation() {
        lock.lock()
        observedTimeoutBeforeCancellation = didTimeout
        lock.unlock()
        cancelled.signal()
    }

    func waitForCancellation() -> Bool { cancelled.wait(timeout: .now() + 10) == .success }
}
