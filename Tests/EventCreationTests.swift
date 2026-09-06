import EventKit
import XCTest
@testable import ekctl

final class EventCreationTests: XCTestCase {
    // Capture the manager's save without writing to the user's calendars or requesting access.
    private final class RecordingEventStore: EKEventStore {
        lazy var testCalendar = EKCalendar(for: .event, eventStore: self)
        var savedEvent: EKEvent?

        override func calendar(withIdentifier identifier: String) -> EKCalendar? {
            identifier == testCalendar.calendarIdentifier ? testCalendar : nil
        }

        override func save(_ event: EKEvent, span: EKSpan) throws {
            savedEvent = event
        }
    }

    private func createEvent(
        in store: RecordingEventStore, recurrenceRule: EKRecurrenceRule? = nil,
        alarms: [AlarmSpec] = []
    ) throws -> [String: Any] {
        let manager = EventKitManager(eventStore: store)
        let start = ISO8601DateFormatter().date(from: "2026-09-07T13:00:00Z")!
        let result = manager.addEvent(
            calendarID: store.testCalendar.calendarIdentifier,
            title: "Morning planning", startDate: start, endDate: start.addingTimeInterval(1800),
            location: nil, notes: nil, url: nil, allDay: false,
            alarms: alarms, recurrenceRule: recurrenceRule
        )
        let receipt = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.toJSON().utf8)) as? [String: Any]
        )
        XCTAssertEqual(receipt["status"] as? String, "success")
        return try XCTUnwrap(receipt["event"] as? [String: Any])
    }

    func testRecurringEventIsSavedAndReportedWithoutAnImplicitAlarm() throws {
        let store = RecordingEventStore()
        let summary = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;COUNT=20"
        let rule = try RecurrenceSpec.parse(summary).get().rule()
        let receipt = try createEvent(in: store, recurrenceRule: rule)

        let saved = try XCTUnwrap(store.savedEvent)
        XCTAssertTrue(saved.hasRecurrenceRules)
        XCTAssertEqual(saved.recurrenceRules?.count, 1)
        XCTAssertEqual(saved.recurrenceRules?.first?.recurrenceEnd?.occurrenceCount, 20)
        XCTAssertEqual(saved.recurrenceRules?.first?.daysOfTheWeek?.map(\.dayOfTheWeek),
                       [.monday, .tuesday, .wednesday, .thursday, .friday])
        XCTAssertTrue((saved.alarms ?? []).isEmpty)
        XCTAssertEqual(receipt["hasRecurrenceRules"] as? Bool, true)
        XCTAssertEqual(receipt["recurrenceRules"] as? [String], [summary])
        XCTAssertEqual(receipt["hasAlarms"] as? Bool, false)
        XCTAssertEqual((receipt["alarms"] as? [[String: Any]])?.count, 0)
    }

    func testOneTimeEventReportsNoRecurrenceAndKeepsExplicitAlarm() throws {
        let store = RecordingEventStore()
        let receipt = try createEvent(in: store, alarms: [.relative(0)])

        let saved = try XCTUnwrap(store.savedEvent)
        XCTAssertFalse(saved.hasRecurrenceRules)
        XCTAssertEqual(saved.alarms?.count, 1)
        XCTAssertEqual(saved.alarms?.first?.relativeOffset, 0)
        XCTAssertEqual(receipt["hasRecurrenceRules"] as? Bool, false)
        XCTAssertEqual(receipt["recurrenceRules"] as? [String], [])
        XCTAssertEqual(receipt["hasAlarms"] as? Bool, true)
        let alarm = try XCTUnwrap((receipt["alarms"] as? [[String: Any]])?.first)
        XCTAssertEqual(alarm["type"] as? String, "relative")
        XCTAssertEqual(alarm["offsetSeconds"] as? Double, 0)
        XCTAssertEqual(alarm["offset"] as? String, "at the time")
    }
}
