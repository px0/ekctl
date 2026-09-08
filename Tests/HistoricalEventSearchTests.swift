import ArgumentParser
import Foundation
import XCTest
@testable import ekctl

final class HistoricalEventSearchTests: XCTestCase {
    private let toronto = TimeZone(identifier: "America/Toronto")!

    func testLiteralTermsMatchAnyFieldCaseAndDiacriticInsensitively() {
        XCTAssertEqual(
            HistoricalEventSearch.matchingFields(
                terms: ["josé", "quarterly"],
                title: "Planning with Jose",
                attendees: ["Dana <dana@example.com>"],
                location: "Office",
                notes: "Quarterly review"
            ),
            ["title", "notes"]
        )
        XCTAssertEqual(
            HistoricalEventSearch.matchingFields(
                terms: ["dana@example.com"], title: "Planning", attendees: ["Dana <dana@example.com>"],
                location: nil, notes: nil
            ),
            ["attendees"]
        )
    }

    func testWindowIsFourTorontoCalendarYearsAndEndsAtTheCommandNow() {
        let now = ISO8601DateFormatter().date(from: "2026-09-07T20:35:52Z")!
        let window = HistoricalEventSearch.window(endingAt: now)
        XCTAssertEqual(window.to, now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = toronto
        XCTAssertEqual(calendar.component(.year, from: window.from), 2022)
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: window.from), DateComponents(month: 9, day: 7))
    }

    func testEligibilityExcludesEventsCrossingTheHistoryBoundaryAndThoseNotYetEnded() {
        let now = ISO8601DateFormatter().date(from: "2026-09-07T20:35:52Z")!
        let window = HistoricalEventSearch.window(endingAt: now)
        XCTAssertTrue(HistoricalEventSearch.isEligible(
            startDate: window.from, endDate: now, in: window
        ))
        XCTAssertFalse(HistoricalEventSearch.isEligible(
            startDate: window.from.addingTimeInterval(-1), endDate: window.from.addingTimeInterval(1), in: window
        ))
        XCTAssertFalse(HistoricalEventSearch.isEligible(
            startDate: now.addingTimeInterval(-1), endDate: now.addingTimeInterval(1), in: window
        ))
    }

    func testDeduplicatesRecurringOccurrencesAndSortsNewestFirstWithStableTies() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let candidates = [
            HistoricalEventSearch.Candidate(calendarID: "b", eventID: "same", startDate: base, occurrenceDate: base),
            HistoricalEventSearch.Candidate(calendarID: "b", eventID: "same", startDate: base, occurrenceDate: base),
            HistoricalEventSearch.Candidate(calendarID: "a", eventID: "a", startDate: base, occurrenceDate: base),
            HistoricalEventSearch.Candidate(calendarID: "z", eventID: "new", startDate: base.addingTimeInterval(1), occurrenceDate: nil),
        ]
        XCTAssertEqual(
            HistoricalEventSearch.uniqueNewestFirst(candidates).map { "\($0.calendarID):\($0.eventID)" },
            ["z:new", "a:a", "b:same"]
        )
    }

    func testDifferentOccurrencesOfOneSeriesAreRetained() {
        let first = Date(timeIntervalSinceReferenceDate: 1_000)
        let later = first.addingTimeInterval(86_400)
        let candidates = [
            HistoricalEventSearch.Candidate(calendarID: "c", eventID: "series", startDate: first, occurrenceDate: first),
            HistoricalEventSearch.Candidate(calendarID: "c", eventID: "series", startDate: later, occurrenceDate: later),
            HistoricalEventSearch.Candidate(calendarID: "c", eventID: "series", startDate: later, occurrenceDate: later),
        ]
        XCTAssertEqual(HistoricalEventSearch.uniqueNewestFirst(candidates).map(\.startDate), [later, first])
    }

    func testEventSearchCLIParsesRepeatedTermsAndDefaultLimit() throws {
        let command = try SearchEvents.parse(["--term", "Smith", "--term", "café"])
        XCTAssertEqual(command.term, ["Smith", "café"])
        XCTAssertEqual(command.limit, 20)
        XCTAssertEqual(try SearchEvents.parse(["--term", "Smith", "--limit", "100"]).limit, 100)
        XCTAssertEqual(try SearchEvents.parse(["--term", "-literal"]).term, ["-literal"])
    }
}
