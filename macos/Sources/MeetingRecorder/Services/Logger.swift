import Foundation
import OSLog

/// Structured logging service with PII filtering and configurable levels
actor Logger {
  static let shared = Logger()

  // MARK: - Log Levels

  enum Level: String, CaseIterable, Comparable {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case critical = "critical"

    var osLogType: OSLogType {
      switch self {
      case .debug: return .debug
      case .info: return .info
      case .warning: return .default
      case .error: return .error
      case .critical: return .fault
      }
    }

    static func < (lhs: Level, rhs: Level) -> Bool {
      let order: [Level] = [.debug, .info, .warning, .error, .critical]
      guard let lhsIndex = order.firstIndex(of: lhs),
        let rhsIndex = order.firstIndex(of: rhs)
      else {
        return false
      }
      return lhsIndex < rhsIndex
    }
  }

  // MARK: - Properties

  private let osLog: OSLog
  private var minimumLogLevel: Level = .info

  // MARK: - PII Filtering

  private let piiPatterns = [
    // Email addresses
    #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#,
    // Phone numbers (basic patterns)
    #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#,
    // AWS Access Keys (basic pattern)
    #"AKIA[0-9A-Z]{16}"#,
    // Common credit card patterns
    #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#,
  ]

  private lazy var piiRegexes: [NSRegularExpression] = {
    piiPatterns.compactMap { pattern in
      try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
  }()

  // MARK: - Initialization

  private init() {
    self.osLog = OSLog(subsystem: "com.meetingrecorder.app", category: "MeetingRecorder")

    #if DEBUG
      self.minimumLogLevel = .debug
    #else
      self.minimumLogLevel = .info
    #endif
  }

  // MARK: - Public Logging Methods

  func debug(
    _ message: String, metadata: [String: String] = [:], file: String = #file,
    function: String = #function, line: Int = #line
  ) {
    log(
      level: .debug, message: message, metadata: metadata, file: file, function: function,
      line: line)
  }

  func info(
    _ message: String, metadata: [String: String] = [:], file: String = #file,
    function: String = #function, line: Int = #line
  ) {
    log(
      level: .info, message: message, metadata: metadata, file: file, function: function, line: line
    )
  }

  func warning(
    _ message: String, metadata: [String: String] = [:], file: String = #file,
    function: String = #function, line: Int = #line
  ) {
    log(
      level: .warning, message: message, metadata: metadata, file: file, function: function,
      line: line)
  }

  func error(
    _ message: String, metadata: [String: String] = [:], file: String = #file,
    function: String = #function, line: Int = #line
  ) {
    log(
      level: .error, message: message, metadata: metadata, file: file, function: function,
      line: line)
  }

  func critical(
    _ message: String, metadata: [String: String] = [:], file: String = #file,
    function: String = #function, line: Int = #line
  ) {
    log(
      level: .critical, message: message, metadata: metadata, file: file, function: function,
      line: line)
  }

  // MARK: - Core Logging

  private func log(
    level: Level,
    message: String,
    metadata: [String: String],
    file: String,
    function: String,
    line: Int
  ) {
    guard level >= minimumLogLevel else { return }

    let sanitizedMessage = filterPII(from: message)
    let sanitizedMetadata = metadata.mapValues { filterPII(from: $0) }

    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let logEntry = createLogEntry(
      level: level,
      message: sanitizedMessage,
      metadata: sanitizedMetadata,
      file: fileName,
      function: function,
      line: line
    )

    os_log("%{public}@", log: osLog, type: level.osLogType, logEntry)
  }

  // MARK: - Private Helpers

  private func filterPII(from text: String) -> String {
    var filtered = text

    for regex in piiRegexes {
      let range = NSRange(location: 0, length: filtered.count)
      filtered = regex.stringByReplacingMatches(
        in: filtered,
        options: [],
        range: range,
        withTemplate: "[REDACTED]"
      )
    }

    return filtered
  }

  private func createLogEntry(
    level: Level,
    message: String,
    metadata: [String: String],
    file: String,
    function: String,
    line: Int
  ) -> String {
    let timestamp = ISO8601DateFormatter().string(from: Date())

    var logDict: [String: Any] = [
      "timestamp": timestamp,
      "level": level.rawValue,
      "message": message,
      "source": [
        "file": file,
        "function": function,
        "line": line,
      ],
    ]

    if !metadata.isEmpty {
      logDict["metadata"] = metadata
    }

    // Convert to JSON string for structured logging
    guard
      let jsonData = try? JSONSerialization.data(withJSONObject: logDict, options: [.sortedKeys]),
      let jsonString = String(data: jsonData, encoding: .utf8)
    else {
      return "[\(level.rawValue.uppercased())] \(message)"
    }

    return jsonString
  }

  // MARK: - Configuration

  func setMinimumLogLevel(_ level: Level) {
    self.minimumLogLevel = level
  }
}
