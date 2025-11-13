import AVFoundation
import Foundation
import ScreenCaptureKit

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
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var currentChunkURL: URL?
    private var currentChunkIndex: Int = 0

    private var isCapturing: Bool = false
    private var isPaused: Bool = false

    // Chunk timing
    private var chunkDuration: TimeInterval { Config.shared.recording.segmentDuration }
    private var chunkStartTime: CMTime?
    private var sessionStartTime: Date?
    private var totalDuration: TimeInterval = 0

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

        self.captureSession = session
    }

    private func startNewChunk(index: Int) async throws {
        // Create temp URL for chunk
        let tempDir = FileManager.default.temporaryDirectory
        let chunkFileName = "chunk-\(String(format: "%04d", index))-\(UUID().uuidString).mp4"
        let chunkURL = tempDir.appendingPathComponent(chunkFileName)

        currentChunkURL = chunkURL
        currentChunkIndex = index

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
        self.chunkStartTime = CMTime.zero

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

        let elapsed = CMTimeSubtract(currentTime, startTime)
        let elapsedSeconds = CMTimeGetSeconds(elapsed)

        return elapsedSeconds >= chunkDuration
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
    // NOTE: Full sample buffer processing will be implemented in the next phase
    // For now, we're focusing on the protocol and test infrastructure
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // TODO: Implement sample buffer processing with proper concurrency handling
        // This will require:
        // 1. A serial queue for writing samples
        // 2. Proper CMSampleBuffer retention/copying
        // 3. Time-based chunk rotation logic
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        Task { @MainActor in
            delegate?.captureDidEncounterError(.frameDrop(1))
        }
    }
}
