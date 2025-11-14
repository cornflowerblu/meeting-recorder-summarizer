import XCTest
import AWSDynamoDB
@testable import MeetingRecorder

/// Unit tests for CatalogService (DynamoDB integration)
///
/// Tests verify:
/// - DynamoDB item creation and updates
/// - Partition key format (user_id#recording_id)
/// - Required attributes and schema
/// - User isolation
/// - Error handling
/// - Query operations
///
/// Uses mock DynamoDB client for fast, isolated testing
final class CatalogServiceTests: XCTestCase {
    var catalogService: CatalogService!
    var mockDynamoDB: MockDynamoDBClient!
    let testUserId = "test-user-123"
    let testRecordingId = "rec-test-001"

    override func setUp() async throws {
        mockDynamoDB = MockDynamoDBClient()
        catalogService = CatalogService(
            dynamoDBClient: mockDynamoDB,
            userId: testUserId
        )
    }

    override func tearDown() async throws {
        catalogService = nil
        mockDynamoDB = nil
    }

    // MARK: - Item Creation Tests

    func testCreateSessionWithRequiredAttributes() async throws {
        // Given
        let createdAt = Date()
        let expectedS3Prefix = "users/\(testUserId)/raw-chunks/\(testRecordingId)/"

        // When
        let item = try await catalogService.createSession(
            recordingId: testRecordingId,
            createdAt: createdAt
        )

        // Then
        XCTAssertEqual(item.recordingId, testRecordingId)
        XCTAssertEqual(item.userId, testUserId)
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.durationMs, 0)
        XCTAssertEqual(item.s3Paths.chunksPrefix, expectedS3Prefix)
        XCTAssertNil(item.s3Paths.videoPath)
        XCTAssertNil(item.s3Paths.audioPath)
        XCTAssertNil(item.s3Paths.transcriptPath)
        XCTAssertNil(item.s3Paths.summaryPath)

        // Verify DynamoDB was called
        XCTAssertEqual(mockDynamoDB.putItemCallCount, 1)
        XCTAssertNotNil(mockDynamoDB.lastPutItem)
    }

    func testPartitionKeyFormat() async throws {
        // Given
        let createdAt = Date()

        // When
        _ = try await catalogService.createSession(
            recordingId: testRecordingId,
            createdAt: createdAt
        )

        // Then
        guard let item = mockDynamoDB.lastPutItem else {
            XCTFail("No item was put to DynamoDB")
            return
        }

        // Verify partition key format: user_id#recording_id
        let expectedPK = "\(testUserId)#\(testRecordingId)"
        XCTAssertEqual(item["pk"]?.stringValue, expectedPK)
        XCTAssertEqual(item["sk"]?.stringValue, "METADATA")
    }

    func testRequiredAttributesPresent() async throws {
        // Given
        let createdAt = Date()

        // When
        _ = try await catalogService.createSession(
            recordingId: testRecordingId,
            createdAt: createdAt
        )

        // Then
        guard let item = mockDynamoDB.lastPutItem else {
            XCTFail("No item was put to DynamoDB")
            return
        }

        // Verify all required attributes
        XCTAssertNotNil(item["pk"])
        XCTAssertNotNil(item["sk"])
        XCTAssertNotNil(item["recording_id"])
        XCTAssertNotNil(item["user_id"])
        XCTAssertNotNil(item["created_at"])
        XCTAssertNotNil(item["status"])
        XCTAssertNotNil(item["duration_ms"])
        XCTAssertNotNil(item["s3_paths"])
    }

    func testInitialStatusIsPending() async throws {
        // Given
        let createdAt = Date()

        // When
        let item = try await catalogService.createSession(
            recordingId: testRecordingId,
            createdAt: createdAt
        )

        // Then
        XCTAssertEqual(item.status, .pending)

        guard let dbItem = mockDynamoDB.lastPutItem else {
            XCTFail("No item was put to DynamoDB")
            return
        }

        XCTAssertEqual(dbItem["status"]?.stringValue, "pending")
    }

    // MARK: - Update Tests

    func testUpdateSessionDuration() async throws {
        // Given - Create initial session
        let createdAt = Date()
        _ = try await catalogService.createSession(
            recordingId: testRecordingId,
            createdAt: createdAt
        )

        // When - Update duration
        let durationMs: Int64 = 180_000 // 3 minutes
        try await catalogService.updateSession(
            recordingId: testRecordingId,
            duration: TimeInterval(durationMs) / 1000.0,
            status: .uploading
        )

        // Then
        XCTAssertEqual(mockDynamoDB.updateItemCallCount, 1)

        guard let updateExpression = mockDynamoDB.lastUpdateExpression else {
            XCTFail("No update expression")
            return
        }

        XCTAssertTrue(updateExpression.contains("duration_ms"))
        XCTAssertTrue(updateExpression.contains("status"))
    }

    func testUpdateSessionStatus() async throws {
        // Given
        let createdAt = Date()
        _ = try await catalogService.createSession(
            recordingId: testRecordingId,
            createdAt: createdAt
        )

        // When - Update to uploading
        try await catalogService.updateSession(
            recordingId: testRecordingId,
            duration: 120.0,
            status: .uploading
        )

        // Then
        XCTAssertEqual(mockDynamoDB.updateItemCallCount, 1)

        // When - Update to completed
        try await catalogService.updateSession(
            recordingId: testRecordingId,
            duration: 120.0,
            status: .completed
        )

        // Then
        XCTAssertEqual(mockDynamoDB.updateItemCallCount, 2)
    }

    func testUpdateNonExistentSession() async throws {
        // Given - Mock DynamoDB to simulate item not found
        mockDynamoDB.shouldThrowItemNotFound = true

        // When/Then - Should throw error
        do {
            try await catalogService.updateSession(
                recordingId: "non-existent-rec",
                duration: 60.0,
                status: .completed
            )
            XCTFail("Should have thrown error for non-existent item")
        } catch {
            // Expected error
            XCTAssertTrue(error is CatalogError)
        }
    }

    // MARK: - Query Tests

    func testListSessions() async throws {
        // Given - Create multiple sessions
        let recordings = [
            ("rec-001", Date().addingTimeInterval(-3600)),
            ("rec-002", Date().addingTimeInterval(-1800)),
            ("rec-003", Date())
        ]

        for (recId, createdAt) in recordings {
            _ = try await catalogService.createSession(
                recordingId: recId,
                createdAt: createdAt
            )
        }

        // Mock query response - DynamoDB returns in descending order (most recent first)
        // because scanIndexForward: false is set in the query
        mockDynamoDB.mockQueryItems = recordings.reversed().map { recId, createdAt in
            [
                "pk": .s("\(testUserId)#\(recId)"),
                "sk": .s("METADATA"),
                "recording_id": .s(recId),
                "user_id": .s(testUserId),
                "created_at": .s(ISO8601DateFormatter().string(from: createdAt)),
                "status": .s("pending"),
                "duration_ms": .n("0"),
                "s3_paths": .m([
                    "chunks_prefix": .s("users/\(testUserId)/raw-chunks/\(recId)/")
                ])
            ]
        }

        // When
        let items = try await catalogService.listSessions()

        // Then
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(mockDynamoDB.queryCallCount, 1)

        // Verify items are sorted by created_at descending (most recent first)
        XCTAssertEqual(items[0].recordingId, "rec-003")
        XCTAssertEqual(items[1].recordingId, "rec-002")
        XCTAssertEqual(items[2].recordingId, "rec-001")
    }

    func testListSessionsEmptyResult() async throws {
        // Given - No sessions
        mockDynamoDB.mockQueryItems = []

        // When
        let items = try await catalogService.listSessions()

        // Then
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(mockDynamoDB.queryCallCount, 1)
    }

    func testListSessionsUsesGSI() async throws {
        // Given
        mockDynamoDB.mockQueryItems = []

        // When
        _ = try await catalogService.listSessions()

        // Then - Verify query used GSI-1 (DateSearch)
        guard let indexName = mockDynamoDB.lastQueryIndexName else {
            XCTFail("Query should have specified an index")
            return
        }

        XCTAssertEqual(indexName, "DateSearch")
    }

    // MARK: - User Isolation Tests

    func testUserIsolation() async throws {
        // Given - Two different users
        let user1 = "user-alice"
        let user2 = "user-bob"

        let service1 = CatalogService(dynamoDBClient: mockDynamoDB, userId: user1)
        let service2 = CatalogService(dynamoDBClient: mockDynamoDB, userId: user2)

        // When - Create sessions for both users
        _ = try await service1.createSession(recordingId: "rec-001", createdAt: Date())
        _ = try await service2.createSession(recordingId: "rec-002", createdAt: Date())

        // Then - Verify partition keys include user IDs
        XCTAssertEqual(mockDynamoDB.putItemCallCount, 2)

        let items = mockDynamoDB.allPutItems
        XCTAssertEqual(items[0]["pk"]?.stringValue, "\(user1)#rec-001")
        XCTAssertEqual(items[1]["pk"]?.stringValue, "\(user2)#rec-002")
    }

    // MARK: - Error Handling Tests

    func testNetworkErrorHandling() async throws {
        // Given - Mock DynamoDB to throw network error
        mockDynamoDB.shouldThrowNetworkError = true

        // When/Then
        do {
            _ = try await catalogService.createSession(
                recordingId: testRecordingId,
                createdAt: Date()
            )
            XCTFail("Should have thrown network error")
        } catch {
            XCTAssertTrue(error is CatalogError)
            if case .networkError = error as? CatalogError {
                // Expected
            } else {
                XCTFail("Expected CatalogError.networkError")
            }
        }
    }

    func testCredentialsExpiredHandling() async throws {
        // Given - Mock DynamoDB to throw credentials error
        mockDynamoDB.shouldThrowCredentialsExpired = true

        // When/Then
        do {
            _ = try await catalogService.createSession(
                recordingId: testRecordingId,
                createdAt: Date()
            )
            XCTFail("Should have thrown credentials error")
        } catch {
            XCTAssertTrue(error is CatalogError)
            if case .credentialsExpired = error as? CatalogError {
                // Expected
            } else {
                XCTFail("Expected CatalogError.credentialsExpired")
            }
        }
    }

    func testInvalidDataHandling() async throws {
        // Given - Mock query returns invalid data
        mockDynamoDB.mockQueryItems = [
            [
                "pk": .s("invalid"),
                // Missing required fields
            ]
        ]

        // When/Then
        do {
            _ = try await catalogService.listSessions()
            // Should either return empty array or throw
        } catch {
            // Expected - invalid data should be handled gracefully
            XCTAssertTrue(error is CatalogError)
        }
    }

    // MARK: - Optional Fields Tests

    func testCreateSessionWithOptionalFields() async throws {
        // Given
        let createdAt = Date()

        // When
        let item = try await catalogService.createSession(
            recordingId: testRecordingId,
            createdAt: createdAt,
            title: "Team Standup",
            participants: ["Alice", "Bob"],
            tags: ["standup", "team-alpha"]
        )

        // Then
        XCTAssertEqual(item.title, "Team Standup")
        XCTAssertEqual(item.participants, ["Alice", "Bob"])
        XCTAssertEqual(item.tags, ["standup", "team-alpha"])

        guard let dbItem = mockDynamoDB.lastPutItem else {
            XCTFail("No item was put to DynamoDB")
            return
        }

        XCTAssertEqual(dbItem["title"]?.stringValue, "Team Standup")
        XCTAssertNotNil(dbItem["participants"])
        XCTAssertNotNil(dbItem["tags"])
    }
}

// MARK: - Mock DynamoDB Client

typealias DynamoDBAttributeValue = AWSDynamoDB.DynamoDBClientTypes.AttributeValue

/// Mock DynamoDB client for testing
final class MockDynamoDBClient: DynamoDBClientProtocol, @unchecked Sendable {
    var putItemCallCount = 0
    var updateItemCallCount = 0
    var queryCallCount = 0

    var lastPutItem: [String: DynamoDBAttributeValue]?
    var allPutItems: [[String: DynamoDBAttributeValue]] = []
    var lastUpdateExpression: String?
    var lastQueryIndexName: String?

    var mockQueryItems: [[String: DynamoDBAttributeValue]] = []

    var shouldThrowNetworkError = false
    var shouldThrowCredentialsExpired = false
    var shouldThrowItemNotFound = false

    func putItem(input: AWSDynamoDB.PutItemInput) async throws -> AWSDynamoDB.PutItemOutput {
        if shouldThrowNetworkError {
            throw CatalogError.networkError("Mock network error")
        }
        if shouldThrowCredentialsExpired {
            throw CatalogError.credentialsExpired
        }

        putItemCallCount += 1
        lastPutItem = input.item
        allPutItems.append(input.item ?? [:])

        return AWSDynamoDB.PutItemOutput()
    }

    func updateItem(input: AWSDynamoDB.UpdateItemInput) async throws -> AWSDynamoDB.UpdateItemOutput {
        if shouldThrowNetworkError {
            throw CatalogError.networkError("Mock network error")
        }
        if shouldThrowItemNotFound {
            throw CatalogError.itemNotFound(testRecordingId)
        }

        updateItemCallCount += 1
        lastUpdateExpression = input.updateExpression

        return AWSDynamoDB.UpdateItemOutput()
    }

    func query(input: AWSDynamoDB.QueryInput) async throws -> AWSDynamoDB.QueryOutput {
        if shouldThrowNetworkError {
            throw CatalogError.networkError("Mock network error")
        }

        queryCallCount += 1
        lastQueryIndexName = input.indexName

        return AWSDynamoDB.QueryOutput(items: mockQueryItems)
    }

    // Helper for tests
    private let testRecordingId = "test-rec"
}

// MARK: - AttributeValue Helper

extension DynamoDBAttributeValue {
    var stringValue: String? {
        if case .s(let value) = self {
            return value
        }
        return nil
    }

    var numberValue: Int64? {
        if case .n(let value) = self {
            return Int64(value)
        }
        return nil
    }
}
