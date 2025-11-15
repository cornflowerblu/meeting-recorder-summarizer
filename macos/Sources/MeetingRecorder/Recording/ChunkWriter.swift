//
//  ChunkWriter.swift
//  MeetingRecorder
//
//  Writes video chunks with checksum computation for upload integrity
//

import Foundation
import AVFoundation
import CryptoKit

// MARK: - Chunk Metadata

/// Metadata for a finalized chunk file
struct ChunkMetadata: Sendable {
    let recordingId: String
    let chunkIndex: Int
    let filePath: URL
    let duration: TimeInterval
    let startTime: Date
    let endTime: Date
    let fileSize: Int64
    let checksum: String?

    /// S3 key path for this chunk
    var s3Key: String {
        "chunks/\(recordingId)/\(filePath.lastPathComponent)"
    }
}

// MARK: - Protocol

/// Protocol for writing video chunks to disk
protocol ChunkWriterProtocol: Sendable {
    /// Start a new chunk file
    /// - Parameters:
    ///   - recordingId: Unique recording identifier
    ///   - chunkIndex: Zero-based chunk index
    ///   - outputDirectory: Directory to write chunk file
    /// - Returns: URL of the chunk file being written
    func startChunk(recordingId: String, chunkIndex: Int, outputDirectory: URL) async throws -> URL

    /// Finalize a chunk file with metadata
    /// - Parameters:
    ///   - filePath: Path to the chunk file
    ///   - duration: Duration of the chunk in seconds
    ///   - startTime: Recording start time for this chunk
    /// - Returns: Complete metadata for the finalized chunk
    func finalizeChunk(filePath: URL, duration: TimeInterval, startTime: Date) async throws -> ChunkMetadata
}

// MARK: - Implementation

/// Writes video chunks to disk with integrity checking
actor ChunkWriter: ChunkWriterProtocol {

    // MARK: - Configuration

    private let enableChecksums: Bool
    private let fileManager = FileManager.default

    // MARK: - Errors

    enum ChunkWriterError: Error, LocalizedError {
        case invalidOutputDirectory
        case fileCreationFailed(Error)
        case fileNotFound(URL)
        case checksumComputationFailed(Error)
        case fileAttributesUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidOutputDirectory:
                return "Output directory does not exist or is not writable"
            case .fileCreationFailed(let error):
                return "Failed to create chunk file: \(error.localizedDescription)"
            case .fileNotFound(let url):
                return "Chunk file not found: \(url.path)"
            case .checksumComputationFailed(let error):
                return "Failed to compute checksum: \(error.localizedDescription)"
            case .fileAttributesUnavailable:
                return "Unable to read file attributes"
            }
        }
    }

    // MARK: - Initialization

    init(enableChecksums: Bool = true) {
        self.enableChecksums = enableChecksums

        Task {
            await Logger.shared.debug("ChunkWriter initialized", metadata: [
                "checksums": String(enableChecksums)
            ])
        }
    }

    // MARK: - ChunkWriterProtocol

    func startChunk(recordingId: String, chunkIndex: Int, outputDirectory: URL) async throws -> URL {
        // Verify output directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            await Logger.shared.error("Output directory does not exist", metadata: [
                "path": outputDirectory.path
            ])
            throw ChunkWriterError.invalidOutputDirectory
        }

        // Generate chunk filename
        let fileName = chunkFileName(recordingId: recordingId, chunkIndex: chunkIndex)
        let filePath = outputDirectory.appendingPathComponent(fileName)

        await Logger.shared.info("Starting chunk", metadata: [
            "recordingId": recordingId,
            "chunkIndex": String(chunkIndex),
            "filePath": filePath.path
        ])

        return filePath
    }

    func finalizeChunk(filePath: URL, duration: TimeInterval, startTime: Date) async throws -> ChunkMetadata {
        // Verify file exists
        guard fileManager.fileExists(atPath: filePath.path) else {
            await Logger.shared.error("Chunk file not found for finalization", metadata: [
                "filePath": filePath.path
            ])
            throw ChunkWriterError.fileNotFound(filePath)
        }

        // Get file size
        let fileSize: Int64
        do {
            let attributes = try fileManager.attributesOfItem(atPath: filePath.path)
            fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            await Logger.shared.error("Failed to read file attributes", metadata: [
                "filePath": filePath.path,
                "error": error.localizedDescription
            ])
            throw ChunkWriterError.fileAttributesUnavailable
        }

        // Compute checksum if enabled
        let checksum: String?
        if enableChecksums {
            checksum = try await computeChecksum(for: filePath)
        } else {
            checksum = nil
        }

        // Extract recording metadata from filename
        let fileName = filePath.deletingPathExtension().lastPathComponent
        let components = fileName.components(separatedBy: "_chunk_")
        let recordingId = components.first ?? "unknown"
        let chunkIndex = Int(components.last ?? "0") ?? 0

        let endTime = startTime.addingTimeInterval(duration)

        let metadata = ChunkMetadata(
            recordingId: recordingId,
            chunkIndex: chunkIndex,
            filePath: filePath,
            duration: duration,
            startTime: startTime,
            endTime: endTime,
            fileSize: fileSize,
            checksum: checksum
        )

        await Logger.shared.info("Chunk finalized", metadata: [
            "recordingId": recordingId,
            "chunkIndex": String(chunkIndex),
            "duration": String(format: "%.2f", duration),
            "fileSize": String(fileSize),
            "checksum": checksum ?? "none"
        ])

        return metadata
    }

    // MARK: - Private Methods

    /// Generate chunk filename with zero-padded index
    private func chunkFileName(recordingId: String, chunkIndex: Int) -> String {
        "\(recordingId)_chunk_\(String(format: "%03d", chunkIndex)).mov"
    }

    /// Compute SHA-256 checksum for a file
    private func computeChecksum(for url: URL) async throws -> String {
        do {
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data)
            let checksum = hash.compactMap { String(format: "%02x", $0) }.joined()

            await Logger.shared.debug("Computed checksum", metadata: [
                "filePath": url.lastPathComponent,
                "checksum": checksum
            ])

            return checksum
        } catch {
            await Logger.shared.error("Checksum computation failed", metadata: [
                "filePath": url.path,
                "error": error.localizedDescription
            ])
            throw ChunkWriterError.checksumComputationFailed(error)
        }
    }
}

// MARK: - Convenience Extensions

extension ChunkWriter {
    /// Create a chunk writer with default settings
    static func standard() -> ChunkWriter {
        ChunkWriter(enableChecksums: true)
    }

    /// Create a chunk writer optimized for testing (no checksums)
    static func testing() -> ChunkWriter {
        ChunkWriter(enableChecksums: false)
    }
}

// MARK: - ChunkMetadata Extensions

extension ChunkMetadata {
    /// Format duration as HH:MM:SS
    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// Format file size as human-readable string
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}
