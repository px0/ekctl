import ArgumentParser
import CoreLocation
import EventKit
import Foundation

// MARK: - Location Trigger Options

/// The location-trigger flags shared by `add reminder` and `edit reminder`, plus the validation both
/// need. Coordinates are resolved from `--location` by geocoding unless the caller pins them here.
struct LocationOptions: ParsableArguments {
    @Option(name: .long, help: "Place name or address that triggers the reminder (e.g. '1 Infinite Loop, Cupertino, CA'). Geocoded to a coordinate so the geofence actually fires.")
    var location: String?

    @Option(name: .long, help: "Location trigger radius in meters (default: 100; 0 lets Reminders pick, which is what the app itself does).")
    var radius: Double?

    @Option(name: .long, help: "Location trigger: 'arrive' or 'depart' (default: arrive).")
    var proximity: String?

    // .unconditional so a western-hemisphere longitude like -79.31 is read as a value rather than
    // mistaken for a flag.
    @Option(name: .long, parsing: .unconditional, help: "Latitude to pin the trigger to, skipping the address lookup. Requires --longitude.")
    var latitude: Double?

    @Option(name: .long, parsing: .unconditional, help: "Longitude to pin the trigger to, skipping the address lookup. Requires --latitude.")
    var longitude: Double?

    /// True when the caller asked for anything location-related at all.
    var isPresent: Bool {
        location != nil || radius != nil || proximity != nil || latitude != nil || longitude != nil
    }

    /// Validates the combination and returns the explicit coordinate, if one was given.
    /// Prints the JSON error and throws on bad input, matching the rest of the CLI.
    func validatedCoordinate() throws -> CLLocationCoordinate2D? {
        // 0 is meaningful: it is what Reminders.app stores when it wants to choose the radius itself.
        if let radius = radius, radius < 0 {
            print(JSONOutput.error("--radius cannot be negative (meters; 0 lets Reminders pick).").toJSON())
            throw ExitCode.failure
        }

        _ = try validatedProximity()

        switch (latitude, longitude) {
        case (nil, nil):
            return nil
        case (let lat?, let lon?):
            guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                print(JSONOutput.error("--latitude must be within -90…90 and --longitude within -180…180.").toJSON())
                throw ExitCode.failure
            }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        default:
            print(JSONOutput.error("--latitude and --longitude must be given together.").toJSON())
            throw ExitCode.failure
        }
    }

    /// Parses `--proximity`, rejecting anything that is not 'arrive' or 'depart' rather than
    /// quietly treating a typo as 'arrive'.
    func validatedProximity() throws -> EKAlarmProximity? {
        guard let proximity = proximity else { return nil }
        switch proximity.lowercased() {
        case "arrive":
            return .enter
        case "depart":
            return .leave
        default:
            print(JSONOutput.error("Invalid --proximity value '\(proximity)'. Use 'arrive' or 'depart'.").toJSON())
            throw ExitCode.failure
        }
    }
}

// MARK: - Alarm Options

/// The `--alarm`/`--clear-alarms` flags shared by every add and edit verb.
///
/// `--alarm` may be repeated to set several. On an edit it describes the resulting state rather than
/// adding to what is there, matching every other option on these commands: the alternative leaves no
/// way to remove one alarm, and makes running the same edit twice double the notifications.
struct AlarmOptions: ParsableArguments {
    // .unconditionalSingleValue so a leading '-' in '-15m' is read as a sign rather than as the
    // start of another flag.
    @Option(
        name: .long,
        parsing: .unconditionalSingleValue,
        help: """
            Notification to attach. Either an offset — '15m', '-1h', '2d' fire before, '+10m' after, \
            '0' at the time — or an absolute ISO8601 instant. Offsets count from an event's start \
            and from a reminder's due date. Repeat to set several; on an edit the set you pass \
            replaces the existing alarms.
            """
    )
    var alarm: [String] = []

    @Flag(name: .long, help: "Remove existing time alarms. A location trigger is left alone; use --clear-location for that.")
    var clearAlarms: Bool = false

    var isPresent: Bool { !alarm.isEmpty || clearAlarms }

    /// Parses every `--alarm`, printing the JSON error and throwing on the first bad one, so a typo
    /// surfaces before anything is written rather than as a silently missing notification.
    func validated() throws -> [AlarmSpec] {
        if clearAlarms && !alarm.isEmpty {
            print(JSONOutput.error("Cannot specify both --clear-alarms and --alarm.").toJSON())
            throw ExitCode.failure
        }
        var specs: [AlarmSpec] = []
        for raw in alarm {
            switch AlarmSpec.parse(raw) {
            case .success(let spec): specs.append(spec)
            case .failure(let failure):
                print(JSONOutput.error(failure.message, code: .invalidInput).toJSON())
                throw ExitCode.failure
            }
        }
        return specs
    }
}

// MARK: - Main Command

@main
struct Ekctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ekctl",
        abstract: "A command-line tool for managing macOS Calendar events and Reminders using EventKit.",
        version: "1.6.0",
        subcommands: [
            List.self, Search.self, Show.self, Add.self, Edit.self, Delete.self, Complete.self,
            Alias.self,
        ],
        defaultSubcommand: List.self
    )
}

// MARK: - List Commands

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List calendars, events, or reminders.",
        subcommands: [ListCalendars.self, ListEvents.self, ListReminders.self]
    )
}

struct ListCalendars: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List all calendars and reminder lists."
    )

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.listCalendars()
        try result.emit()
    }
}

struct ListEvents: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List events in a calendar within a date range."
    )

    @Option(name: .long, help: "The calendar ID or alias.")
    var calendar: String

    @Option(name: .long, help: "Start date in ISO8601 format (e.g., 2026-02-01T00:00:00Z).")
    var from: String

    @Option(name: .long, help: "End date in ISO8601 format (e.g., 2026-02-07T23:59:59Z).")
    var to: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        guard let startDate = ISO8601DateFormatter().date(from: from) else {
            print(JSONOutput.error("Invalid --from date format. Use ISO8601 (e.g., 2026-02-01T00:00:00Z).").toJSON())
            throw ExitCode.failure
        }
        guard let endDate = ISO8601DateFormatter().date(from: to) else {
            print(JSONOutput.error("Invalid --to date format. Use ISO8601 (e.g., 2026-02-07T23:59:59Z).").toJSON())
            throw ExitCode.failure
        }

        let calendarID = ConfigManager.resolveAlias(calendar)
        let result = manager.listEvents(calendarID: calendarID, from: startDate, to: endDate)
        try result.emit()
    }
}

struct ListReminders: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "List reminders in a reminder list."
    )

    @Option(name: .long, help: "The reminder list ID or alias.")
    var list: String

    @Option(name: .long, help: "Filter by completion status (true/false).")
    var completed: Bool?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let listID = ConfigManager.resolveAlias(list)
        let result = manager.listReminders(listID: listID, completed: completed)
        try result.emit()
    }
}

// MARK: - Search Commands

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search across reminders.",
        subcommands: [SearchReminders.self]
    )
}

struct SearchReminders: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Search reminder titles and notes across every list in one pass."
    )

    @Option(name: .long, help: "Text to look for in reminder titles and notes (case-insensitive).")
    var query: String?

    @Option(name: .long, help: "Exact reminder URL to match. Searches the whole store, including old completions, since a URL is an identity rather than a text query.")
    var url: String?

    @Option(name: .long, help: "Restrict the search to one reminder list (ID, alias, or title; an alias of the same name wins).")
    var list: String?

    @Option(name: .long, help: "Filter by completion status (true/false).")
    var completed: Bool?

    @Option(name: .long, help: "Maximum number of matches to return.")
    var limit: Int?

    @Option(name: .long, help: "How far back to search completed reminders, in days (default: 90). Use 0 for no limit.")
    var completedSinceDays: Int?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        var completedSince: Date?
        if let days = completedSinceDays {
            guard days >= 0 else {
                try JSONOutput.error("--completed-since-days cannot be negative.").emit()
                return
            }
            completedSince = days == 0
                ? Date.distantPast
                : Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }

        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if url == nil, trimmed?.isEmpty != false {
            try JSONOutput.error("Pass --query (non-empty) or --url.").emit()
            return
        }
        if let limit = limit, limit <= 0 {
            try JSONOutput.error("--limit must be greater than 0.").emit()
            return
        }

        let result = manager.searchReminders(
            query: trimmed?.isEmpty == false ? trimmed : nil,
            listID: list.map { ConfigManager.resolveAlias($0) },
            completed: completed,
            limit: limit,
            completedSince: completedSince,
            url: url
        )
        try result.emit()
    }
}

// MARK: - Show Commands

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show details of a specific item.",
        subcommands: [ShowEvent.self, ShowReminder.self]
    )
}

struct ShowEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Show details of a specific event."
    )

    @Argument(help: "The event ID to show.")
    var eventID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.showEvent(eventID: eventID)
        try result.emit()
    }
}

struct ShowReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Show details of a specific reminder."
    )

    @Argument(help: "The reminder ID to show.")
    var reminderID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.showReminder(reminderID: reminderID)
        try result.emit()
    }
}

// MARK: - Add Commands

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a new event, reminder, or reminder list.",
        subcommands: [AddEvent.self, AddReminder.self, AddList.self]
    )
}

struct AddList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Create a reminder list."
    )

    @Option(name: .long, help: "The reminder list title.")
    var title: String

    @Option(name: .long, help: "Account to create it in (e.g. 'iCloud'). Defaults to the account holding the default reminder list.")
    var source: String?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        try manager.addReminderList(title: title, sourceName: source).emit()
    }
}

struct AddEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Create a new calendar event."
    )

    @Option(name: .long, help: "The calendar ID or alias.")
    var calendar: String

    @Option(name: .long, help: "The event title.")
    var title: String

    @Option(name: .long, help: "Start date in ISO8601 format.")
    var start: String

    @Option(name: .long, help: "End date in ISO8601 format.")
    var end: String

    @Option(name: .long, help: "Optional location.")
    var location: String?

    @Option(name: .long, help: "Optional notes.")
    var notes: String?

    @Option(name: .long, help: "Optional URL. Must include a scheme, e.g. https://example.com")
    var url: String?

    @Flag(name: .long, help: "Mark as all-day event.")
    var allDay: Bool = false

    @OptionGroup var alarmOptions: AlarmOptions

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        if alarmOptions.clearAlarms {
            print(JSONOutput.error("--clear-alarms applies to an edit; a new event has no alarms to clear.").toJSON())
            throw ExitCode.failure
        }
        let alarms = try alarmOptions.validated()

        guard let startDate = ISO8601DateFormatter().date(from: start) else {
            print(JSONOutput.error("Invalid --start date format. Use ISO8601.").toJSON())
            throw ExitCode.failure
        }
        guard let endDate = ISO8601DateFormatter().date(from: end) else {
            print(JSONOutput.error("Invalid --end date format. Use ISO8601.").toJSON())
            throw ExitCode.failure
        }

        let calendarID = ConfigManager.resolveAlias(calendar)
        let result = manager.addEvent(
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            url: url,
            allDay: allDay,
            alarms: alarms
        )
        try result.emit()
    }
}

struct AddReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Create a new reminder."
    )

    @Option(name: .long, help: "The reminder list ID or alias.")
    var list: String

    @Option(name: .long, help: "The reminder title.")
    var title: String

    @Option(name: .long, help: "Optional due date in ISO8601 format.")
    var due: String?

    @Option(name: .long, help: "Priority (0=none, 1=high, 5=medium, 9=low).")
    var priority: Int?

    @Option(name: .long, help: "Optional notes.")
    var notes: String?

    @Option(name: .long, help: "Optional URL. Must include a scheme, e.g. https://example.com or a custom scheme.")
    var url: String?

    @OptionGroup var locationOptions: LocationOptions

    @OptionGroup var alarmOptions: AlarmOptions

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        if alarmOptions.clearAlarms {
            print(JSONOutput.error("--clear-alarms applies to an edit; a new reminder has no alarms to clear.").toJSON())
            throw ExitCode.failure
        }
        let alarms = try alarmOptions.validated()

        var dueDate: Date?
        if let due = due {
            guard let parsed = ISO8601DateFormatter().date(from: due) else {
                print(JSONOutput.error("Invalid --due date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            dueDate = parsed
        }

        let coordinate = try locationOptions.validatedCoordinate()
        if locationOptions.location == nil && locationOptions.isPresent {
            print(JSONOutput.error(
                "--radius/--proximity/--latitude/--longitude only apply to a trigger — pass --location too."
            ).toJSON())
            throw ExitCode.failure
        }

        let listID = ConfigManager.resolveAlias(list)
        let result = manager.addReminder(
            listID: listID,
            title: title,
            dueDate: dueDate,
            priority: priority ?? 0,
            notes: notes,
            url: url,
            location: locationOptions.location,
            coordinate: coordinate,
            radius: locationOptions.radius ?? EventKitManager.defaultLocationRadius,
            proximity: try locationOptions.validatedProximity() ?? .enter,
            alarms: alarms
        )
        try result.emit()
    }
}

// MARK: - Edit Commands

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit an existing event or reminder.",
        subcommands: [EditEvent.self, EditReminder.self]
    )
}

struct EditEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Edit an existing calendar event. Only the options you pass are changed."
    )

    @Argument(help: "The event ID to edit.")
    var id: String

    @Option(name: .long, help: "New event title.")
    var title: String?

    @Option(name: .long, help: "New start date in ISO8601 format.")
    var start: String?

    @Option(name: .long, help: "New end date in ISO8601 format.")
    var end: String?

    @Option(name: .long, help: "New location.")
    var location: String?

    @Option(name: .long, help: "New notes.")
    var notes: String?

    @Option(name: .long, help: "New URL. Must include a scheme; pass an empty string to clear it.")
    var url: String?

    @Option(name: .long, help: "Move the event to another calendar (ID or alias).")
    var calendar: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Mark as all-day (--all-day) or not (--no-all-day).")
    var allDay: Bool?

    @Option(name: .long, help: "Which occurrences to apply the edit to for recurring events: 'thisEvent' or 'futureEvents' (default: thisEvent).")
    var span: String?

    @OptionGroup var alarmOptions: AlarmOptions

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        let alarms = try alarmOptions.validated()

        var startDate: Date?
        if let start = start {
            guard let parsed = ISO8601DateFormatter().date(from: start) else {
                print(JSONOutput.error("Invalid --start date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            startDate = parsed
        }

        var endDate: Date?
        if let end = end {
            guard let parsed = ISO8601DateFormatter().date(from: end) else {
                print(JSONOutput.error("Invalid --end date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            endDate = parsed
        }

        guard title != nil || startDate != nil || endDate != nil || location != nil
            || notes != nil || url != nil || allDay != nil || calendar != nil
            || alarmOptions.isPresent else {
            print(JSONOutput.error(
                "Nothing to change — pass at least one of --title/--start/--end/--location/--notes/--url/--all-day/--calendar/--alarm/--clear-alarms"
            ).toJSON())
            throw ExitCode.failure
        }

        let ekSpan: EKSpan
        switch span ?? "thisEvent" {
        case "thisEvent":
            ekSpan = .thisEvent
        case "futureEvents":
            ekSpan = .futureEvents
        default:
            print(JSONOutput.error("Invalid --span value. Use 'thisEvent' or 'futureEvents'.").toJSON())
            throw ExitCode.failure
        }

        let calendarID = calendar.map { ConfigManager.resolveAlias($0) }

        let result = manager.editEvent(
            eventID: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            url: url,
            allDay: allDay,
            calendarID: calendarID,
            span: ekSpan,
            alarms: alarms,
            clearAlarms: alarmOptions.clearAlarms
        )
        try result.emit()
    }
}

struct EditReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Edit an existing reminder. Only the options you pass are changed."
    )

    @Argument(help: "The reminder ID to edit.")
    var id: String

    @Option(name: .long, help: "New reminder title.")
    var title: String?

    @Option(name: .long, help: "New due date in ISO8601 format.")
    var due: String?

    @Flag(name: .long, help: "Clear the due date.")
    var clearDue: Bool = false

    @Option(name: .long, help: "Priority (0=none, 1=high, 5=medium, 9=low).")
    var priority: Int?

    @Option(name: .long, help: "New notes.")
    var notes: String?

    @Option(name: .long, help: "Move the reminder to another reminder list (ID or alias).")
    var list: String?

    @Option(name: .long, help: "New URL. Must include a scheme; pass an empty string to clear it.")
    var url: String?

    @OptionGroup var locationOptions: LocationOptions

    @Flag(name: .long, help: "Remove the location trigger, leaving time alarms alone.")
    var clearLocation: Bool = false

    @OptionGroup var alarmOptions: AlarmOptions

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        let alarms = try alarmOptions.validated()

        guard title != nil || due != nil || clearDue || priority != nil || notes != nil || list != nil
            || url != nil || locationOptions.isPresent || clearLocation || alarmOptions.isPresent else {
            print(JSONOutput.error(
                "Nothing to change — pass at least one of --title/--due/--clear-due/--priority/--notes/--list/--url/--location/--radius/--proximity/--clear-location/--alarm/--clear-alarms"
            ).toJSON())
            throw ExitCode.failure
        }

        let coordinate = try locationOptions.validatedCoordinate()
        let proximity = try locationOptions.validatedProximity()

        if clearLocation && locationOptions.isPresent {
            print(JSONOutput.error("Cannot specify both --clear-location and other location options.").toJSON())
            throw ExitCode.failure
        }

        var dueDate: Date?
        if let due = due {
            guard let parsed = ISO8601DateFormatter().date(from: due) else {
                print(JSONOutput.error("Invalid --due date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            dueDate = parsed
        }

        if dueDate != nil && clearDue {
            print(JSONOutput.error("Cannot specify both --due and --clear-due.").toJSON())
            throw ExitCode.failure
        }

        let listID = list.map { ConfigManager.resolveAlias($0) }

        let result = manager.editReminder(
            reminderID: id,
            title: title,
            dueDate: dueDate,
            clearDue: clearDue,
            priority: priority,
            notes: notes,
            listID: listID,
            location: locationOptions.location,
            coordinate: coordinate,
            radius: locationOptions.radius,
            proximity: proximity,
            clearLocation: clearLocation,
            url: url,
            alarms: alarms,
            clearAlarms: alarmOptions.clearAlarms
        )
        try result.emit()
    }
}

// MARK: - Delete Commands

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete an event, reminder, or reminder list.",
        subcommands: [DeleteEvent.self, DeleteReminder.self, DeleteList.self]
    )
}

struct DeleteList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Delete a reminder list. Refuses a list that still holds reminders unless --force."
    )

    @Argument(help: "The reminder list ID, alias, or title.")
    var list: String

    @Flag(name: .long, help: "Delete the list even though it still holds reminders. They go with it.")
    var force: Bool = false

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        try manager.deleteReminderList(ConfigManager.resolveAlias(list), force: force).emit()
    }
}

struct DeleteEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Delete a calendar event."
    )

    @Argument(help: "The event ID to delete.")
    var eventID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.deleteEvent(eventID: eventID)
        try result.emit()
    }
}

struct DeleteReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Delete a reminder."
    )

    @Argument(help: "The reminder ID to delete.")
    var reminderID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.deleteReminder(reminderID: reminderID)
        try result.emit()
    }
}

// MARK: - Complete Command

struct Complete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mark items as completed.",
        subcommands: [CompleteReminder.self]
    )
}

struct CompleteReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Mark a reminder as completed."
    )

    @Argument(help: "The reminder ID to complete.")
    var reminderID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.completeReminder(reminderID: reminderID)
        try result.emit()
    }
}

// MARK: - Alias Commands

struct Alias: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage calendar and reminder list aliases.",
        subcommands: [AliasSet.self, AliasRemove.self, AliasList.self]
    )
}

struct AliasSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Create or update an alias for a calendar or reminder list."
    )

    @Argument(help: "The alias name (e.g., 'work', 'personal', 'groceries').")
    var name: String

    @Argument(help: "The calendar or reminder list ID.")
    var id: String

    func run() throws {
        do {
            try ConfigManager.setAlias(name: name, id: id)
            try JSONOutput.success([
                "status": "success",
                "message": "Alias '\(name)' set successfully",
                "alias": [
                    "name": name,
                    "id": id
                ]
            ]).emit()
        } catch {
            print(JSONOutput.error("Failed to save alias: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }
    }
}

struct AliasRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an alias."
    )

    @Argument(help: "The alias name to remove.")
    var name: String

    func run() throws {
        do {
            let removed = try ConfigManager.removeAlias(name: name)
            if removed {
                try JSONOutput.success([
                    "status": "success",
                    "message": "Alias '\(name)' removed successfully"
                ]).emit()
            } else {
                print(JSONOutput.error("Alias '\(name)' not found").toJSON())
                throw ExitCode.failure
            }
        } catch let error where !(error is ExitCode) {
            print(JSONOutput.error("Failed to remove alias: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }
    }
}

struct AliasList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configured aliases."
    )

    func run() throws {
        let aliases = ConfigManager.getAliases()
        var aliasList: [[String: String]] = []

        for (name, id) in aliases.sorted(by: { $0.key < $1.key }) {
            aliasList.append(["name": name, "id": id])
        }

        try JSONOutput.success([
            "aliases": aliasList,
            "count": aliasList.count,
            "configPath": ConfigManager.configPath()
        ]).emit()
    }
}
