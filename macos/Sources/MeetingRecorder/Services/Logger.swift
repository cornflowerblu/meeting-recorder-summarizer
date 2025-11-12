import Foundation
import os.log

/// Structured Logger for Meeting Recorder
/// MR-19 (T012)
///
/// Provides structured logging with multiple log levels and automatic PII filtering.
/// All logs are written to os_log for integration with Console.app and unified logging.
struct Logger {
    // MARK: - Log Categories

    private static let subsystem = "com.meetingrecorder.macos"

    /// General application logs
    static let app = Logger(category: "App")

    /// Recording-related logs
    static let recording = Logger(category: "Recording")

    /// Upload/S3-related logs
    static let upload = Logger(category: "Upload")

    /// AWS service logs
    static let aws = Logger(category: "AWS")

    /// Authentication logs
    static let auth = Logger(category: "Auth")

    /// UI-related logs
    static let ui = Logger(category: "UI")

    // MARK: - Properties

    private let osLog: OSLog

    private init(category: String) {
        self.osLog = OSLog(subsystem: Logger.subsystem, category: category)
    }

    // MARK: - Log Levels

    /// Debug-level logs (only in debug builds)
    func debug(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        #if DEBUG
            let sanitized = sanitize(message)
            let location = "\(sourceFileName(file)):\(line) \(function)"
            os_log(.debug, log: osLog, "%{public}@ - %{public}@", location, sanitized)
        #endif
    }

    /// Info-level logs
    func info(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        let sanitized = sanitize(message)
        let location = "\(sourceFileName(file)):\(line) \(function)"

        if AWSConfig.enableDetailedLogging {
            os_log(.info, log: osLog, "%{public}@ - %{public}@", location, sanitized)
        } else {
            os_log(.info, log: osLog, "%{public}@", sanitized)
        }
    }

    /// Warning-level logs
    func warning(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        let sanitized = sanitize(message)
        let location = "\(sourceFileName(file)):\(line) \(function)"
        os_log(.default, log: osLog, "⚠️ %{public}@ - %{public}@", location, sanitized)
    }

    /// Error-level logs
    func error(
        _ message: String, error: Error? = nil, file: String = #file, function: String = #function,
        line: Int = #line
    ) {
        let sanitized = sanitize(message)
        let location = "\(sourceFileName(file)):\(line) \(function)"

        if let error = error {
            let errorDescription = sanitize(error.localizedDescription)
            os_log(
                .error, log: osLog, "❌ %{public}@ - %{public}@ | Error: %{public}@", location,
                sanitized, errorDescription)
        } else {
            os_log(.error, log: osLog, "❌ %{public}@ - %{public}@", location, sanitized)
        }
    }

    /// Fatal-level logs (logs before crashing)
    func fatal(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) -> Never {
        let sanitized = sanitize(message)
        let location = "\(sourceFileName(file)):\(line) \(function)"
        os_log(.fault, log: osLog, "💀 %{public}@ - %{public}@", location, sanitized)
        fatalError(sanitized)
    }

    // MARK: - Structured Logging

    /// Log with structured data (JSON-compatible dictionary)
    func log(
        level: LogLevel, _ message: String, data: [String: Any] = [:], file: String = #file,
        function: String = #function, line: Int = #line
    ) {
        let sanitized = sanitize(message)
        let sanitizedData = sanitize(data)
        let location = "\(sourceFileName(file)):\(line) \(function)"

        let jsonData: String
        if !sanitizedData.isEmpty {
            if let jsonDataEncoded = try? JSONSerialization.data(
                withJSONObject: sanitizedData, options: .sortedKeys),
                let jsonString = String(data: jsonDataEncoded, encoding: .utf8)
            {
                jsonData = jsonString
            } else {
                jsonData = "\(sanitizedData)"
            }
        } else {
            jsonData = "{}"
        }

        switch level {
        case .debug:
            #if DEBUG
                os_log(
                    .debug, log: osLog, "%{public}@ - %{public}@ | Data: %{public}@", location,
                    sanitized, jsonData)
            #endif
        case .info:
            os_log(
                .info, log: osLog, "%{public}@ - %{public}@ | Data: %{public}@", location,
                sanitized, jsonData)
        case .warning:
            os_log(
                .default, log: osLog, "⚠️ %{public}@ - %{public}@ | Data: %{public}@", location,
                sanitized, jsonData)
        case .error:
            os_log(
                .error, log: osLog, "❌ %{public}@ - %{public}@ | Data: %{public}@", location,
                sanitized, jsonData)
        }
    }

    // MARK: - PII Sanitization

    /// Patterns that likely contain PII
    private static let piiPatterns = [
        // Email addresses
        #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#,
        // Phone numbers (basic patterns)
        #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#,
        // Credit card numbers (basic)
        #"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b"#,
        // Social Security Numbers
        #"\b\d{3}-\d{2}-\d{4}\b"#,
    ]

    /// Sanitize string by removing potential PII
    private func sanitize(_ message: String) -> String {
        var sanitized = message

        for pattern in Logger.piiPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                sanitized = regex.stringByReplacingMatches(
                    in: sanitized,
                    options: [],
                    range: NSRange(location: 0, length: sanitized.utf16.count),
                    withTemplate: "[REDACTED]"
                )
            }
        }

        return sanitized
    }

    /// Sanitize dictionary by removing known PII keys
    private func sanitize(_ data: [String: Any]) -> [String: Any] {
        let piiKeys = ["email", "phone", "password", "token", "secret", "ssn", "credit_card"]

        var sanitized = data
        for dictKey in sanitized.keys {
            for key in piiKeys {
                if dictKey.lowercased().contains(key) {
                    sanitized[dictKey] = "[REDACTED]"
                }
            }
        }
        return sanitized
    }

    /// Extract file name from file path
    private func sourceFileName(_ filePath: String) -> String {
        return (filePath as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
    }

    // MARK: - Log Level

    enum LogLevel {
        case debug
        case info
        case warning
        case error
    }
}

// MARK: - Convenience Extensions

extension Logger {
    /// Log upload event
    func logUpload(recordingId: String, chunkId: String, attempt: Int, success: Bool) {
        let data: [String: Any] = [
            "recording_id": recordingId,
            "chunk_id": chunkId,
            "attempt": attempt,
            "success": success,
        ]

        if success {
            log(level: .info, "Upload successful", data: data)
        } else {
            log(level: .warning, "Upload failed", data: data)
        }
    }

    /// Log recording event
    func logRecording(recordingId: String, action: String, duration: TimeInterval? = nil) {
        var data: [String: Any] = [
            "recording_id": recordingId,
            "action": action,
        ]

        if let duration = duration {
            data["duration_seconds"] = duration
        }

        log(level: .info, "Recording event", data: data)
    }

    /// Log processing event
    func logProcessing(recordingId: String, status: String, cost: Double? = nil) {
        var data: [String: Any] = [
            "recording_id": recordingId,
            "status": status,
        ]

        if let cost = cost {
            data["estimated_cost_usd"] = cost
        }

        log(level: .info, "Processing event", data: data)
    }
}
