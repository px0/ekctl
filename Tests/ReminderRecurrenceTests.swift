import ArgumentParser
import CoreLocation
import EventKit
import XCTest
@testable import ekctl

final class ReminderRecurrenceTests: XCTestCase {
    private final class RecordingReminderStore: EKEventStore {
        lazy var testList: EKCalendar = {
            let list = EKCalendar(for: .reminder, eventStore: self)
            list.title = "Test reminders"
            return list
        }()
        lazy var existingReminder: EKReminder = {
            let reminder = EKReminder(eventStore: self)
            reminder.calendar = testList
            reminder.title = "Existing reminder"
            reminder.dueDateComponents = Self.dueComponents("2026-09-14T21:30:00Z")
            return reminder
        }()
        var savedReminder: EKReminder?
        var saveCount = 0
        var overwriteAfterSave: [EKRecurrenceRule]?
        var hideReadBackAfterSave = false

        override func calendar(withIdentifier identifier: String) -> EKCalendar? {
            identifier == testList.calendarIdentifier ? testList : nil
        }

        override func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? {
            if hideReadBackAfterSave, saveCount > 0 { return nil }
            if identifier == existingReminder.calendarItemIdentifier { return existingReminder }
            if let savedReminder,
               identifier == savedReminder.calendarItemIdentifier {
                return savedReminder
            }
            return nil
        }

        override func save(_ reminder: EKReminder, commit: Bool) throws {
            saveCount += 1
            savedReminder = reminder
            if let overwriteAfterSave {
                reminder.recurrenceRules = overwriteAfterSave
            }
        }

        private static func dueComponents(_ value: String) -> DateComponents {
            let date = ISO8601DateFormatter().date(from: value)!
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date
            )
            components.timeZone = .current
            return components
        }
    }

    private func date(_ value: String = "2026-09-14T21:30:00Z") -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func rule(_ value: String) throws -> EKRecurrenceRule {
        try RecurrenceSpec.parse(value).get().rule()
    }

    private func object(_ result: JSONOutput) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.toJSON().utf8)) as? [String: Any])
    }

    private func reminder(_ result: JSONOutput) throws -> [String: Any] {
        try XCTUnwrap(object(result)["reminder"] as? [String: Any])
    }

    func testCreateStoresRecurrenceAndExplicitLocalDueDateZone() throws {
        let store = RecordingReminderStore()
        let recurring = try rule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        let result = EventKitManager(eventStore: store).addReminder(
            listID: store.testList.calendarIdentifier,
            title: "Pick up Martin",
            dueDate: date(),
            priority: 0,
            notes: nil,
            alarms: [],
            recurrenceRule: recurring
        )
        let receipt = try object(result)
        XCTAssertEqual(receipt["status"] as? String, "success")
        XCTAssertEqual(try reminder(result)["recurrenceRules"] as? [String], [
            "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        ])
        let saved = try XCTUnwrap(store.savedReminder)
        XCTAssertEqual(saved.recurrenceRules?.count, 1)
        XCTAssertEqual(saved.dueDateComponents?.timeZone, .current)
    }

    func testEditReplacesRuleInPlaceAndClearsItWithOneSaveEach() throws {
        let store = RecordingReminderStore()
        let manager = EventKitManager(eventStore: store)
        let id = store.existingReminder.calendarItemIdentifier

        let replacement = try rule("FREQ=DAILY;INTERVAL=2;COUNT=4")
        let edited = manager.editReminder(
            reminderID: id, title: nil, dueDate: nil, clearDue: false,
            priority: nil, notes: nil, listID: nil, alarms: [], clearAlarms: false,
            recurrenceRule: replacement
        )
        let editedReceipt = try object(edited)
        XCTAssertEqual(editedReceipt["status"] as? String, "success")
        XCTAssertEqual(try reminder(edited)["recurrenceRules"] as? [String], [
            "FREQ=DAILY;INTERVAL=2;COUNT=4"
        ])
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.savedReminder?.calendarItemIdentifier, id)

        let cleared = manager.editReminder(
            reminderID: id, title: nil, dueDate: nil, clearDue: false,
            priority: nil, notes: nil, listID: nil, alarms: [], clearAlarms: false,
            clearRecurrence: true
        )
        let clearedReceipt = try object(cleared)
        XCTAssertEqual(clearedReceipt["status"] as? String, "success")
        XCTAssertEqual(try reminder(cleared)["recurrenceRules"] as? [String], [])
        XCTAssertEqual(store.saveCount, 2)
        XCTAssertEqual(store.savedReminder?.calendarItemIdentifier, id)
    }

    func testClearDueRefusesToStrandAnExistingSeries() throws {
        let store = RecordingReminderStore()
        store.existingReminder.recurrenceRules = [try rule("FREQ=DAILY")]
        let result = EventKitManager(eventStore: store).editReminder(
            reminderID: store.existingReminder.calendarItemIdentifier,
            title: nil, dueDate: nil, clearDue: true,
            priority: nil, notes: nil, listID: nil
        )
        let receipt = try object(result)
        XCTAssertEqual(receipt["status"] as? String, "error")
        XCTAssertEqual(receipt["code"] as? String, "invalid_input")
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.existingReminder.recurrenceRules?.count, 1)
    }

    func testStoredRecurrenceMismatchIsUnconfirmedAfterSave() throws {
        let store = RecordingReminderStore()
        store.overwriteAfterSave = [try rule("FREQ=DAILY")]
        let result = EventKitManager(eventStore: store).addReminder(
            listID: store.testList.calendarIdentifier,
            title: "Pick up Martin",
            dueDate: date(),
            priority: 0,
            notes: nil,
            alarms: [],
            recurrenceRule: try rule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        )
        let receipt = try object(result)
        XCTAssertEqual(receipt["status"] as? String, "error")
        XCTAssertEqual(receipt["code"] as? String, "unconfirmed")
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertTrue((receipt["error"] as? String)?.contains("before retrying") == true)
    }

    func testMissingPostSaveReadBackIsUnconfirmedRatherThanEchoedSuccess() throws {
        let store = RecordingReminderStore()
        store.hideReadBackAfterSave = true
        let result = EventKitManager(eventStore: store).addReminder(
            listID: store.testList.calendarIdentifier,
            title: "Pick up Martin",
            dueDate: date(),
            priority: 0,
            notes: nil,
            recurrenceRule: try rule("FREQ=DAILY")
        )
        let receipt = try object(result)
        XCTAssertEqual(receipt["status"] as? String, "error")
        XCTAssertEqual(receipt["code"] as? String, "unconfirmed")
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertTrue((receipt["error"] as? String)?.contains("no read-back object") == true)
    }

    func testTorontoSpringAndAutumnAnchorsKeepTheLocalHour() throws {
        let toronto = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        for (instant, expectedOffset) in [
            ("2026-03-07T22:30:00Z", "-05:00"),
            ("2026-10-31T21:30:00Z", "-04:00"),
        ] {
            let store = RecordingReminderStore()
            let result = EventKitManager(
                eventStore: store,
                localTimeZone: toronto
            ).addReminder(
                listID: store.testList.calendarIdentifier,
                title: "DST anchor",
                dueDate: date(instant),
                priority: 0,
                notes: nil,
                recurrenceRule: try rule("FREQ=DAILY")
            )
            let receipt = try object(result)
            XCTAssertEqual(receipt["status"] as? String, "success", instant)
            let components = try XCTUnwrap(store.savedReminder?.dueDateComponents)
            XCTAssertEqual(components.hour, 17, instant)
            XCTAssertEqual(components.minute, 30, instant)
            XCTAssertEqual(components.timeZone?.identifier, toronto.identifier, instant)
            XCTAssertTrue(
                (try reminder(result)["dueDate"] as? String)?.hasSuffix(expectedOffset) == true,
                instant
            )
        }
    }

    func testRecurringCreateWithoutDueIsRejectedBeforeListResolution() throws {
        let store = RecordingReminderStore()
        let result = EventKitManager(eventStore: store).addReminder(
            listID: "not-a-list", title: "No anchor", dueDate: nil,
            priority: 0, notes: nil, recurrenceRule: try rule("FREQ=DAILY")
        )
        let receipt = try object(result)
        XCTAssertEqual(receipt["status"] as? String, "error")
        XCTAssertEqual(receipt["code"] as? String, "invalid_input")
        XCTAssertTrue((receipt["error"] as? String)?.contains("due date") == true)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testReminderCommandsParseRepeatAsOneArgument() throws {
        let raw = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        let add = try AddReminder.parse([
            "--list", "Todo", "--title", "Pick up Martin", "--due", "2026-09-15T21:30:00Z",
            "--repeat", raw,
        ])
        XCTAssertEqual(add.recurrence, raw)
        XCTAssertFalse(add.clearRepeat)

        let edit = try EditReminder.parse(["rem-1", "--repeat", raw])
        XCTAssertEqual(edit.recurrence, raw)
        XCTAssertFalse(edit.clearRepeat)
    }

    func testReminderCommandClearRepeatIsEditOnly() throws {
        let add = try AddReminder.parse([
            "--list", "Todo", "--title", "Pick up Martin", "--clear-repeat",
        ])
        XCTAssertThrowsError(try add.run()) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }

        let edit = try EditReminder.parse(["rem-1", "--clear-repeat"])
        XCTAssertNil(edit.recurrence)
        XCTAssertTrue(edit.clearRepeat)
    }

    func testReminderRecurrenceValidationRunsBeforeEventKitAccess() throws {
        let base = [
            "--list", "not-a-list", "--title", "Pick up Martin", "--due", "2026-09-15T21:30:00Z",
        ]
        for recurrence in ["FREQ=HOURLY", "FREQ=DAILY;BYDAY=MO", "FREQ=WEEKLY;BYDAY=MO,MO"] {
            let command = try AddReminder.parse(base + ["--repeat", recurrence])
            XCTAssertThrowsError(try command.run()) { error in
                XCTAssertEqual(error as? ExitCode, .failure)
            }
        }

        let noDue = try AddReminder.parse(Array(base.dropLast(2)) + ["--repeat", "FREQ=DAILY"])
        XCTAssertThrowsError(try noDue.run()) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }

        let contradictory = try EditReminder.parse(["rem-1", "--repeat", "FREQ=DAILY", "--clear-repeat"])
        XCTAssertThrowsError(try contradictory.run()) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }
    }
}
