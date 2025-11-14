import Foundation

/// Upload queue manager for recording chunks
/// Handles concurrent uploads, retry logic, progress tracking, and resumable uploads
@MainActor
final class UploadQueue: ObservableObject {
    // MARK: - Published Properties

    /// Progress of each chunk upload (chunkId -> progress 0.0-1.0)
    @Published var uploadProgress: [String: Double] = [:]

    /// List of failed chunk IDs
    @Published var failedChunks: [String] = []

    /// Overall upload progress (0.0-1.0)
    @Published var overallProgress: Double = 0.0

    /// Current upload status
    @Published var status: UploadStatus = .idle

    // MARK: - Callbacks

    /// Called when a chunk upload completes successfully
    var onChunkUploaded: ((String) -> Void)?

    /// Called when a chunk upload fails after all retries
    var onChunkFailed: ((String, String) -> Void)?

    /// Called when upload progress updates
    var onProgressUpdate: ((Double) -> Void)?

    /// Called when credentials expire (need refresh)
    var onCredentialsExpired: (() -> Void)?

    // MARK: - Dependencies

    private let uploader: S3UploaderProtocol
    private let userId: String
    private let recordingId: String

    // MARK: - State

    private var manifest: UploadManifest
    private var uploadTasks: [String: Task<Void, Error>] = [:]
    private var isPaused: Bool = false
    private var isProcessing: Bool = false // Prevents concurrent processQueue() calls
    private let maxConcurrentUploads = AWSConfig.maxConcurrentChunkUploads

    // MARK: - Constants

    private let maxRetries: Int
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval

    // MARK: - Initialization

    init(
        uploader: S3UploaderProtocol,
        userId: String,
        recordingId: String
    ) {
        self.uploader = uploader
        self.userId = userId
        self.recordingId = recordingId

        // Load or create manifest
        if UploadManifest.exists(recordingId: recordingId) {
            do {
                self.manifest = try UploadManifest.load(recordingId: recordingId)
                Logger.upload.info(
                    "Loaded existing manifest for recording \(recordingId)",
                    file: #file,
                    function: #function,
                    line: #line
                )
            } catch {
                Logger.upload.error(
                    "Failed to load manifest, creating new one",
                    file: #file,
                    function: #function,
                    line: #line
                )
                self.manifest = UploadManifest(recordingId: recordingId, userId: userId, chunks: [])
            }
        } else {
            self.manifest = UploadManifest(recordingId: recordingId, userId: userId, chunks: [])
        }

        // Configuration
        self.maxRetries = AWSConfig.maxUploadRetries
        self.initialBackoff = AWSConfig.initialBackoffDelay
        self.maxBackoff = AWSConfig.maxBackoffDelay

        // Update published properties from manifest
        updatePublishedState()
    }

    // MARK: - Public Methods

    /// Enqueue a chunk for upload
    /// Enqueues a chunk for upload with validation
    ///
    /// Performs safety checks before adding chunk to the upload queue:
    /// - Verifies chunk file exists
    /// - Checks available disk space for manifest persistence
    ///
    /// - Parameter chunk: Chunk metadata to enqueue
    /// - Throws: UploadError.invalidChunk if file doesn't exist
    /// - Throws: UploadError.insufficientStorage if disk space too low
    func enqueue(_ chunk: ChunkMetadata) async throws {
        // Verify chunk file exists
        guard FileManager.default.fileExists(atPath: chunk.filePath.path) else {
            Logger.upload.error(
                "Chunk file not found: \(chunk.filePath.path)",
                file: #file,
                function: #function,
                line: #line
            )
            throw UploadError.invalidChunk("Chunk file not found: \(chunk.filePath.path)")
        }

        // Check disk space for manifest persistence
        let manifestURL = UploadManifest.fileURL(recordingId: recordingId)
        if let resourceValues = try? manifestURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let availableBytes = resourceValues.volumeAvailableCapacity {

            let minRequiredBytes: Int64 = 10_000_000 // 10MB minimum
            if availableBytes < minRequiredBytes {
                let availableMB = availableBytes / 1_000_000
                Logger.upload.error(
                    "Insufficient disk space: \(availableMB)MB available, need at least 10MB",
                    file: #file,
                    function: #function,
                    line: #line
                )
                throw UploadError.insufficientStorage("Only \(availableMB)MB available")
            }
        }

        // Check if chunk already exists in manifest
        if !manifest.chunks.contains(where: { $0.chunkId == chunk.chunkId }) {
            let chunkInfo = UploadManifest.ChunkInfo(
                chunkId: chunk.chunkId,
                path: chunk.filePath.path,
                size: chunk.sizeBytes,
                durationSeconds: chunk.durationSeconds
            )

            manifest.chunks.append(chunkInfo)
            manifest.updateChecksum(chunkId: chunk.chunkId, checksum: chunk.checksum)

            // Save manifest
            try? manifest.save()

            Logger.upload.info(
                "Enqueued chunk \(chunk.chunkId) for upload",
                file: #file,
                function: #function,
                line: #line
            )
        }

        updatePublishedState()
    }

    /// Start processing the upload queue
    func start() async {
        guard status == .idle || status == .paused else {
            Logger.upload.warning("Upload queue already running")
            return
        }

        status = .uploading
        isPaused = false

        await processQueue()
    }

    /// Pause upload processing
    func pause() async {
        guard status == .uploading else { return }

        isPaused = true
        status = .paused

        Logger.upload.info(
            "Upload queue paused",
            file: #file,
            function: #function,
            line: #line
        )
    }

    /// Resume upload processing
    func resume() async {
        // Allow resuming from both paused and idle states
        // Idle state occurs when resuming from a persisted manifest after app restart
        guard status == .paused || status == .idle else { return }

        isPaused = false
        status = .uploading

        Logger.upload.info(
            "Upload queue resumed",
            file: #file,
            function: #function,
            line: #line
        )

        await processQueue()
    }

    /// Retry failed chunks
    func retryFailed() async {
        // Reset failed chunks to pending
        for failedChunkId in failedChunks {
            manifest.updateChunk(chunkId: failedChunkId, status: .pending, error: nil)
        }

        try? manifest.save()
        updatePublishedState()

        await start()
    }

    // MARK: - Private Methods - Queue Processing

    /// Processes the upload queue with concurrency control
    ///
    /// Prevents race conditions by ensuring only one processQueue() operation runs at a time.
    /// Uses TaskGroup to manage concurrent uploads with a maximum limit.
    private func processQueue() async {
        // Prevent concurrent processing
        guard !isProcessing else {
            Logger.upload.warning(
                "Queue processing already in progress, skipping",
                file: #file,
                function: #function,
                line: #line
            )
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        // Get pending chunks (FIFO order)
        let pendingChunks = manifest.chunks
            .filter { $0.status == .pending }
            .sorted { $0.createdAt < $1.createdAt }

        guard !pendingChunks.isEmpty else {
            // All chunks complete
            if manifest.chunks.allSatisfy({ $0.status == .completed }) {
                status = .completed
                manifest.markCompleted()
                try? manifest.save()
            }
            return
        }

        // Process chunks with concurrency limit
        await withTaskGroup(of: Void.self) { group in
            var activeCount = 0

            for chunkInfo in pendingChunks {
                // Check if paused
                if isPaused { break }

                // Wait if at concurrent limit
                while activeCount >= maxConcurrentUploads {
                    _ = await group.next()
                    activeCount -= 1
                }

                // Start upload task
                group.addTask {
                    await self.uploadChunkWithRetry(chunkInfo)
                }
                activeCount += 1
            }

            // Wait for all tasks to complete
            for await _ in group {
                activeCount -= 1
            }
        }

        // After processing, check if there are more pending chunks
        if !isPaused {
            await processQueue()
        }
    }

    private func uploadChunkWithRetry(_ chunkInfo: UploadManifest.ChunkInfo) async {
        var attempt = 0
        var lastError: Error?

        while attempt <= maxRetries {
            // Check if paused
            if isPaused { return }

            do {
                // Load chunk metadata
                guard let chunkMetadata = loadChunkMetadata(chunkInfo) else {
                    throw UploadError.invalidChunk("Chunk file not found: \(chunkInfo.path)")
                }

                // Update status to uploading
                if attempt == 0 {
                    manifest.updateChunk(chunkId: chunkInfo.chunkId, status: .uploading)
                    try? manifest.save()
                    updatePublishedState()
                }

                // Attempt upload
                let result = try await uploader.uploadChunk(
                    recordingId: recordingId,
                    chunkMetadata: chunkMetadata,
                    userId: userId
                )

                // Success!
                manifest.updateChunk(chunkId: chunkInfo.chunkId, status: .completed)
                try? manifest.save()

                uploadProgress[chunkInfo.chunkId] = 1.0
                updatePublishedState()

                onChunkUploaded?(chunkInfo.chunkId)

                Logger.upload.info(
                    "Successfully uploaded chunk \(chunkInfo.chunkId) to \(result.s3Key)",
                    file: #file,
                    function: #function,
                    line: #line
                )

                // Delete local chunk file after successful upload
                try? deleteLocalChunk(chunkInfo)

                return

            } catch let error as UploadError {
                lastError = error

                // Handle credential expiration
                if case .credentialsExpired = error {
                    Logger.upload.warning(
                        "Credentials expired during upload",
                        file: #file,
                        function: #function,
                        line: #line
                    )
                    onCredentialsExpired?()
                }

                // Check if retryable
                if !error.isRetryable {
                    break
                }

                // Exponential backoff
                if attempt < maxRetries {
                    let backoffDelay = calculateBackoff(attempt: attempt)

                    Logger.upload.warning(
                        "Upload attempt \(attempt + 1) failed for chunk \(chunkInfo.chunkId), retrying in \(String(format: "%.1f", backoffDelay))s",
                        file: #file,
                        function: #function,
                        line: #line
                    )

                    try? await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                }

            } catch {
                // Wrap unknown errors
                let uploadError = error as? UploadError ?? UploadError.uploadFailed(error.localizedDescription)
                lastError = uploadError

                // Handle credential expiration for non-UploadError errors
                if error.localizedDescription.lowercased().contains("forbidden") ||
                   error.localizedDescription.lowercased().contains("credentials") {
                    onCredentialsExpired?()
                }
            }

            attempt += 1
        }

        // All retries exhausted
        manifest.updateChunk(
            chunkId: chunkInfo.chunkId,
            status: .failed,
            error: lastError?.localizedDescription ?? "Unknown error"
        )
        try? manifest.save()
        updatePublishedState()

        onChunkFailed?(chunkInfo.chunkId, lastError?.localizedDescription ?? "Unknown error")

        Logger.upload.error(
            "Failed to upload chunk \(chunkInfo.chunkId) after \(maxRetries + 1) attempts",
            file: #file,
            function: #function,
            line: #line
        )
    }

    // MARK: - Private Methods - Helpers

    /// Calculates exponential backoff delay with jitter
    ///
    /// Implements industry best practice for retry logic:
    /// - Base delay doubles with each attempt (exponential backoff)
    /// - Adds ±20% random jitter to prevent thundering herd problem
    /// - Caps at maximum backoff delay
    ///
    /// Example delays (with jitter range):
    /// - Attempt 0: 0.8-1.2s
    /// - Attempt 1: 1.6-2.4s
    /// - Attempt 2: 3.2-4.8s
    /// - Attempt 3: 6.4-9.6s
    ///
    /// - Parameter attempt: Zero-based attempt number
    /// - Returns: Delay in seconds with jitter applied
    private func calculateBackoff(attempt: Int) -> TimeInterval {
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 60s (max)
        let baseDelay = initialBackoff * pow(2.0, Double(attempt))
        let cappedDelay = min(baseDelay, maxBackoff)

        // Add ±20% jitter to prevent thundering herd
        // If many uploads fail simultaneously, jitter spreads retry attempts over time
        let jitter = Double.random(in: 0.8...1.2)
        return cappedDelay * jitter
    }

    private func loadChunkMetadata(_ chunkInfo: UploadManifest.ChunkInfo) -> ChunkMetadata? {
        let fileURL = URL(fileURLWithPath: chunkInfo.path)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Extract index from chunk ID
        let components = chunkInfo.chunkId.split(separator: "-")
        guard let indexStr = components.last,
              let index = Int(indexStr) else {
            return nil
        }

        return ChunkMetadata(
            chunkId: chunkInfo.chunkId,
            filePath: fileURL,
            sizeBytes: chunkInfo.size,
            checksum: chunkInfo.checksum ?? "",
            durationSeconds: chunkInfo.durationSeconds ?? 60.0, // Use stored duration or fallback to 60.0
            index: index,
            recordingId: recordingId,
            createdAt: chunkInfo.createdAt
        )
    }

    private func deleteLocalChunk(_ chunkInfo: UploadManifest.ChunkInfo) throws {
        let fileURL = URL(fileURLWithPath: chunkInfo.path)
        try FileManager.default.removeItem(at: fileURL)

        Logger.upload.debug(
            "Deleted local chunk file: \(chunkInfo.path)",
            file: #file,
            function: #function,
            line: #line
        )
    }

    private func updatePublishedState() {
        // Update failed chunks list
        failedChunks = manifest.chunks
            .filter { $0.status == .failed }
            .map { $0.chunkId }

        // Update overall progress
        overallProgress = manifest.progress
        onProgressUpdate?(overallProgress)
    }

    // MARK: - Upload Status

    enum UploadStatus: String {
        case idle
        case uploading
        case paused
        case completed
        case failed
    }
}
