import EventKit
import Foundation

/// A `--alarm` value, parsed and validated before EventKit ever sees it.
///
/// EventKit models an alarm two ways — a fixed instant, or an offset from the thing it is attached
/// to — and the offset form is what people actually mean by "remind me fifteen minutes before". The
/// offset is signed, and negative means *earlier*, which is the one detail worth hiding behind a
/// spelling: `15m` and `-15m` both mean fifteen minutes beforehand, because an alarm after the fact
/// is the rare case and should have to say so with `+15m`.
///
/// What the offset is measured from depends on what carries it. On an event it is the start date;
/// on a reminder it is the due date, which is why a relative alarm on an undated reminder is
/// refused rather than stored as something that can never fire.
enum AlarmSpec: Equatable {
    case relative(TimeInterval)
    case absolute(Date)

    /// A rejected `--alarm`, carrying the sentence the caller sees.
    struct ParseFailure: Error, Equatable {
        let message: String
    }

    /// A year, as the largest offset that is plausibly a real intention rather than a typo. Beyond
    /// it the likeliest reading of `--alarm 90000h` is a mistake, and an alarm quietly scheduled
    /// ten years early is indistinguishable from one that never fires.
    static let maximumOffset: TimeInterval = 365 * 24 * 3_600

    private static let units: [(suffix: String, seconds: TimeInterval)] = [
        ("w", 7 * 24 * 3_600),
        ("d", 24 * 3_600),
        ("h", 3_600),
        ("m", 60),
        ("s", 1),
    ]

    static func parse(_ raw: String) -> Result<AlarmSpec, ParseFailure> {
        func reject(_ message: String) -> Result<AlarmSpec, ParseFailure> {
            .failure(ParseFailure(message: message))
        }

        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            return reject("--alarm needs a value, e.g. '15m' (15 minutes before) or an ISO8601 instant.")
        }

        // An absolute instant is tried first: it is the only form containing a '-' that is not a
        // sign, so reading it as an offset would mangle it rather than fail.
        if let date = absoluteDate(from: value) { return .success(.absolute(date)) }

        let lowered = value.lowercased()
        var body = Substring(lowered)
        var sign: TimeInterval = -1
        if body.hasPrefix("+") {
            sign = 1
            body = body.dropFirst()
        } else if body.hasPrefix("-") {
            body = body.dropFirst()
        }

        // Zero is the one magnitude that needs no unit, because every unit of it is the same
        // instant: the alarm fires at the due date or start itself.
        if let zero = Double(body), zero == 0 { return .success(.relative(0)) }

        guard let unit = units.first(where: { body.hasSuffix($0.suffix) }) else {
            // A bare number cannot be honoured by guessing a unit: '15' meaning seconds when the
            // caller meant minutes is a silently wrong alarm, which is worse than a refusal.
            if Double(body) != nil {
                return reject(
                    "--alarm '\(raw)' has no unit. Use s/m/h/d/w, e.g. '15m' for fifteen minutes before."
                )
            }
            return reject(
                "--alarm '\(raw)' is neither an offset like '15m'/'-1h'/'+10m' nor an ISO8601 instant."
            )
        }

        let magnitude = body.dropLast(unit.suffix.count)
        guard let amount = Double(magnitude), amount.isFinite, amount >= 0 else {
            return reject("--alarm '\(raw)' does not have a number before its unit.")
        }

        let offset = sign * amount * unit.seconds
        guard abs(offset) <= maximumOffset else {
            return reject("--alarm '\(raw)' is further than a year from the event; that is almost certainly a typo.")
        }
        return .success(.relative(offset))
    }

    private static func absoluteDate(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    var isRelative: Bool {
        if case .relative = self { return true }
        return false
    }

    func alarm() -> EKAlarm {
        switch self {
        case .relative(let offset): return EKAlarm(relativeOffset: offset)
        case .absolute(let date): return EKAlarm(absoluteDate: date)
        }
    }
}

extension EKAlarm {
    /// One alarm, described for JSON output.
    ///
    /// The raw offset is reported alongside a readable form because a consumer deciding whether to
    /// change an alarm needs the number, while one reporting it to a person needs the words.
    func describedForOutput(using formatter: DateFormatter) -> [String: Any] {
        if let structuredLocation = structuredLocation {
            return [
                "type": "location",
                "title": structuredLocation.title ?? "",
                "radius": structuredLocation.radius,
                "proximity": proximity == .leave ? "depart" : "arrive",
            ]
        }
        if let absoluteDate = absoluteDate {
            return ["type": "absolute", "at": formatter.string(from: absoluteDate)]
        }
        return [
            "type": "relative",
            "offsetSeconds": relativeOffset,
            "offset": Self.describeOffset(relativeOffset),
        ]
    }

    static func describeOffset(_ offset: TimeInterval) -> String {
        if offset == 0 { return "at the time" }
        let magnitude = abs(offset)
        let units: [(String, TimeInterval)] = [
            ("week", 7 * 24 * 3_600), ("day", 24 * 3_600), ("hour", 3_600),
            ("minute", 60), ("second", 1),
        ]
        // Report in the largest unit that divides exactly, so a 15-minute alarm reads as minutes
        // rather than as 900 seconds.
        for (name, seconds) in units where magnitude >= seconds
            && magnitude.truncatingRemainder(dividingBy: seconds) == 0 {
            let count = Int(magnitude / seconds)
            let plural = count == 1 ? name : name + "s"
            return "\(count) \(plural) \(offset < 0 ? "before" : "after")"
        }
        return "\(Int(magnitude)) seconds \(offset < 0 ? "before" : "after")"
    }

    /// Whether this is a time alarm rather than a location trigger. The two are authored by separate
    /// flags and cleared separately, so every place that edits one has to leave the other alone.
    var isTimeAlarm: Bool { structuredLocation == nil }
}
