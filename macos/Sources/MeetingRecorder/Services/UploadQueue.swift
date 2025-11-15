//
//  UploadQueue.swift
//  MeetingRecorder
//
//  Simple S3 chunk uploader - emits events, backend handles orchestration
//

import Foundation

// MARK: - Upload Queue

@MainActor
final class UploadQueue: ObservableObject {

    // MARK: - Properties

    @Published private(set) var isUploading = false
    @Published private(set) var uploadedChunks = 0

    private let s3Uploader: S3Uploader

    // MARK: - Errors

    enum UploadQueueError: Error, LocalizedError {
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .uploadFailed(let reason):
                return "Upload failed: \(reason)"
            }
        }
    }

    // MARK: - Initialization

    init(s3Uploader: S3Uploader) {
        self.s3Uploader = s3Uploader

        Task {
            await Logger.shared.debug("UploadQueue initialized")
        }
    }

    // MARK: - Public API

    /// Upload a chunk to S3
    /// Backend will handle retry, stitching, etc. via EventBridge events
    func enqueue(_ chunk: ChunkMetadata) async throws {
        await Logger.shared.info("Uploading chunk", metadata: [
            "recordingId": chunk.recordingId,
            "chunkIndex": String(chunk.chunkIndex)
        ])

        isUploading = true

        do {
            // Upload to S3
            let result = try await s3Uploader.upload(
                fileURL: chunk.filePath,
                s3Key: chunk.s3Key,
                contentType: "video/quicktime"
            )

            await Logger.shared.info("Chunk uploaded successfully", metadata: [
                "s3Key": result.s3Key,
                "fileSize": String(result.fileSize)
            ])

            uploadedChunks += 1

            // TODO: S3 automatically fires EventBridge events on object upload
            // Backend infrastructure tasks: See Phase 3.5 in tasks.md (T028a-T028g)
            // - S3 → EventBridge (T028a-b)
            // - Lambda validators (T028d-e) handle chunk tracking, session completion
            // - Backend handles: retry logic, stitching, processing orchestration

        } catch {
            await Logger.shared.error("Chunk upload failed", metadata: [
                "error": error.localizedDescription,
                "chunkIndex": String(chunk.chunkIndex)
            ])
            throw UploadQueueError.uploadFailed(error.localizedDescription)
        }

        isUploading = false
    }

    /// Resume incomplete uploads (stub - backend handles this via EventBridge)
    func resumeIncompleteUploads() async throws {
        await Logger.shared.info("Resume uploads delegated to backend")
        // Backend will detect missing chunks and request re-upload if needed
    }

    // MARK: - Testing Support

    #if DEBUG
    static func testing() -> UploadQueue {
        UploadQueue(s3Uploader: S3Uploader())
    }
    #endif
}
