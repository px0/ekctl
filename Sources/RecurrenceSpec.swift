import EventKit
import Foundation

/// The supported RRULE subset, validated before requesting access or writing an event.
struct RecurrenceSpec {
    let frequency: EKRecurrenceFrequency
    let interval: Int
    let daysOfTheWeek: [EKRecurrenceDayOfWeek]?
    let end: EKRecurrenceEnd?

    struct ParseFailure: Error, Equatable {
        let message: String
    }

    static func parse(
        _ raw: String, timeZone: TimeZone = .current
    ) -> Result<RecurrenceSpec, ParseFailure> {
        func reject(_ message: String) -> Result<RecurrenceSpec, ParseFailure> {
            .failure(ParseFailure(message: "Invalid --repeat: \(message)"))
        }

        var fields: [String: String] = [:]
        for part in raw.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                return reject("expected KEY=VALUE fields separated by ';', e.g. 'FREQ=DAILY'.")
            }
            let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces).uppercased()
            guard ["FREQ", "BYDAY", "INTERVAL", "COUNT", "UNTIL"].contains(key) else {
                return reject("unsupported field '\(key)'. Use FREQ, BYDAY, INTERVAL, COUNT or UNTIL.")
            }
            guard !value.isEmpty else { return reject("\(key) needs a value.") }
            guard fields[key] == nil else { return reject("\(key) must not appear more than once.") }
            fields[key] = value
        }

        guard let freq = fields["FREQ"] else { return reject("FREQ is required (DAILY or WEEKLY).") }
        let frequency: EKRecurrenceFrequency
        switch freq {
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        default: return reject("unsupported FREQ '\(freq)'. Use DAILY or WEEKLY.")
        }

        func positiveInteger(_ value: String) -> Int? {
            guard value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(value), number > 0 else { return nil }
            return number
        }

        // EventKit accepts Swift Int here but narrows the interval to a signed 32-bit value.
        // Larger inputs can wrap or raise an Objective-C exception that Swift cannot catch.
        guard let interval = positiveInteger(fields["INTERVAL"] ?? "1"), interval <= Int32.max else {
            return reject("INTERVAL must be a positive integer no greater than \(Int32.max).")
        }

        var days: [EKRecurrenceDayOfWeek]?
        if let byDay = fields["BYDAY"] {
            // EventKit silently ignores BYDAY on daily rules. Refuse it instead of saving a
            // schedule that differs from the one the caller requested.
            guard frequency == .weekly else { return reject("BYDAY requires FREQ=WEEKLY.") }
            let weekdays: [String: EKWeekday] = [
                "MO": .monday, "TU": .tuesday, "WE": .wednesday, "TH": .thursday,
                "FR": .friday, "SA": .saturday, "SU": .sunday,
            ]
            var parsedDays: [EKRecurrenceDayOfWeek] = []
            var seen: Set<String> = []
            for token in byDay.split(separator: ",", omittingEmptySubsequences: false) {
                let value = token.trimmingCharacters(in: .whitespaces)
                guard let day = weekdays[value] else {
                    return reject("invalid BYDAY '\(value)'. Use a comma-separated list of MO,TU,WE,TH,FR,SA,SU.")
                }
                guard seen.insert(value).inserted else { return reject("duplicate BYDAY '\(value)'.") }
                parsedDays.append(EKRecurrenceDayOfWeek(day))
            }
            days = parsedDays
        }

        guard fields["COUNT"] == nil || fields["UNTIL"] == nil else {
            return reject("COUNT and UNTIL cannot be used together.")
        }
        var end: EKRecurrenceEnd?
        if let value = fields["COUNT"] {
            guard let count = positiveInteger(value) else { return reject("COUNT must be a positive integer.") }
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if let value = fields["UNTIL"] {
            guard let date = untilDate(value, timeZone: timeZone) else {
                return reject("UNTIL must be a valid YYYYMMDD date or YYYYMMDDTHHMMSSZ UTC instant.")
            }
            end = EKRecurrenceEnd(end: date)
        }

        return .success(RecurrenceSpec(frequency: frequency, interval: interval, daysOfTheWeek: days, end: end))
    }

    private static func untilDate(_ value: String, timeZone: TimeZone) -> Date? {
        let dateOnly = value.range(of: "^[0-9]{8}$", options: .regularExpression) != nil
        guard dateOnly || value.range(of: "^[0-9]{8}T[0-9]{6}Z$", options: .regularExpression) != nil else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = dateOnly ? timeZone : TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = dateOnly ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        formatter.isLenient = false
        // Round-tripping also rejects normalized invalid dates and times, such as February 30.
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        guard dateOnly else { return date }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Use the next midnight rather than adding 24 hours: DST days can be shorter or longer.
        return calendar.dateInterval(of: .day, for: date)?.end.addingTimeInterval(-1)
    }

    func rule() -> EKRecurrenceRule {
        EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfTheWeek,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }
}
