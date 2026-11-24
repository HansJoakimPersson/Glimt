import Foundation
import XCTest
@testable import InspectorCore

final class StreamInspectorTests: XCTestCase {
    func testJSONLinesParsesRecordsIndependentlyAndKeepsLineErrors() throws {
        let result = try StreamInspector.jsonLines("{\"n\":1}\nnot json\n\n[true,2]\n")
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.diagnostics.filter { $0.code == .parseError }.count, 1)
        XCTAssertTrue(result.rawIsComplete)
    }

    func testJSONLinesFixturesCoverNDJSONValuesMalformedRowsAndBlankLines() throws {
        let records = try Data(contentsOf: fixtureURL("Cases/jsonl/valid/records.ndjson"))
        let valid = try StreamInspector.jsonLines(String(decoding: records, as: UTF8.self))
        XCTAssertEqual(valid.records.count, 5)
        XCTAssertTrue(valid.diagnostics.isEmpty)
        XCTAssertTrue(valid.rawIsComplete)

        let malformed = try Data(contentsOf: fixtureURL("Cases/jsonl/invalid/malformed.jsonl"))
        let invalid = try StreamInspector.jsonLines(String(decoding: malformed, as: UTF8.self))
        XCTAssertEqual(invalid.records.count, 3)
        XCTAssertEqual(invalid.diagnostics.filter { $0.code == .parseError }.count, 1)
        XCTAssertTrue(invalid.diagnostics.contains { $0.message.contains("line 2") })
        XCTAssertTrue(invalid.rawIsComplete)

        let blankLines = try Data(contentsOf: fixtureURL("Cases/jsonl/edge/blank-lines.jsonl"))
        let sparse = try StreamInspector.jsonLines(String(decoding: blankLines, as: UTF8.self))
        XCTAssertEqual(sparse.records.count, 2)
        XCTAssertTrue(sparse.diagnostics.isEmpty)
        XCTAssertTrue(sparse.rawIsComplete)
    }

    func testJSONLinesAcceptsCRLFAndFinalLineWithoutTerminator() throws {
        let result = try StreamInspector.jsonLines("{\"first\":true}\r\n\r\n{\"last\":false}")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.rawIsComplete)
    }

    func testLogRecognizesCommonPrefixAndKeepsContinuationsOrdered() throws {
        let result = try StreamInspector.log("2026-11-11T12:00:00Z INFO started\n continuation\nplain line\n2026-11-11T12:01:00Z ERROR failed\n")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records[0].timestamp, "2026-11-11T12:00:00Z")
        XCTAssertEqual(result.records[0].level, "INFO")
        XCTAssertEqual(result.records[0].message, "started\n continuation\nplain line")
        XCTAssertEqual(result.records[1].level, "ERROR")
    }

    func testLogParsesLog4jAndPreservesMultilineStackTrace() throws {
        let result = try StreamInspector.log(logFixture("log4j.log"))
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].timestamp, "2026-11-18 10:00:00,123")
        XCTAssertEqual(result.records[0].level, "ERROR")
        XCTAssertEqual(result.records[0].message, "request failed\njava.lang.IllegalStateException: failed\n\tat app.Service.run(Service.java:42)")
        XCTAssertEqual(result.records[0].fields?.first(where: { $0.key == "thread" })?.value, .string("http-nio-8080-exec-1"))

        let logback = try StreamInspector.log(logFixture("logback.log"))
        XCTAssertEqual(logback.records.first?.level, "WARN")
        XCTAssertEqual(logback.records.first?.message, "slow request")
        XCTAssertEqual(logback.records.first?.fields?.first(where: { $0.key == "logger" })?.value, .string("app.RequestHandler"))
    }

    func testLogParsesNginxErrorAndW3CExtendedFields() throws {
        let nginx = try StreamInspector.log(logFixture("nginx-error.log"))
        XCTAssertEqual(nginx.records.first?.level, "ERROR")
        XCTAssertEqual(nginx.records.first?.timestamp, "2026/11/18 12:00:00")
        XCTAssertEqual(nginx.records.first?.message, "open() failed (2: No such file or directory)")
        XCTAssertEqual(nginx.records.first?.fields?.first(where: { $0.key == "connection" })?.value, .string("1"))
        XCTAssertEqual(nginx.records.last?.level, "CRITICAL")

        let w3c = try StreamInspector.log(logFixture("w3c-iis.log"))
        XCTAssertEqual(w3c.records.count, 2)
        XCTAssertEqual(w3c.records.first?.timestamp, "2026-11-18 12:00:00")
        XCTAssertEqual(w3c.records.first?.level, "INFO")
        XCTAssertEqual(w3c.records.first?.message, "GET /health 200")
        XCTAssertEqual(w3c.records.first?.fields?.first(where: { $0.key == "s-ip" })?.value, .string("10.0.0.1"))
    }

    func testLogParsesSyslogRFC3164AndRFC5424() throws {
        let rfc3164 = try StreamInspector.log(logFixture("syslog-rfc3164.log"))
        XCTAssertEqual(rfc3164.records.first?.timestamp, "Nov 18 12:00:00")
        XCTAssertEqual(rfc3164.records.first?.level, "CRITICAL")
        XCTAssertEqual(rfc3164.records.first?.source, "edge-1")
        XCTAssertEqual(rfc3164.records.first?.message, "Accepted publickey")

        let rfc5424 = try StreamInspector.log(logFixture("syslog-rfc5424.log"))
        XCTAssertEqual(rfc5424.records.first?.level, "CRITICAL")
        XCTAssertEqual(rfc5424.records.first?.source, "edge-1")
        XCTAssertEqual(rfc5424.records.first?.message, "service ready")
        XCTAssertTrue(rfc5424.records.first?.fields?.contains(where: { $0.key == "structured_data" }) == true)
    }

    func testLogParsesApacheCommonAndCombinedAccessLogs() throws {
        let result = try StreamInspector.log(logFixture("apache-access.log"))
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.first?.message, "GET /health HTTP/1.1 200 17")
        XCTAssertEqual(result.records.first?.level, "INFO")
        XCTAssertEqual(result.records[1].level, "ERROR")
        XCTAssertEqual(result.records[1].fields?.first(where: { $0.key == "user_agent" })?.value, .string("curl/8.0"))
    }

    func testLogParsesNginxCombinedAccessLogFixture() throws {
        let result = try StreamInspector.log(logFixture("nginx-access.log"))
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records[1].level, "WARNING")
        XCTAssertEqual(result.records[1].fields?.first(where: { $0.key == "user_agent" })?.value, .string("Mozilla/5.0"))
    }

    func testStructuredJSONLogFixtureRoutesByContentToLogInspector() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/log/structured.json"))
        let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                                                     fileName: "structured.json", systemUTI: "public.json")
        XCTAssertEqual(result.additionalInspection?.formatID, .log)
        let log = try StreamInspector.log(String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(log.records.map(\.message), ["service started", "database timeout"])
    }

    func testLogParsesKubernetesCRILogfmtAndSecurityEventFormats() throws {
        let cri = try StreamInspector.log(logFixture("kubernetes-cri.log"))
        XCTAssertEqual(cri.records.first?.timestamp, "2026-11-18T12:00:00.123456789Z")
        XCTAssertEqual(cri.records.first?.level, "ERROR")
        XCTAssertEqual(cri.records.first?.message, "container failed")
        XCTAssertEqual(cri.records.last?.message, "part1part2part3")
        XCTAssertEqual(cri.records.last?.fields?.first(where: { $0.key == "tag" })?.value, .string("F"))

        let cef = try StreamInspector.log(logFixture("cef.log"))
        XCTAssertEqual(cef.records.first?.level, "ERROR")
        XCTAssertEqual(cef.records.first?.message, "Suspicious login")
        XCTAssertEqual(cef.records.first?.fields?.first(where: { $0.key == "src" })?.value, .string("192.0.2.8"))
        XCTAssertEqual(cef.records.first?.fields?.first(where: { $0.key == "msg" })?.value, .string("failed login"))

        let leef = try StreamInspector.log(logFixture("leef.log"))
        XCTAssertEqual(leef.records.first?.timestamp, "Nov 18 12:00:00")
        XCTAssertEqual(leef.records.first?.level, "WARNING")
        XCTAssertEqual(leef.records.first?.message, "blocked connection")
    }

    func testLogfmtPreservesFieldsAndUnescapesQuotedValues() throws {
        let result = try StreamInspector.log(logFixture("logfmt.log"))
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.first?.source, "payments")
        XCTAssertEqual(result.records.first?.level, "INFO")
        XCTAssertEqual(result.records.first?.message, "request finished")
        XCTAssertEqual(result.records[1].message, #"quoted "value" and equals=a"#)
        XCTAssertEqual(result.records[1].fields?.first(where: { $0.key == "path" })?.value, .string("/tmp/log file"))
    }

    func testLogExtractsDockerGELFAndOpenTelemetryJSONAliasesWithoutLosingFields() throws {
        let docker = try StreamInspector.log(logFixture("docker-json.log"))
        XCTAssertEqual(docker.records.first?.timestamp, "2026-11-18T12:00:00.000000000Z")
        XCTAssertEqual(docker.records.first?.message, "container started\n")
        XCTAssertEqual(docker.records.first?.fields?.first(where: { $0.key == "stream" })?.value, .string("stdout"))

        let gelf = try StreamInspector.log(logFixture("gelf.jsonl"))
        XCTAssertEqual(gelf.records.first?.level, "ERROR")
        XCTAssertEqual(gelf.records.first?.message, "database unavailable")
        XCTAssertEqual(gelf.records.first?.timestamp, "2026-11-18T12:00:00.000Z")
        XCTAssertEqual(gelf.records.first?.fields?.first(where: { $0.key == "_request_id" })?.value, .string("abc"))

        let otel = try StreamInspector.log(logFixture("otel.jsonl"))
        XCTAssertEqual(otel.records.first?.level, "WARN")
        XCTAssertEqual(otel.records.first?.message, "retrying")
        XCTAssertEqual(otel.records.first?.source, "payment-api")
        XCTAssertEqual(otel.records.first?.timestamp, "2026-11-18T12:00:00.000Z")
        XCTAssertEqual(otel.records.first?.fields?.first(where: { $0.key == "attributes" })?.value, .object([.init(key: "attempt", value: .number("2"))]))
    }

    func testStructuredJSONArrayUsesOneNormalizedEventPerObjectAndKeepsSourceFields() throws {
        let result = try StreamInspector.log(logFixture("json-array.log"))
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records[1].level, "ERROR")
        XCTAssertEqual(result.records[1].message, "failed")
        XCTAssertEqual(result.records[1].fields?.first(where: { $0.key == "request_id" })?.value, .string("42"))
    }

    func testContentDetectionRecognizesStrongLogSignalsWithoutClaimingOrdinaryJSON() {
        XCTAssertTrue(StreamInspector.recognizesLogContent(#"{"timestamp":"2026-11-18T12:00:00Z","level":"INFO","message":"ready"}"#))
        XCTAssertTrue(StreamInspector.recognizesLogContent("{\"timestamp\":\"2026-11-18T12:00:00Z\",\"level\":\"INFO\",\"message\":\"ready\"}\n{\"timestamp\":\"2026-11-18T12:00:01Z\",\"level\":\"WARN\",\"message\":\"slow\"}"))
        XCTAssertTrue(StreamInspector.recognizesLogContent("2026-11-18T12:00:00Z stdout F started"))
        XCTAssertFalse(StreamInspector.recognizesLogContent(#"{"name":"Ada","active":true}"#))
    }

    func testMalformedJSONLogLineGetsAVisibleDiagnosticAndDoesNotMergeTheNextRecord() throws {
        let result = try StreamInspector.log("{\"level\":\"ERROR\",\"message\":\n{\"level\":\"INFO\",\"message\":\"ready\"}")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .parseError })
        XCTAssertEqual(result.records.last?.message, "ready")
    }

    func testJSONLogContentRoutesByContentWhileOrdinaryJSONStaysJSON() {
        let logText = #"{"timestamp":"2026-11-18T12:00:00Z","level":"INFO","message":"ready"}"#
        let logBytes = Data(logText.utf8)
        let logResult = PreviewInspectionResult.prepare(bytes: logBytes, fileSize: logBytes.count,
                                                        fileName: "events.json", systemUTI: "public.json")
        XCTAssertEqual(logResult.additionalInspection?.formatID, .log)
        XCTAssertEqual(logResult.detectionReason, "contentProbe")

        let jsonText = #"{"name":"Ada","active":true}"#
        let jsonBytes = Data(jsonText.utf8)
        let jsonResult = PreviewInspectionResult.prepare(bytes: jsonBytes, fileSize: jsonBytes.count,
                                                         fileName: "person.json", systemUTI: "public.json")
        XCTAssertNotEqual(jsonResult.additionalInspection?.formatID, .log)
        XCTAssertNotNil(jsonResult.jsonInspection)

        let jsonLinesText = "{\"timestamp\":\"2026-11-18T12:00:00Z\",\"level\":\"INFO\",\"message\":\"ready\"}\n{\"timestamp\":\"2026-11-18T12:00:01Z\",\"level\":\"WARN\",\"message\":\"slow\"}"
        let jsonLines = Data(jsonLinesText.utf8)
        let jsonLinesResult = PreviewInspectionResult.prepare(bytes: jsonLines, fileSize: jsonLines.count,
                                                             fileName: "events.jsonl", systemUTI: "public.ndjson")
        XCTAssertEqual(jsonLinesResult.additionalInspection?.formatID, .log)
    }

    func testLineLimitMarksResultIncompleteAndCancellationPropagates() async throws {
        let limited = try StreamInspector.jsonLines("{\"a\":1}\n{\"a\":2}", maximumLines: 1)
        XCTAssertFalse(limited.rawIsComplete)
        XCTAssertTrue(limited.diagnostics.contains { $0.code == .truncated })
        let task = Task { try StreamInspector.log("INFO ready") }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
    }

    func testNegativeAndZeroLineLimitsClampToZeroForBothReaders() throws {
        for maximumLines in [-1, 0] {
            let json = try StreamInspector.jsonLines("{\"a\":1}", maximumLines: maximumLines)
            XCTAssertTrue(json.records.isEmpty)
            XCTAssertFalse(json.rawIsComplete)
            XCTAssertTrue(json.diagnostics.contains { $0.code == .truncated })

            let log = try StreamInspector.log("INFO ready", maximumLines: maximumLines)
            XCTAssertTrue(log.records.isEmpty)
            XCTAssertFalse(log.rawIsComplete)
            XCTAssertTrue(log.diagnostics.contains { $0.code == .truncated })
        }
    }
}

private func logFixture(_ name: String) throws -> String {
    try String(contentsOf: fixtureURL("Cases/log/\(name)"), encoding: .utf8)
}
