import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// Real implementation of screen capture using AVFoundation
///
/// ⚠️ **WARNING: Partial Implementation**
/// This is a foundational implementation establishing the protocol contract and basic structure.
/// Critical functionality NOT yet implemented:
/// - Actual sample buffer processing and video data capture
/// - Chunk rotation logic based on time intervals
/// - Full error recovery and resource cleanup
///
/// DO NOT USE for production recording. This will be completed in Phase 3, PR Group 2.
/// For testing purposes, use mock implementations instead.
@MainActor
class AVFoundationCaptureService: NSObject, ScreenCaptureService {
    // MARK: - Properties

    weak var delegate: ScreenCaptureDelegate?

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var currentChunkURL: URL?
    private var currentChunkIndex: Int = 0

    private var isCapturing: Bool = false
    private var isPaused: Bool = false

    // Chunk timing
    private var chunkDuration: TimeInterval { Config.shared.recording.segmentDuration }
    private var chunkStartTime: CMTime?
    private var lastFrameTime: CMTime?  // Timestamp of last processed frame
    private var sessionStartTime: Date?
    private var totalDuration: TimeInterval = 0
    private var accumulatedChunkDuration: TimeInterval = 0  // Time recorded in current chunk before any pauses

    // Video processing
    private let videoProcessingQueue = DispatchQueue(
        label: "com.interviewcompanion.videocapture",
        qos: .userInitiated
    )
    private var processedFrameCount: Int = 0
    private var droppedFrameCount: Int = 0
    private var createdChunkURLs: [URL] = []

    // Video quality configuration (from Config)
    private var frameRate: Int32 { Config.shared.recording.frameRate }
    private var resolution: CGSize { Config.shared.recording.resolution.size }
    private var bitrate: Int { Config.shared.recording.bitrate }

    // MARK: - ScreenCaptureService Implementation

    func hasPermission() -> Bool {
        // Use CGPreflightScreenCaptureAccess to check screen recording permission
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission() async throws {
        if #available(macOS 14.0, *) {
            // Request permission using ScreenCaptureKit
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            } catch {
                throw CaptureError.permissionDenied
            }
        } else {
            // For older macOS, request using CGRequestScreenCaptureAccess
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                throw CaptureError.permissionDenied
            }
        }
    }

    func startCapture() async throws {
        guard !isCapturing else {
            throw CaptureError.invalidState("Already capturing")
        }

        guard hasPermission() else {
            throw CaptureError.permissionDenied
        }

        guard delegate != nil else {
            throw CaptureError.invalidState("Delegate must be set before starting capture")
        }

        // Setup capture session
        try setupCaptureSession()

        // Start the session
        captureSession?.startRunning()

        isCapturing = true
        sessionStartTime = Date()
        currentChunkIndex = 0

        // Start first chunk
        try await startNewChunk(index: 0)
    }

    func stopCapture() async throws {
        guard isCapturing else {
            throw CaptureError.invalidState("Not capturing")
        }

        // Finalize current chunk
        await finalizeCurrentChunk()

        // Stop session
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil

        isCapturing = false
        isPaused = false
    }

    func pauseCapture() async throws {
        guard isCapturing else {
            throw CaptureError.invalidState("Not capturing")
        }

        guard !isPaused else {
            throw CaptureError.invalidState("Already paused")
        }

        // Calculate elapsed time in current recording segment
        if let startTime = chunkStartTime, let lastTime = lastFrameTime {
            let elapsed = CMTimeSubtract(lastTime, startTime)
            let elapsedSeconds = CMTimeGetSeconds(elapsed)
            accumulatedChunkDuration += elapsedSeconds
        }

        // Reset chunk start time so resume can set a new reference
        chunkStartTime = nil

        // Pause the asset writer (stop writing frames but keep session running)
        isPaused = true
    }

    func resumeCapture() async throws {
        guard isCapturing else {
            throw CaptureError.invalidState("Not capturing")
        }

        guard isPaused else {
            throw CaptureError.invalidState("Not paused")
        }

        isPaused = false
    }

    // MARK: - Private Methods

    private func setupCaptureSession() throws {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        // Create screen input
        guard let screen = NSScreen.main else {
            throw CaptureError.captureSessionFailed("No main screen found")
        }

        let displayID =
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            ?? 0

        guard let screenInput = AVCaptureScreenInput(displayID: displayID) else {
            throw CaptureError.captureSessionFailed("Failed to create screen input")
        }

        // Configure screen input
        screenInput.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        screenInput.capturesMouseClicks = false
        screenInput.capturesCursor = true

        // Add input to session
        if session.canAddInput(screenInput) {
            session.addInput(screenInput)
        } else {
            throw CaptureError.captureSessionFailed("Cannot add screen input to session")
        }

        // Create and configure video data output
        let output = AVCaptureVideoDataOutput()

        // Configure video settings - use 32BGRA for compatibility with asset writer
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        // Set the sample buffer delegate on our video processing queue
        output.setSampleBufferDelegate(self, queue: videoProcessingQueue)

        // Don't drop frames if processing is slow (we'll handle this in delegate)
        output.alwaysDiscardsLateVideoFrames = false

        // Add output to session
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            throw CaptureError.captureSessionFailed("Cannot add video output to session")
        }

        self.captureSession = session
        self.videoOutput = output
    }

    private func startNewChunk(index: Int) async throws {
        // Create temp URL for chunk
        let tempDir = FileManager.default.temporaryDirectory
        let chunkFileName = "chunk-\(String(format: "%04d", index))-\(UUID().uuidString).mp4"
        let chunkURL = tempDir.appendingPathComponent(chunkFileName)

        currentChunkURL = chunkURL
        currentChunkIndex = index
        createdChunkURLs.append(chunkURL)

        // Create asset writer
        guard let writer = try? AVAssetWriter(url: chunkURL, fileType: .mp4) else {
            throw CaptureError.captureSessionFailed("Failed to create asset writer")
        }

        // Configure video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: resolution.width,
            AVVideoHeightKey: resolution.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        } else {
            throw CaptureError.captureSessionFailed("Cannot add video input to writer")
        }

        // Start writing
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.videoInput = videoInput
        self.chunkStartTime = nil  // Will be set to first frame's timestamp
        self.accumulatedChunkDuration = 0  // Reset for new chunk

        // TODO: Connect capture output to writer input
        // This is a simplified implementation. In reality, you'd need to:
        // 1. Add AVCaptureVideoDataOutput to the session
        // 2. Implement AVCaptureVideoDataOutputSampleBufferDelegate
        // 3. Write samples to the asset writer
        // 4. Monitor time and rotate chunks
    }

    private func finalizeCurrentChunk() async {
        guard let writer = assetWriter,
            let chunkURL = currentChunkURL
        else {
            return
        }

        // Finish writing
        videoInput?.markAsFinished()

        await writer.finishWriting()

        // Calculate duration (estimate based on chunk configuration)
        let durationSeconds = chunkDuration

        // Notify delegate
        delegate?.captureDidCompleteChunk(
            fileURL: chunkURL,
            index: currentChunkIndex,
            duration: durationSeconds
        )

        // Update total duration
        totalDuration += durationSeconds

        // Reset for next chunk
        assetWriter = nil
        videoInput = nil
        currentChunkURL = nil
        chunkStartTime = nil
    }

    private func shouldRotateChunk(currentTime: CMTime) -> Bool {
        guard let startTime = chunkStartTime else { return false }

        // Calculate elapsed time in current recording segment (since last pause or chunk start)
        let elapsed = CMTimeSubtract(currentTime, startTime)
        let elapsedSeconds = CMTimeGetSeconds(elapsed)

        // Add accumulated time from before any pauses
        let totalRecordedTime = accumulatedChunkDuration + elapsedSeconds

        return totalRecordedTime >= chunkDuration
    }

    private func rotateChunk(at currentTime: CMTime) async {
        // Finalize current chunk
        await finalizeCurrentChunk()

        // Start new chunk
        let nextIndex = currentChunkIndex + 1
        try? await startNewChunk(index: nextIndex)

        // Notify progress
        delegate?.captureDidUpdateProgress(
            duration: totalDuration,
            chunkCount: nextIndex
        )
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension AVFoundationCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Check if paused - if so, don't write frames
        Task { @MainActor in
            guard !isPaused else { return }

            // Get current video input and check if ready
            guard let videoInput = videoInput, videoInput.isReadyForMoreMediaData else {
                return
            }

            // Get current time for chunk rotation check
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Set chunk start time from first frame if not already set
            if chunkStartTime == nil {
                chunkStartTime = presentationTime
            }

            // Track last frame time for pause calculations
            lastFrameTime = presentationTime

            // Write the sample buffer to the asset writer
            if videoInput.append(sampleBuffer) {
                processedFrameCount += 1

                // Check if we need to rotate chunks
                if shouldRotateChunk(currentTime: presentationTime) {
                    await rotateChunk(at: presentationTime)
                }
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        Task { @MainActor in
            droppedFrameCount += 1
            delegate?.captureDidEncounterError(.frameDrop(droppedFrameCount))
        }
    }
}

// MARK: - Testing Support

#if DEBUG
/// Extensions for testing - these expose internal state for verification
extension AVFoundationCaptureService {
    func hasVideoOutput() async -> Bool {
        return videoOutput != nil
    }

    func getVideoOutputSettings() async throws -> [String: Any] {
        guard let output = videoOutput else {
            throw CaptureError.captureSessionFailed("No video output configured")
        }
        return output.videoSettings ?? [:]
    }

    func hasVideoOutputDelegate() async -> Bool {
        return videoOutput?.sampleBufferDelegate != nil
    }

    func canProcessSampleBuffer(_ sampleBuffer: CMSampleBuffer) async -> Bool {
        // Check if we have a video input and it's ready
        guard let input = videoInput else {
            return false
        }
        return input.isReadyForMoreMediaData
    }

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) async throws {
        // Simulate processing by appending to video input
        guard let input = videoInput else {
            throw CaptureError.captureSessionFailed("No video input configured")
        }

        // Wait for input to be ready (with timeout for tests)
        var retries = 0
        while !input.isReadyForMoreMediaData && retries < 200 {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            retries += 1
        }

        guard input.isReadyForMoreMediaData else {
            throw CaptureError.captureSessionFailed("Video input not ready after timeout")
        }

        // Get presentation time for chunk tracking
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Set chunk start time from first frame if not already set
        if chunkStartTime == nil {
            chunkStartTime = presentationTime
        }

        // Track last frame time for pause calculations
        lastFrameTime = presentationTime

        if !input.append(sampleBuffer) {
            throw CaptureError.captureSessionFailed("Failed to append sample buffer")
        }

        processedFrameCount += 1

        // Check for chunk rotation
        if shouldRotateChunk(currentTime: presentationTime) {
            await rotateChunk(at: presentationTime)
        }
    }

    func getProcessedFrameCount() async -> Int {
        return processedFrameCount
    }

    func getDroppedFrameCount() async -> Int {
        return droppedFrameCount
    }

    func simulateWriterNotReady() async throws {
        // Mark video input as not ready by stopping the asset writer temporarily
        videoInput?.markAsFinished()
    }

    func getVideoProcessingQueueLabel() async throws -> String {
        return videoProcessingQueue.label
    }

    func getCurrentChunkIndex() async -> Int {
        return currentChunkIndex
    }

    func getCreatedChunkCount() async -> Int {
        return createdChunkURLs.count
    }

    func getChunkFileURLs() async -> [URL] {
        return createdChunkURLs
    }
}
#endif
