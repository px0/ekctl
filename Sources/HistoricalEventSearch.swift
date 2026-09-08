import Foundation

/// The deterministic parts of historical event search live outside EventKit so the search contract
/// can be tested without reading a user's calendars. EventKit supplies candidates; this type decides
/// which text matched and which occurrences survive truncation.
enum HistoricalEventSearch {
    static let timeZone = TimeZone(identifier: "America/Toronto")!

    struct Window: Equatable {
        let from: Date
        let to: Date
    }

    struct Candidate: Equatable {
        let calendarID: String
        let eventID: String
        let startDate: Date
        let occurrenceDate: Date?

        var key: String {
            let occurrence = occurrenceDate ?? startDate
            return "\(calendarID)\u{1F}\(eventID)\u{1F}\(occurrence.timeIntervalSinceReferenceDate)"
        }
    }

    /// The public contract is four Toronto calendar years ending at the instant the command starts.
    /// The EventKit fetch is split in two below because its single-predicate maximum is four years.
    static func window(endingAt now: Date) -> Window {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Window(
            from: calendar.date(byAdding: .year, value: -4, to: now)!,
            to: now
        )
    }

    static func matchingFields(
        terms: [String], title: String?, attendees: [String], location: String?, notes: String?
    ) -> [String] {
        let fields: [(String, [String])] = [
            ("title", [title ?? ""]),
            ("attendees", attendees),
            ("location", [location ?? ""]),
            ("notes", [notes ?? ""]),
        ]
        return fields.compactMap { name, values in
            values.contains { value in terms.contains { literalMatch($0, in: value) } } ? name : nil
        }
    }

    /// EventKit's predicate returns events that overlap a range. Historical search promises
    /// occurrences *in* this window that have already ended, so a long event crossing either edge
    /// must not leak into the answer.
    static func isEligible(startDate: Date?, endDate: Date?, in window: Window) -> Bool {
        guard let startDate, let endDate else { return false }
        return startDate >= window.from && endDate <= window.to
    }

    static func uniqueNewestFirst(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        let unique = candidates.filter { candidate in
            seen.insert(candidate.key).inserted
        }
        return unique.sorted { left, right in
            if left.startDate != right.startDate { return left.startDate > right.startDate }
            if left.calendarID != right.calendarID { return left.calendarID < right.calendarID }
            if left.eventID != right.eventID { return left.eventID < right.eventID }
            return (left.occurrenceDate ?? left.startDate) > (right.occurrenceDate ?? right.startDate)
        }
    }

    private static func literalMatch(_ term: String, in value: String) -> Bool {
        value.range(
            of: term,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil
    }
}
