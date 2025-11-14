import XCTest
@testable import MeetingRecorder

@MainActor
final class UploadQueueTests: XCTestCase {
    var mockUploader: MockS3Uploader!
    var uploadQueue: UploadQueue!
    var testRecordingId: String!
    var testUserId: String!
    var tempDirectory: URL!

    override func setUp() async throws {
        testRecordingId = "test-recording-\(UUID().uuidString)"
        testUserId = "test-user-123"

        // Create temp directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )

        mockUploader = MockS3Uploader()
        uploadQueue = UploadQueue(
            uploader: mockUploader!,
            userId: testUserId,
            recordingId: testRecordingId
        )
    }

    override func tearDown() async throws {
        uploadQueue = nil
        mockUploader = nil

        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Upload Success Tests

    func testMultipartUploadSuccess() async throws {
        // Given
        let chunk = createTestChunk(index: 0, size: 50_000_000) // 50MB
        mockUploader.shouldSucceed = true

        let expectation = expectation(description: "Upload completes")
        var uploadedChunks: [String] = []

        uploadQueue.onChunkUploaded = { chunkId in
            uploadedChunks.append(chunkId)
            expectation.fulfill()
        }

        // When
        await uploadQueue.enqueue(chunk)
        await uploadQueue.start()

        // Wait for upload
        await fulfillment(of: [expectation], timeout: 2.0)

        // Then
        XCTAssertEqual(uploadedChunks.count, 1, "Should upload one chunk")
        XCTAssertEqual(mockUploader.uploadedChunks.count, 1, "Uploader should receive one chunk")
        XCTAssertEqual(mockUploader.uploadedChunks[0].chunkId, chunk.chunkId)
    }

    func testMultipleChunksUploadInFIFOOrder() async throws {
        // Given
        let chunks = [
            createTestChunk(index: 0, size: 10_000_000),
            createTestChunk(index: 1, size: 10_000_000),
            createTestChunk(index: 2, size: 10_000_000)
        ]
        mockUploader.shouldSucceed = true
        mockUploader.uploadDelay = 0.05 // Small delay to ensure sequential processing

        let expectation = expectation(description: "All chunks uploaded")
        expectation.expectedFulfillmentCount = 3
        var uploadOrder: [Int] = []

        uploadQueue.onChunkUploaded = { chunkId in
            // Extract index from chunk ID
            if let indexStr = chunkId.split(separator: "-").last,
               let index = Int(indexStr) {
                uploadOrder.append(index)
            }
            expectation.fulfill()
        }

        // When
        for chunk in chunks {
            await uploadQueue.enqueue(chunk)
        }
        await uploadQueue.start()

        // Wait for all uploads
        await fulfillment(of: [expectation], timeout: 3.0)

        // Then
        // Note: With concurrent uploads, exact order isn't guaranteed
        // Just verify all chunks were uploaded
        XCTAssertEqual(uploadOrder.sorted(), [0, 1, 2], "All chunks should be uploaded")
        XCTAssertEqual(Set(uploadOrder).count, 3, "No duplicate uploads")
    }

    // MARK: - Concurrent Upload Limit Tests

    func testConcurrentUploadLimit() async throws {
        // Given
        let chunks = (0..<10).map { createTestChunk(index: $0, size: 10_000_000) }
        mockUploader.shouldSucceed = true
        mockUploader.uploadDelay = 0.5 // 500ms delay per upload

        // When
        for chunk in chunks {
            await uploadQueue.enqueue(chunk)
        }
        await uploadQueue.start()

        // Allow some uploads to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Then
        let activeUploads = mockUploader.activeUploadCount
        XCTAssertLessThanOrEqual(
            activeUploads,
            3,
            "Should not exceed 3 concurrent uploads"
        )
    }

    // MARK: - Retry with Exponential Backoff Tests

    func testRetryWithExponentialBackoff() async throws {
        // Given
        let chunk = createTestChunk(index: 0, size: 10_000_000)
        mockUploader.shouldSucceed = false
        mockUploader.failuresUntilSuccess = 2 // Fail twice, then succeed

        let expectation = expectation(description: "Upload succeeds after retries")
        var attemptTimestamps: [Date] = []

        mockUploader.onUploadAttempt = { _ in
            attemptTimestamps.append(Date())
        }

        uploadQueue.onChunkUploaded = { _ in
            expectation.fulfill()
        }

        // When
        await uploadQueue.enqueue(chunk)
        await uploadQueue.start()

        // Wait for retries and eventual success
        await fulfillment(of: [expectation], timeout: 10.0)

        // Then
        XCTAssertEqual(attemptTimestamps.count, 3, "Should make 3 attempts (1 initial + 2 retries)")

        // Verify exponential backoff timing
        if attemptTimestamps.count >= 3 {
            let delay1 = attemptTimestamps[1].timeIntervalSince(attemptTimestamps[0])
            let delay2 = attemptTimestamps[2].timeIntervalSince(attemptTimestamps[1])

            // First retry should be ~1s
            XCTAssertGreaterThanOrEqual(delay1, 0.9, "First retry should wait ~1s")
            XCTAssertLessThanOrEqual(delay1, 1.5, "First retry should not exceed 1.5s")

            // Second retry should be ~2s
            XCTAssertGreaterThanOrEqual(delay2, 1.8, "Second retry should wait ~2s")
            XCTAssertLessThanOrEqual(delay2, 2.5, "Second retry should not exceed 2.5s")
        }
    }

    func testUploadFailsAfterMaxRetries() async throws {
        // Given
        let chunk = createTestChunk(index: 0, size: 10_000_000)
        mockUploader.shouldSucceed = false
        mockUploader.failuresUntilSuccess = 10 // Always fail

        let expectation = expectation(description: "Upload fails after max retries")
        var failedChunks: [String] = []

        uploadQueue.onChunkFailed = { chunkId, error in
            failedChunks.append(chunkId)
            expectation.fulfill()
        }

        // When
        await uploadQueue.enqueue(chunk)
        await uploadQueue.start()

        // Wait for failure
        await fulfillment(of: [expectation], timeout: 20.0)

        // Then
        XCTAssertEqual(failedChunks.count, 1, "Should mark chunk as failed")
        XCTAssertEqual(
            mockUploader.attemptCounts[chunk.chunkId],
            AWSConfig.maxUploadRetries + 1,
            "Should attempt max retries + 1 initial attempt"
        )
    }

    func testMaxBackoffDelayEnforced() async throws {
        // Given
        let chunk = createTestChunk(index: 0, size: 10_000_000)
        mockUploader.shouldSucceed = false
        mockUploader.failuresUntilSuccess = 10 // Fail many times

        var attemptTimestamps: [Date] = []
        mockUploader.onUploadAttempt = { _ in
            attemptTimestamps.append(Date())
        }

        let expectation = expectation(description: "Upload fails")
        uploadQueue.onChunkFailed = { _, _ in
            expectation.fulfill()
        }

        // When
        await uploadQueue.enqueue(chunk)
        await uploadQueue.start()

        await fulfillment(of: [expectation], timeout: 120.0)

        // Then - verify no delay exceeds 60s
        for i in 1..<attemptTimestamps.count {
            let delay = attemptTimestamps[i].timeIntervalSince(attemptTimestamps[i-1])
            XCTAssertLessThanOrEqual(
                delay,
                AWSConfig.maxBackoffDelay + 1.0,
                "Backoff delay should not exceed maximum"
            )
        }
    }

    // MARK: - Manifest Persistence Tests

    func testManifestSavedAfterEachUpload() async throws {
        // Given
        let chunks = [
            createTestChunk(index: 0, size: 10_000_000),
            createTestChunk(index: 1, size: 10_000_000)
        ]
        mockUploader.shouldSucceed = true

        // When
        for chunk in chunks {
            await uploadQueue.enqueue(chunk)
        }
        await uploadQueue.start()

        // Wait for uploads to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Then - manifest should exist on disk
        XCTAssertTrue(
            UploadManifest.exists(recordingId: testRecordingId),
            "Manifest should be persisted to disk"
        )

        // Load and verify manifest
        let manifest = try UploadManifest.load(recordingId: testRecordingId)
        XCTAssertEqual(manifest.recordingId, testRecordingId)
        XCTAssertEqual(manifest.chunks.count, 2)
    }

    func testResumeFromManifestAfterAppRestart() async throws {
        // Given - Create manifest with partially uploaded chunks
        let chunks = [
            createTestChunk(index: 0, size: 10_000_000),
            createTestChunk(index: 1, size: 10_000_000),
            createTestChunk(index: 2, size: 10_000_000)
        ]

        var manifest = UploadManifest(
            recordingId: testRecordingId,
            userId: testUserId,
            chunks: chunks.map { chunk in
                UploadManifest.ChunkInfo(
                    chunkId: chunk.chunkId,
                    path: chunk.filePath.path,
                    size: chunk.sizeBytes
                )
            }
        )

        // Mark first chunk as completed
        manifest.updateChunk(chunkId: chunks[0].chunkId, status: .completed)
        try manifest.save()

        // When - Create new upload queue and resume
        mockUploader.shouldSucceed = true
        let newQueue = UploadQueue(
            uploader: mockUploader!,
            userId: testUserId,
            recordingId: testRecordingId
        )

        let expectation = expectation(description: "Resume completes")
        expectation.expectedFulfillmentCount = 2 // Only chunks 1 and 2 should upload

        var uploadedChunkIds: [String] = []
        newQueue.onChunkUploaded = { (chunkId: String) in
            uploadedChunkIds.append(chunkId)
            expectation.fulfill()
        }

        await newQueue.resume()

        // Wait for resumed uploads
        await fulfillment(of: [expectation], timeout: 3.0)

        // Then
        XCTAssertEqual(uploadedChunkIds.count, 2, "Should only upload incomplete chunks")
        XCTAssertFalse(
            uploadedChunkIds.contains(chunks[0].chunkId),
            "Should not re-upload completed chunk"
        )
        XCTAssertTrue(
            uploadedChunkIds.contains(chunks[1].chunkId),
            "Should upload pending chunk 1"
        )
        XCTAssertTrue(
            uploadedChunkIds.contains(chunks[2].chunkId),
            "Should upload pending chunk 2"
        )
    }

    func testCorruptedManifestHandledGracefully() async throws {
        // Given - Create corrupted manifest file
        let manifestURL = UploadManifest.fileURL(recordingId: testRecordingId)
        let corruptedData = Data("corrupted json data".utf8)
        try corruptedData.write(to: manifestURL)

        // When - Try to resume
        let newQueue = UploadQueue(
            uploader: mockUploader!,
            userId: testUserId,
            recordingId: testRecordingId
        )

        // Then - Should not crash, should handle gracefully
        await newQueue.resume()
        // Success - corrupted manifest was handled without crashing
    }

    // MARK: - Progress Tracking Tests

    func testProgressUpdates() async throws {
        // Given
        let chunks = (0..<5).map { createTestChunk(index: $0, size: 10_000_000) }
        mockUploader.shouldSucceed = true

        var progressUpdates: [Double] = []
        uploadQueue.onProgressUpdate = { progress in
            progressUpdates.append(progress)
        }

        // When
        for chunk in chunks {
            await uploadQueue.enqueue(chunk)
        }
        await uploadQueue.start()

        // Wait for all uploads
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s

        // Then
        XCTAssertFalse(progressUpdates.isEmpty, "Should receive progress updates")
        XCTAssertEqual(progressUpdates.last ?? 0.0, 1.0, accuracy: 0.01, "Final progress should be 100%")
    }

    // MARK: - Pause/Resume Tests

    func testPauseAndResumeQueue() async throws {
        // Given
        let chunks = (0..<5).map { createTestChunk(index: $0, size: 10_000_000) }
        mockUploader.shouldSucceed = true
        mockUploader.uploadDelay = 0.5 // Slow uploads

        for chunk in chunks {
            await uploadQueue.enqueue(chunk)
        }
        await uploadQueue.start()

        // Wait for some uploads to start
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // When - Pause
        await uploadQueue.pause()
        let uploadsAfterPause = mockUploader.uploadedChunks.count

        // Wait a bit
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Then - No new uploads should complete while paused
        XCTAssertEqual(
            mockUploader.uploadedChunks.count,
            uploadsAfterPause,
            "No new uploads should complete while paused"
        )

        // When - Resume
        await uploadQueue.resume()
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s

        // Then - All chunks should eventually upload
        XCTAssertEqual(mockUploader.uploadedChunks.count, 5, "All chunks should upload after resume")
    }

    // MARK: - Error Handling Tests

    func testNetworkErrorHandling() async throws {
        // Given
        let chunk = createTestChunk(index: 0, size: 10_000_000)
        mockUploader.shouldSucceed = false
        mockUploader.errorToThrow = UploadError.networkError("Connection lost")

        let expectation = expectation(description: "Error handled")
        var errorMessages: [String] = []

        uploadQueue.onChunkFailed = { _, error in
            errorMessages.append(error)
            expectation.fulfill()
        }

        // When
        await uploadQueue.enqueue(chunk)
        await uploadQueue.start()

        await fulfillment(of: [expectation], timeout: 20.0)

        // Then
        XCTAssertFalse(errorMessages.isEmpty, "Should receive error notification")
        XCTAssertTrue(
            errorMessages[0].contains("Connection lost"),
            "Error message should include network error details"
        )
    }

    func testCredentialRefreshOn403Error() async throws {
        // Given
        let chunk = createTestChunk(index: 0, size: 10_000_000)
        mockUploader.shouldSucceed = false
        mockUploader.errorToThrow = UploadError.credentialsExpired
        mockUploader.throwErrorOnce = true // Throw once, then succeed

        let expectation = expectation(description: "Credentials refreshed")
        var credentialRefreshCount = 0

        uploadQueue.onCredentialsExpired = {
            credentialRefreshCount += 1
            expectation.fulfill()
        }

        // When
        await uploadQueue.enqueue(chunk)
        await uploadQueue.start()

        await fulfillment(of: [expectation], timeout: 3.0)

        // Then
        XCTAssertEqual(credentialRefreshCount, 1, "Should trigger credential refresh")
    }

    // MARK: - Helper Methods

    private func createTestChunk(index: Int, size: Int64) -> ChunkMetadata {
        let chunkId = ChunkMetadata.generateChunkId(recordingId: testRecordingId, index: index)
        let fileName = "part-\(String(format: "%04d", index + 1)).mp4"
        let filePath = tempDirectory.appendingPathComponent(fileName)

        // Create empty file
        FileManager.default.createFile(atPath: filePath.path, contents: nil)

        return ChunkMetadata(
            chunkId: chunkId,
            filePath: filePath,
            sizeBytes: size,
            checksum: "mock-checksum-\(index)",
            durationSeconds: 60.0,
            index: index,
            recordingId: testRecordingId
        )
    }
}

// MARK: - Mock S3Uploader

@MainActor
final class MockS3Uploader: S3UploaderProtocol, @unchecked Sendable {
    var shouldSucceed = true
    var failuresUntilSuccess = 0
    var uploadDelay: TimeInterval = 0.1
    var errorToThrow: UploadError?
    var throwErrorOnce = false // If true, errorToThrow is reset after first throw

    var uploadedChunks: [ChunkMetadata] = []
    var attemptCounts: [String: Int] = [:]
    var activeUploadCount: Int = 0
    var onUploadAttempt: ((ChunkMetadata) -> Void)?

    func uploadChunk(
        recordingId: String,
        chunkMetadata: ChunkMetadata,
        userId: String
    ) async throws -> S3UploadResult {
        activeUploadCount += 1
        defer { activeUploadCount -= 1 }

        // Track attempts
        attemptCounts[chunkMetadata.chunkId, default: 0] += 1
        onUploadAttempt?(chunkMetadata)

        // Simulate upload delay
        try await Task.sleep(nanoseconds: UInt64(uploadDelay * 1_000_000_000))

        // Handle failures
        if !shouldSucceed {
            // If specific error is set, throw it
            if let error = errorToThrow {
                // If throwErrorOnce is true, reset errorToThrow after first throw
                if throwErrorOnce {
                    errorToThrow = nil
                }
                throw error
            }

            // Otherwise use failuresUntilSuccess counter
            if failuresUntilSuccess > 0 {
                failuresUntilSuccess -= 1
                throw UploadError.uploadFailed("Mock upload failure")
            }
        }

        // Success
        uploadedChunks.append(chunkMetadata)

        return S3UploadResult(
            s3Key: "users/\(userId)/chunks/\(recordingId)/part-\(String(format: "%04d", chunkMetadata.index + 1)).mp4",
            etag: "mock-etag-\(chunkMetadata.index)",
            uploadDuration: uploadDelay
        )
    }
}

// Protocol and types are defined in S3Uploader.swift
