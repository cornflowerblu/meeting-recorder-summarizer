import AWSClientRuntime
import Foundation

/// AWS service configuration and client management
struct AWSConfig {

  // MARK: - Regional Configuration

  static let defaultRegion: String = "us-east-1"

  @MainActor
  static var region: String {
    Config.shared.awsRegion
  }

  // MARK: - Service Endpoints

  @MainActor
  static var s3BucketName: String {
    Config.shared.s3BucketName
  }

  @MainActor
  static var dynamoDBTableName: String {
    Config.shared.dynamoDBTableName
  }

  // MARK: - Firebase Auth + STS Configuration

  static let stsRoleArn = "arn:aws:iam::123456789012:role/MeetingRecorderFederatedRole"
  static let stsRoleSessionName = "MeetingRecorderSession"
  static let firebaseProjectId = "meeting-recorder-1323c"

  // MARK: - S3 Configuration

  struct S3Config {
    static let storageClass: String = "STANDARD"
    static let serverSideEncryption: String = "AES256"

    // Object key patterns
    static func userPrefix(userId: String) -> String {
      "users/\(userId)/"
    }

    static func chunkKey(userId: String, recordingId: String, chunkId: String) -> String {
      "\(userPrefix(userId: userId))chunks/\(recordingId)/\(chunkId).mp4"
    }

    static func videoKey(userId: String, recordingId: String) -> String {
      "\(userPrefix(userId: userId))videos/\(recordingId).mp4"
    }

    static func audioKey(userId: String, recordingId: String) -> String {
      "\(userPrefix(userId: userId))audio/\(recordingId).mp3"
    }

    static func transcriptKey(userId: String, recordingId: String) -> String {
      "\(userPrefix(userId: userId))transcripts/\(recordingId).json"
    }

    static func summaryKey(userId: String, recordingId: String) -> String {
      "\(userPrefix(userId: userId))summaries/\(recordingId).json"
    }
  }

  // MARK: - DynamoDB Configuration

  struct DynamoDB {
    @MainActor
    static var tableName: String {
      Config.shared.dynamoDBTableName
    }

    // Key patterns
    static func partitionKey(userId: String, recordingId: String) -> String {
      "\(userId)#\(recordingId)"
    }

    static let sortKey = "METADATA"

    // GSI names
    static let dateSearchIndexName = "DateSearchIndex"
    static let participantSearchIndexName = "ParticipantSearchIndex"
    static let tagSearchIndexName = "TagSearchIndex"
  }

  // MARK: - Retry Configuration

  struct Retry {
    static let maxAttempts = 3
    static let baseDelaySeconds: TimeInterval = 1.0
    static let maxDelaySeconds: TimeInterval = 60.0
    static let backoffMultiplier = 2.0

    static func calculateDelay(attempt: Int) -> TimeInterval {
      let delay = baseDelaySeconds * pow(backoffMultiplier, Double(attempt - 1))
      return min(delay, maxDelaySeconds)
    }
  }

  // MARK: - Upload Configuration

  struct Upload {
    static let multipartThresholdBytes: Int64 = 5 * 1024 * 1024  // 5 MB
    static let partSizeBytes: Int64 = 5 * 1024 * 1024  // 5 MB parts
    static let maxConcurrentUploads = 3
    static let uploadTimeoutSeconds: TimeInterval = 300  // 5 minutes

    @MainActor
    static var chunkSize: Int64 {
      Int64(Config.shared.chunkDurationSeconds * 1024 * 1024)  // Rough estimate
    }
  }

  // MARK: - Security Configuration

  struct Security {
    // Ensure all traffic uses TLS 1.2+
    static let minimumTLSVersion = "1.2"

    // Session token expiration buffer
    static let tokenExpirationBufferMinutes = 10

    // Local credential cache duration
    static let credentialCacheMinutes = 55  // Less than 1-hour STS limit
  }
}
