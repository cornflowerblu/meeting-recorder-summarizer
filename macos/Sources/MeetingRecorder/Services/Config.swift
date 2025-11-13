import Foundation

/// Configuration Management
/// MR-22 (T015)
///
/// Manages application configuration from environment variables and user defaults.
struct Config {
    // MARK: - Singleton

    static let shared = Config()

    private init() {
        // Load configuration on initialization
        loadConfiguration()
    }

    // MARK: - Configuration Properties

    /// AWS configuration
    var aws = AWSConfiguration()

    /// Firebase configuration
    var firebase = FirebaseConfiguration()

    /// Recording configuration
    var recording = RecordingConfiguration()

    /// Upload configuration
    var upload = UploadConfiguration()

    // MARK: - Configuration Structures

    struct AWSConfiguration {
        var region: String = AWSConfig.region
        var s3BucketName: String = AWSConfig.s3BucketName
        var dynamoDBTableName: String = AWSConfig.dynamoDBTableName
        var authExchangeEndpoint: String = AWSConfig.authExchangeEndpoint
    }

    struct FirebaseConfiguration {
        var projectId: String = ""
        var apiKey: String = ""
        var enabled: Bool = false
    }

    struct RecordingConfiguration {
        var segmentDuration: TimeInterval = AWSConfig.recordingSegmentDuration
        var tempStoragePath: URL = AWSConfig.tempStorageDirectory
        var enableAutoCleanup: Bool = true
        var maxStorageSize: Int64 = 10 * 1024 * 1024 * 1024  // 10 GB

        // Video quality settings
        var resolution: VideoResolution = .hd1080p
        var frameRate: Int32 = 30
        var bitrate: Int = 5_000_000  // 5 Mbps
    }

    enum VideoResolution {
        case hd720p
        case hd1080p
        case uhd4k
        case custom(width: Int, height: Int)

        var size: CGSize {
            switch self {
            case .hd720p:
                return CGSize(width: 1280, height: 720)
            case .hd1080p:
                return CGSize(width: 1920, height: 1080)
            case .uhd4k:
                return CGSize(width: 3840, height: 2160)
            case .custom(let width, let height):
                return CGSize(width: width, height: height)
            }
        }

        var displayName: String {
            switch self {
            case .hd720p:
                return "720p HD"
            case .hd1080p:
                return "1080p Full HD"
            case .uhd4k:
                return "4K UHD"
            case .custom(let width, let height):
                return "\(width)×\(height)"
            }
        }
    }

    struct UploadConfiguration {
        var chunkSize: Int = AWSConfig.multipartChunkSize
        var maxRetries: Int = AWSConfig.maxUploadRetries
        var initialBackoff: TimeInterval = AWSConfig.initialBackoffDelay
        var maxBackoff: TimeInterval = AWSConfig.maxBackoffDelay
        var concurrentUploads: Int = 3
    }

    // MARK: - Configuration Loading

    private mutating func loadConfiguration() {
        // Load from environment variables (if present)
        loadFromEnvironment()

        // Load from user defaults
        loadFromUserDefaults()

        // Validate configuration
        do {
            try validate()
        } catch {
            Logger.app.error("Configuration validation failed", error: error)
        }
    }

    private mutating func loadFromEnvironment() {
        let env = ProcessInfo.processInfo.environment

        // AWS configuration
        if let region = env["AWS_REGION"] {
            aws.region = region
        }
        if let bucket = env["S3_BUCKET_NAME"] {
            aws.s3BucketName = bucket
        }
        if let table = env["DYNAMODB_TABLE_NAME"] {
            aws.dynamoDBTableName = table
        }
        if let endpoint = env["AUTH_EXCHANGE_ENDPOINT"] {
            aws.authExchangeEndpoint = endpoint
        }

        // Firebase configuration
        if let projectId = env["FIREBASE_PROJECT_ID"] {
            firebase.projectId = projectId
            firebase.enabled = true
        }
        if let apiKey = env["FIREBASE_API_KEY"] {
            firebase.apiKey = apiKey
        }

        // Recording configuration
        if let duration = env["RECORDING_SEGMENT_DURATION"], let value = TimeInterval(duration) {
            recording.segmentDuration = value
        }

        // Upload configuration
        if let chunkSize = env["UPLOAD_CHUNK_SIZE"], let value = Int(chunkSize) {
            upload.chunkSize = value
        }
        if let maxRetries = env["UPLOAD_MAX_RETRIES"], let value = Int(maxRetries) {
            upload.maxRetries = value
        }
    }

    private mutating func loadFromUserDefaults() {
        let defaults = UserDefaults.standard

        // Recording configuration
        if defaults.object(forKey: "recording.autoCleanup") != nil {
            recording.enableAutoCleanup = defaults.bool(forKey: "recording.autoCleanup")
        }
        if let maxSize = defaults.object(forKey: "recording.maxStorageSize") as? Int64 {
            recording.maxStorageSize = maxSize
        }
        if let frameRate = defaults.object(forKey: "recording.frameRate") as? Int32 {
            recording.frameRate = frameRate
        }
        if let bitrate = defaults.object(forKey: "recording.bitrate") as? Int {
            recording.bitrate = bitrate
        }
        if let resolutionRaw = defaults.string(forKey: "recording.resolution") {
            switch resolutionRaw {
            case "720p":
                recording.resolution = .hd720p
            case "1080p":
                recording.resolution = .hd1080p
            case "4k":
                recording.resolution = .uhd4k
            default:
                break
            }
        }

        // Upload configuration
        if let concurrentUploads = defaults.object(forKey: "upload.concurrentUploads") as? Int {
            upload.concurrentUploads = concurrentUploads
        }
    }

    // MARK: - Configuration Persistence

    func saveToUserDefaults() {
        let defaults = UserDefaults.standard

        // Recording configuration
        defaults.set(recording.enableAutoCleanup, forKey: "recording.autoCleanup")
        defaults.set(recording.maxStorageSize, forKey: "recording.maxStorageSize")
        defaults.set(recording.frameRate, forKey: "recording.frameRate")
        defaults.set(recording.bitrate, forKey: "recording.bitrate")

        let resolutionString: String
        switch recording.resolution {
        case .hd720p:
            resolutionString = "720p"
        case .hd1080p:
            resolutionString = "1080p"
        case .uhd4k:
            resolutionString = "4k"
        case .custom:
            resolutionString = "custom"
        }
        defaults.set(resolutionString, forKey: "recording.resolution")

        // Upload configuration
        defaults.set(upload.concurrentUploads, forKey: "upload.concurrentUploads")
    }

    // MARK: - Validation

    func validate() throws {
        // Validate AWS configuration
        try AWSConfig.validate()

        // Validate recording configuration
        guard recording.segmentDuration > 0 else {
            throw ConfigError.invalidValue("recording.segmentDuration must be positive")
        }

        guard recording.maxStorageSize > 0 else {
            throw ConfigError.invalidValue("recording.maxStorageSize must be positive")
        }

        // Validate recording video quality settings
        guard recording.frameRate > 0 && recording.frameRate <= 120 else {
            throw ConfigError.invalidValue("recording.frameRate must be between 1 and 120")
        }

        guard recording.bitrate >= 1_000_000 else {
            throw ConfigError.invalidValue("recording.bitrate must be at least 1 Mbps")
        }

        let resolution = recording.resolution.size
        guard resolution.width > 0 && resolution.height > 0 else {
            throw ConfigError.invalidValue("recording.resolution must have positive dimensions")
        }

        // Validate upload configuration
        guard upload.chunkSize >= 5 * 1024 * 1024 else {
            throw ConfigError.invalidValue("upload.chunkSize must be at least 5 MB")
        }

        guard upload.maxRetries >= 0 else {
            throw ConfigError.invalidValue("upload.maxRetries must be non-negative")
        }
    }

    enum ConfigError: Error, LocalizedError {
        case invalidValue(String)
        case missingRequired(String)

        var errorDescription: String? {
            switch self {
            case .invalidValue(let message):
                return "Invalid configuration value: \(message)"
            case .missingRequired(let key):
                return "Missing required configuration: \(key)"
            }
        }
    }
}
