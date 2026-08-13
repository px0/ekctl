import CoreLocation
import Foundation

/// Turns a place name or street address into the coordinate a reminder's geofence needs.
///
/// A location reminder fires because EventKit registers a geofence around a coordinate. The
/// structured location's title is only a label: nothing in Reminders.app or on iOS resolves it to a
/// coordinate later, so a trigger saved without one is a reminder that displays an address and never
/// goes off. Every location we write therefore carries a coordinate, either supplied explicitly or
/// obtained here.
enum LocationResolver {
    /// Why a place could not be pinned to a coordinate, phrased for the CLI's JSON error.
    struct Failure: Error {
        let message: String
    }

    /// A geocoded place: where it is, and what the geocoder thought it was.
    ///
    /// `matchedAddress` is reported back to the caller because Apple's geocoder answers vague or
    /// garbled input with a confident match somewhere else entirely — "qqzzxx not a real place
    /// 12345" resolves to Schenectady, NY, on the strength of the ZIP code alone. Showing the match
    /// is the only way a caller can tell a good fence from a plausible-looking wrong one.
    struct ResolvedPlace {
        let location: CLLocation
        let matchedAddress: String?
    }

    /// Geocodes `address` and returns the place, or a message explaining why it could not.
    ///
    /// CLGeocoder delivers its completion on the main queue, so a semaphore would deadlock the CLI's
    /// only thread. Pumping the run loop instead lets the callback land while we wait.
    static func resolve(_ address: String, timeout: TimeInterval = 15) -> Result<ResolvedPlace, Failure> {
        let geocoder = CLGeocoder()
        var outcome: Result<ResolvedPlace, Failure>?

        geocoder.geocodeAddressString(address) { placemarks, error in
            if let error = error {
                outcome = .failure(Failure(message: describe(error, address: address)))
                return
            }
            guard let placemark = placemarks?.first, let location = placemark.location else {
                outcome = .failure(Failure(message: "No place matched '\(address)'."))
                return
            }
            outcome = .success(ResolvedPlace(
                location: location,
                matchedAddress: format(placemark)
            ))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard let outcome = outcome else {
            geocoder.cancelGeocode()
            return .failure(Failure(message: "Geocoding '\(address)' timed out after \(Int(timeout))s."))
        }
        return outcome
    }

    /// A one-line rendering of what the geocoder matched, specific enough to spot a wrong city.
    private static func format(_ placemark: CLPlacemark) -> String? {
        let parts = [
            placemark.name,
            placemark.locality,
            placemark.administrativeArea,
            placemark.postalCode,
            placemark.country
        ].compactMap { $0 }.filter { !$0.isEmpty }

        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    private static func describe(_ error: Error, address: String) -> String {
        guard let clError = error as? CLError else {
            return "Could not geocode '\(address)': \(error.localizedDescription)"
        }
        switch clError.code {
        case .geocodeFoundNoResult, .geocodeFoundPartialResult:
            return "No place matched '\(address)'."
        case .network:
            return "Geocoding '\(address)' failed: no network connection to Apple's geocoder."
        default:
            return "Could not geocode '\(address)': \(clError.localizedDescription)"
        }
    }
}
