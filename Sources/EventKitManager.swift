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
    private let eventStore = EKEventStore()
    private var calendarAccessGranted = false
    private var reminderAccessGranted = false

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
            return JSONOutput.error("Calendar not found with ID: \(calendarID)")
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

    /// Shows details of a specific event
    func showEvent(eventID: String) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)")
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
        allDay: Bool
    ) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
            return JSONOutput.error("Calendar not found with ID: \(calendarID)")
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error("Calendar '\(calendar.title)' does not allow modifications.")
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
        span: EKSpan
    ) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)")
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
                return JSONOutput.error("Calendar not found with ID: \(calendarID)")
            }
            guard calendar.allowsContentModifications else {
                return JSONOutput.error("Calendar '\(calendar.title)' does not allow modifications.")
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
            return JSONOutput.error("Event not found with ID: \(eventID)")
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
        guard let calendar = eventStore.calendar(withIdentifier: listID) else {
            return JSONOutput.error("Reminder list not found with ID: \(listID)")
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

    /// Shows details of a specific reminder
    func showReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
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
        location: String? = nil,
        coordinate: CLLocationCoordinate2D? = nil,
        radius: Double = EventKitManager.defaultLocationRadius,
        proximity: EKAlarmProximity = .enter
    ) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: listID) else {
            return JSONOutput.error("Reminder list not found with ID: \(listID)")
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error("Reminder list '\(calendar.title)' does not allow modifications.")
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.priority = priority
        reminder.notes = notes

        if let dueDate = dueDate {
            reminder.dueDateComponents = reminderDueDateComponents(from: dueDate)
        }

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
        clearLocation: Bool = false
    ) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        if clearDue && dueDate != nil {
            return JSONOutput.error("Cannot specify both a due date and --clear-due.")
        }

        if clearLocation && (location != nil || coordinate != nil || radius != nil || proximity != nil) {
            return JSONOutput.error("Cannot specify both --clear-location and other location options.")
        }

        if let listID = listID {
            guard let calendar = eventStore.calendar(withIdentifier: listID) else {
                return JSONOutput.error("Reminder list not found with ID: \(listID)")
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

        if clearDue {
            reminder.dueDateComponents = nil
        } else if let dueDate = dueDate {
            reminder.dueDateComponents = reminderDueDateComponents(from: dueDate)
        }

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
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
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
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
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
        dict["hasRecurrenceRules"] = event.hasRecurrenceRules

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
