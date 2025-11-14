import Foundation
import AWSSSM
import AWSClientRuntime

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
    /// Fetched from SSM Parameter Store: /meeting-recorder/{environment}/dynamodb/meetings-table-name
    static var dynamoDBTableName: String {
        return RuntimeConfig.shared.dynamoDBTableName
    }


    /// DynamoDB sort key for metadata items
    static let dynamoDBMetadataSortKey = "METADATA"

    // MARK: - Authentication Configuration

    /// Firebase auth exchange Lambda URL
    /// This Lambda exchanges Firebase ID tokens for AWS credentials
    /// Deployed via Terraform - see infra/terraform/api_gateway.tf
    static let authExchangeEndpoint: String = {
        #if DEBUG
            return "https://2d9wdaov4i.execute-api.us-east-1.amazonaws.com/auth/exchange"
        #else
            return "https://2d9wdaov4i.execute-api.us-east-1.amazonaws.com/auth/exchange" // TODO: Deploy separate prod endpoint
        #endif
    }()

    /// AWS STS session duration (1 hour)
    static let sessionDurationSeconds = 3600

    // MARK: - Upload Configuration

    /// S3 multipart upload chunk size (5 MB minimum)
    static let multipartChunkSize = 5 * 1024 * 1024  // 5 MB

    /// Maximum concurrent part uploads per file
    /// Limits parallel uploads within a single multipart upload
    static let maxConcurrentPartUploads = 3

    /// Maximum concurrent chunk uploads
    /// Limits number of chunks being uploaded simultaneously
    static let maxConcurrentChunkUploads = 3

    /// Maximum retry attempts for uploads
    static let maxUploadRetries = 3

    /// Initial backoff delay for retries (seconds)
    static let initialBackoffDelay: TimeInterval = 1.0

    /// Maximum backoff delay for retries (seconds)
    static let maxBackoffDelay: TimeInterval = 60.0

    /// KMS Key ID for server-side encryption
    /// TODO: Replace with actual KMS key ARN after infrastructure setup
    /// static let kmsKeyId = "arn:aws:kms:us-east-1:ACCOUNT:key/YOUR-KEY-ID"

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
    private let queue = DispatchQueue(label: "com.slingshotgroup.interviewcompanion.runtimeconfig")

    private init() {
        // Initialize SSM client for parameter fetching
        do {
            ssmClient = try SSMClient(region: AWSConfig.region)
        } catch {
            Logger.app.error(
                "Failed to initialize SSM client: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
        }
    }

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
            // TODO: Implement SSM parameter fetching - this is the actual deployed bucket
            let fallback = "meeting-recorder-\(AWSConfig.environment)-recordings-8bc998ca"
            cachedS3BucketName = fallback
            return fallback
        }
    }

    /// DynamoDB meetings table name from Parameter Store
    var dynamoDBTableName: String {
        return queue.sync {
            if let cached = cachedDynamoDBTableName {
                return cached
            }

            // Fetch from SSM Parameter Store
            let parameterName = "/meeting-recorder/\(AWSConfig.environment)/dynamodb/meetings-table-name"

            if let value = fetchParameter(name: parameterName) {
                cachedDynamoDBTableName = value
                return value
            }

            // Fallback to hardcoded value with warning
            Logger.app.warning(
                "Failed to fetch DynamoDB meetings table name from Parameter Store, using fallback",
                file: #file,
                function: #function,
                line: #line
            )
            let fallback = "meeting-recorder-\(AWSConfig.environment)-meetings"
            cachedDynamoDBTableName = fallback
            return fallback
        }
    }

    /// DynamoDB users table name from Parameter Store

    /// Fetch a parameter from SSM Parameter Store
    /// Uses a semaphore to block until the async AWS call completes
    /// Returns nil if SSM client is not available or fetch fails
    private func fetchParameter(name: String) -> String? {
        guard let ssmClient = ssmClient else {
            Logger.app.warning(
                "SSM client not initialized, cannot fetch parameter: \(name)",
                file: #file,
                function: #function,
                line: #line
            )
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        Task {
            do {
                let input = GetParameterInput(name: name, withDecryption: false)
                let output = try await ssmClient.getParameter(input: input)

                result = output.parameter?.value

                if let value = result {
                    Logger.app.info(
                        "Successfully fetched parameter: \(name) = \(value)",
                        file: #file,
                        function: #function,
                        line: #line
                    )
                }
            } catch {
                Logger.app.error(
                    "Failed to fetch parameter \(name): \(error.localizedDescription)",
                    file: #file,
                    function: #function,
                    line: #line
                )
            }

            semaphore.signal()
        }

        // Wait for the async call to complete (with 5 second timeout)
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    /// Clear cached values (useful for testing)
    func clearCache() {
        queue.sync {
            cachedS3BucketName = nil
            cachedDynamoDBTableName = nil
        }
    }
}
