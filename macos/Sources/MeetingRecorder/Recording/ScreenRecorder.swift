//
//  ScreenRecorder.swift
//  MeetingRecorder
//
//  Screen recording with ScreenCaptureKit, segmented into timed chunks
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// MARK: - Recording State

enum RecordingState: String, Sendable {
    case stopped
    case recording
    case paused
}

// MARK: - Errors

enum ScreenRecorderError: Error, LocalizedError {
    case alreadyRecording(currentRecordingId: String)
    case notRecording
    case permissionDenied
    case configurationFailed(String)
    case streamInitializationFailed(Error)
    case assetWriterFailed(Error)
    case noDisplaysAvailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording(let currentRecordingId):
            return "Already recording session: \(currentRecordingId)"
        case .notRecording:
            return "No active recording session"
        case .permissionDenied:
            return "Screen recording permission denied"
        case .configurationFailed(let reason):
            return "Configuration failed: \(reason)"
        case .streamInitializationFailed(let error):
            return "Stream initialization failed: \(error.localizedDescription)"
        case .assetWriterFailed(let error):
            return "Asset writer failed: \(error.localizedDescription)"
        case .noDisplaysAvailable:
            return "No displays available for recording"
        }
    }
}

// MARK: - Screen Recorder

/// Records screen with ScreenCaptureKit, segmenting into timed chunks
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {

    // MARK: - Properties

    @Published private(set) var recordingState: RecordingState = .stopped
    @Published private(set) var currentRecordingId: String?
    @Published private(set) var elapsedTime: TimeInterval = 0

    private let chunkWriter: ChunkWriterProtocol
    private let chunkDuration: TimeInterval
    private let outputDirectory: URL

    // ScreenCaptureKit
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var availableContent: SCShareableContent?

    // AVFoundation
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    // Chunk management
    private var currentChunkURL: URL?
    private var currentChunkIndex: Int = 0
    private var currentChunkStartTime: Date?
    private var recordingStartTime: Date?
    private var chunkTimer: Timer?

    // MARK: - Initialization

    init(
        chunkWriter: ChunkWriterProtocol,
        chunkDuration: TimeInterval = 60.0,
        outputDirectory: URL
    ) {
        self.chunkWriter = chunkWriter
        self.chunkDuration = chunkDuration
        self.outputDirectory = outputDirectory

        super.init()

        Task {
            await Logger.shared.debug("ScreenRecorder initialized", metadata: [
                "chunkDuration": String(chunkDuration),
                "outputDirectory": outputDirectory.path
            ])
        }
    }

    // MARK: - Public API

    /// Start recording with automatic display selection
    func startRecording(recordingId: String) async throws {
        // Check for existing recording
        guard recordingState == .stopped else {
            throw ScreenRecorderError.alreadyRecording(currentRecordingId: currentRecordingId ?? "unknown")
        }

        await Logger.shared.info("Starting recording", metadata: [
            "recordingId": recordingId
        ])

        // Check permissions
        guard await checkScreenRecordingPermission() else {
            throw ScreenRecorderError.permissionDenied
        }

        // Get available content
        do {
            availableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            await Logger.shared.error("Failed to get shareable content", metadata: [
                "error": error.localizedDescription
            ])
            throw ScreenRecorderError.configurationFailed("Unable to access displays")
        }

        guard let display = availableContent?.displays.first else {
            throw ScreenRecorderError.noDisplaysAvailable
        }

        // Configure stream
        let config = SCStreamConfiguration()
        config.width = Int(display.width) * 2 // Retina
        config.height = Int(display.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60 FPS
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = true

        // Create content filter
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Create stream
        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)

        // Create stream output handler
        let output = StreamOutput(recorder: self)
        streamOutput = output

        do {
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)

            if config.capturesAudio {
                try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .main)
            }
        } catch {
            await Logger.shared.error("Failed to add stream output", metadata: [
                "error": error.localizedDescription
            ])
            throw ScreenRecorderError.streamInitializationFailed(error)
        }

        stream = newStream

        // Initialize recording state
        currentRecordingId = recordingId
        currentChunkIndex = 0
        recordingStartTime = Date()
        recordingState = .recording

        // Start first chunk
        try await startNewChunk()

        // Start stream
        do {
            try await newStream.startCapture()
        } catch {
            await Logger.shared.error("Failed to start capture", metadata: [
                "error": error.localizedDescription
            ])

            // Clean up
            await cleanup()
            throw ScreenRecorderError.streamInitializationFailed(error)
        }

        // Start chunk rotation timer
        startChunkTimer()

        await Logger.shared.info("Recording started successfully", metadata: [
            "recordingId": recordingId,
            "resolution": "\(config.width)x\(config.height)"
        ])
    }

    /// Stop recording and finalize all chunks
    func stopRecording() async throws {
        guard recordingState == .recording else {
            throw ScreenRecorderError.notRecording
        }

        await Logger.shared.info("Stopping recording", metadata: [
            "recordingId": currentRecordingId ?? "unknown",
            "elapsedTime": String(format: "%.2f", elapsedTime)
        ])

        // Stop chunk timer
        chunkTimer?.invalidate()
        chunkTimer = nil

        // Stop stream
        do {
            try await stream?.stopCapture()
        } catch {
            await Logger.shared.warning("Error stopping stream", metadata: [
                "error": error.localizedDescription
            ])
        }

        // Finalize current chunk
        if let url = currentChunkURL, let startTime = currentChunkStartTime {
            let duration = Date().timeIntervalSince(startTime)
            let _ = try await chunkWriter.finalizeChunk(
                filePath: url,
                duration: duration,
                startTime: startTime
            )
        }

        // Clean up
        await cleanup()

        await Logger.shared.info("Recording stopped successfully")
    }

    // MARK: - Chunk Management

    private func startNewChunk() async throws {
        guard let recordingId = currentRecordingId else {
            throw ScreenRecorderError.notRecording
        }

        await Logger.shared.debug("Starting new chunk", metadata: [
            "chunkIndex": String(currentChunkIndex)
        ])

        // Start chunk with ChunkWriter
        let chunkURL = try await chunkWriter.startChunk(
            recordingId: recordingId,
            chunkIndex: currentChunkIndex,
            outputDirectory: outputDirectory
        )

        currentChunkURL = chunkURL
        currentChunkStartTime = Date()

        // Set up AVAssetWriter for this chunk
        try await setupAssetWriter(for: chunkURL)
    }

    private func rotateToNextChunk() async {
        do {
            // Finalize current chunk
            if let url = currentChunkURL, let startTime = currentChunkStartTime {
                // Finish current asset writer
                assetWriter?.finishWriting { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }

                        let duration = Date().timeIntervalSince(startTime)

                        do {
                            let _ = try await self.chunkWriter.finalizeChunk(
                                filePath: url,
                                duration: duration,
                                startTime: startTime
                            )

                            await Logger.shared.info("Chunk finalized", metadata: [
                                "chunkIndex": String(self.currentChunkIndex),
                                "duration": String(format: "%.2f", duration)
                            ])
                        } catch {
                            await Logger.shared.error("Failed to finalize chunk", metadata: [
                                "chunkIndex": String(self.currentChunkIndex),
                                "error": error.localizedDescription
                            ])
                        }
                    }
                }
            }

            // Start next chunk
            currentChunkIndex += 1
            try await startNewChunk()

            await Logger.shared.debug("Rotated to next chunk", metadata: [
                "chunkIndex": String(currentChunkIndex)
            ])
        } catch {
            await Logger.shared.error("Failed to rotate chunk", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: - AVAssetWriter Setup

    private func setupAssetWriter(for url: URL) async throws {
        do {
            let writer = try AVAssetWriter(url: url, fileType: .mov)

            // Video input
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Config.shared.videoCompressionBitrate,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]

            let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            video.expectsMediaDataInRealTime = true

            if writer.canAdd(video) {
                writer.add(video)
                videoInput = video
            }

            // Audio input
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: Config.shared.audioCompressionBitrate
            ]

            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true

            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }

            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            assetWriter = writer

            await Logger.shared.debug("AVAssetWriter configured", metadata: [
                "url": url.lastPathComponent
            ])
        } catch {
            await Logger.shared.error("Failed to setup AVAssetWriter", metadata: [
                "error": error.localizedDescription
            ])
            throw ScreenRecorderError.assetWriterFailed(error)
        }
    }

    // MARK: - Timer Management

    private func startChunkTimer() {
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.rotateToNextChunk()
            }
        }
    }

    // MARK: - Permissions

    private func checkScreenRecordingPermission() async -> Bool {
        // ScreenCaptureKit permission check (macOS 13+)
        if #available(macOS 13.0, *) {
            do {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                return true
            } catch {
                return false
            }
        } else {
            // For macOS 12.3-12.x, we'll assume permission is granted if we get here
            return true
        }
    }

    // MARK: - Sample Buffer Handling

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard recordingState == .recording else { return }

        switch type {
        case .screen:
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }

        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }

        @unknown default:
            break
        }

        // Update elapsed time
        if let startTime = recordingStartTime {
            elapsedTime = Date().timeIntervalSince(startTime)
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        stream = nil
        streamOutput = nil
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        currentChunkURL = nil
        currentChunkStartTime = nil
        currentRecordingId = nil
        recordingState = .stopped
        elapsedTime = 0
    }

    // MARK: - Testing Support

    #if DEBUG
    /// Simulate recording time for testing (advances chunk boundaries)
    func simulateRecordingTime(_ interval: TimeInterval) async {
        guard recordingState == .recording else { return }

        // Fast-forward elapsed time
        if let startTime = recordingStartTime {
            elapsedTime = Date().timeIntervalSince(startTime) + interval
        }

        // Check if we need to rotate chunks
        if let chunkStart = currentChunkStartTime {
            let chunkElapsed = Date().timeIntervalSince(chunkStart) + interval

            if chunkElapsed >= chunkDuration {
                await rotateToNextChunk()
            }
        }
    }
    #endif
}

// MARK: - Stream Output Delegate

private class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    weak var recorder: ScreenRecorder?

    init(recorder: ScreenRecorder) {
        self.recorder = recorder
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        Task { @MainActor in
            recorder?.processSampleBuffer(sampleBuffer, type: type)
        }
    }
}
