//
//  UploadQueue.swift
//  MeetingRecorder
//
//  Background queue worker for uploading chunks to S3 with retry and concurrency control
//

import Foundation

// MARK: - Upload Queue

@MainActor
final class UploadQueue: ObservableObject {

    // MARK: - Properties

    @Published private(set) var isProcessing = false

    private let s3Uploader: S3Uploader
    private let manifestStore: UploadManifestStore
    private let maxConcurrentUploads: Int
    private let retryDelay: TimeInterval
    private let maxRetryAttempts: Int

    // Background processing
    private var processingTask: Task<Void, Never>?
    private var activeTasks: Set<String> = [] // Set of chunk IDs currently uploading

    // Progress callback
    var onProgressUpdate: ((String, UploadProgress) -> Void)?

    // MARK: - Errors

    enum UploadQueueError: Error, LocalizedError {
        case manifestLoadFailed(Error)
        case manifestSaveFailed(Error)
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .manifestLoadFailed(let error):
                return "Failed to load manifest: \(error.localizedDescription)"
            case .manifestSaveFailed(let error):
                return "Failed to save manifest: \(error.localizedDescription)"
            case .uploadFailed(let reason):
                return "Upload failed: \(reason)"
            }
        }
    }

    // MARK: - Initialization

    init(
        s3Uploader: S3Uploader,
        manifestStore: UploadManifestStore,
        maxConcurrentUploads: Int = 3,
        retryDelay: TimeInterval = 5.0,
        maxRetryAttempts: Int = 3
    ) {
        self.s3Uploader = s3Uploader
        self.manifestStore = manifestStore
        self.maxConcurrentUploads = maxConcurrentUploads
        self.retryDelay = retryDelay
        self.maxRetryAttempts = maxRetryAttempts

        Task {
            await Logger.shared.debug("UploadQueue initialized", metadata: [
                "maxConcurrent": String(maxConcurrentUploads),
                "maxRetries": String(maxRetryAttempts)
            ])
        }
    }

    // MARK: - Public API

    /// Enqueue a chunk for upload
    func enqueue(chunk: ChunkMetadata) async throws {
        await Logger.shared.info("Enqueueing chunk for upload", metadata: [
            "recordingId": chunk.recordingId,
            "chunkIndex": String(chunk.chunkIndex)
        ])

        // Load or create manifest
        var manifest: UploadManifest
        do {
            manifest = try await manifestStore.loadManifest(recordingId: chunk.recordingId)
        } catch {
            // Create new manifest if it doesn't exist
            manifest = UploadManifest(recordingId: chunk.recordingId, chunks: [])
        }

        // Add chunk entry to manifest
        let entry = UploadManifest.ChunkEntry(
            chunkIndex: chunk.chunkIndex,
            filePath: chunk.filePath,
            status: .pending,
            s3Key: nil,
            etag: nil,
            retryCount: 0,
            lastAttempt: nil
        )

        // Check if chunk already exists in manifest
        if let existingIndex = manifest.chunks.firstIndex(where: { $0.chunkIndex == chunk.chunkIndex }) {
            manifest.chunks[existingIndex] = entry
        } else {
            manifest.chunks.append(entry)
        }

        // Save manifest
        do {
            try await manifestStore.saveManifest(manifest)
        } catch {
            throw UploadQueueError.manifestSaveFailed(error)
        }

        // Start background processing if not already running
        if !isProcessing {
            startProcessing()
        }
    }

    /// Resume incomplete uploads from previous session
    func resumeIncompleteUploads() async throws {
        await Logger.shared.info("Resuming incomplete uploads")

        let manifests = try await manifestStore.loadAllManifests()

        for manifest in manifests {
            let pendingCount = manifest.chunks.filter { $0.status == .pending || $0.status == .uploading }.count

            if pendingCount > 0 {
                await Logger.shared.info("Found incomplete manifest", metadata: [
                    "recordingId": manifest.recordingId,
                    "pendingChunks": String(pendingCount)
                ])

                // Start processing if not already running
                if !isProcessing {
                    startProcessing()
                }
            }
        }
    }

    /// Stop background processing
    func stopProcessing() {
        await Logger.shared.info("Stopping upload queue processing")

        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
    }

    // MARK: - Background Processing

    private func startProcessing() {
        guard !isProcessing else { return }

        isProcessing = true

        processingTask = Task {
            await Logger.shared.info("Upload queue processing started")

            await processQueue()

            await Logger.shared.info("Upload queue processing stopped")
            isProcessing = false
        }
    }

    private func processQueue() async {
        while !Task.isCancelled {
            // Get all manifests
            let manifests: [UploadManifest]
            do {
                manifests = try await manifestStore.loadAllManifests()
            } catch {
                await Logger.shared.error("Failed to load manifests", metadata: [
                    "error": error.localizedDescription
                ])
                break
            }

            // Find pending chunks
            var pendingChunks: [(manifest: UploadManifest, entry: UploadManifest.ChunkEntry)] = []

            for manifest in manifests {
                for entry in manifest.chunks where entry.status == .pending {
                    // Check if we should retry (if it has a lastAttempt)
                    if let lastAttempt = entry.lastAttempt {
                        let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
                        let requiredDelay = retryDelay * pow(2.0, Double(entry.retryCount)) // Exponential backoff

                        if timeSinceLastAttempt < requiredDelay {
                            continue // Skip this chunk for now
                        }
                    }

                    pendingChunks.append((manifest, entry))
                }
            }

            // If no pending chunks, stop processing
            if pendingChunks.isEmpty {
                break
            }

            // Process chunks up to concurrency limit
            while activeTasks.count < maxConcurrentUploads, !pendingChunks.isEmpty {
                let (manifest, entry) = pendingChunks.removeFirst()

                // Start upload task
                startUploadTask(recordingId: manifest.recordingId, entry: entry)
            }

            // Wait a bit before checking again
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
    }

    private func startUploadTask(recordingId: String, entry: UploadManifest.ChunkEntry) {
        let chunkId = "\(recordingId)_\(entry.chunkIndex)"
        activeTasks.insert(chunkId)

        Task {
            do {
                try await uploadChunk(recordingId: recordingId, entry: entry)
            } catch {
                await Logger.shared.error("Upload task failed", metadata: [
                    "recordingId": recordingId,
                    "chunkIndex": String(entry.chunkIndex),
                    "error": error.localizedDescription
                ])
            }

            activeTasks.remove(chunkId)
        }
    }

    private func uploadChunk(recordingId: String, entry: UploadManifest.ChunkEntry) async throws {
        await Logger.shared.info("Uploading chunk", metadata: [
            "recordingId": recordingId,
            "chunkIndex": String(entry.chunkIndex),
            "retryCount": String(entry.retryCount)
        ])

        // Load manifest
        var manifest = try await manifestStore.loadManifest(recordingId: recordingId)

        guard let entryIndex = manifest.chunks.firstIndex(where: { $0.chunkIndex == entry.chunkIndex }) else {
            throw UploadQueueError.uploadFailed("Chunk entry not found in manifest")
        }

        // Mark as uploading
        manifest.chunks[entryIndex].status = .uploading
        manifest.chunks[entryIndex].lastAttempt = Date()
        try await manifestStore.saveManifest(manifest)

        do {
            // Check if file exists
            guard FileManager.default.fileExists(atPath: entry.filePath.path) else {
                await Logger.shared.error("Chunk file not found", metadata: [
                    "filePath": entry.filePath.path
                ])

                // Mark as failed without retries
                manifest.chunks[entryIndex].status = .failed
                try await manifestStore.saveManifest(manifest)
                return
            }

            // Generate S3 key
            let s3Key = "users/\(recordingId)/chunks/\(entry.filePath.lastPathComponent)"

            // Upload to S3
            let result = try await s3Uploader.upload(
                fileURL: entry.filePath,
                s3Key: s3Key,
                contentType: "video/quicktime"
            )

            // Update manifest with success
            manifest = try await manifestStore.loadManifest(recordingId: recordingId)

            if let index = manifest.chunks.firstIndex(where: { $0.chunkIndex == entry.chunkIndex }) {
                manifest.chunks[index].status = .completed
                manifest.chunks[index].s3Key = result.s3Key
                manifest.chunks[index].etag = result.etag
                try await manifestStore.saveManifest(manifest)

                await Logger.shared.info("Chunk upload completed", metadata: [
                    "recordingId": recordingId,
                    "chunkIndex": String(entry.chunkIndex),
                    "s3Key": result.s3Key,
                    "etag": result.etag
                ])

                // Report progress
                reportProgress(recordingId: recordingId, manifest: manifest)
            }
        } catch {
            await Logger.shared.warning("Chunk upload failed", metadata: [
                "recordingId": recordingId,
                "chunkIndex": String(entry.chunkIndex),
                "error": error.localizedDescription
            ])

            // Reload manifest (may have been updated)
            manifest = try await manifestStore.loadManifest(recordingId: recordingId)

            if let index = manifest.chunks.firstIndex(where: { $0.chunkIndex == entry.chunkIndex }) {
                let newRetryCount = manifest.chunks[index].retryCount + 1

                if newRetryCount >= maxRetryAttempts {
                    // Max retries reached - mark as failed
                    manifest.chunks[index].status = .failed
                    manifest.chunks[index].retryCount = newRetryCount

                    await Logger.shared.error("Max retries reached for chunk", metadata: [
                        "recordingId": recordingId,
                        "chunkIndex": String(entry.chunkIndex),
                        "retries": String(newRetryCount)
                    ])
                } else {
                    // Set back to pending for retry
                    manifest.chunks[index].status = .pending
                    manifest.chunks[index].retryCount = newRetryCount
                    manifest.chunks[index].lastAttempt = Date()

                    await Logger.shared.info("Chunk will be retried", metadata: [
                        "recordingId": recordingId,
                        "chunkIndex": String(entry.chunkIndex),
                        "retryCount": String(newRetryCount)
                    ])
                }

                try await manifestStore.saveManifest(manifest)
            }
        }
    }

    private func reportProgress(recordingId: String, manifest: UploadManifest) {
        let completedCount = manifest.chunks.filter { $0.status == .completed }.count
        let totalCount = manifest.chunks.count

        let progress = UploadProgress(
            completedChunks: completedCount,
            totalChunks: totalCount,
            percentage: Double(completedCount) / Double(totalCount)
        )

        onProgressUpdate?(recordingId, progress)
    }
}

// MARK: - Upload Progress Extension

extension UploadProgress {
    init(completedChunks: Int, totalChunks: Int, percentage: Double) {
        self.init(
            bytesUploaded: Int64(completedChunks),
            totalBytes: Int64(totalChunks)
        )
    }

    var completedChunks: Int {
        Int(bytesUploaded)
    }

    var totalChunks: Int {
        Int(totalBytes)
    }
}

// MARK: - Upload Manifest Store

/// Protocol for persisting upload manifests
protocol UploadManifestStore: Sendable {
    func loadManifest(recordingId: String) async throws -> UploadManifest
    func saveManifest(_ manifest: UploadManifest) async throws
    func loadAllManifests() async throws -> [UploadManifest]
}

/// File-based implementation of UploadManifestStore
actor FileUploadManifestStore: UploadManifestStore {
    private let storageDirectory: URL

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingRecorder/Manifests")

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: self.storageDirectory,
            withIntermediateDirectories: true
        )
    }

    func loadManifest(recordingId: String) async throws -> UploadManifest {
        let fileURL = manifestURL(for: recordingId)

        let data = try Data(contentsOf: fileURL)
        let manifest = try JSONDecoder().decode(UploadManifest.self, from: data)

        return manifest
    }

    func saveManifest(_ manifest: UploadManifest) async throws {
        let fileURL = manifestURL(for: manifest.recordingId)

        let data = try JSONEncoder().encode(manifest)
        try data.write(to: fileURL)
    }

    func loadAllManifests() async throws -> [UploadManifest] {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)

        var manifests: [UploadManifest] = []

        for fileURL in files where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let manifest = try JSONDecoder().decode(UploadManifest.self, from: data)
                manifests.append(manifest)
            } catch {
                await Logger.shared.warning("Failed to load manifest", metadata: [
                    "file": fileURL.lastPathComponent,
                    "error": error.localizedDescription
                ])
            }
        }

        return manifests
    }

    private func manifestURL(for recordingId: String) -> URL {
        storageDirectory.appendingPathComponent("\(recordingId).json")
    }
}
