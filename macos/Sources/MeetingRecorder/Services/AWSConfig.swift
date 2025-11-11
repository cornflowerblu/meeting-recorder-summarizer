import Foundation

/// AWS Configuration Constants
/// MR-18 (T011)
///
/// Provides centralized AWS configuration for the macOS app including
/// region, resource names, and service endpoints.
struct AWSConfig {
    // MARK: - AWS Region

    /// Primary AWS region for all resources
    static let region = "us-east-1"

    // MARK: - S3 Configuration

    /// S3 bucket name for meeting recordings and artifacts
    /// Format: meeting-recorder-{environment}-recordings-{suffix}
    static let s3BucketName: String = {
        #if DEBUG
        return "meeting-recorder-dev-recordings"
        #else
        return "meeting-recorder-prod-recordings"
        #endif
    }()

    /// S3 user prefix template
    /// User data is stored under: users/{user_id}/
    static func s3UserPrefix(userId: String) -> String {
        return "users/\(userId)/"
    }

    /// S3 path for raw recording chunks
    static func s3ChunksPath(userId: String, recordingId: String) -> String {
        return "\(s3UserPrefix(userId: userId))raw-chunks/\(recordingId)/"
    }

    /// S3 path for processed video
    static func s3VideoPath(userId: String, recordingId: String) -> String {
        return "\(s3UserPrefix(userId: userId))processed/\(recordingId)/video.mp4"
    }

    /// S3 path for extracted audio
    static func s3AudioPath(userId: String, recordingId: String) -> String {
        return "\(s3UserPrefix(userId: userId))audio/\(recordingId)/audio.m4a"
    }

    /// S3 path for transcript JSON
    static func s3TranscriptPath(userId: String, recordingId: String) -> String {
        return "\(s3UserPrefix(userId: userId))transcripts/\(recordingId)/transcript.json"
    }

    /// S3 path for summary JSON
    static func s3SummaryPath(userId: String, recordingId: String) -> String {
        return "\(s3UserPrefix(userId: userId))summaries/\(recordingId)/summary.json"
    }

    // MARK: - DynamoDB Configuration

    /// DynamoDB table name for meetings metadata
    /// Format: meeting-recorder-{environment}-meetings
    static let dynamoDBTableName: String = {
        #if DEBUG
        return "meeting-recorder-dev-meetings"
        #else
        return "meeting-recorder-prod-meetings"
        #endif
    }()

    /// DynamoDB partition key format
    static func dynamoDBPartitionKey(userId: String, recordingId: String) -> String {
        return "\(userId)#\(recordingId)"
    }

    /// DynamoDB sort key for metadata items
    static let dynamoDBMetadataSortKey = "METADATA"

    // MARK: - Authentication Configuration

    /// Firebase auth exchange Lambda URL
    /// This Lambda exchanges Firebase ID tokens for AWS credentials
    static let authExchangeEndpoint: String = {
        #if DEBUG
        return "https://dev-auth-exchange.execute-api.us-east-1.amazonaws.com/auth/exchange"
        #else
        return "https://auth-exchange.execute-api.us-east-1.amazonaws.com/auth/exchange"
        #endif
    }()

    /// AWS STS session duration (1 hour)
    static let sessionDurationSeconds = 3600

    // MARK: - Upload Configuration

    /// S3 multipart upload chunk size (5 MB minimum)
    static let multipartChunkSize = 5 * 1024 * 1024  // 5 MB

    /// Maximum retry attempts for uploads
    static let maxUploadRetries = 3

    /// Initial backoff delay for retries (seconds)
    static let initialBackoffDelay: TimeInterval = 1.0

    /// Maximum backoff delay for retries (seconds)
    static let maxBackoffDelay: TimeInterval = 60.0

    // MARK: - Recording Configuration

    /// Recording segment duration (60 seconds)
    static let recordingSegmentDuration: TimeInterval = 60.0

    /// Temporary storage directory for recording chunks
    static let tempStorageDirectory: URL = {
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("MeetingRecorder", isDirectory: true)
    }()

    // MARK: - Environment

    /// Current environment (dev or prod)
    static let environment: String = {
        #if DEBUG
        return "dev"
        #else
        return "prod"
        #endif
    }()

    /// Is debug build
    static let isDebug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    // MARK: - Feature Flags

    /// Enable detailed logging
    static let enableDetailedLogging: Bool = isDebug

    /// Enable cost estimation before processing
    static let enableCostEstimation = true

    /// Enable upload resume from manifest
    static let enableUploadResume = true
}

// MARK: - Configuration Validation

extension AWSConfig {
    /// Validates required configuration is present
    static func validate() throws {
        guard !s3BucketName.isEmpty else {
            throw ConfigurationError.missingConfiguration("S3 bucket name")
        }

        guard !dynamoDBTableName.isEmpty else {
            throw ConfigurationError.missingConfiguration("DynamoDB table name")
        }

        guard !authExchangeEndpoint.isEmpty else {
            throw ConfigurationError.missingConfiguration("Auth exchange endpoint")
        }

        guard !region.isEmpty else {
            throw ConfigurationError.missingConfiguration("AWS region")
        }
    }

    enum ConfigurationError: Error, LocalizedError {
        case missingConfiguration(String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration(let item):
                return "Missing required configuration: \(item)"
            }
        }
    }
}
