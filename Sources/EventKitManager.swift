import ArgumentParser
import CoreLocation
import EventKit
import Foundation

/// EventKitManager handles all interactions with the EventKit framework.
///
/// IMPORTANT: macOS Permission Requirements
/// ----------------------------------------
/// On macOS, command-line tools require special setup to access Calendar and Reminders:
///
/// 1. The tool must be code-signed with appropriate entitlements
/// 2. An Info.plist must include privacy usage descriptions:
///    - NSCalendarsUsageDescription: Explains why calendar access is needed
///    - NSRemindersUsageDescription: Explains why reminders access is needed
///
/// 3. For development, you can embed the Info.plist:
///    - Add to Package.swift target: linkerSettings: [.unsafeFlags(["-sectcreate", "__TEXT", "__info_plist", "Info.plist"])]
///    - Or sign the binary: codesign --entitlements entitlements.plist -s - ekctl
///
/// 4. The first time the tool runs, macOS will prompt the user to grant access.
///    If denied, all operations will fail with a permission error.
///
/// 5. Users can manage permissions in: System Settings > Privacy & Security > Calendars/Reminders
class EventKitManager {
    private let eventStore: EKEventStore
    private var calendarAccessGranted = false
    private var reminderAccessGranted = false

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    /// Requests access to both Calendar and Reminders.
    /// This must be called before any EventKit operations.
    func requestAccess() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var calendarError: Error?
        var reminderError: Error?

        // Request calendar access
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                self.calendarAccessGranted = granted
                calendarError = error
                semaphore.signal()
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                self.calendarAccessGranted = granted
                calendarError = error
                semaphore.signal()
            }
        }
        semaphore.wait()

        // Request reminders access
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { granted, error in
                self.reminderAccessGranted = granted
                reminderError = error
                semaphore.signal()
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                self.reminderAccessGranted = granted
                reminderError = error
                semaphore.signal()
            }
        }
        semaphore.wait()

        // Check for errors
        if let error = calendarError {
            print(JSONOutput.error("Calendar access error: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }
        if let error = reminderError {
            print(JSONOutput.error("Reminders access error: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }

        // Check permissions
        if !calendarAccessGranted && !reminderAccessGranted {
            print(JSONOutput.error(
                "Permission denied for both Calendar and Reminders. " +
                "Please grant access in System Settings > Privacy & Security."
            ).toJSON())
            throw ExitCode.failure
        }
    }

    // MARK: - Calendar Operations

    /// Lists all calendars (event calendars and reminder lists)
    func listCalendars() -> JSONOutput {
        var calendars: [[String: Any]] = []

        // Event calendars
        for calendar in eventStore.calendars(for: .event) {
            calendars.append([
                "id": calendar.calendarIdentifier,
                "title": calendar.title,
                "type": "event",
                "source": calendar.source?.title ?? "Unknown",
                "color": calendar.cgColor?.hexString ?? "#000000",
                "allowsModifications": calendar.allowsContentModifications
            ])
        }

        // Reminder lists
        for calendar in eventStore.calendars(for: .reminder) {
            calendars.append([
                "id": calendar.calendarIdentifier,
                "title": calendar.title,
                "type": "reminder",
                "source": calendar.source?.title ?? "Unknown",
                "color": calendar.cgColor?.hexString ?? "#000000",
                "allowsModifications": calendar.allowsContentModifications
            ])
        }

        return JSONOutput.success(["calendars": calendars])
    }

    // MARK: - Event Operations

    /// Lists events in a calendar within a date range
    func listEvents(calendarID: String, from startDate: Date, to endDate: Date) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
            return JSONOutput.error("Calendar not found with ID: \(calendarID)", code: .notFound)
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: [calendar]
        )

        let events = eventStore.events(matching: predicate)
        let eventDicts = events.map { eventToDict($0) }

        return JSONOutput.success(["events": eventDicts, "count": eventDicts.count])
    }

    /// Searches the accessible event calendars without asking callers to guess a range. A single
    /// EventKit event predicate may be silently shortened at four years, so two adjacent two-year
    /// predicates make the stated coverage explicit and avoid losing the oldest half.
    func searchPastEvents(terms: [String], limit: Int, now: Date) -> JSONOutput {
        let calendars = eventStore.calendars(for: .event)
        let window = HistoricalEventSearch.window(endingAt: now)
        let midpoint = window.from.addingTimeInterval(window.to.timeIntervalSince(window.from) / 2)

        let first = eventStore.predicateForEvents(withStart: window.from, end: midpoint, calendars: calendars)
        let second = eventStore.predicateForEvents(withStart: midpoint, end: window.to, calendars: calendars)
        let events = eventStore.events(matching: first) + eventStore.events(matching: second)

        let matching = events.compactMap { event -> (event: EKEvent, fields: [String])? in
            // A query returns events which overlap the range. The search is about past meetings,
            // so exclude an in-progress or future occurrence even when its start overlaps now.
            guard HistoricalEventSearch.isEligible(startDate: event.startDate, endDate: event.endDate, in: window) else {
                return nil
            }
            let fields = HistoricalEventSearch.matchingFields(
                terms: terms,
                title: event.title,
                attendees: attendeeValues(of: event),
                location: event.location,
                notes: event.notes
            )
            return fields.isEmpty ? nil : (event, fields)
        }

        var fieldsByKey: [String: [String]] = [:]
        var eventByKey: [String: EKEvent] = [:]
        for match in matching {
            let key = eventSearchCandidate(for: match.event).key
            fieldsByKey[key] = match.fields
            eventByKey[key] = match.event
        }
        let sorted = HistoricalEventSearch.uniqueNewestFirst(matching.map { eventSearchCandidate(for: $0.event) })
        let total = sorted.count
        let returned = Array(sorted.prefix(limit))
        let formatter = searchDateFormatter()
        let resultEvents = returned.map { candidate -> [String: Any] in
            let key = candidate.key
            // Every candidate was created from `matching`, which fills both dictionaries above.
            return eventSearchDict(eventByKey[key]!, matchedFields: fieldsByKey[key]!, formatter: formatter)
        }

        let coverageCalendars = calendars.map { calendar in
            ["id": calendar.calendarIdentifier, "title": calendar.title, "source": calendar.source?.title ?? "Unknown"]
        }
        return JSONOutput.success([
            "events": resultEvents,
            "matched_count": total,
            "returned_count": resultEvents.count,
            "truncated": total > resultEvents.count,
            "coverage": [
                "from": formatter.string(from: window.from),
                "to": formatter.string(from: window.to),
                "time_zone": HistoricalEventSearch.timeZone.identifier,
                "calendars": coverageCalendars,
                "complete": true,
                "scope": "past_four_years_available_in_eventkit",
            ],
        ])
    }

    /// Shows details of a specific event
    func showEvent(eventID: String) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)", code: .notFound)
        }

        return JSONOutput.success(["event": eventToDict(event)])
    }

    /// Parses a user-supplied URL string. An explicit scheme is required: EventKit would happily
    /// store a bare "example.com" as a relative URL, which then shows up in Calendar.app as a link
    /// that does nothing. Failing here is better than writing a dead link into an event.
    static func parseURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme, !scheme.isEmpty else {
            return nil
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host(), !host.isEmpty else { return nil }
        }
        return url
    }

    static func invalidURLMessage(_ string: String) -> String {
        "Invalid --url '\(string)'. Include a scheme (and host), e.g. https://example.com"
    }

    /// Creates a new calendar event
    func addEvent(
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        url: String?,
        allDay: Bool,
        alarms: [AlarmSpec] = [],
        recurrenceRule: EKRecurrenceRule? = nil
    ) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
            return JSONOutput.error("Calendar not found with ID: \(calendarID)", code: .notFound)
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error("Calendar '\(calendar.title)' does not allow modifications.", code: .notModifiable)
        }

        var parsedURL: URL?
        if let url = url, !url.isEmpty {
            guard let candidate = Self.parseURL(url) else {
                return JSONOutput.error(Self.invalidURLMessage(url))
            }
            parsedURL = candidate
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.location = location
        event.notes = notes
        event.url = parsedURL
        event.isAllDay = allDay
        if let recurrenceRule = recurrenceRule {
            event.recurrenceRules = [recurrenceRule]
        }
        applyTimeAlarms(alarms, clear: false, to: event)

        do {
            try eventStore.save(event, span: .thisEvent)
            return JSONOutput.success([
                "status": "success",
                "message": "Event created successfully",
                "event": eventToDict(event)
            ])
        } catch {
            return JSONOutput.error("Failed to create event: \(error.localizedDescription)")
        }
    }

    /// Edits an existing calendar event. Only non-nil fields are applied; a nil field
    /// leaves the existing value untouched.
    func editEvent(
        eventID: String,
        title: String?,
        startDate: Date?,
        endDate: Date?,
        location: String?,
        notes: String?,
        url: String?,
        allDay: Bool?,
        calendarID: String?,
        span: EKSpan,
        alarms: [AlarmSpec] = [],
        clearAlarms: Bool = false
    ) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)", code: .notFound)
        }

        // Resolve the URL before touching the event: the EKEvent is a live store object, so a
        // late validation failure would leave the other fields already applied in memory.
        // Outer nil = not passed, inner nil = explicitly cleared with an empty string.
        var resolvedURL: URL??
        if let url = url {
            if url.isEmpty {
                resolvedURL = .some(nil)
            } else {
                guard let candidate = Self.parseURL(url) else {
                    return JSONOutput.error(Self.invalidURLMessage(url))
                }
                resolvedURL = .some(candidate)
            }
        }

        if let calendarID = calendarID {
            guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
                return JSONOutput.error("Calendar not found with ID: \(calendarID)", code: .notFound)
            }
            guard calendar.allowsContentModifications else {
                return JSONOutput.error("Calendar '\(calendar.title)' does not allow modifications.", code: .notModifiable)
            }
            event.calendar = calendar
        }

        if let title = title {
            event.title = title
        }
        if let startDate = startDate {
            event.startDate = startDate
        }
        if let endDate = endDate {
            event.endDate = endDate
        }
        if let location = location {
            event.location = location
        }
        if let notes = notes {
            event.notes = notes
        }
        if let resolvedURL = resolvedURL {
            event.url = resolvedURL
        }
        if let allDay = allDay {
            event.isAllDay = allDay
        }
        applyTimeAlarms(alarms, clear: clearAlarms, to: event)

        do {
            try eventStore.save(event, span: span, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Event updated successfully",
                "event": eventToDict(event)
            ])
        } catch {
            return JSONOutput.error("Failed to update event: \(error.localizedDescription)")
        }
    }

    /// Deletes a calendar event
    func deleteEvent(eventID: String) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)", code: .notFound)
        }

        let title = event.title ?? "Untitled"

        do {
            try eventStore.remove(event, span: .thisEvent)
            return JSONOutput.success([
                "status": "success",
                "message": "Event '\(title)' deleted successfully",
                "deletedEventID": eventID
            ])
        } catch {
            return JSONOutput.error("Failed to delete event: \(error.localizedDescription)")
        }
    }

    // MARK: - Reminder Operations

    /// Lists reminders in a reminder list
    func listReminders(listID: String, completed: Bool?) -> JSONOutput {
        let calendar: EKCalendar
        switch resolveReminderList(listID) {
        case .success(let resolved): calendar = resolved
        case .failure(let error): return JSONOutput.error(error.message, code: error.code)
        }

        let predicate = eventStore.predicateForReminders(in: [calendar])

        var reminders: [EKReminder] = []
        let semaphore = DispatchSemaphore(value: 0)

        eventStore.fetchReminders(matching: predicate) { fetchedReminders in
            if let fetchedReminders = fetchedReminders {
                reminders = fetchedReminders
            }
            semaphore.signal()
        }
        semaphore.wait()

        // Filter by completion status if specified
        if let completed = completed {
            reminders = reminders.filter { $0.isCompleted == completed }
        }

        let reminderDicts = reminders.map { reminderToDict($0) }

        return JSONOutput.success(["reminders": reminderDicts, "count": reminderDicts.count])
    }

    /// Resolves what a caller typed into a reminder list.
    ///
    /// Callers hold names, EventKit holds identifiers, and list identifiers change when macOS
    /// rebuilds its store — so requiring an id means every caller first runs `list calendars`, which
    /// is a second process for every write. Identifier wins over title, so a list whose title
    /// happens to look like another list's id can never shadow it; an ambiguous title is an error
    /// rather than a coin flip, because the two lists may live in different accounts.
    struct ListResolutionError: Error {
        let message: String
        let code: JSONOutput.ErrorCode
    }

    func resolveReminderList(_ nameOrID: String) -> Result<EKCalendar, ListResolutionError> {
        let value = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failure(ListResolutionError(message: "A reminder list must be named.", code: .invalidInput)) }

        if let byIdentifier = eventStore.calendar(withIdentifier: value),
           byIdentifier.allowedEntityTypes.contains(.reminder) {
            return .success(byIdentifier)
        }

        let lists = eventStore.calendars(for: .reminder)
        let exact = lists.filter { $0.title == value }
        if exact.count == 1 { return .success(exact[0]) }
        if exact.count > 1 {
            return .failure(ListResolutionError(message: ambiguous(value, exact), code: .conflict))
        }

        let insensitive = lists.filter {
            $0.title.compare(value, options: .caseInsensitive) == .orderedSame
        }
        if insensitive.count == 1 { return .success(insensitive[0]) }
        if insensitive.count > 1 {
            return .failure(ListResolutionError(message: ambiguous(value, insensitive), code: .conflict))
        }

        let available = lists.map(\.title).sorted().joined(separator: ", ")
        return .failure(ListResolutionError(message: "Reminder list '\(value)' not found. Available lists: \(available)", code: .notFound))
    }

    private func ambiguous(_ value: String, _ matches: [EKCalendar]) -> String {
        let detail = matches.map { calendar in
            "\(calendar.calendarIdentifier) (\(calendar.source?.title ?? "unknown account"))"
        }.joined(separator: ", ")
        return "Reminder list '\(value)' is ambiguous; pass one of these ids: \(detail)"
    }

    /// Creates a reminder list.
    ///
    /// The source matters: a list has to belong to an account (iCloud, a local store, an Exchange
    /// mailbox), and picking the wrong one creates a list that never syncs to the phone. Absent an
    /// explicit choice, inherit the account that already holds the default reminder list, which is
    /// where the user's own new lists land.
    func addReminderList(title: String, sourceName: String?) -> JSONOutput {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return JSONOutput.error("Reminder list title must not be empty.")
        }
        if let existing = eventStore.calendars(for: .reminder).first(where: {
            $0.title.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            return JSONOutput.error(
                "A reminder list named '\(existing.title)' already exists (id \(existing.calendarIdentifier)).",
                code: .conflict
            )
        }

        let source: EKSource?
        if let sourceName = sourceName {
            source = eventStore.sources.first {
                $0.title.compare(sourceName, options: .caseInsensitive) == .orderedSame
                    && $0.calendars(for: .reminder).isEmpty == false
            } ?? eventStore.sources.first {
                $0.title.compare(sourceName, options: .caseInsensitive) == .orderedSame
            }
            guard source != nil else {
                let available = Set(eventStore.calendars(for: .reminder).compactMap {
                    $0.source?.title
                }).sorted().joined(separator: ", ")
                return JSONOutput.error(
                    "No account named '\(sourceName)'. Accounts holding reminder lists: \(available)."
                )
            }
        } else {
            source = eventStore.defaultCalendarForNewReminders()?.source
                ?? eventStore.sources.first { !$0.calendars(for: .reminder).isEmpty }
        }

        guard let resolvedSource = source else {
            return JSONOutput.error("No account is available to hold a new reminder list.")
        }

        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = trimmed
        calendar.source = resolvedSource

        do {
            try eventStore.saveCalendar(calendar, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder list created successfully",
                "list": [
                    "id": calendar.calendarIdentifier,
                    "title": calendar.title,
                    "type": "reminder",
                    "source": resolvedSource.title,
                ],
            ])
        } catch {
            return JSONOutput.error("Failed to create reminder list: \(error.localizedDescription)")
        }
    }

    /// Deletes a reminder list.
    ///
    /// Deleting a list takes its reminders with it and EventKit offers no undo, so a list that still
    /// holds anything is refused unless the caller says otherwise. That keeps `add list` reversible
    /// without making "remove this list" a way to lose work by accident.
    func deleteReminderList(_ nameOrID: String, force: Bool) -> JSONOutput {
        let calendar: EKCalendar
        switch resolveReminderList(nameOrID) {
        case .success(let resolved): calendar = resolved
        case .failure(let error): return JSONOutput.error(error.message, code: error.code)
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error("Reminder list '\(calendar.title)' does not allow modifications.", code: .notModifiable)
        }

        let remaining = fetch(eventStore.predicateForReminders(in: [calendar]))
        if !remaining.isEmpty && !force {
            return JSONOutput.error(
                "Reminder list '\(calendar.title)' still holds \(remaining.count) reminder"
                    + "\(remaining.count == 1 ? "" : "s"); pass --force to delete it and them."
            )
        }

        let title = calendar.title
        let id = calendar.calendarIdentifier
        do {
            try eventStore.removeCalendar(calendar, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder list '\(title)' deleted successfully",
                "deletedListID": id,
                "deletedReminderCount": remaining.count,
            ])
        } catch {
            return JSONOutput.error("Failed to delete reminder list: \(error.localizedDescription)")
        }
    }

    /// Searches reminder titles and notes across every list, or one named list.
    ///
    /// One process, one EventKit fetch. Doing this by listing each list in turn costs a subprocess
    /// and a store connection per list — measured at 5.4s across 24 lists, against 0.17s here — and
    /// searching is the most frequent reminder operation there is.
    /// Runs one reminder predicate to completion.
    private func fetch(_ predicate: NSPredicate) -> [EKReminder] {
        var results: [EKReminder] = []
        let semaphore = DispatchSemaphore(value: 0)
        eventStore.fetchReminders(matching: predicate) { fetched in
            results = fetched ?? []
            semaphore.signal()
        }
        semaphore.wait()
        return results
    }

    /// How far back completed reminders are searched when the caller does not say.
    ///
    /// Searching is overwhelmingly a "does this already exist, or did I already do it?" question,
    /// and a completion from last year answers neither — while the store keeps every completion
    /// forever. Bounding the completed half by time is what keeps the search proportional to what is
    /// actually being asked, and `--completed-since` widens it when a caller really wants history.
    static let defaultCompletedSearchWindowDays = 90

    func searchReminders(
        query: String?, listID: String?, completed: Bool?, limit: Int?,
        completedSince: Date? = nil, url: String? = nil
    ) -> JSONOutput {
        let calendars: [EKCalendar]
        if let listID = listID {
            let calendar: EKCalendar
            switch resolveReminderList(listID) {
            case .success(let resolved): calendar = resolved
            case .failure(let error): return JSONOutput.error(error.message, code: error.code)
            }
            calendars = [calendar]
        } else {
            calendars = eventStore.calendars(for: .reminder)
        }

        guard !calendars.isEmpty else {
            return JSONOutput.success(["reminders": [], "count": 0, "query": query])
        }

        // A URL lookup is an exact identity question — a follow-up marker, say — so it must see the
        // whole store, including a completion from years ago. Only the text search is windowed.
        let effectiveCompletedSince = url != nil ? (completedSince ?? Date.distantPast) : completedSince

        // Two bounded fetches rather than one unbounded one. `predicateForReminders(in:)` returns
        // every reminder the store has ever held — here 4,414 rows against 184 open ones — and the
        // completed 96% is what the search spends its time on.
        let window = effectiveCompletedSince
            ?? Calendar.current.date(
                byAdding: .day, value: -Self.defaultCompletedSearchWindowDays, to: Date()
            )!

        var reminders: [EKReminder] = []
        if completed != true {
            reminders += fetch(eventStore.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars
            ))
        }
        if completed != false {
            reminders += fetch(eventStore.predicateForCompletedReminders(
                withCompletionDateStarting: window, ending: nil, calendars: calendars
            ))
        }

        var matching = reminders
        if let url = url {
            matching = matching.filter { $0.url?.absoluteString == url }
        }
        if let query = query {
            let needle = query.lowercased()
            matching = matching.filter { reminder in
                (reminder.title?.lowercased().contains(needle) ?? false)
                    || (reminder.notes?.lowercased().contains(needle) ?? false)
            }
        }
        // Most recently due first, undated last, so a truncated result keeps the useful end.
        matching.sort { left, right in
            let leftDate = left.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let rightDate = right.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            switch (leftDate, rightDate) {
            case (let l?, let r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (left.title ?? "") < (right.title ?? "")
            }
        }

        let total = matching.count
        if let limit = limit, limit > 0, total > limit {
            matching = Array(matching.prefix(limit))
        }

        var payload: [String: Any] = [
            "reminders": matching.map { reminderToDict($0) },
            "count": matching.count,
            "query": query ?? "",
            "searchedLists": calendars.count,
        ]
        // State the coverage, so an empty result can be read as "not in this window" rather than
        // "never existed". Callers that render results for a model depend on this being explicit.
        if completed != false {
            payload["completedSearchedSince"] = window == Date.distantPast
                ? "all"
                : localDateFormatter().string(from: window)
        } else {
            payload["completedSearchedSince"] = "none"
        }
        if matching.count < total {
            payload["truncated"] = true
            payload["totalMatches"] = total
        }
        return JSONOutput.success(payload)
    }

    /// Shows details of a specific reminder
    func showReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)", code: .notFound)
        }

        return JSONOutput.success(["reminder": reminderToDict(reminder)])
    }

    /// Creates a new reminder
    func addReminder(
        listID: String,
        title: String,
        dueDate: Date?,
        priority: Int,
        notes: String?,
        url: String? = nil,
        location: String? = nil,
        coordinate: CLLocationCoordinate2D? = nil,
        radius: Double = EventKitManager.defaultLocationRadius,
        proximity: EKAlarmProximity = .enter,
        alarms: [AlarmSpec] = []
    ) -> JSONOutput {
        if let refusal = rejectUndatedRelativeAlarms(alarms, hasDueDate: dueDate != nil) {
            return refusal
        }
        let calendar: EKCalendar
        switch resolveReminderList(listID) {
        case .success(let resolved): calendar = resolved
        case .failure(let error): return JSONOutput.error(error.message, code: error.code)
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error("Reminder list '\(calendar.title)' does not allow modifications.", code: .notModifiable)
        }

        var parsedURL: URL?
        if let url = url, !url.isEmpty {
            guard let candidate = Self.parseURL(url) else {
                return JSONOutput.error(Self.invalidURLMessage(url))
            }
            parsedURL = candidate
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.priority = priority
        reminder.notes = notes
        reminder.url = parsedURL

        if let dueDate = dueDate {
            reminder.dueDateComponents = reminderDueDateComponents(from: dueDate)
        }
        applyTimeAlarms(alarms, clear: false, to: reminder)

        var matchedAddress: String?
        if let locationName = location {
            switch makeLocationAlarm(
                title: locationName,
                radius: radius,
                proximity: proximity,
                coordinate: coordinate
            ) {
            case .success(let built):
                reminder.addAlarm(built.alarm)
                matchedAddress = built.matchedAddress
            case .failure(let failure):
                return JSONOutput.error(failure.message)
            }
        }

        do {
            try eventStore.save(reminder, commit: true)
            var payload: [String: Any] = [
                "status": "success",
                "message": "Reminder created successfully",
                "reminder": reminderToDict(reminder)
            ]
            if let matchedAddress = matchedAddress {
                payload["geocodedTo"] = matchedAddress
            }
            return JSONOutput.success(payload)
        } catch {
            return JSONOutput.error("Failed to create reminder: \(error.localizedDescription)")
        }
    }

    /// Edits an existing reminder. Only non-nil fields are applied; a nil field
    /// leaves the existing value untouched.
    func editReminder(
        reminderID: String,
        title: String?,
        dueDate: Date?,
        clearDue: Bool,
        priority: Int?,
        notes: String?,
        listID: String?,
        location: String? = nil,
        coordinate: CLLocationCoordinate2D? = nil,
        radius: Double? = nil,
        proximity: EKAlarmProximity? = nil,
        clearLocation: Bool = false,
        url: String? = nil,
        alarms: [AlarmSpec] = [],
        clearAlarms: Bool = false
    ) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)", code: .notFound)
        }

        if clearDue && dueDate != nil {
            return JSONOutput.error("Cannot specify both a due date and --clear-due.")
        }

        if clearLocation && (location != nil || coordinate != nil || radius != nil || proximity != nil) {
            return JSONOutput.error("Cannot specify both --clear-location and other location options.")
        }

        if clearAlarms && !alarms.isEmpty {
            return JSONOutput.error("Cannot specify both --clear-alarms and --alarm.")
        }

        // A relative alarm is measured from the due date the reminder will have once this edit is
        // applied, not the one it has now — so a single call may legitimately add both.
        let willHaveDueDate = clearDue ? false : (dueDate != nil || reminder.dueDateComponents != nil)
        if let refusal = rejectUndatedRelativeAlarms(alarms, hasDueDate: willHaveDueDate) {
            return refusal
        }

        // Resolve the URL before touching the reminder, so a late validation failure cannot leave
        // the other fields already applied in memory. Outer nil = not passed, inner nil = cleared.
        var resolvedURL: URL??
        if let url = url {
            if url.isEmpty {
                resolvedURL = .some(nil)
            } else {
                guard let candidate = Self.parseURL(url) else {
                    return JSONOutput.error(Self.invalidURLMessage(url))
                }
                resolvedURL = .some(candidate)
            }
        }

        if let listID = listID {
            let calendar: EKCalendar
            switch resolveReminderList(listID) {
            case .success(let resolved): calendar = resolved
            case .failure(let error): return JSONOutput.error(error.message, code: error.code)
            }
            guard calendar.allowedEntityTypes.contains(.reminder) else {
                return JSONOutput.error("Calendar '\(calendar.title)' is not a reminder list.")
            }
            reminder.calendar = calendar
        }

        if let title = title {
            reminder.title = title
        }
        if let priority = priority {
            reminder.priority = priority
        }
        if let notes = notes {
            reminder.notes = notes
        }
        if let resolvedURL = resolvedURL {
            reminder.url = resolvedURL
        }

        if clearDue {
            reminder.dueDateComponents = nil
        } else if let dueDate = dueDate {
            reminder.dueDateComponents = reminderDueDateComponents(from: dueDate)
        }
        applyTimeAlarms(alarms, clear: clearAlarms, to: reminder)

        var matchedAddress: String?
        if clearLocation {
            removeLocationAlarms(from: reminder)
        } else if location != nil || coordinate != nil || radius != nil || proximity != nil {
            // A trigger is rebuilt rather than mutated in place: the values not being changed are
            // read off the existing alarm, so `--radius` alone keeps the place, and an old trigger
            // stored without a coordinate is re-geocoded and starts working.
            let existing = locationAlarm(of: reminder)
            let existingLocation = existing?.structuredLocation

            guard let title = location ?? existingLocation?.title else {
                return JSONOutput.error(
                    "This reminder has no location trigger to adjust — pass --location as well."
                )
            }

            let existingCoordinate = existingLocation.flatMap { fencedCoordinate(of: $0) }
            let radiusToUse = radius ?? existingLocation?.radius ?? Self.defaultLocationRadius

            switch makeLocationAlarm(
                title: title,
                radius: radiusToUse,
                proximity: proximity ?? existing?.proximity ?? .enter,
                // Re-geocode when the place itself changed; otherwise keep the coordinate we have.
                coordinate: coordinate ?? (location == nil ? existingCoordinate : nil)
            ) {
            case .success(let built):
                removeLocationAlarms(from: reminder)
                reminder.addAlarm(built.alarm)
                matchedAddress = built.matchedAddress
            case .failure(let failure):
                return JSONOutput.error(failure.message)
            }
        }

        do {
            try eventStore.save(reminder, commit: true)
            var payload: [String: Any] = [
                "status": "success",
                "message": "Reminder updated successfully",
                "reminder": reminderToDict(reminder)
            ]
            if let matchedAddress = matchedAddress {
                payload["geocodedTo"] = matchedAddress
            }
            return JSONOutput.success(payload)
        } catch {
            return JSONOutput.error("Failed to update reminder: \(error.localizedDescription)")
        }
    }

    /// Marks a reminder as completed
    func completeReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)", code: .notFound)
        }

        // Completing an already-completed reminder must not restamp it: the original completion date
        // is evidence of when the thing actually happened, and rewriting it moves the item back
        // inside any recent-completion window a caller is searching.
        guard !reminder.isCompleted else {
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder '\(reminder.title ?? "Untitled")' was already completed",
                "alreadyCompleted": true,
                "reminder": reminderToDict(reminder)
            ])
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()

        do {
            try eventStore.save(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder '\(reminder.title ?? "Untitled")' marked as completed",
                "reminder": reminderToDict(reminder)
            ])
        } catch {
            return JSONOutput.error("Failed to complete reminder: \(error.localizedDescription)")
        }
    }

    /// Deletes a reminder
    func deleteReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)", code: .notFound)
        }

        let title = reminder.title ?? "Untitled"

        do {
            try eventStore.remove(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder '\(title)' deleted successfully",
                "deletedReminderID": reminderID
            ])
        } catch {
            return JSONOutput.error("Failed to delete reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Location Triggers

    /// Radius used when the caller does not name one. Below roughly this distance a geofence fires
    /// unreliably, so it is also the smallest value worth defaulting to.
    static let defaultLocationRadius: Double = 100

    /// Builds the alarm that makes a reminder fire on arrival at or departure from a place.
    ///
    /// EventKit stores a location trigger as an alarm carrying a structured location. That location
    /// needs a coordinate to become a geofence — a title alone produces a reminder that shows an
    /// address and never fires — so an unresolvable place is an error rather than a silent
    /// half-trigger.
    private func makeLocationAlarm(
        title: String,
        radius: Double,
        proximity: EKAlarmProximity,
        coordinate: CLLocationCoordinate2D?
    ) -> Result<(alarm: EKAlarm, matchedAddress: String?), LocationResolver.Failure> {
        let resolved: CLLocation
        var matchedAddress: String?
        if let coordinate = coordinate {
            resolved = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        } else {
            switch LocationResolver.resolve(title) {
            case .success(let place):
                resolved = place.location
                matchedAddress = place.matchedAddress
            case .failure(let failure):
                return .failure(LocationResolver.Failure(
                    message: "\(failure.message) Pass --latitude and --longitude to set the trigger without a lookup."
                ))
            }
        }

        let structuredLocation = EKStructuredLocation(title: title)
        structuredLocation.geoLocation = resolved
        structuredLocation.radius = radius

        let alarm = EKAlarm()
        alarm.structuredLocation = structuredLocation
        alarm.proximity = proximity
        return .success((alarm, matchedAddress))
    }

    /// The reminder's location trigger, if it has one. Time alarms are left out.
    private func locationAlarm(of reminder: EKReminder) -> EKAlarm? {
        reminder.alarms?.first { $0.structuredLocation != nil }
    }

    /// The coordinate a structured location actually fences, or nil when it fences nothing.
    ///
    /// A structured location built from a title alone reads back as latitude 0, longitude 0 rather
    /// than as a missing coordinate — a point in the Gulf of Guinea, so the reminder never fires.
    /// Treating that as "no coordinate" is what lets such a trigger be reported as broken and
    /// re-geocoded on edit.
    private func fencedCoordinate(of location: EKStructuredLocation) -> CLLocationCoordinate2D? {
        guard let coordinate = location.geoLocation?.coordinate,
              CLLocationCoordinate2DIsValid(coordinate),
              !(coordinate.latitude == 0 && coordinate.longitude == 0) else {
            return nil
        }
        return coordinate
    }

    /// Drops every location trigger, leaving any time-based alarms in place.
    private func removeLocationAlarms(from reminder: EKReminder) {
        for alarm in reminder.alarms ?? [] where alarm.structuredLocation != nil {
            reminder.removeAlarm(alarm)
        }
    }

    // MARK: - Time alarms

    /// Applies `--alarm`/`--clear-alarms` to a calendar item, leaving location triggers untouched.
    ///
    /// Supplying alarms **replaces** the existing time alarms rather than adding to them. Appending
    /// would be the more literal reading of the flag, but it gives no way to remove one alarm and
    /// makes an edit repeated twice silently double the notifications; replacement means the flag
    /// describes the resulting state, which is how every other option on these commands behaves.
    private func applyTimeAlarms(
        _ specs: [AlarmSpec], clear: Bool, to item: EKCalendarItem
    ) {
        guard clear || !specs.isEmpty else { return }
        for alarm in item.alarms ?? [] where alarm.isTimeAlarm {
            item.removeAlarm(alarm)
        }
        for spec in specs {
            item.addAlarm(spec.alarm())
        }
    }

    /// A relative alarm on a reminder with no due date is stored happily and can never fire, because
    /// there is no instant for the offset to be relative to. Refusing it is the difference between
    /// an error the caller can act on and a reminder that silently never notifies.
    private func rejectUndatedRelativeAlarms(
        _ specs: [AlarmSpec], hasDueDate: Bool
    ) -> JSONOutput? {
        guard !hasDueDate, specs.contains(where: \.isRelative) else { return nil }
        return JSONOutput.error(
            "A relative alarm needs a due date to be relative to. Pass --due as well, or give the "
                + "alarm as an absolute ISO8601 instant.",
            code: .invalidInput
        )
    }

    /// The time alarms of an item, described for JSON output.
    private func timeAlarms(of item: EKCalendarItem) -> [[String: Any]] {
        let formatter = localDateFormatter()
        return (item.alarms ?? [])
            .filter { $0.isTimeAlarm }
            .map { $0.describedForOutput(using: formatter) }
    }

    // MARK: - Helper Methods

    /// Converts a due date into the date components EventKit expects for a reminder's due date.
    private func reminderDueDateComponents(from date: Date) -> DateComponents {
        Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }

    /// Creates a date formatter that outputs ISO 8601 format in the user's local timezone
    private func localDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"  // ISO 8601 with timezone offset
        formatter.timeZone = TimeZone.current
        return formatter
    }

    private func searchDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = HistoricalEventSearch.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }

    private func attendeeValues(of event: EKEvent) -> [String] {
        (event.attendees ?? []).flatMap { attendee in
            [attendee.name, attendee.url.absoluteString].compactMap { $0 }
        }
    }

    private func eventSearchCandidate(for event: EKEvent) -> HistoricalEventSearch.Candidate {
        HistoricalEventSearch.Candidate(
            calendarID: event.calendar?.calendarIdentifier ?? "",
            eventID: event.eventIdentifier ?? "",
            startDate: event.startDate ?? .distantPast,
            occurrenceDate: event.occurrenceDate
        )
    }

    private func eventSearchDict(
        _ event: EKEvent, matchedFields: [String], formatter: DateFormatter
    ) -> [String: Any] {
        let calendar = event.calendar
        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "startDate": event.startDate.map(formatter.string) ?? "",
            "endDate": event.endDate.map(formatter.string) ?? "",
            "calendarID": calendar?.calendarIdentifier ?? "",
            "calendarTitle": calendar?.title ?? "",
            "source": calendar?.source?.title ?? "Unknown",
            "attendees": attendeeSummaries(of: event),
            "status": eventStatusName(event.status),
            "matchedFields": matchedFields,
        ]
        if let occurrenceDate = event.occurrenceDate {
            dict["occurrenceDate"] = formatter.string(from: occurrenceDate)
        }
        return dict
    }

    private func eventStatusName(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    /// Invitation state is evidence about the appointment, not attendance. Keeping it on each
    /// attendee prevents a declined invite from being presented to Spock as proof of a visit.
    private func attendeeSummaries(of event: EKEvent) -> [[String: Any]] {
        (event.attendees ?? []).map { attendee in
            let address = attendee.url.absoluteString
            let email = address.lowercased().hasPrefix("mailto:")
                ? String(address.dropFirst("mailto:".count))
                : address
            return [
                "name": attendee.name ?? "",
                "email": email.removingPercentEncoding ?? email,
                "status": participantStatusName(attendee.participantStatus),
            ]
        }
    }

    private func participantStatusName(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in_process"
        @unknown default: return "unknown"
        }
    }

    /// Converts an EKEvent to a dictionary for JSON output
    private func eventToDict(_ event: EKEvent) -> [String: Any] {
        let formatter = localDateFormatter()

        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "calendar": [
                "id": event.calendar?.calendarIdentifier ?? "",
                "title": event.calendar?.title ?? ""
            ],
            "allDay": event.isAllDay
        ]

        if let startDate = event.startDate {
            dict["startDate"] = formatter.string(from: startDate)
        }
        if let endDate = event.endDate {
            dict["endDate"] = formatter.string(from: endDate)
        }
        if let location = event.location, !location.isEmpty {
            dict["location"] = location
        } else {
            dict["location"] = NSNull()
        }
        if let notes = event.notes, !notes.isEmpty {
            dict["notes"] = notes
        } else {
            dict["notes"] = NSNull()
        }
        if let url = event.url {
            dict["url"] = url.absoluteString
        }

        dict["hasAlarms"] = event.hasAlarms
        // `hasAlarms` answers "are there any"; this answers "which", which is what a caller deciding
        // whether to add or replace one actually needs. Location triggers appear here too, since an
        // event has no separate field for them the way a reminder does.
        dict["alarms"] = (event.alarms ?? []).map { $0.describedForOutput(using: formatter) }
        dict["hasRecurrenceRules"] = event.hasRecurrenceRules
        dict["recurrenceRules"] = (event.recurrenceRules ?? []).map { JSONOutput.recurrenceSummary($0) }

        return dict
    }

    /// Converts an EKReminder to a dictionary for JSON output
    private func reminderToDict(_ reminder: EKReminder) -> [String: Any] {
        let formatter = localDateFormatter()

        var dict: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list": [
                "id": reminder.calendar?.calendarIdentifier ?? "",
                "title": reminder.calendar?.title ?? ""
            ],
            "completed": reminder.isCompleted,
            "priority": reminder.priority
        ]

        if let dueDateComponents = reminder.dueDateComponents,
           let dueDate = Calendar.current.date(from: dueDateComponents) {
            dict["dueDate"] = formatter.string(from: dueDate)
        } else {
            dict["dueDate"] = NSNull()
        }

        if let completionDate = reminder.completionDate {
            dict["completionDate"] = formatter.string(from: completionDate)
        }

        if let notes = reminder.notes, !notes.isEmpty {
            dict["notes"] = notes
        } else {
            dict["notes"] = NSNull()
        }

        if let url = reminder.url {
            dict["url"] = url.absoluteString
        }

        // Time alarms only: the location trigger keeps its own `locationTrigger` field below,
        // because it is authored and cleared by its own flags. Listing it in both places would make
        // `--clear-alarms` look as though it should remove it.
        dict["alarms"] = timeAlarms(of: reminder)

        if let alarm = locationAlarm(of: reminder), let location = alarm.structuredLocation {
            var trigger: [String: Any] = [
                "title": location.title ?? "",
                "radius": location.radius,
                "proximity": alarm.proximity == .leave ? "depart" : "arrive"
            ]
            if let coordinate = fencedCoordinate(of: location) {
                trigger["latitude"] = coordinate.latitude
                trigger["longitude"] = coordinate.longitude
            } else {
                // No coordinate means no geofence: the reminder will never fire on location.
                trigger["latitude"] = NSNull()
                trigger["longitude"] = NSNull()
                trigger["unresolved"] = true
            }
            dict["locationTrigger"] = trigger
        } else {
            dict["locationTrigger"] = NSNull()
        }

        return dict
    }
}

// MARK: - CGColor Extension for Hex String

import CoreGraphics

extension CGColor {
    var hexString: String {
        guard let components = components, components.count >= 3 else {
            return "#000000"
        }

        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)

        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
