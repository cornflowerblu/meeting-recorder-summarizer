import AWSDynamoDB
import Foundation

/// Service for managing recording catalog in DynamoDB
///
/// Provides CRUD operations for recording metadata, including:
/// - Creating session entries when recording starts
/// - Updating duration and status when recording completes
/// - Querying user's recordings sorted by date
///
/// ## DynamoDB Schema
///
/// **Table**: meetings
/// **Primary Key**: pk (Partition Key), sk (Sort Key)
/// **GSI-1 (DateSearch)**: user_id (PK), created_at (SK)
///
/// **Item Structure**:
/// ```
/// {
///   "pk": "user_id#recording_id",
///   "sk": "METADATA",
///   "recording_id": "rec-uuid",
///   "user_id": "user-uuid",
///   "created_at": "2025-11-14T10:30:00Z",
///   "duration_ms": 180000,
///   "status": "pending|uploading|processing|completed|failed",
///   "s3_paths": {
///     "chunks_prefix": "s3://bucket/users/uid/chunks/rec-id/",
///     "video_path": "s3://bucket/users/uid/videos/rec-id.mp4",
///     ...
///   },
///   "title": "Optional meeting title",
///   "participants": ["alice@example.com", "bob@example.com"],
///   "tags": ["standup", "team-alpha"]
/// }
/// ```
final class CatalogService: ObservableObject, @unchecked Sendable {
    // MARK: - Properties

    private let dynamoDBClient: any DynamoDBClientProtocol
    private let tableName: String
    private let userId: String

    // MARK: - Initialization

    init(
        dynamoDBClient: any DynamoDBClientProtocol,
        userId: String,
        tableName: String? = nil
    ) {
        self.dynamoDBClient = dynamoDBClient
        self.userId = userId
        self.tableName = tableName ?? AWSConfig.dynamoDBTableName
    }

    // MARK: - Public Methods

    /// Create a new session entry in the catalog
    ///
    /// - Parameters:
    ///   - recordingId: Unique recording identifier
    ///   - createdAt: Timestamp when recording started
    ///   - title: Optional meeting title
    ///   - participants: Optional list of participant emails
    ///   - tags: Optional list of tags for categorization
    /// - Returns: Created catalog item
    /// - Throws: CatalogError if creation fails
    func createSession(
        recordingId: String,
        createdAt: Date,
        title: String? = nil,
        participants: [String]? = nil,
        tags: [String]? = nil
    ) async throws -> CatalogItem {
        let pk = generatePartitionKey(userId: userId, recordingId: recordingId)
        let sk = "METADATA"
        let s3ChunksPrefix = AWSConfig.s3ChunksPath(userId: userId, recordingId: recordingId)

        var item: [String: DynamoDBClientTypes.AttributeValue] = [
            "pk": .s(pk),
            "sk": .s(sk),
            "recording_id": .s(recordingId),
            "user_id": .s(userId),
            "created_at": .s(ISO8601DateFormatter().string(from: createdAt)),
            "duration_ms": .n("0"),
            "status": .s(RecordingStatus.pending.rawValue),
            "s3_paths": .m([
                "chunks_prefix": .s(s3ChunksPrefix)
            ])
        ]

        // Add optional fields if provided
        if let title = title {
            item["title"] = .s(title)
        }

        if let participants = participants {
            item["participants"] = .l(participants.map { .s($0) })
        }

        if let tags = tags {
            item["tags"] = .l(tags.map { .s($0) })
        }

        let input = PutItemInput(
            item: item,
            tableName: tableName
        )

        do {
            _ = try await dynamoDBClient.putItem(input: input)

            Logger.catalog.info(
                "Created catalog entry for recording \(recordingId)",
                file: #file,
                function: #function,
                line: #line
            )

            return CatalogItem(
                recordingId: recordingId,
                userId: userId,
                createdAt: createdAt,
                durationMs: 0,
                status: .pending,
                s3Paths: S3Paths(chunksPrefix: s3ChunksPrefix),
                title: title,
                participants: participants,
                tags: tags
            )

        } catch {
            Logger.catalog.error(
                "Failed to create catalog entry: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            throw mapDynamoDBError(error)
        }
    }

    /// Update an existing session's duration and status
    ///
    /// - Parameters:
    ///   - recordingId: Recording to update
    ///   - duration: Recording duration in seconds
    ///   - status: New status
    /// - Throws: CatalogError if update fails
    func updateSession(
        recordingId: String,
        duration: TimeInterval,
        status: RecordingStatus
    ) async throws {
        let pk = generatePartitionKey(userId: userId, recordingId: recordingId)
        let sk = "METADATA"
        let durationMs = Int64(duration * 1000)

        let input = UpdateItemInput(
            expressionAttributeNames: [
                "#status": "status"
            ],
            expressionAttributeValues: [
                ":duration": .n(String(durationMs)),
                ":status": .s(status.rawValue)
            ],
            key: [
                "pk": .s(pk),
                "sk": .s(sk)
            ],
            tableName: tableName,
            updateExpression: "SET duration_ms = :duration, #status = :status"
        )

        do {
            _ = try await dynamoDBClient.updateItem(input: input)

            Logger.catalog.info(
                "Updated catalog entry for recording \(recordingId) (duration: \(String(format: "%.0f", duration))s, status: \(status.rawValue))",
                file: #file,
                function: #function,
                line: #line
            )

        } catch {
            Logger.catalog.error(
                "Failed to update catalog entry: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            throw mapDynamoDBError(error)
        }
    }

    /// List all sessions for the current user
    ///
    /// - Returns: Array of catalog items sorted by created_at descending (most recent first)
    /// - Throws: CatalogError if query fails
    func listSessions() async throws -> [CatalogItem] {
        let input = QueryInput(
            expressionAttributeValues: [
                ":user_id": .s(userId)
            ],
            indexName: "DateSearch",  // GSI-1
            keyConditionExpression: "user_id = :user_id",
            scanIndexForward: false,  // Descending order (most recent first)
            tableName: tableName
        )

        do {
            let output = try await dynamoDBClient.query(input: input)

            guard let items = output.items else {
                return []
            }

            let catalogItems = items.compactMap { item -> CatalogItem? in
                do {
                    return try parseCatalogItem(from: item)
                } catch {
                    Logger.catalog.warning(
                        "Failed to parse catalog item: \(error.localizedDescription)",
                        file: #file,
                        function: #function,
                        line: #line
                    )
                    return nil
                }
            }

            Logger.catalog.info(
                "Listed \(catalogItems.count) sessions for user \(userId)",
                file: #file,
                function: #function,
                line: #line
            )

            return catalogItems

        } catch {
            Logger.catalog.error(
                "Failed to list sessions: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            throw mapDynamoDBError(error)
        }
    }

    // MARK: - Private Methods

    private func generatePartitionKey(userId: String, recordingId: String) -> String {
        "\(userId)#\(recordingId)"
    }

    private func parseCatalogItem(from item: [String: DynamoDBClientTypes.AttributeValue]) throws -> CatalogItem {
        guard let recordingId = item["recording_id"]?.asString(),
              let userId = item["user_id"]?.asString(),
              let createdAtStr = item["created_at"]?.asString(),
              let createdAt = ISO8601DateFormatter().date(from: createdAtStr),
              let durationMsStr = item["duration_ms"]?.asNumber(),
              let durationMs = Int64(durationMsStr),
              let statusStr = item["status"]?.asString(),
              let status = RecordingStatus(rawValue: statusStr) else {
            throw CatalogError.invalidData("Missing required attributes")
        }

        // Parse S3 paths
        guard let s3PathsMap = item["s3_paths"]?.asMap() else {
            throw CatalogError.invalidData("Missing s3_paths")
        }

        let chunksPrefix = s3PathsMap["chunks_prefix"]?.asString() ?? ""
        let videoPath = s3PathsMap["video_path"]?.asString()
        let audioPath = s3PathsMap["audio_path"]?.asString()
        let transcriptPath = s3PathsMap["transcript_path"]?.asString()
        let summaryPath = s3PathsMap["summary_path"]?.asString()

        let s3Paths = S3Paths(
            chunksPrefix: chunksPrefix,
            videoPath: videoPath,
            audioPath: audioPath,
            transcriptPath: transcriptPath,
            summaryPath: summaryPath
        )

        // Parse optional fields
        let title = item["title"]?.asString()
        let participants = item["participants"]?.asList()?.compactMap { $0.asString() }
        let tags = item["tags"]?.asList()?.compactMap { $0.asString() }

        return CatalogItem(
            recordingId: recordingId,
            userId: userId,
            createdAt: createdAt,
            durationMs: durationMs,
            status: status,
            s3Paths: s3Paths,
            title: title,
            participants: participants,
            tags: tags
        )
    }

    private func mapDynamoDBError(_ error: Error) -> CatalogError {
        let errorMessage = error.localizedDescription.lowercased()

        if errorMessage.contains("network") || errorMessage.contains("connection") {
            return .networkError(error.localizedDescription)
        }

        if errorMessage.contains("credentials") || errorMessage.contains("forbidden") ||
           errorMessage.contains("unauthorized") {
            return .credentialsExpired
        }

        if errorMessage.contains("not found") || errorMessage.contains("does not exist") {
            return .itemNotFound("")
        }

        return .operationFailed(error.localizedDescription)
    }
}

// MARK: - Protocol for Testing

protocol DynamoDBClientProtocol: Sendable {
    func putItem(input: PutItemInput) async throws -> PutItemOutput
    func updateItem(input: UpdateItemInput) async throws -> UpdateItemOutput
    func query(input: QueryInput) async throws -> QueryOutput
}

extension AWSDynamoDB.DynamoDBClient: @unchecked Sendable, DynamoDBClientProtocol {}

// MARK: - AttributeValue Helpers

extension DynamoDBClientTypes.AttributeValue {
    func asString() -> String? {
        if case .s(let value) = self {
            return value
        }
        return nil
    }

    func asNumber() -> String? {
        if case .n(let value) = self {
            return value
        }
        return nil
    }

    func asMap() -> [String: DynamoDBClientTypes.AttributeValue]? {
        if case .m(let value) = self {
            return value
        }
        return nil
    }

    func asList() -> [DynamoDBClientTypes.AttributeValue]? {
        if case .l(let value) = self {
            return value
        }
        return nil
    }
}

// MARK: - Models

/// Catalog item representing a recording session
struct CatalogItem: Identifiable, Codable, Sendable {
    var id: String { recordingId }

    let recordingId: String
    let userId: String
    let createdAt: Date
    let durationMs: Int64
    let status: RecordingStatus
    let s3Paths: S3Paths
    let title: String?
    let participants: [String]?
    let tags: [String]?

    /// Duration in seconds
    var duration: TimeInterval {
        TimeInterval(durationMs) / 1000.0
    }
}

/// Recording status enum
enum RecordingStatus: String, Codable, Sendable {
    case pending
    case uploading
    case processing
    case completed
    case failed
}

/// S3 paths for recording artifacts
struct S3Paths: Codable, Sendable {
    let chunksPrefix: String
    let videoPath: String?
    let audioPath: String?
    let transcriptPath: String?
    let summaryPath: String?

    init(
        chunksPrefix: String,
        videoPath: String? = nil,
        audioPath: String? = nil,
        transcriptPath: String? = nil,
        summaryPath: String? = nil
    ) {
        self.chunksPrefix = chunksPrefix
        self.videoPath = videoPath
        self.audioPath = audioPath
        self.transcriptPath = transcriptPath
        self.summaryPath = summaryPath
    }
}

/// Catalog operation errors
enum CatalogError: Error, LocalizedError {
    case networkError(String)
    case credentialsExpired
    case itemNotFound(String)
    case invalidData(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .credentialsExpired:
            return "AWS credentials expired. Please refresh and try again."
        case .itemNotFound(let recordingId):
            return "Recording not found: \(recordingId)"
        case .invalidData(let message):
            return "Invalid data: \(message)"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        }
    }
}
