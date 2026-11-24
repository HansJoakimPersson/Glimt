import Foundation
import XCTest
@testable import InspectorCore

final class PreviewInspectionTimeLimitTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testReadWithinTheLimitMatchesTheSynchronousRead() async throws {
        let url = try write(#"{"name": "glimt"}"#, as: "config.json")
        let timed = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(30), contentTypeIdentifier: { _ in nil })
        let direct = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
        XCTAssertNotNil(timed.jsonInspection)
        XCTAssertEqual(timed.formatName, direct.formatName)
        XCTAssertEqual(timed.inspectionDiagnostics, direct.inspectionDiagnostics)
    }

    func testInspectionPastTheLimitFallsBackToRawContentAndIsCancelled() async throws {
        let text = #"{"name": "glimt"}"#
        let url = try write(text, as: "config.json")
        let probe = StartProbe()
        let result = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(30), sleep: { _ in
            // Expire the deadline only once the bounded read is done and inspection has begun.
            while !probe.hasStarted { try await Task.sleep(for: .milliseconds(1)) }
        }, contentTypeIdentifier: { _ in nil }, inspect: { _ in
            probe.markStarted()
            while !Task.isCancelled { usleep(1_000) }
            probe.markCancelled()
            throw CancellationError()
        })
        XCTAssertNil(result.jsonInspection)
        XCTAssertEqual(result.inspectionDiagnostics, [InspectionPipeline.timeoutDiagnostic])
        XCTAssertEqual(result.originalBytes, Data(text.utf8))
        XCTAssertEqual(result.formatName, try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil }).formatName,
                       "The fallback keeps the selected route so Raw/Hex views and status stay accurate")
        XCTAssertTrue(probe.waitForCancellation())
    }

    func testStagedInspectionTimeoutDispatchesOnceAndCancelsTheSelectedInspector() async throws {
        let bytes = Data(repeating: 0x61, count: 100_000)
        let url = try write(String(decoding: bytes, as: UTF8.self), as: "late-timeout.swift")
        let probe = StartProbe()
        let inspector = CancellationWaitingInspector(probe: probe)
        let registry = try FormatInspectorRegistry([inspector])
        let events = TimeoutEventRecorder()

        let result = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(30),
            sleep: { _ in
                while !probe.hasStarted { try await Task.sleep(for: .milliseconds(1)) }
            }, contentTypeIdentifier: { _ in nil }, inspectionRegistry: registry,
            observe: { events.append($0) })

        XCTAssertEqual(result.selectedInspectorID, .source)
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertEqual(result.inspectionDiagnostics, [InspectionPipeline.timeoutDiagnostic])
        XCTAssertTrue(probe.waitForCancellation())
        let recorded = events.values
        XCTAssertEqual(recorded.filter { if case .selectionCommitted = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(recorded.filter { if case .dispatchStarted = $0 { return true }; return false }.count, 1)
        let reads = recorded.compactMap { event -> (Int, Int)? in
            guard case .read(let offset, _, let returned, _) = event, returned > 0 else { return nil }
            return (offset, returned)
        }
        XCTAssertEqual(reads.map(\.0), [0, 65_536])
        XCTAssertEqual(reads.map(\.1).reduce(0, +), bytes.count)
    }

    func testReadThatCannotFinishBeforeTheLimitThrowsTimeout() async throws {
        let url = try write("plain", as: "notes.txt")
        do {
            _ = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(30), sleep: { _ in }, contentTypeIdentifier: { _ in
                while !Task.isCancelled { usleep(1_000) }
                return nil
            })
            XCTFail("Expected a timeout before any bytes were available")
        } catch {
            XCTAssertTrue(error is InspectionWatchdog.TimeoutError)
        }
    }

    func testTimeoutWithAnEmptySelectedSnapshotThrowsTimeout() async throws {
        let url = directory.appendingPathComponent("empty.txt")
        try Data().write(to: url)
        let gate = SelectionGate()
        do {
            _ = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(30),
                sleep: { _ in try await gate.waitUntilEntered() }, contentTypeIdentifier: { _ in nil },
                snapshotObserver: { _ in gate.blockAfterSelection() })
            XCTFail("An empty timeout snapshot has no content to present")
        } catch {
            XCTAssertTrue(error is InspectionWatchdog.TimeoutError)
        }
        gate.release()
        XCTAssertTrue(gate.waitUntilReleased())
    }

    func testTimeoutAfterSelectionUsesTheFrozenSnapshotAndDoesNotContinue() async throws {
        let url = directory.appendingPathComponent("large.txt")
        try Data(repeating: 0x61, count: 100_000).write(to: url)
        let gate = SelectionGate()
        let events = TimeoutEventRecorder()
        let result = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(30),
            sleep: { _ in try await gate.waitUntilEntered() }, contentTypeIdentifier: { _ in nil },
            observe: { events.append($0) }, snapshotObserver: { snapshot in
                if snapshot.retainedBytes.count == snapshot.routingByteCount { gate.blockAfterSelection() }
            })
        XCTAssertEqual(result.originalBytes.count, 65_536)
        XCTAssertEqual(result.sampleByteCount, 65_536)
        XCTAssertFalse(result.sampleIsComplete)
        XCTAssertEqual(result.inspectionDiagnostics, [InspectionPipeline.timeoutDiagnostic])
        XCTAssertEqual(result.selectedInspectorID, .text)
        gate.release()
        XCTAssertTrue(gate.waitUntilReleased())
        let recorded = events.values
        XCTAssertEqual(recorded.filter { if case .selectionCommitted = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(recorded.contains { if case .continuationAppended = $0 { return true }; return false })
        XCTAssertFalse(recorded.contains { if case .dispatchStarted = $0 { return true }; return false })
    }

    func testTimeoutDuringContinuationUsesTheLatestPublishedBytes() async throws {
        let url = directory.appendingPathComponent("continuing.txt")
        try Data(repeating: 0x61, count: 100_000).write(to: url)
        let gate = SelectionGate()
        let events = TimeoutEventRecorder()
        let result = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(30),
            sleep: { _ in try await gate.waitUntilEntered() }, contentTypeIdentifier: { _ in nil },
            observe: { events.append($0) }, snapshotObserver: { snapshot in
                if snapshot.retainedBytes.count > snapshot.routingByteCount { gate.blockAfterSelection() }
            })
        XCTAssertEqual(result.originalBytes.count, 100_000)
        XCTAssertEqual(result.analysis.fileSize, 100_000)
        XCTAssertEqual(result.inspectionDiagnostics, [InspectionPipeline.timeoutDiagnostic])
        gate.release()
        XCTAssertTrue(gate.waitUntilReleased())
        let recorded = events.values
        XCTAssertTrue(recorded.contains { if case .continuationAppended = $0 { return true }; return false })
        XCTAssertFalse(recorded.contains { if case .dispatchStarted = $0 { return true }; return false })
    }

    // MARK: Helpers

    private func write(_ text: String, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

private final class SelectionGate: @unchecked Sendable {
    private let reachedLock = NSLock()
    private var hasReached = false
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func blockAfterSelection() {
        reachedLock.withLock { hasReached = true }
        _ = releaseSignal.wait(timeout: .now() + 10)
        released.signal()
    }

    func waitUntilEntered() async throws {
        while !reachedLock.withLock({ hasReached }) {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() { releaseSignal.signal() }
    func waitUntilReleased() -> Bool { released.wait(timeout: .now() + 10) == .success }
}

private final class TimeoutEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RegularFileReadEvent] = []
    var values: [RegularFileReadEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: RegularFileReadEvent) { lock.lock(); stored.append(value); lock.unlock() }
}

/// Lets the injected deadline wait for inspection to start without timing assumptions.
private final class StartProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let cancelled = DispatchSemaphore(value: 0)

    var hasStarted: Bool { lock.withLock { started } }
    func markStarted() { lock.withLock { started = true } }
    func markCancelled() { cancelled.signal() }
    func waitForCancellation() -> Bool { cancelled.wait(timeout: .now() + 10) == .success }
}

private struct CancellationWaitingInspector: FormatInspector {
    let probe: StartProbe
    let id: InspectorID = .source

    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        probe.markStarted()
        while !Task.isCancelled { usleep(1_000) }
        probe.markCancelled()
        throw CancellationError()
    }
}
