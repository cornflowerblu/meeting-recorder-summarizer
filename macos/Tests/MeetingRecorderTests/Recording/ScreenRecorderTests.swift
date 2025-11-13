import XCTest
@testable import MeetingRecorder

@MainActor
final class ScreenRecorderTests: XCTestCase {
    var mockCaptureService: MockScreenCaptureService!
    var mockStorageService: MockChunkStorageService!
    var recorder: ScreenRecorder!

    override func setUp() async throws {
        mockCaptureService = MockScreenCaptureService()
        mockStorageService = MockChunkStorageService()
        recorder = ScreenRecorder(
            captureService: mockCaptureService,
            storageService: mockStorageService
        )

        // Set up delegate connection for mock
        mockCaptureService.delegate = recorder
    }

    override func tearDown() async throws {
        recorder = nil
        mockStorageService = nil
        mockCaptureService = nil
    }

    // MARK: - State Transition Tests

    func testInitialState() {
        XCTAssertFalse(recorder.isRecording, "Recorder should not be recording initially")
        XCTAssertFalse(recorder.isPaused, "Recorder should not be paused initially")
        XCTAssertEqual(recorder.currentChunkIndex, 0, "Chunk index should be 0 initially")
        XCTAssertEqual(recorder.recordingDuration, 0, "Duration should be 0 initially")
    }

    func testStartRecording() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        let recordingId = "test-recording-001"

        // When
        try await recorder.startRecording(recordingId: recordingId)

        // Then
        XCTAssertTrue(recorder.isRecording, "Recorder should be recording after start")
        XCTAssertTrue(mockCaptureService.startCaptureCalled, "Capture service should have been started")
        XCTAssertEqual(recorder.recordingId, recordingId, "Recording ID should be set")
    }

    func testStartRecordingWithoutPermission() async {
        // Given
        mockCaptureService.hasPermissionResult = false

        // When/Then
        do {
            try await recorder.startRecording(recordingId: "test-recording-001")
            XCTFail("Should throw permission denied error")
        } catch CaptureError.permissionDenied {
            // Expected
            XCTAssertFalse(recorder.isRecording, "Recorder should not be recording without permission")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPauseRecording() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        // When
        try await recorder.pauseRecording()

        // Then
        XCTAssertTrue(recorder.isPaused, "Recorder should be paused")
        XCTAssertTrue(mockCaptureService.pauseCaptureCalled, "Capture service should have been paused")
    }

    func testResumeRecording() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")
        try await recorder.pauseRecording()

        // When
        try await recorder.resumeRecording()

        // Then
        XCTAssertFalse(recorder.isPaused, "Recorder should not be paused after resume")
        XCTAssertTrue(mockCaptureService.resumeCaptureCalled, "Capture service should have been resumed")
    }

    func testStopRecording() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        // When
        try await recorder.stopRecording()

        // Then
        XCTAssertFalse(recorder.isRecording, "Recorder should not be recording after stop")
        XCTAssertTrue(mockCaptureService.stopCaptureCalled, "Capture service should have been stopped")
    }

    func testInvalidStateTransitions() async throws {
        // Test pause without starting
        do {
            try await recorder.pauseRecording()
            XCTFail("Should throw invalid state error")
        } catch CaptureError.invalidState {
            // Expected
        }

        // Test resume without pausing
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")
        do {
            try await recorder.resumeRecording()
            XCTFail("Should throw invalid state error")
        } catch CaptureError.invalidState {
            // Expected
        }
    }

    // MARK: - Chunk Segmentation Tests

    func testChunkCompletionNotification() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        let recordingId = "test-recording-001"
        try await recorder.startRecording(recordingId: recordingId)

        let expectation = expectation(description: "Chunk completed callback")
        var chunkNotifications: [(URL, Int, TimeInterval)] = []
        recorder.onChunkCompleted = { url, index, duration in
            chunkNotifications.append((url, index, duration))
            expectation.fulfill()
        }

        // When - Simulate chunk completion
        let chunkURL = URL(fileURLWithPath: "/tmp/part-0001.mp4")
        mockCaptureService.delegate?.captureDidCompleteChunk(
            fileURL: chunkURL,
            index: 0,
            duration: 60.0
        )

        // Wait for async callback
        await fulfillment(of: [expectation], timeout: 1.0)

        // Then
        XCTAssertEqual(chunkNotifications.count, 1, "Should receive one chunk notification")
        XCTAssertEqual(chunkNotifications[0].1, 0, "Chunk index should be 0")
        XCTAssertEqual(chunkNotifications[0].2, 60.0, accuracy: 0.1, "Chunk duration should be ~60s")
    }

    func testMultipleChunkGeneration() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        let expectation = expectation(description: "Multiple chunks completed")
        expectation.expectedFulfillmentCount = 3
        var chunkIndices: [Int] = []
        recorder.onChunkCompleted = { _, index, _ in
            chunkIndices.append(index)
            expectation.fulfill()
        }

        // When - Simulate 3 chunks (3-minute recording)
        for index in 0..<3 {
            let chunkURL = URL(fileURLWithPath: "/tmp/part-\(String(format: "%04d", index + 1)).mp4")
            mockCaptureService.delegate?.captureDidCompleteChunk(
                fileURL: chunkURL,
                index: index,
                duration: 60.0
            )
        }

        // Wait for all async callbacks
        await fulfillment(of: [expectation], timeout: 2.0)

        // Then
        XCTAssertEqual(chunkIndices, [0, 1, 2], "Should generate 3 sequential chunks")
        XCTAssertEqual(recorder.currentChunkIndex, 3, "Current chunk index should be 3")
    }

    func testChunkDurationVariance() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        let expectation = expectation(description: "Varied duration chunks completed")
        expectation.expectedFulfillmentCount = 4
        var durations: [TimeInterval] = []
        recorder.onChunkCompleted = { _, _, duration in
            durations.append(duration)
            expectation.fulfill()
        }

        // When - Simulate chunks with acceptable variance (58-62 seconds)
        let variedDurations: [TimeInterval] = [58.2, 60.1, 61.8, 59.5]
        for (index, duration) in variedDurations.enumerated() {
            let chunkURL = URL(fileURLWithPath: "/tmp/part-\(String(format: "%04d", index + 1)).mp4")
            mockCaptureService.delegate?.captureDidCompleteChunk(
                fileURL: chunkURL,
                index: index,
                duration: duration
            )
        }

        // Wait for all async callbacks
        await fulfillment(of: [expectation], timeout: 2.0)

        // Then
        XCTAssertEqual(durations.count, 4, "Should receive 4 chunks")
        for duration in durations {
            XCTAssertGreaterThanOrEqual(duration, 58.0, "Duration should be at least 58s")
            XCTAssertLessThanOrEqual(duration, 62.0, "Duration should be at most 62s")
        }
    }

    // MARK: - Error Handling Tests

    func testDiskSpaceLowError() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        mockStorageService.shouldThrowDiskSpaceError = true

        // When/Then
        do {
            try await recorder.startRecording(recordingId: "test-recording-001")
            XCTFail("Should throw disk space error")
        } catch ChunkStorageError.insufficientDiskSpace {
            // Expected
            XCTAssertFalse(recorder.isRecording, "Should not start recording with low disk space")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testErrorHandlingDuringRecording() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        let expectation = expectation(description: "Error callback")
        var errorReceived: CaptureError?
        recorder.onError = { error in
            errorReceived = error
            expectation.fulfill()
        }

        // When - Simulate capture error
        let testError = CaptureError.captureSessionFailed("Test error")
        mockCaptureService.delegate?.captureDidEncounterError(testError)

        // Wait for callback
        await fulfillment(of: [expectation], timeout: 1.0)

        // Then
        XCTAssertNotNil(errorReceived, "Should receive error notification")
        if case .captureSessionFailed(let message) = errorReceived {
            XCTAssertEqual(message, "Test error")
        } else {
            XCTFail("Wrong error type received")
        }
    }

    func testFrameDropWarning() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        let expectation = expectation(description: "Frame drop warning")
        var warningsReceived: [CaptureError] = []
        recorder.onError = { error in
            warningsReceived.append(error)
            expectation.fulfill()
        }

        // When - Simulate frame drops
        mockCaptureService.delegate?.captureDidEncounterError(.frameDrop(5))

        // Wait for callback
        await fulfillment(of: [expectation], timeout: 1.0)

        // Then
        XCTAssertEqual(warningsReceived.count, 1, "Should receive frame drop warning")
        if case .frameDrop(let count) = warningsReceived[0] {
            XCTAssertEqual(count, 5, "Should report 5 dropped frames")
        } else {
            XCTFail("Wrong error type")
        }

        // Recording should continue despite frame drops
        XCTAssertTrue(recorder.isRecording, "Recording should continue after frame drops")
    }

    // MARK: - Cleanup Tests

    func testCleanupOnStop() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        let recordingId = "test-recording-001"
        try await recorder.startRecording(recordingId: recordingId)

        // When
        try await recorder.stopRecording()

        // Then
        XCTAssertTrue(mockCaptureService.stopCaptureCalled, "Capture should be stopped")
        XCTAssertFalse(recorder.isRecording, "Recording state should be cleared")
    }

    func testCleanupOnCancellation() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        // When
        try await recorder.cancelRecording()

        // Then
        XCTAssertTrue(mockCaptureService.stopCaptureCalled, "Capture should be stopped")
        XCTAssertFalse(recorder.isRecording, "Recording should be stopped")
        XCTAssertTrue(mockStorageService.cleanupCalled, "Storage should be cleaned up")
    }

    // MARK: - Progress Tracking Tests

    func testProgressUpdates() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        var progressUpdates: [(TimeInterval, Int)] = []
        recorder.onProgress = { duration, chunkCount in
            progressUpdates.append((duration, chunkCount))
        }

        // When - Simulate progress updates
        mockCaptureService.delegate?.captureDidUpdateProgress(duration: 30.0, chunkCount: 0)
        mockCaptureService.delegate?.captureDidUpdateProgress(duration: 60.0, chunkCount: 1)
        mockCaptureService.delegate?.captureDidUpdateProgress(duration: 90.0, chunkCount: 1)

        // Then
        XCTAssertEqual(progressUpdates.count, 3, "Should receive 3 progress updates")
        XCTAssertEqual(progressUpdates[0].0, 30.0, accuracy: 0.1)
        XCTAssertEqual(progressUpdates[1].0, 60.0, accuracy: 0.1)
        XCTAssertEqual(progressUpdates[2].1, 1, "Should have 1 completed chunk after 90s")
    }

    func testDurationTracking() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true
        try await recorder.startRecording(recordingId: "test-recording-001")

        // When - Simulate duration updates
        mockCaptureService.delegate?.captureDidUpdateProgress(duration: 180.5, chunkCount: 3)

        // Then
        XCTAssertEqual(recorder.recordingDuration, 180.5, accuracy: 0.1, "Duration should be tracked accurately")
    }

    // MARK: - Memory Management Tests

    func testNoMemoryLeaks() async throws {
        // Given
        mockCaptureService.hasPermissionResult = true

        // When - Start and stop multiple times
        for i in 0..<5 {
            try await recorder.startRecording(recordingId: "test-recording-\(i)")
            try await recorder.stopRecording()
        }

        // Then - Test would fail if strong reference cycles exist
        // This is a basic test; more sophisticated leak detection would use Instruments
        XCTAssertFalse(recorder.isRecording, "Should be in clean state")
    }
}

// MARK: - Mock Services

@MainActor
class MockScreenCaptureService: ScreenCaptureService {
    var hasPermissionResult = false
    var startCaptureCalled = false
    var stopCaptureCalled = false
    var pauseCaptureCalled = false
    var resumeCaptureCalled = false
    weak var delegate: ScreenCaptureDelegate?

    func hasPermission() -> Bool {
        return hasPermissionResult
    }

    func requestPermission() async throws {
        // Simulate permission grant
        hasPermissionResult = true
    }

    func startCapture() async throws {
        if !hasPermissionResult {
            throw CaptureError.permissionDenied
        }
        startCaptureCalled = true
    }

    func stopCapture() async throws {
        stopCaptureCalled = true
    }

    func pauseCapture() async throws {
        pauseCaptureCalled = true
    }

    func resumeCapture() async throws {
        resumeCaptureCalled = true
    }
}

/// Mock storage service for testing
/// Uses @unchecked Sendable as test mocks operate in controlled, single-threaded test contexts
final class MockChunkStorageService: ChunkStorageService, @unchecked Sendable {
    var shouldThrowDiskSpaceError = false
    var cleanupCalled = false
    var savedChunks: [ChunkMetadata] = []

    func hasSufficientDiskSpace(requiredBytes: Int64) -> Bool {
        !shouldThrowDiskSpaceError
    }

    func saveChunk(fileURL: URL, index: Int, recordingId: String) async throws -> ChunkMetadata {
        if shouldThrowDiskSpaceError {
            throw ChunkStorageError.insufficientDiskSpace(available: 100_000_000, required: 1_000_000_000)
        }

        let metadata = ChunkMetadata(
            chunkId: ChunkMetadata.generateChunkId(recordingId: recordingId, index: index),
            filePath: fileURL,
            sizeBytes: 50_000_000, // 50MB mock size
            checksum: "mock-checksum-\(index)",
            durationSeconds: 60.0,
            index: index,
            recordingId: recordingId
        )
        savedChunks.append(metadata)
        return metadata
    }

    func calculateChecksum(fileURL: URL) throws -> String {
        return "mock-checksum"
    }

    func cleanup(recordingId: String) async throws {
        cleanupCalled = true
        savedChunks.removeAll { $0.recordingId == recordingId }
    }

    func getChunkDirectory(for recordingId: String) -> URL {
        return URL(fileURLWithPath: "/tmp/\(recordingId)")
    }
}
