import Foundation

/// AWS Configuration Constants
/// MR-18 (T011)
///
/// Provides centralized AWS configuration for the macOS app including
/// region, resource names, and service endpoints.
///
/// Runtime configuration values (bucket names, table names) are fetched from
/// AWS Systems Manager Parameter Store on first access and cached.
struct AWSConfig {
    // MARK: - AWS Region

    /// Primary AWS region for all resources
    static let region = "us-east-1"

    // MARK: - S3 Configuration

    /// S3 bucket name for meeting recordings and artifacts
    /// Fetched from SSM Parameter Store: /meeting-recorder/{environment}/s3/bucket-name
    static var s3BucketName: String {
        return RuntimeConfig.shared.s3BucketName
    }

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
    /// Fetched from SSM Parameter Store: /meeting-recorder/{environment}/dynamodb/table-name
    static var dynamoDBTableName: String {
        return RuntimeConfig.shared.dynamoDBTableName
    }

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
        // Trigger config fetch by accessing properties
        _ = s3BucketName
        _ = dynamoDBTableName

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

// MARK: - Runtime Configuration from Parameter Store

/// Manages runtime configuration fetched from AWS Systems Manager Parameter Store
/// Values are fetched on first access and cached for the lifetime of the app
final class RuntimeConfig: @unchecked Sendable {
    static let shared = RuntimeConfig()

    private var cachedS3BucketName: String?
    private var cachedDynamoDBTableName: String?
    private let queue = DispatchQueue(label: "com.meetingrecorder.runtimeconfig")

    private init() {}

    /// S3 bucket name from Parameter Store
    var s3BucketName: String {
        return queue.sync {
            if let cached = cachedS3BucketName {
                return cached
            }

            // Fetch from SSM Parameter Store
            let parameterName =
                "/\(AWSConfig.environment == "dev" ? "meeting-recorder" : "meeting-recorder")/\(AWSConfig.environment)/s3/bucket-name"

            if let value = fetchParameter(name: parameterName) {
                cachedS3BucketName = value
                return value
            }

            // Fallback to hardcoded value with warning
            Logger.app.warning(
                "Failed to fetch S3 bucket name from Parameter Store, using fallback")
            let fallback = "meeting-recorder-\(AWSConfig.environment)-recordings"
            cachedS3BucketName = fallback
            return fallback
        }
    }

    /// DynamoDB table name from Parameter Store
    var dynamoDBTableName: String {
        return queue.sync {
            if let cached = cachedDynamoDBTableName {
                return cached
            }

            // Fetch from SSM Parameter Store
            let parameterName = "/meeting-recorder/\(AWSConfig.environment)/dynamodb/table-name"

            if let value = fetchParameter(name: parameterName) {
                cachedDynamoDBTableName = value
                return value
            }

            // Fallback to hardcoded value with warning
            Logger.app.warning(
                "Failed to fetch DynamoDB table name from Parameter Store, using fallback")
            let fallback = "meeting-recorder-\(AWSConfig.environment)-meetings"
            cachedDynamoDBTableName = fallback
            return fallback
        }
    }

    /// Fetch a parameter from SSM Parameter Store
    /// TODO: Implement actual SSM API call using AWS SDK for Swift
    /// For now, returns nil to trigger fallback behavior
    private func fetchParameter(name: String) -> String? {
        // IMPLEMENTATION NOTE:
        // This needs to use the AWS SDK for Swift to call SSM GetParameter
        // Example (pseudocode):
        //
        // import AWSSSM
        //
        // let ssmClient = SSMClient(region: AWSConfig.region)
        // let input = GetParameterInput(name: name, withDecryption: false)
        //
        // do {
        //     let output = try await ssmClient.getParameter(input: input)
        //     return output.parameter?.value
        // } catch {
        //     Logger.app.error("Failed to fetch parameter from SSM", error: error)
        //     return nil
        // }
        //
        // For Phase 2, we'll return nil to use fallback values
        // This will be implemented in Phase 3 when we integrate AWS SDK

        Logger.app.debug("SSM fetch not yet implemented for parameter: \(name)")
        return nil
    }

    /// Clear cached values (useful for testing)
    func clearCache() {
        queue.sync {
            cachedS3BucketName = nil
            cachedDynamoDBTableName = nil
        }
    }
}
