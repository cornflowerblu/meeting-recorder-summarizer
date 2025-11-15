import Foundation

/// Application configuration singleton providing centralized access to environment-specific settings
@MainActor
final class Config: ObservableObject {
  static let shared = Config()

  // MARK: - Environment Detection

  enum Environment: String, CaseIterable {
    case development = "Development"
    case production = "Production"

    var isProduction: Bool {
      self == .production
    }
  }

  // MARK: - Properties

  @Published private(set) var environment: Environment

  // MARK: - AWS Configuration

  var awsRegion: String {
    bundleValue(for: "AWS_REGION") ?? "us-east-1"
  }

  var s3BucketName: String {
    bundleValue(for: "AWS_S3_BUCKET") ?? "meeting-recorder-dev-recordings-8bc998ca"
  }

  var dynamoDBTableName: String {
    bundleValue(for: "AWS_DYNAMODB_TABLE") ?? "meeting-recorder-dev-meetings"
  }

  // MARK: - Firebase Configuration

  var firebaseConfigFile: String {
    bundleValue(for: "FIREBASE_CONFIG_FILE") ?? "GoogleService-Info-Dev.plist"
  }

  // MARK: - Lambda Configuration

  var authExchangeLambdaURL: String {
    bundleValue(for: "AUTH_EXCHANGE_LAMBDA_URL") ?? "https://your-api-gateway-url.execute-api.us-east-1.amazonaws.com/prod/auth/exchange"
  }

  // MARK: - Recording Settings

  var chunkDurationSeconds: TimeInterval {
    30.0  // 30-second chunks for incremental upload
  }

  var maxRecordingDurationHours: Double {
    8.0  // Maximum 8-hour recordings
  }

  var videoCompressionBitrate: Int {
    5_000_000  // 5 Mbps for 1080p
  }

  var audioCompressionBitrate: Int {
    128_000  // 128 kbps AAC
  }

  // MARK: - Upload Settings

  var uploadRetryAttempts: Int {
    3
  }

  var uploadTimeoutSeconds: TimeInterval {
    300.0  // 5 minutes per chunk
  }

  var multipartUploadThresholdBytes: Int64 {
    5_000_000  // 5 MB threshold for multipart uploads
  }

  // MARK: - Initialization

  private init() {
    // Detect environment from bundle configuration
    #if DEBUG
      self.environment = .development
    #else
      self.environment = .production
    #endif

    Task {
      await Logger.shared.info(
        "Config initialized",
        metadata: [
          "environment": environment.rawValue,
          "awsRegion": awsRegion,
          "s3Bucket": s3BucketName,
          "dynamoDBTable": dynamoDBTableName
        ])
    }
  }

  // MARK: - Private Helpers

  private func bundleValue(for key: String) -> String? {
    Bundle.main.infoDictionary?[key] as? String
  }
}
