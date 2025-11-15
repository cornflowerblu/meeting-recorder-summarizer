import XCTest
import Foundation
@testable import MeetingRecorder

@MainActor
final class UploadQueueTests: XCTestCase {
    var uploadQueue: UploadQueue!
    var mockS3Uploader: MockS3Uploader!
    var mockManifestStore: MockUploadManifestStore!
    var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Initialize mock dependencies
        mockS3Uploader = MockS3Uploader()
        mockManifestStore = MockUploadManifestStore()
        
        // Initialize upload queue with test configuration
        uploadQueue = UploadQueue(
            s3Uploader: mockS3Uploader,
            manifestStore: mockManifestStore,
            maxConcurrentUploads: 2,
            retryDelay: 0.1, // Fast retry for tests
            maxRetryAttempts: 3
        )
    }
    
    override func tearDown() async throws {
        // Stop any background operations
        await uploadQueue.stopProcessing()
        
        // Clean up temporary files
        try? FileManager.default.removeItem(at: tempDirectory)
        
        uploadQueue = nil
        mockS3Uploader = nil
        mockManifestStore = nil
        
        try await super.tearDown()
    }
    
    // MARK: - Chunk Queuing Tests
    
    func testEnqueueChunkCreatesManifestEntry() async throws {
        // Given: A chunk to upload
        let chunk = createTestChunkMetadata(recordingId: "rec_123", chunkIndex: 0)
        
        // When: Enqueueing the chunk
        try await uploadQueue.enqueue(chunk: chunk)
        
        // Then: Manifest should contain the chunk entry
        let manifest = try await mockManifestStore.loadManifest(recordingId: "rec_123")
        XCTAssertEqual(manifest.chunks.count, 1)
        
        let entry = try XCTUnwrap(manifest.chunks.first)
        XCTAssertEqual(entry.chunkIndex, 0)
        XCTAssertEqual(entry.status, .pending)
        XCTAssertEqual(entry.filePath, chunk.filePath)
    }
    
    func testEnqueueMultipleChunksInOrder() async throws {
        // Given: Multiple chunks for the same recording
        let chunks = [
            createTestChunkMetadata(recordingId: "rec_456", chunkIndex: 0),
            createTestChunkMetadata(recordingId: "rec_456", chunkIndex: 1),
            createTestChunkMetadata(recordingId: "rec_456", chunkIndex: 2)
        ]
        
        // When: Enqueueing chunks
        for chunk in chunks {
            try await uploadQueue.enqueue(chunk: chunk)
        }
        
        // Then: All chunks should be in manifest with correct order
        let manifest = try await mockManifestStore.loadManifest(recordingId: "rec_456")
        XCTAssertEqual(manifest.chunks.count, 3)
        
        for (index, entry) in manifest.chunks.sorted(by: { $0.chunkIndex < $1.chunkIndex }).enumerated() {
            XCTAssertEqual(entry.chunkIndex, index)
            XCTAssertEqual(entry.status, .pending)
        }
    }
    
    func testEnqueueStartsBackgroundProcessing() async throws {
        // Given: Upload queue is idle
        XCTAssertFalse(uploadQueue.isProcessing)
        
        // When: Enqueueing a chunk
        let chunk = createTestChunkMetadata(recordingId: "rec_auto", chunkIndex: 0)
        try await uploadQueue.enqueue(chunk: chunk)
        
        // Then: Background processing should start
        XCTAssertTrue(uploadQueue.isProcessing)
        
        // Wait for processing to complete
        try await waitForUploadCompletion(recordingId: "rec_auto")
        XCTAssertEqual(mockS3Uploader.uploadedFiles.count, 1)
    }
    
    // MARK: - Background Processing Tests
    
    func testBackgroundUploadExecution() async throws {
        // Given: Queued chunks
        let chunk1 = createTestChunkMetadata(recordingId: "rec_bg", chunkIndex: 0)
        let chunk2 = createTestChunkMetadata(recordingId: "rec_bg", chunkIndex: 1)
        
        try await uploadQueue.enqueue(chunk: chunk1)
        try await uploadQueue.enqueue(chunk: chunk2)
        
        // When: Processing completes
        try await waitForUploadCompletion(recordingId: "rec_bg")
        
        // Then: Both chunks should be uploaded
        XCTAssertEqual(mockS3Uploader.uploadedFiles.count, 2)
        
        let manifest = try await mockManifestStore.loadManifest(recordingId: "rec_bg")
        for entry in manifest.chunks {
            XCTAssertEqual(entry.status, .completed)
            XCTAssertNotNil(entry.s3Key)
            XCTAssertNotNil(entry.etag)
        }
    }
    
    func testConcurrentUploadLimit() async throws {
        // Given: More chunks than concurrent limit
        let recordingId = "rec_concurrent"
        let chunks = (0..<5).map { index in
            createTestChunkMetadata(recordingId: recordingId, chunkIndex: index)
        }
        
        // Configure S3 uploader to track concurrent operations
        mockS3Uploader.uploadDelay = 0.5
        mockS3Uploader.trackConcurrency = true
        
        // When: Enqueueing all chunks
        for chunk in chunks {
            try await uploadQueue.enqueue(chunk: chunk)
        }
        
        // Wait for some uploads to start
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Then: Should not exceed concurrent limit (2)
        XCTAssertLessThanOrEqual(mockS3Uploader.currentConcurrentUploads, 2)
        
        // Wait for completion
        try await waitForUploadCompletion(recordingId: recordingId)
        XCTAssertEqual(mockS3Uploader.uploadedFiles.count, 5)
        XCTAssertLessThanOrEqual(mockS3Uploader.maxObservedConcurrency, 2)
    }
    
    func testProcessingStopsWhenQueueEmpty() async throws {
        // Given: Upload queue with chunks
        let chunk = createTestChunkMetadata(recordingId: "rec_stop", chunkIndex: 0)
        try await uploadQueue.enqueue(chunk: chunk)
        
        XCTAssertTrue(uploadQueue.isProcessing)
        
        // When: Processing completes
        try await waitForUploadCompletion(recordingId: "rec_stop")
        
        // Then: Processing should stop automatically
        XCTAssertFalse(uploadQueue.isProcessing)
    }
    
    // MARK: - Retry Logic Tests
    
    func testRetryOnUploadFailure() async throws {
        // Given: S3 uploader that fails initially
        mockS3Uploader.failureCount = 2 // Fail first 2 attempts, succeed on 3rd
        
        let chunk = createTestChunkMetadata(recordingId: "rec_retry", chunkIndex: 0)
        try await uploadQueue.enqueue(chunk: chunk)
        
        // When: Processing with retries
        try await waitForUploadCompletion(recordingId: "rec_retry", timeout: 5.0)
        
        // Then: Should eventually succeed after retries
        XCTAssertEqual(mockS3Uploader.uploadedFiles.count, 1)
        XCTAssertEqual(mockS3Uploader.totalAttempts, 3)
        
        let manifest = try await mockManifestStore.loadManifest(recordingId: "rec_retry")
        let entry = try XCTUnwrap(manifest.chunks.first)
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.retryCount, 2)
    }
    
    func testRetryExhaustionMarksFailed() async throws {
        // Given: S3 uploader that always fails
        mockS3Uploader.alwaysFail = true
        
        let chunk = createTestChunkMetadata(recordingId: "rec_failed", chunkIndex: 0)
        try await uploadQueue.enqueue(chunk: chunk)
        
        // When: Processing until retries exhausted
        try await waitForProcessingEnd(recordingId: "rec_failed", timeout: 5.0)
        
        // Then: Should be marked as failed after max retries
        let manifest = try await mockManifestStore.loadManifest(recordingId: "rec_failed")
        let entry = try XCTUnwrap(manifest.chunks.first)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.retryCount, 3) // maxRetryAttempts
        
        // Should not upload successfully
        XCTAssertEqual(mockS3Uploader.uploadedFiles.count, 0)
        XCTAssertEqual(mockS3Uploader.totalAttempts, 4) // Initial + 3 retries
    }
    
    func testRetryDelayProgression() async throws {
        // Given: S3 uploader that fails initially
        mockS3Uploader.failureCount = 3
        
        let chunk = createTestChunkMetadata(recordingId: "rec_delay", chunkIndex: 0)
        
        // Track retry timing
        let startTime = Date()
        try await uploadQueue.enqueue(chunk: chunk)
        try await waitForUploadCompletion(recordingId: "rec_delay", timeout: 10.0)
        let endTime = Date()
        
        // Then: Should have appropriate delays between retries
        let totalTime = endTime.timeIntervalSince(startTime)
        
        // Expected delays: 0.1s + 0.2s + 0.4s = 0.7s minimum (exponential backoff)
        XCTAssertGreaterThan(totalTime, 0.6)
        
        let manifest = try await mockManifestStore.loadManifest(recordingId: "rec_delay")
        let entry = try XCTUnwrap(manifest.chunks.first)
        XCTAssertEqual(entry.retryCount, 3)
    }
    
    // MARK: - Persistence Tests
    
    func testManifestPersistsBetweenSessions() async throws {
        // Given: Uploaded chunks in one session
        let chunk1 = createTestChunkMetadata(recordingId: "rec_persist", chunkIndex: 0)
        let chunk2 = createTestChunkMetadata(recordingId: "rec_persist", chunkIndex: 1)
        
        try await uploadQueue.enqueue(chunk: chunk1)
        try await uploadQueue.enqueue(chunk: chunk2)
        try await waitForUploadCompletion(recordingId: "rec_persist")
        
        // When: Creating new upload queue (simulating app restart)
        let newUploadQueue = UploadQueue(
            s3Uploader: MockS3Uploader(),
            manifestStore: mockManifestStore, // Same store
            maxConcurrentUploads: 2,
            retryDelay: 0.1,
            maxRetryAttempts: 3
        )
        
        // Then: Previous upload state should be recoverable
        let manifest = try await mockManifestStore.loadManifest(recordingId: "rec_persist")
        XCTAssertEqual(manifest.chunks.count, 2)
        
        for entry in manifest.chunks {
            XCTAssertEqual(entry.status, .completed)
            XCTAssertNotNil(entry.s3Key)
        }
    }
    
    func testResumeIncompleteUploads() async throws {
        // Given: A manifest with pending uploads
        let recordingId = "rec_resume"
        var manifest = UploadManifest(recordingId: recordingId, chunks: [])
        
        let pendingEntry = UploadManifest.ChunkEntry(
            chunkIndex: 0,
            filePath: createTestFile(name: "test_chunk_0.mov"),
            status: .pending,
            s3Key: nil,
            etag: nil,
            retryCount: 1,
            lastAttempt: Date().addingTimeInterval(-300) // 5 minutes ago
        )
        manifest.chunks.append(pendingEntry)
        
        try await mockManifestStore.saveManifest(manifest)
        
        // When: Starting upload queue with resume capability
        let resumeQueue = UploadQueue(
            s3Uploader: mockS3Uploader,
            manifestStore: mockManifestStore,
            maxConcurrentUploads: 2,
            retryDelay: 0.1,
            maxRetryAttempts: 3
        )
        
        try await resumeQueue.resumeIncompleteUploads()
        try await waitForUploadCompletion(recordingId: recordingId)
        
        // Then: Pending upload should complete
        let updatedManifest = try await mockManifestStore.loadManifest(recordingId: recordingId)
        let entry = try XCTUnwrap(updatedManifest.chunks.first)
        XCTAssertEqual(entry.status, .completed)
        XCTAssertNotNil(entry.s3Key)
    }
    
    // MARK: - Progress Tracking Tests
    
    func testUploadProgressReporting() async throws {
        // Given: Upload queue with progress callback
        var progressUpdates: [(recordingId: String, progress: UploadProgress)] = []
        
        uploadQueue.onProgressUpdate = { recordingId, progress in
            progressUpdates.append((recordingId, progress))
        }
        
        let recordingId = "rec_progress"
        let chunks = (0..<3).map { index in
            createTestChunkMetadata(recordingId: recordingId, chunkIndex: index)
        }
        
        // When: Uploading chunks
        for chunk in chunks {
            try await uploadQueue.enqueue(chunk: chunk)
        }
        
        try await waitForUploadCompletion(recordingId: recordingId)
        
        // Then: Should receive progress updates
        XCTAssertFalse(progressUpdates.isEmpty)
        
        let finalProgress = progressUpdates.last?.progress
        XCTAssertEqual(finalProgress?.completedChunks, 3)
        XCTAssertEqual(finalProgress?.totalChunks, 3)
        XCTAssertEqual(finalProgress?.percentage, 1.0)
    }
    
    // MARK: - Error Handling Tests
    
    func testHandlesFileNotFoundError() async throws {
        // Given: Chunk with non-existent file
        let chunk = ChunkMetadata(
            recordingId: "rec_missing",
            chunkIndex: 0,
            filePath: tempDirectory.appendingPathComponent("missing.mov"),
            duration: 60.0,
            startTime: Date(),
            endTime: Date().addingTimeInterval(60.0),
            fileSize: 1024
        )
        
        // When: Attempting to upload
        try await uploadQueue.enqueue(chunk: chunk)
        try await waitForProcessingEnd(recordingId: "rec_missing")
        
        // Then: Should mark as failed without retries
        let manifest = try await mockManifestStore.loadManifest(recordingId: "rec_missing")
        let entry = try XCTUnwrap(manifest.chunks.first)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.retryCount, 0) // No retries for file not found
    }
    
    // MARK: - Helper Methods
    
    private func createTestChunkMetadata(recordingId: String, chunkIndex: Int) -> ChunkMetadata {
        let fileName = "\(recordingId)_chunk_\(String(format: "%03d", chunkIndex)).mov"
        let filePath = createTestFile(name: fileName)
        
        return ChunkMetadata(
            recordingId: recordingId,
            chunkIndex: chunkIndex,
            filePath: filePath,
            duration: 60.0,
            startTime: Date().addingTimeInterval(TimeInterval(chunkIndex * 60)),
            endTime: Date().addingTimeInterval(TimeInterval((chunkIndex + 1) * 60)),
            fileSize: 1024 * 1024
        )
    }
    
    private func createTestFile(name: String) -> URL {
        let filePath = tempDirectory.appendingPathComponent(name)
        
        // Create a dummy file
        let testData = Data(repeating: 0x42, count: 1024)
        try? testData.write(to: filePath)
        
        return filePath
    }
    
    private func waitForUploadCompletion(recordingId: String, timeout: TimeInterval = 3.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            let manifest = try await mockManifestStore.loadManifest(recordingId: recordingId)
            let completedCount = manifest.chunks.filter { $0.status == .completed }.count
            
            if completedCount == manifest.chunks.count && !uploadQueue.isProcessing {
                return
            }
            
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        }
        
        throw XCTError("Upload completion timeout")
    }
    
    private func waitForProcessingEnd(recordingId: String, timeout: TimeInterval = 3.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            if !uploadQueue.isProcessing {
                return
            }
            
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        }
        
        throw XCTError("Processing end timeout")
    }
}
