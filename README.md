# ekctl

A native macOS command-line tool for managing Calendar events and Reminders using the EventKit framework. All output is JSON, making it perfect for scripting and automation.

## Features

- List, create, edit, and delete calendar events
- List, create, edit, complete, and delete reminders
- **Location triggers** on reminders — geocoded geofences that fire on arrival or departure
- **Calendar aliases** - Use friendly names instead of long IDs
- JSON output for easy parsing and scripting
- Full EventKit integration with proper permission handling
- Support for all calendar and reminder list types (iCloud, Exchange, local, etc.)

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools or Xcode
- Swift 5.9+

## Installation

### Homebrew (Recommended)

```bash
brew tap schappim/ekctl
brew install ekctl
```

### Build from Source

```bash
# Clone the repository
git clone https://github.com/schappim/ekctl.git
cd ekctl

# Build release version
swift build -c release

# Optional: Sign with entitlements for better permission handling
codesign --force --sign - --entitlements ekctl.entitlements .build/release/ekctl

# Install to /usr/local/bin
sudo cp .build/release/ekctl /usr/local/bin/
```

### First Run

On first run, macOS will prompt you to grant access to Calendars and Reminders. You can manage these permissions later in:

**System Settings → Privacy & Security → Calendars / Reminders**

## Usage

### List Calendars

List all calendars (event calendars and reminder lists):

```bash
ekctl list calendars
```

Output:
```json
{
  "calendars": [
    {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work",
      "type": "event",
      "source": "iCloud",
      "color": "#0088FF",
      "allowsModifications": true
    },
    {
      "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
      "title": "Reminders",
      "type": "reminder",
      "source": "iCloud",
      "color": "#1BADF8",
      "allowsModifications": true
    }
  ],
  "status": "success"
}
```

### Calendar Aliases

Instead of using long calendar IDs, you can create friendly aliases:

```bash
# Set an alias for a calendar
ekctl alias set work "CA513B39-1659-4359-8FE9-0C2A3DCEF153"
ekctl alias set personal "4E367C6F-354B-4811-935E-7F25A1BB7D39"
ekctl alias set groceries "E30AE972-8F29-40AF-BFB9-E984B98B08AB"

# List all aliases
ekctl alias list

# Remove an alias
ekctl alias remove work
```

Output for `ekctl alias list`:
```json
{
  "aliases": [
    { "name": "groceries", "id": "E30AE972-8F29-40AF-BFB9-E984B98B08AB" },
    { "name": "personal", "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39" },
    { "name": "work", "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153" }
  ],
  "count": 3,
  "configPath": "/Users/you/.ekctl/config.json",
  "status": "success"
}
```

Once set, use aliases anywhere you would use a calendar ID:

```bash
# These are equivalent:
ekctl list events --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" --from ...
ekctl list events --calendar work --from ...

# Works with all commands
ekctl add event --calendar work --title "Meeting" --start ...
ekctl list reminders --list groceries
ekctl add reminder --list personal --title "Call mom"
```

Aliases are stored in `~/.ekctl/config.json`.

### List Events

List events in a calendar within a date range:

```bash
# Using calendar ID
ekctl list events \
  --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" \
  --from "2026-01-01T00:00:00Z" \
  --to "2026-01-31T23:59:59Z"

# Or using an alias (after setting one)
ekctl list events \
  --calendar work \
  --from "2026-01-01T00:00:00Z" \
  --to "2026-01-31T23:59:59Z"
```

Output:
```json
{
  "count": 2,
  "events": [
    {
      "id": "ABC123:DEF456",
      "title": "Team Meeting",
      "calendar": {
        "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
        "title": "Work"
      },
      "startDate": "2026-01-15T09:00:00Z",
      "endDate": "2026-01-15T10:00:00Z",
      "location": "Conference Room A",
      "notes": null,
      "allDay": false,
      "hasAlarms": true,
      "hasRecurrenceRules": false
    }
  ],
  "status": "success"
}
```

### Show Event Details

```bash
ekctl show event "ABC123:DEF456"
```

### Add Event

Create a new calendar event:

```bash
# Basic event (using alias)
ekctl add event \
  --calendar work \
  --title "Lunch with Client" \
  --start "2026-02-10T12:30:00Z" \
  --end "2026-02-10T13:30:00Z"

# Event with location and notes
ekctl add event \
  --calendar work \
  --title "Project Review" \
  --start "2026-02-15T14:00:00Z" \
  --end "2026-02-15T15:30:00Z" \
  --location "Building 2, Room 301" \
  --notes "Bring Q1 reports"

# All-day event (using full ID also works)
ekctl add event \
  --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" \
  --title "Company Holiday" \
  --start "2026-03-01T00:00:00Z" \
  --end "2026-03-02T00:00:00Z" \
  --all-day
```

Output:
```json
{
  "status": "success",
  "message": "Event created successfully",
  "event": {
    "id": "NEW123:EVENT456",
    "title": "Lunch with Client",
    "calendar": {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work"
    },
    "startDate": "2026-02-10T12:30:00Z",
    "endDate": "2026-02-10T13:30:00Z",
    "location": null,
    "notes": null,
    "allDay": false
  }
}
```

### Edit an Event

Update fields on an existing event without recreating it — the event's ID, alarms, recurrence, and invitation state are preserved. Only the options you pass are changed; everything else is left as-is.

```bash
# Change the title and location
ekctl edit event "ABC123:DEF456" \
  --title "Lunch with Client (moved)" \
  --location "Building 4, Room 12"

# Reschedule
ekctl edit event "ABC123:DEF456" \
  --start "2026-02-10T13:00:00Z" \
  --end "2026-02-10T14:00:00Z"

# Move to another calendar (ID or alias)
ekctl edit event "ABC123:DEF456" --calendar personal

# Turn an all-day event back into a timed event
ekctl edit event "ABC123:DEF456" \
  --no-all-day \
  --start "2026-03-01T09:00:00Z" \
  --end "2026-03-01T10:00:00Z"

# Edit a recurring event: apply the change only to this occurrence (default)
# or to this and all future occurrences
ekctl edit event "ABC123:DEF456" --title "New name" --span futureEvents
```

Output:
```json
{
  "status": "success",
  "message": "Event updated successfully",
  "event": {
    "id": "ABC123:DEF456",
    "title": "Lunch with Client (moved)",
    "calendar": {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work"
    },
    "startDate": "2026-02-10T12:30:00Z",
    "endDate": "2026-02-10T13:30:00Z",
    "location": "Building 4, Room 12",
    "notes": null,
    "allDay": false
  }
}
```

If you don't pass any field to change:
```json
{
  "status": "error",
  "error": "Nothing to change — pass at least one of --title/--start/--end/--location/--notes/--all-day/--calendar"
}
```

### Delete Event

```bash
ekctl delete event "ABC123:DEF456"
```

Output:
```json
{
  "status": "success",
  "message": "Event 'Team Meeting' deleted successfully",
  "deletedEventID": "ABC123:DEF456"
}
```

### List Reminders

List reminders in a reminder list:

```bash
# List all reminders (using alias)
ekctl list reminders --list personal

# List only incomplete reminders
ekctl list reminders --list personal --completed false

# List only completed reminders (using full ID also works)
ekctl list reminders --list "4E367C6F-354B-4811-935E-7F25A1BB7D39" --completed true
```

Output:
```json
{
  "count": 2,
  "reminders": [
    {
      "id": "REM123-456-789",
      "title": "Buy groceries",
      "list": {
        "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
        "title": "Reminders"
      },
      "dueDate": "2026-01-20T17:00:00Z",
      "completed": false,
      "priority": 0,
      "notes": null,
      "locationTrigger": null
    }
  ],
  "status": "success"
}
```

### Show Reminder Details

```bash
ekctl show reminder "REM123-456-789"
```

### Add Reminder

Create a new reminder:

```bash
# Simple reminder (using alias)
ekctl add reminder \
  --list personal \
  --title "Call the dentist"

# Reminder with due date
ekctl add reminder \
  --list personal \
  --title "Submit expense report" \
  --due "2026-01-25T09:00:00Z"

# Reminder with priority and notes
# Priority: 0=none, 1=high, 5=medium, 9=low
ekctl add reminder \
  --list groceries \
  --title "Buy milk" \
  --due "2026-02-01T12:00:00Z" \
  --priority 1 \
  --notes "Check expiration date first"

# Reminder that fires when you arrive at a place
ekctl add reminder \
  --list groceries \
  --title "Pick up the prescription" \
  --location "20500 Stevens Creek Blvd, Cupertino, CA" \
  --radius 200

# ...or when you leave one
ekctl add reminder \
  --list personal \
  --title "Text home that I'm on my way" \
  --location "San Francisco International Airport" \
  --proximity depart
```

See [Location Triggers](#location-triggers) for how the place is resolved and when to pin
coordinates yourself.

Output:
```json
{
  "status": "success",
  "message": "Reminder created successfully",
  "reminder": {
    "id": "NEWREM-123-456",
    "title": "Submit expense report",
    "list": {
      "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
      "title": "Reminders"
    },
    "dueDate": "2026-01-25T09:00:00Z",
    "completed": false,
    "priority": 0,
    "notes": null
  }
}
```

### Edit a Reminder

Update fields on an existing reminder without recreating it. Only the options you pass are changed; everything else is left as-is.

```bash
# Change the title and priority
ekctl edit reminder "REM123-456-789" \
  --title "Buy oat milk" \
  --priority 1

# Reschedule the due date
ekctl edit reminder "REM123-456-789" --due "2026-02-05T09:00:00Z"

# Clear the due date entirely
ekctl edit reminder "REM123-456-789" --clear-due

# Move to another reminder list (ID or alias)
ekctl edit reminder "REM123-456-789" --list groceries

# Set, move, or drop the location trigger
ekctl edit reminder "REM123-456-789" --location "1 Infinite Loop, Cupertino, CA"
ekctl edit reminder "REM123-456-789" --radius 400          # keeps the place and proximity
ekctl edit reminder "REM123-456-789" --proximity depart
ekctl edit reminder "REM123-456-789" --clear-location      # drops the fence, keeps time alarms
```

Output:
```json
{
  "status": "success",
  "message": "Reminder updated successfully",
  "reminder": {
    "id": "REM123-456-789",
    "title": "Buy oat milk",
    "list": {
      "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
      "title": "Reminders"
    },
    "dueDate": "2026-02-05T09:00:00Z",
    "completed": false,
    "priority": 1,
    "notes": null
  }
}
```

Passing both `--due` and `--clear-due` is rejected rather than guessed:
```json
{
  "status": "error",
  "error": "Cannot specify both --due and --clear-due."
}
```

`--clear-location` combined with any other location option is rejected the same way. `--radius` or
`--proximity` on their own adjust the existing trigger and fail on a reminder that has none.

### Location Triggers

A location reminder fires because EventKit registers a geofence around a **coordinate**. The place
name stored alongside it is only a label: nothing in Reminders.app resolves it later. So `--location`
is geocoded at write time, and a place that cannot be resolved is an error rather than a reminder
that displays an address and never goes off.

```bash
# Geocoded: the response tells you what the geocoder matched
ekctl add reminder --list personal --title "Buy stamps" --location "US Post Office, Cupertino, CA"
```
```json
{
  "status": "success",
  "message": "Reminder created successfully",
  "geocodedTo": "21701 Stevens Creek Blvd, Cupertino, CA 95014, United States",
  "reminder": {
    "id": "NEWREM-123-456",
    "title": "Buy stamps",
    "locationTrigger": {
      "title": "US Post Office, Cupertino, CA",
      "radius": 100,
      "proximity": "arrive",
      "latitude": 37.3230,
      "longitude": -122.0322
    }
  }
}
```

**Read `geocodedTo` before trusting the fence.** Apple's geocoder answers vague or garbled input with
a confident match somewhere else: `--location "qqzzxx not a real place 12345"` succeeds, landing in
Schenectady, NY, because of the ZIP code. Give it a full street address when you have one, and check
the city it echoes back.

When a place has no postal address — a backyard, a trailhead, a parking lot — pin it yourself and
skip the lookup entirely. Both coordinates are required together, along with a `--location` label:

```bash
ekctl add reminder --list personal --title "Water the tomatoes" \
  --location "Backyard" --latitude 43.6883577 --longitude -79.3142972
```

Options: `--radius` is meters (default 100; `0` hands the choice to Reminders, which is what the app
itself stores), and `--proximity` is `arrive` or `depart` — a typo is rejected rather than silently
treated as `arrive`.

Reads report the trigger too, as `locationTrigger` on every reminder (`null` when there is none).
A trigger written by ekctl before 1.3.0 has no usable coordinate; it reads back with
`"unresolved": true` and null coordinates, and `ekctl edit reminder <id> --radius 100` re-geocodes
it in place. To find them:

```bash
for id in $(ekctl list calendars | jq -r '.calendars[]|select(.type=="reminder").id'); do
  ekctl list reminders --list "$id" | jq -c '.reminders[]? | select(.locationTrigger.unresolved) | {id, title, locationTrigger}'
done
```

### Complete Reminder

Mark a reminder as completed:

```bash
ekctl complete reminder "REM123-456-789"
```

Output:
```json
{
  "status": "success",
  "message": "Reminder 'Buy groceries' marked as completed",
  "reminder": {
    "id": "REM123-456-789",
    "title": "Buy groceries",
    "completed": true,
    "completionDate": "2026-01-21T10:30:00Z"
  }
}
```

### Delete Reminder

```bash
ekctl delete reminder "REM123-456-789"
```

## Date Format

All dates use **ISO 8601** format with timezone. Examples:

| Format | Example | Description |
|--------|---------|-------------|
| UTC | `2026-01-15T09:00:00Z` | 9:00 AM UTC |
| With offset | `2026-01-15T09:00:00+10:00` | 9:00 AM AEST |
| Midnight | `2026-01-15T00:00:00Z` | Start of day |
| End of day | `2026-01-15T23:59:59Z` | End of day |

## Scripting Examples

### Get calendar ID by name

```bash
# Using jq to find a calendar by name
CALENDAR_ID=$(ekctl list calendars | jq -r '.calendars[] | select(.title == "Work") | .id')
echo $CALENDAR_ID
```

### List today's events

```bash
TODAY=$(date -u +"%Y-%m-%dT00:00:00Z")
TOMORROW=$(date -u -v+1d +"%Y-%m-%dT00:00:00Z")

ekctl list events \
  --calendar "$CALENDAR_ID" \
  --from "$TODAY" \
  --to "$TOMORROW"
```

### Create event from variables

```bash
TITLE="Sprint Planning"
START="2026-01-20T10:00:00Z"
END="2026-01-20T11:00:00Z"

ekctl add event \
  --calendar "$CALENDAR_ID" \
  --title "$TITLE" \
  --start "$START" \
  --end "$END"
```

### Count incomplete reminders

```bash
ekctl list reminders --list "$LIST_ID" --completed false | jq '.count'
```

### Export events to CSV

```bash
ekctl list events \
  --calendar "$CALENDAR_ID" \
  --from "2026-01-01T00:00:00Z" \
  --to "2026-12-31T23:59:59Z" \
  | jq -r '.events[] | [.title, .startDate, .endDate, .location // ""] | @csv'
```

## Error Handling

When an error occurs, the output includes an error message:

```json
{
  "status": "error",
  "error": "Calendar not found with ID: invalid-id"
}
```

Common errors:
- `Permission denied` - Grant access in System Settings
- `Calendar not found` - Check the calendar ID with `list calendars`
- `Invalid date format` - Use ISO 8601 format (see examples above)

## Help

Get help for any command:

```bash
ekctl --help
ekctl list --help
ekctl add event --help
ekctl edit event --help
ekctl edit reminder --help
ekctl list reminders --help
```

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
