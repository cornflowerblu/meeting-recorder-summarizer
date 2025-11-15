import AVFoundation
import Foundation

/// Protocol defining screen capture capabilities for dependency injection and testing
@MainActor
protocol ScreenCaptureService {
    /// Start capturing screen content
    /// - Throws: `CaptureError` if permission denied or capture fails
    func startCapture() async throws

    /// Stop capturing screen content
    /// - Throws: `CaptureError` if stop fails
    func stopCapture() async throws

    /// Pause screen capture (buffering continues but not written)
    /// - Throws: `CaptureError` if pause fails
    func pauseCapture() async throws

    /// Resume screen capture after pause
    /// - Throws: `CaptureError` if resume fails
    func resumeCapture() async throws

    /// Check if screen recording permission is granted
    /// - Returns: true if permission granted
    func hasPermission() -> Bool

    /// Request screen recording permission
    func requestPermission() async throws
}

/// Errors that can occur during screen capture
enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case captureSessionFailed(String)
    case invalidState(String)
    case diskSpaceLow
    case frameDrop(Int)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission is required. Click 'Open Settings' to grant permission."
        case .captureSessionFailed(let reason):
            return "Screen capture failed: \(reason)"
        case .invalidState(let state):
            return "Invalid capture state: \(state)"
        case .diskSpaceLow:
            return "Disk space is low. At least 1GB free space required for recording."
        case .frameDrop(let count):
            return "Dropped \(count) frames during capture"
        }
    }
}

/// Delegate protocol for receiving capture events
@MainActor
protocol ScreenCaptureDelegate: AnyObject {
    /// Called when a chunk is completed and ready for processing
    /// - Parameters:
    ///   - fileURL: Local URL of the completed chunk
    ///   - index: Zero-based chunk index
    ///   - duration: Actual duration of the chunk
    func captureDidCompleteChunk(fileURL: URL, index: Int, duration: TimeInterval)

    /// Called when capture encounters an error
    /// - Parameter error: The error that occurred
    func captureDidEncounterError(_ error: CaptureError)

    /// Called periodically to report progress
    /// - Parameters:
    ///   - duration: Total duration recorded so far
    ///   - chunkCount: Number of chunks completed
    func captureDidUpdateProgress(duration: TimeInterval, chunkCount: Int)
}
