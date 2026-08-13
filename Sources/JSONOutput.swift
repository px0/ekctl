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

    /// Creates an error response with the given message
    static func error(_ message: String) -> JSONOutput {
        return JSONOutput([
            "status": "error",
            "error": message
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
