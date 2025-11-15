import XCTest
import AVFoundation
@testable import MeetingRecorder

@MainActor
final class ScreenRecorderTests: XCTestCase {
    var screenRecorder: ScreenRecorder!
    var mockChunkWriter: MockChunkWriter!
    var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Initialize mock dependencies
        mockChunkWriter = MockChunkWriter()
        
        // Initialize screen recorder with test configuration
        screenRecorder = ScreenRecorder(
            chunkWriter: mockChunkWriter,
            chunkDuration: 60.0, // 60 second chunks for production
            outputDirectory: tempDirectory
        )
    }
    
    override func tearDown() async throws {
        // Clean up temporary files
        try? FileManager.default.removeItem(at: tempDirectory)
        screenRecorder = nil
        mockChunkWriter = nil
        
        try await super.tearDown()
    }
    
    // MARK: - Chunk Segmentation Tests
    
    func testChunkSegmentationAt60Seconds() async throws {
        // Given: A recording session with 60-second chunk duration
        let recordingId = "rec_test_123"
        
        // When: Starting recording
        try await screenRecorder.startRecording(recordingId: recordingId)
        
        // Simulate 60 seconds of recording time
        try await advanceRecordingTime(by: 60.0)
        
        // Then: First chunk should be finalized
        XCTAssertEqual(mockChunkWriter.finalizedChunks.count, 1)
        
        let firstChunk = try XCTUnwrap(mockChunkWriter.finalizedChunks.first)
        XCTAssertEqual(firstChunk.recordingId, recordingId)
        XCTAssertEqual(firstChunk.chunkIndex, 0)
        XCTAssertEqual(firstChunk.duration, 60.0, accuracy: 0.1)
    }
    
    func testMultipleChunkSegmentation() async throws {
        // Given: A longer recording session
        let recordingId = "rec_test_456"
        
        // When: Recording for 150 seconds (2.5 chunks)
        try await screenRecorder.startRecording(recordingId: recordingId)
        
        // Advance through multiple chunk boundaries
        try await advanceRecordingTime(by: 60.0)  // First chunk
        try await advanceRecordingTime(by: 60.0)  // Second chunk
        try await advanceRecordingTime(by: 30.0)  // Partial third chunk
        
        // Then: Two full chunks should be finalized
        XCTAssertEqual(mockChunkWriter.finalizedChunks.count, 2)
        
        let firstChunk = mockChunkWriter.finalizedChunks[0]
        let secondChunk = mockChunkWriter.finalizedChunks[1]
        
        XCTAssertEqual(firstChunk.chunkIndex, 0)
        XCTAssertEqual(secondChunk.chunkIndex, 1)
        XCTAssertEqual(firstChunk.duration, 60.0, accuracy: 0.1)
        XCTAssertEqual(secondChunk.duration, 60.0, accuracy: 0.1)
    }
    
    func testChunkFileNaming() async throws {
        // Given: A recording session
        let recordingId = "rec_test_789"
        
        // When: Creating chunks
        try await screenRecorder.startRecording(recordingId: recordingId)
        try await advanceRecordingTime(by: 60.0)
        
        // Then: Chunk should have correct naming pattern
        let chunk = try XCTUnwrap(mockChunkWriter.finalizedChunks.first)
        
        // Expected format: {recordingId}_chunk_{index:03d}.mov
        let expectedFileName = "\(recordingId)_chunk_000.mov"
        XCTAssertTrue(chunk.filePath.lastPathComponent == expectedFileName)
        
        // Advance to second chunk
        try await advanceRecordingTime(by: 60.0)
        
        let secondChunk = mockChunkWriter.finalizedChunks[1]
        let expectedSecondFileName = "\(recordingId)_chunk_001.mov"
        XCTAssertTrue(secondChunk.filePath.lastPathComponent == expectedSecondFileName)
    }
    
    // MARK: - Recording State Tests
    
    func testRecordingStateTransitions() async throws {
        let recordingId = "rec_state_test"
        
        // Initial state should be stopped
        XCTAssertEqual(screenRecorder.recordingState, .stopped)
        XCTAssertNil(screenRecorder.currentRecordingId)
        
        // After starting recording
        try await screenRecorder.startRecording(recordingId: recordingId)
        XCTAssertEqual(screenRecorder.recordingState, .recording)
        XCTAssertEqual(screenRecorder.currentRecordingId, recordingId)
        
        // After stopping recording
        try await screenRecorder.stopRecording()
        XCTAssertEqual(screenRecorder.recordingState, .stopped)
        XCTAssertNil(screenRecorder.currentRecordingId)
    }
    
    func testCannotStartRecordingWhenAlreadyRecording() async throws {
        // Given: An active recording session
        try await screenRecorder.startRecording(recordingId: "rec_first")
        
        // When/Then: Attempting to start another recording should throw
        await XCTAssertThrowsError(
            try await screenRecorder.startRecording(recordingId: "rec_second")
        ) { error in
            XCTAssertTrue(error is ScreenRecorderError)
            if case let ScreenRecorderError.alreadyRecording(currentId) = error {
                XCTAssertEqual(currentId, "rec_first")
            } else {
                XCTFail("Expected alreadyRecording error")
            }
        }
    }
    
    func testStopRecordingFinalizesCurrentChunk() async throws {
        // Given: An active recording with partial chunk
        let recordingId = "rec_finalize_test"
        try await screenRecorder.startRecording(recordingId: recordingId)
        
        // Record for 30 seconds (less than full chunk)
        try await advanceRecordingTime(by: 30.0)
        XCTAssertEqual(mockChunkWriter.finalizedChunks.count, 0)
        
        // When: Stopping recording
        try await screenRecorder.stopRecording()
        
        // Then: Partial chunk should be finalized
        XCTAssertEqual(mockChunkWriter.finalizedChunks.count, 1)
        
        let finalChunk = try XCTUnwrap(mockChunkWriter.finalizedChunks.first)
        XCTAssertEqual(finalChunk.duration, 30.0, accuracy: 0.1)
        XCTAssertEqual(finalChunk.chunkIndex, 0)
    }
    
    // MARK: - Error Handling Tests
    
    func testHandlesChunkWriterErrors() async throws {
        // Given: A chunk writer that will fail
        mockChunkWriter.shouldFailOnWrite = true
        
        let recordingId = "rec_error_test"
        
        // When/Then: Starting recording should propagate error
        await XCTAssertThrowsError(
            try await screenRecorder.startRecording(recordingId: recordingId)
        ) { error in
            XCTAssertTrue(error is MockChunkWriterError)
        }
        
        // Recording state should remain stopped on error
        XCTAssertEqual(screenRecorder.recordingState, .stopped)
        XCTAssertNil(screenRecorder.currentRecordingId)
    }
    
    func testRecoveryFromChunkSegmentationError() async throws {
        // Given: A recording that fails during chunk boundary
        let recordingId = "rec_recovery_test"
        try await screenRecorder.startRecording(recordingId: recordingId)
        
        // When: Chunk writer fails at 60-second boundary
        try await advanceRecordingTime(by: 59.0)
        mockChunkWriter.shouldFailOnFinalize = true
        
        // Advance to trigger chunk boundary (should handle error gracefully)
        try await advanceRecordingTime(by: 2.0)
        
        // Then: Recording should continue with next chunk
        XCTAssertEqual(screenRecorder.recordingState, .recording)
        
        // Reset error condition and continue
        mockChunkWriter.shouldFailOnFinalize = false
        try await advanceRecordingTime(by: 60.0)
        
        // Should have recovered and created subsequent chunks
        XCTAssertTrue(mockChunkWriter.finalizedChunks.count >= 1)
    }
    
    // MARK: - Timing and Duration Tests
    
    func testAccurateChunkDurationTracking() async throws {
        let recordingId = "rec_duration_test"
        
        // Test various chunk durations
        let testDurations: [TimeInterval] = [60.0, 30.5, 120.25, 0.1]
        
        for duration in testDurations {
            setUp()
            
            try await screenRecorder.startRecording(recordingId: "\(recordingId)_\(Int(duration))")
            try await advanceRecordingTime(by: duration)
            try await screenRecorder.stopRecording()
            
            let chunk = try XCTUnwrap(mockChunkWriter.finalizedChunks.first)
            XCTAssertEqual(chunk.duration, duration, accuracy: 0.01)
            
            tearDown()
        }
    }
    
    func testChunkTimestampSequencing() async throws {
        let recordingId = "rec_timestamp_test"
        
        try await screenRecorder.startRecording(recordingId: recordingId)
        
        // Record multiple chunks and verify timestamp progression
        let startTime = Date()
        
        try await advanceRecordingTime(by: 60.0)
        let firstChunk = try XCTUnwrap(mockChunkWriter.finalizedChunks.first)
        
        try await advanceRecordingTime(by: 60.0)
        let secondChunk = mockChunkWriter.finalizedChunks[1]
        
        // Verify timestamps are sequential and realistic
        XCTAssertTrue(firstChunk.startTime >= startTime)
        XCTAssertTrue(secondChunk.startTime >= firstChunk.endTime)
        
        let expectedSecondStart = firstChunk.startTime.addingTimeInterval(60.0)
        XCTAssertEqual(secondChunk.startTime.timeIntervalSince(expectedSecondStart), 0.0, accuracy: 1.0)
    }
    
    // MARK: - Helper Methods
    
    /// Simulates the passage of recording time to trigger chunk boundaries
    private func advanceRecordingTime(by interval: TimeInterval) async throws {
        // This would interact with the real AVFoundation recording session
        // For now, we'll simulate by calling internal timing methods
        await screenRecorder.simulateRecordingTime(interval)
    }
}

// MARK: - Mock Dependencies

final class MockChunkWriter: ChunkWriterProtocol {
    var finalizedChunks: [ChunkMetadata] = []
    var shouldFailOnWrite = false
    var shouldFailOnFinalize = false
    
    func startChunk(recordingId: String, chunkIndex: Int, outputDirectory: URL) async throws -> URL {
        if shouldFailOnWrite {
            throw MockChunkWriterError.writeFailure
        }
        
        let fileName = "\(recordingId)_chunk_\(String(format: "%03d", chunkIndex)).mov"
        return outputDirectory.appendingPathComponent(fileName)
    }
    
    func finalizeChunk(filePath: URL, duration: TimeInterval, startTime: Date) async throws -> ChunkMetadata {
        if shouldFailOnFinalize {
            throw MockChunkWriterError.finalizeFailure
        }
        
        let metadata = ChunkMetadata(
            recordingId: extractRecordingId(from: filePath),
            chunkIndex: extractChunkIndex(from: filePath),
            filePath: filePath,
            duration: duration,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(duration),
            fileSize: 1024 * 1024 // Mock 1MB file
        )
        
        finalizedChunks.append(metadata)
        return metadata
    }
    
    private func extractRecordingId(from url: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        let components = fileName.components(separatedBy: "_chunk_")
        return components.first ?? "unknown"
    }
    
    private func extractChunkIndex(from url: URL) -> Int {
        let fileName = url.deletingPathExtension().lastPathComponent
        let components = fileName.components(separatedBy: "_chunk_")
        return Int(components.last ?? "0") ?? 0
    }
}

enum MockChunkWriterError: Error {
    case writeFailure
    case finalizeFailure
}

// MARK: - Supporting Types (These will be defined in implementation)

enum ScreenRecorderError: Error {
    case alreadyRecording(currentRecordingId: String)
    case notRecording
    case permissionDenied
    case configurationFailed
}

enum RecordingState {
    case stopped
    case recording
    case paused
}

struct ChunkMetadata {
    let recordingId: String
    let chunkIndex: Int
    let filePath: URL
    let duration: TimeInterval
    let startTime: Date
    let endTime: Date
    let fileSize: Int64
}

protocol ChunkWriterProtocol {
    func startChunk(recordingId: String, chunkIndex: Int, outputDirectory: URL) async throws -> URL
    func finalizeChunk(filePath: URL, duration: TimeInterval, startTime: Date) async throws -> ChunkMetadata
}
