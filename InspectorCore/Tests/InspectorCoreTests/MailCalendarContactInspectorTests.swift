import XCTest
@testable import InspectorCore

final class MailCalendarContactInspectorTests: XCTestCase {
    func testEmailParsesFoldedHeadersPlainBodyAndAttachmentMetadataWithoutPayload() throws {
        let source = """
            From: sender@example.test
            To: reader@example.test
            Subject: A long
             subject
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="boundary-1"

            --boundary-1
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Hello=20there.
            --boundary-1
            Content-Type: application/pdf; name="report.pdf"
            Content-Disposition: attachment; filename="report.pdf"
            Content-Transfer-Encoding: base64

            U0VDUkVU
            --boundary-1--
            """

        let result = try EmailMessageInspector.inspect(source)
        XCTAssertEqual(result.rows.first { $0.section == "Header" && $0.name == "Subject" }?.value, "A long subject")
        XCTAssertEqual(result.rows.first { $0.name == "Text body" }?.value, "Hello there.")
        let attachment = try XCTUnwrap(result.rows.first { $0.name == "Filename" })
        XCTAssertEqual(attachment.value, "report.pdf")
        XCTAssertFalse(result.rows.contains { $0.value.contains("U0VDUkVU") || $0.value.contains("SECRET") })
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.rawIsComplete)
    }

    func testEmailMalformedHeadersAndMissingMultipartBoundaryAreDiagnosed() throws {
        let malformed = try EmailMessageInspector.inspect("This is not a header\n\nbody\n")
        XCTAssertTrue(malformed.diagnostics.contains { $0.code == .parseError })

        let missingBoundary = try EmailMessageInspector.inspect(
            "From: a@example.test\nContent-Type: multipart/mixed; boundary=x\n\nbody\n")
        XCTAssertTrue(missingBoundary.diagnostics.contains { $0.code == .parseError || $0.code == .truncated })
    }

    func testEmailTruncationIsReportedAndRawBytesRemainOutsideTheModel() throws {
        let source = "From: a@example.test\nSubject: hello\n\nbody\n"
        let result = try EmailMessageInspector.inspect(source, isComplete: false)
        XCTAssertFalse(result.rawIsComplete)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .truncated })
    }

    func testICalendarParsesFoldedPropertiesAndNestedComponentsWithoutExpandingRecurrence() throws {
        let source = """
            BEGIN:VCALENDAR
            VERSION:2.0
            PRODID:-//Glimt//EN
            BEGIN:VEVENT
            UID:event-1
            DTSTART:20261121T120000Z
            SUMMARY:Planning
             meeting
            RRULE:FREQ=DAILY;COUNT=5
            ATTACH:https://example.test/file
            END:VEVENT
            END:VCALENDAR
            """

        let result = try CalendarContactInspector.inspectICalendar(source)
        XCTAssertEqual(result.rows.first { $0.name == "SUMMARY" }?.value, "Planningmeeting")
        XCTAssertTrue(result.rows.contains { $0.name == "RRULE" && $0.value == "FREQ=DAILY;COUNT=5" })
        XCTAssertTrue(result.rows.contains { $0.name == "ATTACH" && $0.value == "https://example.test/file" })
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.rawIsComplete)
    }

    func testICalendarRejectsUnbalancedComponentsAndReportsTruncation() throws {
        let malformed = try CalendarContactInspector.inspectICalendar("BEGIN:VCALENDAR\nEND:VEVENT\n")
        XCTAssertTrue(malformed.diagnostics.contains { $0.code == .parseError })

        let partial = try CalendarContactInspector.inspectICalendar("BEGIN:VCALENDAR\nBEGIN:VEVENT\n", isComplete: false)
        XCTAssertFalse(partial.rawIsComplete)
        XCTAssertTrue(partial.diagnostics.contains { $0.code == .truncated })
    }

    func testVCardParsesMultipleCardsAndOmitsInlinePhotoPayload() throws {
        let source = """
            BEGIN:VCARD
            VERSION:4.0
            FN:Zoë Example
            EMAIL;TYPE=work:zoe@example.test
            PHOTO;ENCODING=b;MEDIATYPE=image/png:QkFTRTY0U0VDUkVU
            END:VCARD
            BEGIN:VCARD
            VERSION:3.0
            FN:Second Person
            END:VCARD
            """

        let result = try CalendarContactInspector.inspectVCard(source)
        XCTAssertEqual(result.rows.filter { $0.name == "FN" }.map(\.value), ["Zoë Example", "Second Person"])
        XCTAssertTrue(result.rows.contains { $0.name == "PHOTO" && $0.value == "[payload omitted]" })
        XCTAssertFalse(result.rows.contains { $0.value.contains("QkFTRTY0U0VDUkVU") })
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.rawIsComplete)
    }

    func testVCardRejectsMalformedLinesAndRetainsIncompleteCards() throws {
        let malformed = try CalendarContactInspector.inspectVCard("BEGIN:VCARD\nnot a property\nEND:VCARD\n")
        XCTAssertTrue(malformed.diagnostics.contains { $0.code == .parseError })

        let partial = try CalendarContactInspector.inspectVCard("BEGIN:VCARD\nFN:Example\n", isComplete: false)
        XCTAssertFalse(partial.rawIsComplete)
        XCTAssertTrue(partial.diagnostics.contains { $0.code == .truncated })
    }

    func testAllThreeFormatsEnforceLineLimits() throws {
        let email = try EmailMessageInspector.inspect("From: a@example.test\nSubject: hello\n\nbody\n", maximumLines: 1)
        let calendar = try CalendarContactInspector.inspectICalendar("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n", maximumLines: 1)
        let contact = try CalendarContactInspector.inspectVCard("BEGIN:VCARD\nVERSION:4.0\nEND:VCARD\n", maximumLines: 1)

        for result in [email.diagnostics, calendar.diagnostics, contact.diagnostics] {
            XCTAssertTrue(result.contains { $0.code == .truncated || $0.code == .limitExceeded }, "\(result)")
        }
        XCTAssertFalse(email.rawIsComplete)
        XCTAssertFalse(calendar.rawIsComplete)
        XCTAssertFalse(contact.rawIsComplete)
    }
}
