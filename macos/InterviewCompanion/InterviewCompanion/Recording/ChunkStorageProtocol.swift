import CryptoKit
import Foundation

/// Protocol defining chunk storage capabilities for dependency injection and testing
protocol ChunkStorageService: Sendable {
    /// Save a chunk to local storage
    /// - Parameters:
    ///   - fileURL: Temporary URL of the chunk file
    ///   - index: Zero-based chunk index
    ///   - recordingId: Unique recording identifier
    /// - Returns: Metadata about the saved chunk
    /// - Throws: `ChunkStorageError` if save fails
    func saveChunk(fileURL: URL, index: Int, recordingId: String) async throws -> ChunkMetadata

    /// Calculate SHA-256 checksum for a file
    /// - Parameter fileURL: URL of the file
    /// - Returns: Hex-encoded SHA-256 checksum
    /// - Throws: Error if file cannot be read
    func calculateChecksum(fileURL: URL) throws -> String

    /// Clean up temporary chunks for a recording
    /// - Parameter recordingId: Recording to clean up
    /// - Throws: Error if cleanup fails
    func cleanup(recordingId: String) async throws

    /// Check if sufficient disk space is available
    /// - Parameter requiredBytes: Minimum bytes required
    /// - Returns: true if sufficient space available
    func hasSufficientDiskSpace(requiredBytes: Int64) -> Bool

    /// Get the base directory for storing chunks
    /// - Parameter recordingId: Recording identifier
    /// - Returns: URL of the directory
    func getChunkDirectory(for recordingId: String) -> URL
}

/// Metadata about a stored chunk
struct ChunkMetadata: Codable, Sendable {
    /// Unique identifier for this chunk
    let chunkId: String

    /// Local file path
    let filePath: URL

    /// File size in bytes
    let sizeBytes: Int64

    /// SHA-256 checksum (hex-encoded)
    let checksum: String

    /// Duration of this chunk in seconds
    let durationSeconds: TimeInterval

    /// Zero-based index of this chunk
    let index: Int

    /// Recording ID this chunk belongs to
    let recordingId: String

    /// Timestamp when chunk was created
    let createdAt: Date

    init(
        chunkId: String,
        filePath: URL,
        sizeBytes: Int64,
        checksum: String,
        durationSeconds: TimeInterval,
        index: Int,
        recordingId: String,
        createdAt: Date = Date()
    ) {
        self.chunkId = chunkId
        self.filePath = filePath
        self.sizeBytes = sizeBytes
        self.checksum = checksum
        self.durationSeconds = durationSeconds
        self.index = index
        self.recordingId = recordingId
        self.createdAt = createdAt
    }

    /// Generate a chunk ID
    static func generateChunkId(recordingId: String, index: Int) -> String {
        "\(recordingId)-chunk-\(String(format: "%04d", index))"
    }
}

/// Errors that can occur during chunk storage
enum ChunkStorageError: Error, LocalizedError {
    case insufficientDiskSpace(available: Int64, required: Int64)
    case fileWriteFailed(String)
    case checksumCalculationFailed(String)
    case invalidChunkFile(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let available, let required):
            return "Insufficient disk space. Available: \(available / 1_000_000)MB, Required: \(required / 1_000_000)MB"
        case .fileWriteFailed(let reason):
            return "Failed to write chunk file: \(reason)"
        case .checksumCalculationFailed(let reason):
            return "Failed to calculate checksum: \(reason)"
        case .invalidChunkFile(let reason):
            return "Invalid chunk file: \(reason)"
        case .cleanupFailed(let reason):
            return "Failed to clean up chunks: \(reason)"
        }
    }
}
