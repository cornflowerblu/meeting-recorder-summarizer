import XCTest
import Foundation
@testable import MeetingRecorder

@MainActor
final class CatalogServiceTests: XCTestCase {
    var catalogService: CatalogService!
    var mockDynamoClient: MockDynamoDBClient!
    var mockCredentialService: MockCredentialExchangeService!
    var testRecordingId: String!
    var testUserId: String!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Generate test identifiers
        testRecordingId = "rec_test_\(UUID().uuidString)"
        testUserId = "user_test_\(UUID().uuidString)"
        
        // Initialize mock dependencies
        mockDynamoClient = MockDynamoDBClient()
        mockCredentialService = MockCredentialExchangeService()
        
        // Set up valid credentials
        mockCredentialService.mockCredentials = AWSCredentials(
            accessKeyId: "AKIA_TEST_KEY",
            secretAccessKey: "test_secret_key",
            sessionToken: "test_session_token",
            expiration: Date().addingTimeInterval(3600)
        )
        
        // Initialize catalog service
        catalogService = CatalogService(
            dynamoClient: mockDynamoClient,
            credentialService: mockCredentialService,
            tableName: "test-meetings-table"
        )
    }
    
    override func tearDown() async throws {
        catalogService = nil
        mockDynamoClient = nil
        mockCredentialService = nil
        testRecordingId = nil
        testUserId = nil
        
        try await super.tearDown()
    }
    
    // MARK: - Session Creation Tests
    
    func testCreateSessionWithValidData() async throws {
        // Given: Valid session data
        let sessionData = RecordingSession(
            recordingId: testRecordingId,
            userId: testUserId,
            title: "Test Meeting",
            participants: ["Alice", "Bob"],
            tags: ["team", "planning"],
            startTime: Date(),
            duration: 0,
            status: .pending,
            chunkCount: 0,
            s3Prefix: "users/\(testUserId)/chunks/\(testRecordingId)/"
        )
        
        // When: Creating session in catalog
        try await catalogService.createSession(sessionData)
        
        // Then: DynamoDB should receive put item request
        XCTAssertEqual(mockDynamoClient.putItemCalls.count, 1)
        
        let putCall = try XCTUnwrap(mockDynamoClient.putItemCalls.first)
        XCTAssertEqual(putCall.tableName, "test-meetings-table")
        
        // Verify item structure
        let item = putCall.item
        XCTAssertEqual(item["PK"]?.stringValue, "\(testUserId)#\(testRecordingId)")
        XCTAssertEqual(item["SK"]?.stringValue, "METADATA")
        XCTAssertEqual(item["recording_id"]?.stringValue, testRecordingId)
        XCTAssertEqual(item["user_id"]?.stringValue, testUserId)
        XCTAssertEqual(item["title"]?.stringValue, "Test Meeting")
        XCTAssertEqual(item["status"]?.stringValue, "pending")
        XCTAssertNotNil(item["created_at"]?.stringValue)
    }
    
    func testCreateSessionSetsTimestamps() async throws {
        // Given: Session data without explicit timestamps
        let sessionData = RecordingSession(
            recordingId: testRecordingId,
            userId: testUserId,
            title: "Timestamp Test",
            participants: [],
            tags: [],
            startTime: Date(),
            duration: 0,
            status: .pending,
            chunkCount: 0,
            s3Prefix: "users/\(testUserId)/chunks/\(testRecordingId)/"
        )
        
        let beforeCreation = Date()
        
        // When: Creating session
        try await catalogService.createSession(sessionData)
        
        let afterCreation = Date()
        
        // Then: Timestamps should be set appropriately
        let putCall = try XCTUnwrap(mockDynamoClient.putItemCalls.first)
        let item = putCall.item
        
        let createdAtString = try XCTUnwrap(item["created_at"]?.stringValue)
        let updatedAtString = try XCTUnwrap(item["updated_at"]?.stringValue)
        
        // Parse ISO dates
        let dateFormatter = ISO8601DateFormatter()
        let createdAt = try XCTUnwrap(dateFormatter.date(from: createdAtString))
        let updatedAt = try XCTUnwrap(dateFormatter.date(from: updatedAtString))
        
        // Verify timestamps are within reasonable range
        XCTAssertGreaterThanOrEqual(createdAt, beforeCreation)
        XCTAssertLessThanOrEqual(createdAt, afterCreation)
        XCTAssertEqual(createdAt, updatedAt) // Should be same for new records
    }
    
    func testCreateSessionWithArrayFields() async throws {
        // Given: Session with complex array data
        let participants = ["Alice Johnson", "Bob Smith", "Carol White"]
        let tags = ["quarterly", "review", "team-alpha"]
        
        let sessionData = RecordingSession(
            recordingId: testRecordingId,
            userId: testUserId,
            title: "Array Test Meeting",
            participants: participants,
            tags: tags,
            startTime: Date(),
            duration: 0,
            status: .pending,
            chunkCount: 0,
            s3Prefix: "users/\(testUserId)/chunks/\(testRecordingId)/"
        )
        
        // When: Creating session
        try await catalogService.createSession(sessionData)
        
        // Then: Arrays should be properly stored
        let putCall = try XCTUnwrap(mockDynamoClient.putItemCalls.first)
        let item = putCall.item
        
        let storedParticipants = try XCTUnwrap(item["participants"]?.listValue)
        let storedTags = try XCTUnwrap(item["tags"]?.listValue)
        
        XCTAssertEqual(storedParticipants.count, 3)
        XCTAssertEqual(storedTags.count, 3)
        
        // Verify array contents
        let participantStrings = storedParticipants.compactMap { $0.stringValue }
        let tagStrings = storedTags.compactMap { $0.stringValue }
        
        XCTAssertEqual(Set(participantStrings), Set(participants))
        XCTAssertEqual(Set(tagStrings), Set(tags))
    }
    
    // MARK: - Session Update Tests
    
    func testUpdateSessionStatus() async throws {
        // Given: Existing session
        try await createTestSession()
        
        // When: Updating status to processing
        try await catalogService.updateSessionStatus(
            recordingId: testRecordingId,
            userId: testUserId,
            status: .processing
        )
        
        // Then: DynamoDB should receive update request
        XCTAssertEqual(mockDynamoClient.updateItemCalls.count, 1)
        
        let updateCall = try XCTUnwrap(mockDynamoClient.updateItemCalls.first)
        XCTAssertEqual(updateCall.tableName, "test-meetings-table")
        
        let key = updateCall.key
        XCTAssertEqual(key["PK"]?.stringValue, "\(testUserId)#\(testRecordingId)")
        XCTAssertEqual(key["SK"]?.stringValue, "METADATA")
        
        // Verify update expression includes status and updated_at
        let updateExpression = updateCall.updateExpression
        XCTAssertTrue(updateExpression.contains("SET #status"))
        XCTAssertTrue(updateExpression.contains("#updated_at"))
        
        let expressionAttributeValues = updateCall.expressionAttributeValues
        XCTAssertEqual(expressionAttributeValues[":status"]?.stringValue, "processing")
        XCTAssertNotNil(expressionAttributeValues[":updated_at"]?.stringValue)
    }
    
    func testUpdateSessionWithProcessingResults() async throws {
        // Given: Existing session
        try await createTestSession()
        
        let processingResults = ProcessingResults(
            transcriptS3Key: "users/\(testUserId)/transcripts/\(testRecordingId).json",
            summaryS3Key: "users/\(testUserId)/summaries/\(testRecordingId).json",
            videoS3Key: "users/\(testUserId)/videos/\(testRecordingId).mp4",
            processingDuration: 120.5,
            pipelineVersion: "1.0.0",
            modelVersions: ["transcribe": "amazon-transcribe-2023", "summarize": "claude-3-sonnet"]
        )
        
        // When: Updating with processing results
        try await catalogService.updateSessionWithResults(
            recordingId: testRecordingId,
            userId: testUserId,
            results: processingResults,
            status: .completed
        )
        
        // Then: Update should include all processing metadata
        let updateCall = try XCTUnwrap(mockDynamoClient.updateItemCalls.first)
        let values = updateCall.expressionAttributeValues
        
        XCTAssertEqual(values[":status"]?.stringValue, "completed")
        XCTAssertEqual(values[":transcript_s3_key"]?.stringValue, processingResults.transcriptS3Key)
        XCTAssertEqual(values[":summary_s3_key"]?.stringValue, processingResults.summaryS3Key)
        XCTAssertEqual(values[":video_s3_key"]?.stringValue, processingResults.videoS3Key)
        XCTAssertEqual(values[":processing_duration"]?.numberValue, 120.5)
        XCTAssertEqual(values[":pipeline_version"]?.stringValue, "1.0.0")
        
        // Verify model versions map
        let modelVersionsMap = try XCTUnwrap(values[":model_versions"]?.mapValue)
        XCTAssertEqual(modelVersionsMap["transcribe"]?.stringValue, "amazon-transcribe-2023")
        XCTAssertEqual(modelVersionsMap["summarize"]?.stringValue, "claude-3-sonnet")
    }
    
    func testUpdateSessionDuration() async throws {
        // Given: Existing session
        try await createTestSession()
        
        // When: Updating duration after recording completion
        let finalDuration: TimeInterval = 1847.5 // 30:47.5
        
        try await catalogService.updateSessionDuration(
            recordingId: testRecordingId,
            userId: testUserId,
            duration: finalDuration
        )
        
        // Then: Duration should be updated
        let updateCall = try XCTUnwrap(mockDynamoClient.updateItemCalls.first)
        let values = updateCall.expressionAttributeValues
        
        XCTAssertEqual(values[":duration"]?.numberValue, finalDuration)
        XCTAssertNotNil(values[":updated_at"]?.stringValue)
    }
    
    // MARK: - Session Retrieval Tests
    
    func testGetSession() async throws {
        // Given: Existing session in DynamoDB
        let mockItem = createMockDynamoDBItem()
        mockDynamoClient.getItemResponse = mockItem
        
        // When: Retrieving session
        let session = try await catalogService.getSession(
            recordingId: testRecordingId,
            userId: testUserId
        )
        
        // Then: Should return proper session object
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.recordingId, testRecordingId)
        XCTAssertEqual(session?.userId, testUserId)
        XCTAssertEqual(session?.title, "Mock Meeting")
        XCTAssertEqual(session?.status, .completed)
        
        // Verify DynamoDB get request
        let getCall = try XCTUnwrap(mockDynamoClient.getItemCalls.first)
        XCTAssertEqual(getCall.key["PK"]?.stringValue, "\(testUserId)#\(testRecordingId)")
        XCTAssertEqual(getCall.key["SK"]?.stringValue, "METADATA")
    }
    
    func testGetNonExistentSession() async throws {
        // Given: Non-existent session
        mockDynamoClient.getItemResponse = nil
        
        // When: Retrieving session
        let session = try await catalogService.getSession(
            recordingId: "non_existent",
            userId: testUserId
        )
        
        // Then: Should return nil
        XCTAssertNil(session)
    }
    
    func testListUserSessions() async throws {
        // Given: Multiple sessions for user
        let mockItems = [
            createMockDynamoDBItem(recordingId: "rec1", title: "Meeting 1", date: "2024-01-01T10:00:00Z"),
            createMockDynamoDBItem(recordingId: "rec2", title: "Meeting 2", date: "2024-01-02T14:00:00Z"),
            createMockDynamoDBItem(recordingId: "rec3", title: "Meeting 3", date: "2024-01-03T09:00:00Z")
        ]
        mockDynamoClient.queryResponse = mockItems
        
        // When: Listing sessions
        let sessions = try await catalogService.listUserSessions(userId: testUserId, limit: 10)
        
        // Then: Should return all sessions
        XCTAssertEqual(sessions.count, 3)
        
        // Verify sessions are ordered by date (newest first)
        XCTAssertEqual(sessions[0].recordingId, "rec3")
        XCTAssertEqual(sessions[1].recordingId, "rec2")
        XCTAssertEqual(sessions[2].recordingId, "rec1")
        
        // Verify query parameters
        let queryCall = try XCTUnwrap(mockDynamoClient.queryCalls.first)
        XCTAssertTrue(queryCall.keyConditionExpression.contains("begins_with(#pk, :user_prefix)"))
        XCTAssertEqual(queryCall.expressionAttributeValues[":user_prefix"]?.stringValue, testUserId)
        XCTAssertTrue(queryCall.scanIndexForward == false) // Descending order
    }
    
    // MARK: - Error Handling Tests
    
    func testCreateSessionWithInvalidCredentials() async throws {
        // Given: Invalid credentials
        mockCredentialService.shouldFail = true
        
        let sessionData = RecordingSession(
            recordingId: testRecordingId,
            userId: testUserId,
            title: "Auth Fail Test",
            participants: [],
            tags: [],
            startTime: Date(),
            duration: 0,
            status: .pending,
            chunkCount: 0,
            s3Prefix: "test/"
        )
        
        // When/Then: Should throw credential error
        await XCTAssertThrowsError(
            try await catalogService.createSession(sessionData)
        ) { error in
            XCTAssertTrue(error is CredentialExchangeError)
        }
        
        // Verify no DynamoDB calls were made
        XCTAssertEqual(mockDynamoClient.putItemCalls.count, 0)
    }
    
    func testCreateSessionWithDynamoDBError() async throws {
        // Given: DynamoDB client that fails
        mockDynamoClient.shouldFailPutItem = true
        
        let sessionData = RecordingSession(
            recordingId: testRecordingId,
            userId: testUserId,
            title: "DynamoDB Fail Test",
            participants: [],
            tags: [],
            startTime: Date(),
            duration: 0,
            status: .pending,
            chunkCount: 0,
            s3Prefix: "test/"
        )
        
        // When/Then: Should throw DynamoDB error
        await XCTAssertThrowsError(
            try await catalogService.createSession(sessionData)
        ) { error in
            XCTAssertTrue(error is MockDynamoDBError)
        }
    }
    
    func testUpdateNonExistentSession() async throws {
        // Given: DynamoDB returns no item found
        mockDynamoClient.shouldFailUpdateItem = true
        
        // When/Then: Should handle gracefully or throw appropriate error
        await XCTAssertThrowsError(
            try await catalogService.updateSessionStatus(
                recordingId: "non_existent",
                userId: testUserId,
                status: .completed
            )
        ) { error in
            XCTAssertTrue(error is MockDynamoDBError || error is CatalogServiceError)
        }
    }
    
    // MARK: - Integration Tests
    
    func testCompleteSessionLifecycle() async throws {
        // Given: New recording session
        let sessionData = RecordingSession(
            recordingId: testRecordingId,
            userId: testUserId,
            title: "Lifecycle Test Meeting",
            participants: ["Alice", "Bob"],
            tags: ["integration-test"],
            startTime: Date(),
            duration: 0,
            status: .pending,
            chunkCount: 0,
            s3Prefix: "users/\(testUserId)/chunks/\(testRecordingId)/"
        )
        
        // When: Complete lifecycle - Create, update status, duration, results
        try await catalogService.createSession(sessionData)
        XCTAssertEqual(mockDynamoClient.putItemCalls.count, 1)
        
        try await catalogService.updateSessionStatus(
            recordingId: testRecordingId,
            userId: testUserId,
            status: .recording
        )
        
        try await catalogService.updateSessionDuration(
            recordingId: testRecordingId,
            userId: testUserId,
            duration: 900.0
        )
        
        let results = ProcessingResults(
            transcriptS3Key: "users/\(testUserId)/transcripts/\(testRecordingId).json",
            summaryS3Key: "users/\(testUserId)/summaries/\(testRecordingId).json",
            videoS3Key: "users/\(testUserId)/videos/\(testRecordingId).mp4",
            processingDuration: 45.0,
            pipelineVersion: "1.0.0",
            modelVersions: ["transcribe": "test-model"]
        )
        
        try await catalogService.updateSessionWithResults(
            recordingId: testRecordingId,
            userId: testUserId,
            results: results,
            status: .completed
        )
        
        // Then: All operations should succeed
        XCTAssertEqual(mockDynamoClient.updateItemCalls.count, 3)
        
        let finalUpdate = mockDynamoClient.updateItemCalls.last!
        let values = finalUpdate.expressionAttributeValues
        XCTAssertEqual(values[":status"]?.stringValue, "completed")
    }
    
    // MARK: - Helper Methods
    
    private func createTestSession() async throws {
        let sessionData = RecordingSession(
            recordingId: testRecordingId,
            userId: testUserId,
            title: "Test Session",
            participants: [],
            tags: [],
            startTime: Date(),
            duration: 0,
            status: .pending,
            chunkCount: 0,
            s3Prefix: "test/"
        )
        
        try await catalogService.createSession(sessionData)
    }
    
    private func createMockDynamoDBItem(
        recordingId: String? = nil,
        title: String = "Mock Meeting",
        date: String = "2024-01-01T12:00:00Z"
    ) -> [String: DynamoDBAttributeValue] {
        let recId = recordingId ?? testRecordingId
        
        return [
            "PK": .string("\(testUserId)#\(recId)"),
            "SK": .string("METADATA"),
            "recording_id": .string(recId),
            "user_id": .string(testUserId),
            "title": .string(title),
            "status": .string("completed"),
            "created_at": .string(date),
            "updated_at": .string(date),
            "duration": .number(1200.0),
            "participants": .list([.string("Alice"), .string("Bob")]),
            "tags": .list([.string("test"), .string("mock")])
        ]
    }
}
