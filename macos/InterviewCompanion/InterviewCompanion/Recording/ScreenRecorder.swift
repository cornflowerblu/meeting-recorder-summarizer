import AVFoundation
import Combine
import Foundation

/// Main screen recording coordinator that manages capture and storage
@MainActor
class ScreenRecorder: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var currentChunkIndex: Int = 0
    @Published private(set) var recordingDuration: TimeInterval = 0

    // MARK: - Internal Properties

    private(set) var recordingId: String?

    // MARK: - Dependencies

    private let captureService: ScreenCaptureService
    private let storageService: ChunkStorageService

    // MARK: - Callbacks

    var onChunkCompleted: ((URL, Int, TimeInterval) -> Void)?
    var onProgress: ((TimeInterval, Int) -> Void)?
    var onError: ((CaptureError) -> Void)?

    // MARK: - Private State

    private var recordingStartTime: Date?
    private var pausedDuration: TimeInterval = 0
    private var lastPauseTime: Date?

    // MARK: - Constants

    /// Minimum required disk space (1GB)
    /// This threshold is checked at recording start and before each chunk save to prevent
    /// mid-recording failures due to disk space exhaustion during long sessions
    private let minimumRequiredDiskSpace: Int64 = 1_000_000_000

    // MARK: - Initialization

    init(
        captureService: ScreenCaptureService,
        storageService: ChunkStorageService
    ) {
        self.captureService = captureService
        self.storageService = storageService

        // Set up delegate connection if capture service supports it
        if let avCaptureService = captureService as? AVFoundationCaptureService {
            avCaptureService.delegate = self
        }
    }

    // MARK: - Public Methods

    /// Start a new recording session
    /// - Parameter recordingId: Unique identifier for this recording
    /// - Throws: CaptureError if permission denied or disk space insufficient
    func startRecording(recordingId: String) async throws {
        // Check permission
        guard captureService.hasPermission() else {
            throw CaptureError.permissionDenied
        }

        // Check disk space (require at least 1GB)
        guard storageService.hasSufficientDiskSpace(requiredBytes: minimumRequiredDiskSpace) else {
            throw ChunkStorageError.insufficientDiskSpace(
                available: 0, // TODO: Get actual available space
                required: minimumRequiredDiskSpace
            )
        }

        // Reset state
        self.recordingId = recordingId
        currentChunkIndex = 0
        recordingDuration = 0
        recordingStartTime = Date()
        pausedDuration = 0
        lastPauseTime = nil

        // Start capture
        try await captureService.startCapture()

        isRecording = true
    }

    /// Pause the current recording
    /// - Throws: CaptureError if not currently recording
    func pauseRecording() async throws {
        guard isRecording else {
            throw CaptureError.invalidState("Cannot pause: not recording")
        }

        guard !isPaused else {
            throw CaptureError.invalidState("Already paused")
        }

        try await captureService.pauseCapture()

        lastPauseTime = Date()
        isPaused = true
    }

    /// Resume a paused recording
    /// - Throws: CaptureError if not currently paused
    func resumeRecording() async throws {
        guard isRecording else {
            throw CaptureError.invalidState("Cannot resume: not recording")
        }

        guard isPaused else {
            throw CaptureError.invalidState("Cannot resume: not paused")
        }

        // Update paused duration
        if let pauseTime = lastPauseTime {
            pausedDuration += Date().timeIntervalSince(pauseTime)
            lastPauseTime = nil
        }

        try await captureService.resumeCapture()

        isPaused = false
    }

    /// Stop the current recording
    /// - Throws: CaptureError if not currently recording
    func stopRecording() async throws {
        guard isRecording else {
            throw CaptureError.invalidState("Cannot stop: not recording")
        }

        try await captureService.stopCapture()

        // Reset state
        isRecording = false
        isPaused = false
        recordingStartTime = nil
        pausedDuration = 0
        lastPauseTime = nil
    }

    /// Cancel the current recording and clean up all chunks
    /// - Throws: CaptureError or ChunkStorageError
    func cancelRecording() async throws {
        guard let recordingId = recordingId else {
            throw CaptureError.invalidState("No recording to cancel")
        }

        // Stop capture if running
        if isRecording {
            try? await captureService.stopCapture()
        }

        // Clean up storage
        try await storageService.cleanup(recordingId: recordingId)

        // Reset state
        isRecording = false
        isPaused = false
        self.recordingId = nil
        currentChunkIndex = 0
        recordingDuration = 0
        recordingStartTime = nil
        pausedDuration = 0
        lastPauseTime = nil
    }
}

// MARK: - ScreenCaptureDelegate

extension ScreenRecorder: ScreenCaptureDelegate {
    func captureDidCompleteChunk(fileURL: URL, index: Int, duration: TimeInterval) {
        guard let recordingId = recordingId else { return }

        // Store chunk asynchronously
        let service = storageService
        Task { @MainActor in
            // Check disk space before saving each chunk
            // Note: This check is redundant with the initial check in startRecording(),
            // but necessary to handle disk space depletion during long recording sessions.
            // A 60-minute recording can generate ~3GB of chunks, so disk space can be
            // exhausted mid-recording even if sufficient space existed at start.
            if !service.hasSufficientDiskSpace(requiredBytes: minimumRequiredDiskSpace) {
                onError?(.diskSpaceLow)
                try? await stopRecording()
                return
            }

            do {
                let metadata = try await service.saveChunk(
                    fileURL: fileURL,
                    index: index,
                    recordingId: recordingId
                )

                // Only update state AFTER successful save
                currentChunkIndex = index + 1

                // Notify completion
                onChunkCompleted?(metadata.filePath, index, duration)
            } catch {
                onError?(.captureSessionFailed("Failed to save chunk \(index): \(error.localizedDescription)"))
            }
        }
    }

    func captureDidEncounterError(_ error: CaptureError) {
        // Forward error to callback
        onError?(error)

        // For non-critical errors (like frame drops), continue recording
        if case .frameDrop = error {
            // Log but continue
            return
        }

        // For critical errors, stop recording
        Task {
            try? await stopRecording()
        }
    }

    func captureDidUpdateProgress(duration: TimeInterval, chunkCount: Int) {
        recordingDuration = duration
        onProgress?(duration, chunkCount)
    }
}
