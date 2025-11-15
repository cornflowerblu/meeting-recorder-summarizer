//
//  CatalogService.swift
//  MeetingRecorder
//
//  DynamoDB-backed catalog for recording session metadata
//

import Foundation
import AWSDynamoDB

// MARK: - Recording Status

enum RecordingStatus: String, Sendable, Codable {
    case pending
    case recording
    case processing
    case completed
    case failed
}

// MARK: - Recording Session

struct RecordingSession: Sendable, Codable {
    let recordingId: String
    let userId: String
    var title: String
    var participants: [String]
    var tags: [String]
    let startTime: Date
    var duration: TimeInterval
    var status: RecordingStatus
    var chunkCount: Int
    var s3Prefix: String

    // Processing results (optional)
    var transcriptS3Key: String?
    var summaryS3Key: String?
    var videoS3Key: String?
    var processingDuration: TimeInterval?
    var pipelineVersion: String?
    var modelVersions: [String: String]?

    // Timestamps
    var createdAt: Date?
    var updatedAt: Date?
}

// MARK: - Processing Results

struct ProcessingResults: Sendable {
    let transcriptS3Key: String
    let summaryS3Key: String
    let videoS3Key: String
    let processingDuration: TimeInterval
    let pipelineVersion: String
    let modelVersions: [String: String]
}

// MARK: - Catalog Service

actor CatalogService {

    // MARK: - Properties

    private let dynamoClientFactory = DynamoDBClientFactory.shared
    private let tableName: String

    // MARK: - Errors

    enum CatalogServiceError: Error, LocalizedError {
        case sessionNotFound(String)
        case dynamoDBOperationFailed(String, Error)
        case invalidSessionData(String)

        var errorDescription: String? {
            switch self {
            case .sessionNotFound(let recordingId):
                return "Session not found: \(recordingId)"
            case .dynamoDBOperationFailed(let operation, let error):
                return "\(operation) failed: \(error.localizedDescription)"
            case .invalidSessionData(let reason):
                return "Invalid session data: \(reason)"
            }
        }
    }

    // MARK: - Initialization

    init(tableName: String? = nil) {
        self.tableName = tableName ?? AWSConfig.dynamoDBTableName

        Task {
            await Logger.shared.debug("CatalogService initialized", metadata: [
                "tableName": self.tableName
            ])
        }
    }

    // MARK: - Create Session

    func createSession(_ session: RecordingSession) async throws {
        await Logger.shared.info("Creating catalog session", metadata: [
            "recordingId": session.recordingId,
            "userId": session.userId
        ])

        let client = try await dynamoClientFactory.getClient()

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()

        // Build item
        var item: [String: AWSDynamoDB.AttributeValue] = [
            "PK": .s("\(session.userId)#\(session.recordingId)"),
            "SK": .s("METADATA"),
            "recording_id": .s(session.recordingId),
            "user_id": .s(session.userId),
            "title": .s(session.title),
            "participants": .ss(session.participants.isEmpty ? [""] : session.participants),
            "tags": .ss(session.tags.isEmpty ? [""] : session.tags),
            "start_time": .s(isoFormatter.string(from: session.startTime)),
            "duration": .n(String(session.duration)),
            "status": .s(session.status.rawValue),
            "chunk_count": .n(String(session.chunkCount)),
            "s3_prefix": .s(session.s3Prefix),
            "created_at": .s(isoFormatter.string(from: now)),
            "updated_at": .s(isoFormatter.string(from: now))
        ]

        // Add optional fields
        if let transcriptKey = session.transcriptS3Key {
            item["transcript_s3_key"] = .s(transcriptKey)
        }
        if let summaryKey = session.summaryS3Key {
            item["summary_s3_key"] = .s(summaryKey)
        }
        if let videoKey = session.videoS3Key {
            item["video_s3_key"] = .s(videoKey)
        }

        let input = PutItemInput(
            item: item,
            tableName: tableName
        )

        do {
            _ = try await client.putItem(input: input)

            await Logger.shared.info("Session created successfully", metadata: [
                "recordingId": session.recordingId
            ])
        } catch {
            await Logger.shared.error("Failed to create session", metadata: [
                "error": error.localizedDescription
            ])
            throw CatalogServiceError.dynamoDBOperationFailed("PutItem", error)
        }
    }

    // MARK: - Update Session Status

    func updateSessionStatus(
        recordingId: String,
        userId: String,
        status: RecordingStatus
    ) async throws {
        await Logger.shared.info("Updating session status", metadata: [
            "recordingId": recordingId,
            "status": status.rawValue
        ])

        let client = try await dynamoClientFactory.getClient()

        let key: [String: AWSDynamoDB.AttributeValue] = [
            "PK": .s("\(userId)#\(recordingId)"),
            "SK": .s("METADATA")
        ]

        let isoFormatter = ISO8601DateFormatter()
        let now = isoFormatter.string(from: Date())

        let input = UpdateItemInput(
            expressionAttributeNames: [
                "#status": "status",
                "#updated_at": "updated_at"
            ],
            expressionAttributeValues: [
                ":status": .s(status.rawValue),
                ":updated_at": .s(now)
            ],
            key: key,
            tableName: tableName,
            updateExpression: "SET #status = :status, #updated_at = :updated_at"
        )

        do {
            _ = try await client.updateItem(input: input)

            await Logger.shared.info("Session status updated", metadata: [
                "recordingId": recordingId,
                "status": status.rawValue
            ])
        } catch {
            await Logger.shared.error("Failed to update session status", metadata: [
                "error": error.localizedDescription
            ])
            throw CatalogServiceError.dynamoDBOperationFailed("UpdateItem", error)
        }
    }

    // MARK: - Update Session with Results

    func updateSessionWithResults(
        recordingId: String,
        userId: String,
        results: ProcessingResults,
        status: RecordingStatus
    ) async throws {
        await Logger.shared.info("Updating session with processing results", metadata: [
            "recordingId": recordingId
        ])

        let client = try await dynamoClientFactory.getClient()

        let key: [String: AWSDynamoDB.AttributeValue] = [
            "PK": .s("\(userId)#\(recordingId)"),
            "SK": .s("METADATA")
        ]

        let isoFormatter = ISO8601DateFormatter()
        let now = isoFormatter.string(from: Date())

        // Build model versions map
        var modelVersionsMap: [String: AWSDynamoDB.AttributeValue] = [:]
        for (key, value) in results.modelVersions {
            modelVersionsMap[key] = .s(value)
        }

        let input = UpdateItemInput(
            expressionAttributeNames: [
                "#status": "status",
                "#transcript_s3_key": "transcript_s3_key",
                "#summary_s3_key": "summary_s3_key",
                "#video_s3_key": "video_s3_key",
                "#processing_duration": "processing_duration",
                "#pipeline_version": "pipeline_version",
                "#model_versions": "model_versions",
                "#updated_at": "updated_at"
            ],
            expressionAttributeValues: [
                ":status": .s(status.rawValue),
                ":transcript_s3_key": .s(results.transcriptS3Key),
                ":summary_s3_key": .s(results.summaryS3Key),
                ":video_s3_key": .s(results.videoS3Key),
                ":processing_duration": .n(String(results.processingDuration)),
                ":pipeline_version": .s(results.pipelineVersion),
                ":model_versions": .m(modelVersionsMap),
                ":updated_at": .s(now)
            ],
            key: key,
            tableName: tableName,
            updateExpression: """
                SET #status = :status,
                    #transcript_s3_key = :transcript_s3_key,
                    #summary_s3_key = :summary_s3_key,
                    #video_s3_key = :video_s3_key,
                    #processing_duration = :processing_duration,
                    #pipeline_version = :pipeline_version,
                    #model_versions = :model_versions,
                    #updated_at = :updated_at
                """
        )

        do {
            _ = try await client.updateItem(input: input)

            await Logger.shared.info("Session updated with results", metadata: [
                "recordingId": recordingId
            ])
        } catch {
            await Logger.shared.error("Failed to update session with results", metadata: [
                "error": error.localizedDescription
            ])
            throw CatalogServiceError.dynamoDBOperationFailed("UpdateItem", error)
        }
    }

    // MARK: - Update Session Duration

    func updateSessionDuration(
        recordingId: String,
        userId: String,
        duration: TimeInterval
    ) async throws {
        await Logger.shared.info("Updating session duration", metadata: [
            "recordingId": recordingId,
            "duration": String(format: "%.2f", duration)
        ])

        let client = try await dynamoClientFactory.getClient()

        let key: [String: AWSDynamoDB.AttributeValue] = [
            "PK": .s("\(userId)#\(recordingId)"),
            "SK": .s("METADATA")
        ]

        let isoFormatter = ISO8601DateFormatter()
        let now = isoFormatter.string(from: Date())

        let input = UpdateItemInput(
            expressionAttributeNames: [
                "#duration": "duration",
                "#updated_at": "updated_at"
            ],
            expressionAttributeValues: [
                ":duration": .n(String(duration)),
                ":updated_at": .s(now)
            ],
            key: key,
            tableName: tableName,
            updateExpression: "SET #duration = :duration, #updated_at = :updated_at"
        )

        do {
            _ = try await client.updateItem(input: input)

            await Logger.shared.info("Session duration updated", metadata: [
                "recordingId": recordingId,
                "duration": String(format: "%.2f", duration)
            ])
        } catch {
            await Logger.shared.error("Failed to update session duration", metadata: [
                "error": error.localizedDescription
            ])
            throw CatalogServiceError.dynamoDBOperationFailed("UpdateItem", error)
        }
    }

    // MARK: - Get Session

    func getSession(recordingId: String, userId: String) async throws -> RecordingSession? {
        await Logger.shared.debug("Fetching session", metadata: [
            "recordingId": recordingId
        ])

        let client = try await dynamoClientFactory.getClient()

        let key: [String: AWSDynamoDB.AttributeValue] = [
            "PK": .s("\(userId)#\(recordingId)"),
            "SK": .s("METADATA")
        ]

        let input = GetItemInput(
            key: key,
            tableName: tableName
        )

        do {
            let output = try await client.getItem(input: input)

            guard let item = output.item, !item.isEmpty else {
                return nil
            }

            return try parseSession(from: item)
        } catch {
            await Logger.shared.error("Failed to get session", metadata: [
                "error": error.localizedDescription
            ])
            throw CatalogServiceError.dynamoDBOperationFailed("GetItem", error)
        }
    }

    // MARK: - List User Sessions

    func listUserSessions(userId: String, limit: Int = 20) async throws -> [RecordingSession] {
        await Logger.shared.debug("Listing user sessions", metadata: [
            "userId": userId,
            "limit": String(limit)
        ])

        let client = try await dynamoClientFactory.getClient()

        let input = QueryInput(
            expressionAttributeNames: [
                "#pk": "PK"
            ],
            expressionAttributeValues: [
                ":user_prefix": .s(userId)
            ],
            keyConditionExpression: "begins_with(#pk, :user_prefix)",
            limit: limit,
            scanIndexForward: false, // Descending order (newest first)
            tableName: tableName
        )

        do {
            let output = try await client.query(input: input)

            guard let items = output.items else {
                return []
            }

            var sessions: [RecordingSession] = []
            for item in items {
                do {
                    let session = try parseSession(from: item)
                    sessions.append(session)
                } catch {
                    await Logger.shared.warning("Failed to parse session item", metadata: [
                        "error": error.localizedDescription
                    ])
                }
            }

            return sessions
        } catch {
            await Logger.shared.error("Failed to list sessions", metadata: [
                "error": error.localizedDescription
            ])
            throw CatalogServiceError.dynamoDBOperationFailed("Query", error)
        }
    }

    // MARK: - Private Helpers

    private func parseSession(from item: [String: AWSDynamoDB.AttributeValue]) throws -> RecordingSession {
        let isoFormatter = ISO8601DateFormatter()

        guard let recordingId = extractString(item["recording_id"]),
              let userId = extractString(item["user_id"]),
              let title = extractString(item["title"]),
              let statusString = extractString(item["status"]),
              let status = RecordingStatus(rawValue: statusString),
              let startTimeString = extractString(item["start_time"]),
              let startTime = isoFormatter.date(from: startTimeString),
              let durationValue = extractDouble(item["duration"]),
              let chunkCount = extractInt(item["chunk_count"]),
              let s3Prefix = extractString(item["s3_prefix"]) else {
            throw CatalogServiceError.invalidSessionData("Missing required fields")
        }

        let participants = extractStringList(item["participants"]) ?? []
        let tags = extractStringList(item["tags"]) ?? []

        var session = RecordingSession(
            recordingId: recordingId,
            userId: userId,
            title: title,
            participants: participants.filter { !$0.isEmpty },
            tags: tags.filter { !$0.isEmpty },
            startTime: startTime,
            duration: durationValue,
            status: status,
            chunkCount: chunkCount,
            s3Prefix: s3Prefix
        )

        // Optional fields
        session.transcriptS3Key = extractString(item["transcript_s3_key"])
        session.summaryS3Key = extractString(item["summary_s3_key"])
        session.videoS3Key = extractString(item["video_s3_key"])
        session.processingDuration = extractDouble(item["processing_duration"])
        session.pipelineVersion = extractString(item["pipeline_version"])

        // Timestamps
        if let createdAtString = extractString(item["created_at"]) {
            session.createdAt = isoFormatter.date(from: createdAtString)
        }
        if let updatedAtString = extractString(item["updated_at"]) {
            session.updatedAt = isoFormatter.date(from: updatedAtString)
        }

        return session
    }

    private func extractString(_ attribute: AWSDynamoDB.AttributeValue?) -> String? {
        guard case .s(let value) = attribute else { return nil }
        return value
    }

    private func extractInt(_ attribute: AWSDynamoDB.AttributeValue?) -> Int? {
        guard case .n(let value) = attribute else { return nil }
        return Int(value)
    }

    private func extractDouble(_ attribute: AWSDynamoDB.AttributeValue?) -> Double? {
        guard case .n(let value) = attribute else { return nil }
        return Double(value)
    }

    private func extractStringList(_ attribute: AWSDynamoDB.AttributeValue?) -> [String]? {
        guard case .ss(let value) = attribute else { return nil }
        return value
    }
}
