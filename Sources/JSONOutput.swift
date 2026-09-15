import EventKit
import Foundation

/// JSONOutput provides consistent JSON formatting for all CLI output.
/// All commands output valid JSON for easy scripting and parsing.
struct JSONOutput {
    private let data: [String: Any]

    private init(_ data: [String: Any]) {
        self.data = data
    }

    /// Creates a success response with the given data
    static func success(_ data: [String: Any]) -> JSONOutput {
        var output = data
        if output["status"] == nil {
            output["status"] = "success"
        }
        return JSONOutput(output)
    }

    /// A compact RRULE-style summary of the rule actually stored on the event. Include the other
    /// EventKit frequencies and filters too, since reads can return rules created by Calendar.app.
    static func recurrenceSummary(_ rule: EKRecurrenceRule) -> String {
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "DAILY"
        case .weekly: frequency = "WEEKLY"
        case .monthly: frequency = "MONTHLY"
        case .yearly: frequency = "YEARLY"
        @unknown default: frequency = "UNKNOWN"
        }
        var parts = ["FREQ=\(frequency)"]
        if rule.interval != 1 { parts.append("INTERVAL=\(rule.interval)") }

        let weekdays: [EKWeekday: String] = [
            .monday: "MO", .tuesday: "TU", .wednesday: "WE", .thursday: "TH",
            .friday: "FR", .saturday: "SA", .sunday: "SU",
        ]
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let values = days.map { day in
                (day.weekNumber == 0 ? "" : String(day.weekNumber)) + (weekdays[day.dayOfTheWeek] ?? "?")
            }
            parts.append("BYDAY=\(values.joined(separator: ","))")
        }
        for (key, values) in [
            ("BYMONTHDAY", rule.daysOfTheMonth), ("BYMONTH", rule.monthsOfTheYear),
            ("BYWEEKNO", rule.weeksOfTheYear), ("BYYEARDAY", rule.daysOfTheYear),
            ("BYSETPOS", rule.setPositions),
        ] {
            if let values = values, !values.isEmpty {
                parts.append("\(key)=\(values.map { $0.stringValue }.joined(separator: ","))")
            }
        }
        // Monday is the RRULE default; EventKit reports it even when no week start was supplied.
        if let day = EKWeekday(rawValue: rule.firstDayOfTheWeek), day != .monday, let value = weekdays[day] {
            parts.append("WKST=\(value)")
        }
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
                parts.append("UNTIL=\(formatter.string(from: date))")
            } else if end.occurrenceCount > 0 {
                parts.append("COUNT=\(end.occurrenceCount)")
            }
        }
        return parts.joined(separator: ";")
    }

    /// What kind of failure this is, for callers that must branch on it.
    ///
    /// Prose is for humans and changes freely; a program that decides between "this reminder is
    /// gone, stop retrying" and "try again later" cannot be left matching on the wording. Anything
    /// without a more specific kind is `failed`.
    enum ErrorCode: String {
        case notFound = "not_found"
        case notModifiable = "not_modifiable"
        case invalidInput = "invalid_input"
        case permissionDenied = "permission_denied"
        case conflict = "conflict"
        /// The provider may have saved the item, but could not prove the requested postcondition
        /// from the object EventKit returned after the save. Callers must read before retrying.
        case unconfirmed = "unconfirmed"
        case failed = "failed"
    }

    /// Creates an error response with the given message
    static func error(_ message: String, code: ErrorCode = .failed) -> JSONOutput {
        return JSONOutput([
            "status": "error",
            "error": message,
            "code": code.rawValue
        ])
    }

    /// Whether this receipt reports an application-level failure.
    var isError: Bool {
        (data["status"] as? String) == "error"
    }

    /// Prints the receipt, and fails the process when the receipt reports a failure.
    ///
    /// ekctl used to exit 0 while printing `{"status":"error"}`, so every caller that trusted `$?` —
    /// a shell pipeline, a script's `set -e`, an agent's tool harness — read a failure as success.
    /// The JSON stays the authority on *what* went wrong; the exit code exists so that silence
    /// cannot be mistaken for success.
    func emit() throws {
        print(toJSON())
        if isError { throw ExitCode.failure }
    }

    /// Converts the output to a JSON string
    func toJSON() -> String {
        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: data,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            )
            return String(data: jsonData, encoding: .utf8) ?? "{\"error\": \"Failed to encode JSON\"}"
        } catch {
            return "{\"status\": \"error\", \"error\": \"JSON serialization failed: \(error.localizedDescription)\"}"
        }
    }
}

// MARK: - ExitCode Extension

import ArgumentParser

extension ExitCode {
    static let permissionDenied = ExitCode(rawValue: 2)
}
