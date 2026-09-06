import ArgumentParser
import EventKit
import XCTest
@testable import ekctl

final class RecurrenceSpecTests: XCTestCase {
    private let toronto = TimeZone(identifier: "America/Toronto")!

    private func parse(_ value: String) throws -> EKRecurrenceRule {
        try RecurrenceSpec.parse(value, timeZone: toronto).get().rule()
    }

    func testWeekdayMorningsMapToEventKitDays() throws {
        let rule = try parse("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.interval, 1)
        XCTAssertEqual(rule.daysOfTheWeek?.map(\.dayOfTheWeek), [.monday, .tuesday, .wednesday, .thursday, .friday])
        XCTAssertTrue(rule.daysOfTheWeek?.allSatisfy { $0.weekNumber == 0 } == true)
        XCTAssertNil(rule.recurrenceEnd)
        XCTAssertEqual(JSONOutput.recurrenceSummary(rule), "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
    }

    func testDailyAndWeeklyDefaults() throws {
        for (value, frequency) in [("FREQ=DAILY", EKRecurrenceFrequency.daily), ("FREQ=WEEKLY", .weekly)] {
            let rule = try parse(value)
            XCTAssertEqual(rule.frequency, frequency)
            XCTAssertEqual(rule.interval, 1)
            XCTAssertNil(rule.daysOfTheWeek)
            XCTAssertNil(rule.recurrenceEnd)
            XCTAssertEqual(JSONOutput.recurrenceSummary(rule), value)
        }
    }

    func testSaturdayWithIntervalAndCount() throws {
        let rule = try parse("FREQ=WEEKLY;BYDAY=SA;INTERVAL=2;COUNT=10")
        XCTAssertEqual(rule.daysOfTheWeek?.map(\.dayOfTheWeek), [.saturday])
        XCTAssertEqual(rule.interval, 2)
        XCTAssertEqual(rule.recurrenceEnd?.occurrenceCount, 10)
        XCTAssertNil(rule.recurrenceEnd?.endDate)
        let summary = JSONOutput.recurrenceSummary(rule)
        XCTAssertTrue(summary.contains("INTERVAL=2"))
        XCTAssertTrue(summary.contains("BYDAY=SA"))
        XCTAssertTrue(summary.contains("COUNT=10"))
    }

    func testSundayAndCaseInsensitiveReorderedFields() throws {
        let rule = try parse(" count=1; byday=su; freq=weekly ")
        XCTAssertEqual(rule.daysOfTheWeek?.first?.dayOfTheWeek, .sunday)
        XCTAssertEqual(rule.recurrenceEnd?.occurrenceCount, 1)
    }

    func testIntervalCannotOverflowEventKitStorage() throws {
        let maximum = Int(Int32.max)
        XCTAssertEqual(try parse("FREQ=DAILY;INTERVAL=\(maximum)").interval, maximum)
        for interval in [maximum + 1, Int(UInt32.max) + 2, Int.max] {
            assertRejected("FREQ=DAILY;INTERVAL=\(interval)", containing: "no greater than \(maximum)")
        }
    }

    func testDailyIntervalAndUTCDeadlineAreExact() throws {
        let rule = try parse("FREQ=DAILY;INTERVAL=3;UNTIL=20260930T173045Z")
        XCTAssertEqual(rule.interval, 3)
        XCTAssertEqual(rule.recurrenceEnd?.endDate, ISO8601DateFormatter().date(from: "2026-09-30T17:30:45Z"))
        XCTAssertEqual(JSONOutput.recurrenceSummary(rule), "FREQ=DAILY;INTERVAL=3;UNTIL=20260930T173045Z")
    }

    func testBareDeadlineIncludesWholeLocalDayAcrossDSTAndLeapDay() throws {
        for (input, expected) in [
            ("20260930", "2026-10-01T03:59:59Z"),
            ("20260308", "2026-03-09T03:59:59Z"),  // 23-hour spring day
            ("20261101", "2026-11-02T04:59:59Z"),  // 25-hour autumn day
            ("20280229", "2028-03-01T04:59:59Z"),
        ] {
            let rule = try parse("FREQ=DAILY;UNTIL=\(input)")
            XCTAssertEqual(rule.recurrenceEnd?.endDate, ISO8601DateFormatter().date(from: expected), input)
        }
    }

    func testMalformedRulesAreRejectedWithActionableErrors() {
        let cases = [
            ("", "KEY=VALUE"),
            ("BYDAY=MO", "FREQ is required"),
            ("FREQ=MONTHLY", "unsupported FREQ"),
            ("FREQ=YEARLY", "unsupported FREQ"),
            ("FREQ=HOURLY", "unsupported FREQ"),
            ("FREQ=DAILY;BYMONTH=3", "unsupported field"),
            ("FREQ=DAILY;", "KEY=VALUE"),
            ("FREQ=DAILY;;COUNT=1", "KEY=VALUE"),
            ("FREQ=DAILY=1", "KEY=VALUE"),
            ("FREQ=", "needs a value"),
            ("FREQ=DAILY;freq=WEEKLY", "more than once"),
            ("FREQ=DAILY;BYDAY=MO", "BYDAY requires FREQ=WEEKLY"),
            ("FREQ=WEEKLY;BYDAY=XX", "invalid BYDAY"),
            ("FREQ=WEEKLY;BYDAY=1MO", "invalid BYDAY"),
            ("FREQ=WEEKLY;BYDAY=MO,", "invalid BYDAY"),
            ("FREQ=WEEKLY;BYDAY=MO,,TU", "invalid BYDAY"),
            ("FREQ=WEEKLY;BYDAY=MO,MO", "duplicate BYDAY"),
            ("FREQ=DAILY;INTERVAL=0", "positive integer"),
            ("FREQ=DAILY;INTERVAL=-1", "positive integer"),
            ("FREQ=DAILY;INTERVAL=1.5", "positive integer"),
            ("FREQ=DAILY;INTERVAL=99999999999999999999", "positive integer"),
            ("FREQ=DAILY;COUNT=0", "positive integer"),
            ("FREQ=DAILY;COUNT=-1", "positive integer"),
            ("FREQ=DAILY;COUNT=+1", "positive integer"),
            ("FREQ=DAILY;COUNT=1e2", "positive integer"),
            ("FREQ=DAILY;COUNT=99999999999999999999", "positive integer"),
            ("FREQ=DAILY;COUNT=1;UNTIL=20260930", "cannot be used together"),
        ]
        for (value, message) in cases {
            assertRejected(value, containing: message)
        }
        for value in [
            "20260229", "20260931", "20261301", "20260001", "20260100", "2026093",
            "2026-09-30", "20260930T240000Z", "20260930T126000Z", "20260930T120000",
            "20260930T120000-0400", "20260930T120000Zjunk",
        ] {
            assertRejected("FREQ=DAILY;UNTIL=\(value)", containing: "UNTIL must be a valid")
        }
    }

    private func assertRejected(_ value: String, containing message: String, file: StaticString = #filePath, line: UInt = #line) {
        switch RecurrenceSpec.parse(value, timeZone: toronto) {
        case .success: XCTFail("Accepted invalid rule: \(value)", file: file, line: line)
        case .failure(let failure):
            XCTAssertTrue(failure.message.hasPrefix("Invalid --repeat:"), file: file, line: line)
            XCTAssertTrue(failure.message.contains(message), failure.message, file: file, line: line)
        }
    }

    func testReadSummaryPreservesExistingMonthlyFilters() {
        let rule = EKRecurrenceRule(
            recurrenceWith: .monthly, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.friday)], daysOfTheMonth: nil,
            monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: [-1], end: nil
        )
        XCTAssertEqual(JSONOutput.recurrenceSummary(rule), "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1")
    }

    func testAddFlagParsingDoesNotInventAnAlarm() throws {
        let required = ["--calendar", "test", "--title", "test", "--start", "2026-09-07T09:00:00Z", "--end", "2026-09-07T09:30:00Z"]
        let command = try AddEvent.parse(required + ["--repeat", "FREQ=DAILY"])
        XCTAssertEqual(command.recurrence, "FREQ=DAILY")
        XCTAssertEqual(try command.alarmOptions.validated(), [])
        let plain = try AddEvent.parse(required)
        XCTAssertNil(plain.recurrence)
        XCTAssertEqual(try plain.alarmOptions.validated(), [])
        let withAlarm = try AddEvent.parse(required + ["--alarm", "0"])
        XCTAssertEqual(try withAlarm.alarmOptions.validated(), [.relative(0)])
    }

    func testBadRecurrenceFailsBeforeCalendarAccess() throws {
        for recurrence in ["FREQ=HOURLY", "FREQ=DAILY;UNTIL=20260101", "FREQ=DAILY;INTERVAL=2147483648"] {
            let command = try AddEvent.parse([
                "--calendar", "nonexistent", "--title", "test", "--start", "2026-09-07T09:00:00Z",
                "--end", "2026-09-07T09:30:00Z", "--repeat", recurrence,
            ])
            XCTAssertThrowsError(try command.run()) { error in
                XCTAssertEqual(error as? ExitCode, .failure)
            }
        }
    }
}
