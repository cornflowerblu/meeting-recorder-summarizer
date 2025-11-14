import Foundation

/// Upload Manifest Model
/// MR-21 (T014)
///
/// Tracks the upload state of recording chunks for resumable uploads.
/// Persisted locally to survive app restarts.
struct UploadManifest: Codable, Identifiable {
    // MARK: - Properties

    /// Unique identifier for this manifest
    let id: UUID

    /// Recording ID this manifest belongs to
    let recordingId: String

    /// User ID
    let userId: String

    /// List of chunks to upload
    var chunks: [ChunkInfo]

    /// Overall upload status
    var status: UploadStatus

    /// Created timestamp
    let createdAt: Date

    /// Last updated timestamp
    var updatedAt: Date

    // MARK: - Initialization

    init(recordingId: String, userId: String, chunks: [ChunkInfo]) {
        self.id = UUID()
        self.recordingId = recordingId
        self.userId = userId
        self.chunks = chunks
        self.status = .pending
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Computed Properties

    /// Total number of chunks
    var totalChunks: Int {
        chunks.count
    }

    /// Number of completed chunks
    var completedChunks: Int {
        chunks.filter { $0.status == .completed }.count
    }

    /// Number of failed chunks
    var failedChunks: Int {
        chunks.filter { $0.status == .failed }.count
    }

    /// Upload progress (0.0 to 1.0)
    var progress: Double {
        guard totalChunks > 0 else { return 0.0 }
        return Double(completedChunks) / Double(totalChunks)
    }

    /// Total size in bytes
    var totalSize: Int64 {
        chunks.reduce(0) { $0 + $1.size }
    }

    /// Uploaded size in bytes
    var uploadedSize: Int64 {
        chunks.filter { $0.status == .completed }.reduce(0) { $0 + $1.size }
    }

    // MARK: - Mutating Methods

    /// Update chunk status
    mutating func updateChunk(chunkId: String, status: ChunkStatus, error: String? = nil) {
        if let index = chunks.firstIndex(where: { $0.chunkId == chunkId }) {
            chunks[index].status = status
            chunks[index].lastError = error
            chunks[index].updatedAt = Date()

            if status == .uploading {
                chunks[index].attempts += 1
            }

            updatedAt = Date()
            updateOverallStatus()
        }
    }

    /// Update chunk checksum after writing
    mutating func updateChecksum(chunkId: String, checksum: String) {
        if let index = chunks.firstIndex(where: { $0.chunkId == chunkId }) {
            chunks[index].checksum = checksum
            updatedAt = Date()
        }
    }

    /// Mark manifest as completed
    mutating func markCompleted() {
        status = .completed
        updatedAt = Date()
    }

    /// Mark manifest as failed
    mutating func markFailed() {
        status = .failed
        updatedAt = Date()
    }

    /// Update overall status based on chunk statuses
    private mutating func updateOverallStatus() {
        if chunks.allSatisfy({ $0.status == .completed }) {
            status = .completed
        } else if chunks.contains(where: { $0.status == .uploading }) {
            status = .uploading
        } else if failedChunks > 0 && failedChunks == totalChunks {
            status = .failed
        } else {
            status = .pending
        }
    }
}

// MARK: - Chunk Info

extension UploadManifest {
    /// Information about a single recording chunk
    struct ChunkInfo: Codable, Identifiable {
        /// Unique chunk identifier
        let chunkId: String

        /// Local file path
        let path: String

        /// File size in bytes
        let size: Int64

        /// SHA-256 checksum (computed after writing)
        var checksum: String?

        /// Duration of this chunk in seconds (optional for backward compatibility)
        var durationSeconds: TimeInterval?

        /// Upload status
        var status: ChunkStatus

        /// Number of upload attempts
        var attempts: Int

        /// Last error message (if failed)
        var lastError: String?

        /// Created timestamp
        let createdAt: Date

        /// Last updated timestamp
        var updatedAt: Date

        // Codable conformance
        var id: String { chunkId }

        init(chunkId: String, path: String, size: Int64, durationSeconds: TimeInterval? = nil) {
            self.chunkId = chunkId
            self.path = path
            self.size = size
            self.checksum = nil
            self.durationSeconds = durationSeconds
            self.status = .pending
            self.attempts = 0
            self.lastError = nil
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }
}

// MARK: - Enums

extension UploadManifest {
    /// Overall upload status
    enum UploadStatus: String, Codable {
        case pending
        case uploading
        case completed
        case failed
        case cancelled
    }

    /// Individual chunk status
    enum ChunkStatus: String, Codable {
        case pending
        case uploading
        case completed
        case failed
    }
}

// MARK: - Persistence

extension UploadManifest {
    /// File URL for manifest storage
    static func fileURL(recordingId: String) -> URL {
        let directory = AWSConfig.tempStorageDirectory
        return directory.appendingPathComponent("\(recordingId)-manifest.json")
    }

    /// Save manifest to disk
    func save() throws {
        let url = Self.fileURL(recordingId: recordingId)

        // Create directory if needed
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Encode and write
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)

        Logger.upload.debug("Saved upload manifest", file: #file, function: #function, line: #line)
    }

    /// Load manifest from disk
    static func load(recordingId: String) throws -> UploadManifest {
        let url = fileURL(recordingId: recordingId)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UploadManifest.self, from: data)
    }

    /// Delete manifest from disk
    func delete() throws {
        let url = Self.fileURL(recordingId: recordingId)
        try FileManager.default.removeItem(at: url)

        Logger.upload.debug("Deleted upload manifest")
    }

    /// Check if manifest exists on disk
    static func exists(recordingId: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(recordingId: recordingId).path)
    }
}
