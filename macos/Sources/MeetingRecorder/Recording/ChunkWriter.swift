import CryptoKit
import Foundation

/// Service for writing and managing recording chunks on local storage
final class ChunkWriter: ChunkStorageService, @unchecked Sendable {
    // MARK: - Properties

    private let fileManager = FileManager.default
    private let baseDirectory: URL

    // Minimum free space required: 1GB
    private let minimumFreeSpace: Int64 = 1_000_000_000

    // MARK: - Initialization

    init() {
        // Base directory: ~/Library/Caches/MeetingRecorder/
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.baseDirectory = cacheDir.appendingPathComponent("MeetingRecorder", isDirectory: true)

        // Create base directory if it doesn't exist
        try? fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    // MARK: - ChunkStorageService Implementation

    func saveChunk(fileURL: URL, index: Int, recordingId: String) async throws -> ChunkMetadata {
        // Check disk space
        guard hasSufficientDiskSpace(requiredBytes: minimumFreeSpace) else {
            let available = getAvailableDiskSpace()
            throw ChunkStorageError.insufficientDiskSpace(
                available: available,
                required: minimumFreeSpace
            )
        }

        // Get chunk directory
        let chunkDir = getChunkDirectory(for: recordingId)

        // Create directory if needed
        try fileManager.createDirectory(
            at: chunkDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Generate chunk filename
        let chunkFileName = "part-\(String(format: "%04d", index + 1)).mp4"
        let destinationURL = chunkDir.appendingPathComponent(chunkFileName)

        // Calculate checksum before moving
        let checksum = try calculateChecksum(fileURL: fileURL)

        // Get file size
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = attributes[.size] as? Int64 else {
            throw ChunkStorageError.invalidChunkFile("Cannot determine file size")
        }

        // Get duration (approximate from file size and bitrate)
        // For a more accurate duration, we'd need to parse the video file
        let estimatedDuration: TimeInterval = 60.0 // Default to 60s

        // Atomic write: use temporary file then rename
        let tempURL = destinationURL.appendingPathExtension("tmp")

        do {
            // Copy to temp location
            if fileManager.fileExists(atPath: tempURL.path) {
                try fileManager.removeItem(at: tempURL)
            }

            try fileManager.copyItem(at: fileURL, to: tempURL)

            // Atomic rename
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.moveItem(at: tempURL, to: destinationURL)

            // Delete original temp file
            try? fileManager.removeItem(at: fileURL)

        } catch {
            // Cleanup temp file on error
            try? fileManager.removeItem(at: tempURL)
            throw ChunkStorageError.fileWriteFailed(error.localizedDescription)
        }

        // Create metadata
        let metadata = ChunkMetadata(
            chunkId: ChunkMetadata.generateChunkId(recordingId: recordingId, index: index),
            filePath: destinationURL,
            sizeBytes: fileSize,
            checksum: checksum,
            durationSeconds: estimatedDuration,
            index: index,
            recordingId: recordingId,
            createdAt: Date()
        )

        return metadata
    }

    func calculateChecksum(fileURL: URL) throws -> String {
        do {
            let data = try Data(contentsOf: fileURL)
            let hash = SHA256.hash(data: data)
            return hash.compactMap { String(format: "%02x", $0) }.joined()
        } catch {
            throw ChunkStorageError.checksumCalculationFailed(error.localizedDescription)
        }
    }

    func cleanup(recordingId: String) async throws {
        let chunkDir = getChunkDirectory(for: recordingId)

        guard fileManager.fileExists(atPath: chunkDir.path) else {
            // Directory doesn't exist, nothing to clean up
            return
        }

        do {
            try fileManager.removeItem(at: chunkDir)
        } catch {
            throw ChunkStorageError.cleanupFailed(error.localizedDescription)
        }
    }

    func hasSufficientDiskSpace(requiredBytes: Int64) -> Bool {
        let available = getAvailableDiskSpace()
        return available >= requiredBytes
    }

    func getChunkDirectory(for recordingId: String) -> URL {
        baseDirectory.appendingPathComponent(recordingId, isDirectory: true)
    }

    // MARK: - Private Methods

    private func getAvailableDiskSpace() -> Int64 {
        do {
            let systemAttributes = try fileManager.attributesOfFileSystem(
                forPath: baseDirectory.path
            )

            if let freeSpace = systemAttributes[.systemFreeSize] as? Int64 {
                return freeSpace
            }
        } catch {
            // If we can't determine, return 0 to be safe
            return 0
        }

        return 0
    }

    /// Get chunk files for a recording, sorted by index
    func getChunkFiles(for recordingId: String) throws -> [URL] {
        let chunkDir = getChunkDirectory(for: recordingId)

        guard fileManager.fileExists(atPath: chunkDir.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: chunkDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        )

        // Filter only .mp4 files and sort by name
        return contents
            .filter { $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Get total size of all chunks for a recording
    func getTotalSize(for recordingId: String) throws -> Int64 {
        let chunks = try getChunkFiles(for: recordingId)

        var totalSize: Int64 = 0
        for chunkURL in chunks {
            let attributes = try fileManager.attributesOfItem(atPath: chunkURL.path)
            if let size = attributes[.size] as? Int64 {
                totalSize += size
            }
        }

        return totalSize
    }
}
