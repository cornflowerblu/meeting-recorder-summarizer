import Foundation

/// Tracks upload progress and retry state for recording chunks
struct UploadManifest: Codable, Sendable {

  // MARK: - Properties

  let recordingId: String
  let userId: String
  let createdAt: Date
  var updatedAt: Date
  var chunks: [ChunkEntry]
  var overallStatus: UploadStatus

  // MARK: - Chunk Entry

  struct ChunkEntry: Codable, Sendable, Identifiable {
    let id: String  // chunk_000, chunk_001, etc.
    let localPath: String
    let s3Key: String
    let fileSizeBytes: Int64
    let checksum: String
    var uploadStatus: UploadStatus
    var uploadAttempts: Int
    var lastUploadAttempt: Date?
    var lastError: String?
    var uploadedAt: Date?

    var isCompleted: Bool {
      uploadStatus == .completed
    }

    var canRetry: Bool {
      uploadStatus == .failed && uploadAttempts < 3
    }
  }

  // MARK: - Upload Status

  enum UploadStatus: String, Codable, CaseIterable {
    case pending = "pending"
    case uploading = "uploading"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
  }

  // MARK: - Computed Properties

  var completedChunks: [ChunkEntry] {
    chunks.filter(\.isCompleted)
  }

  var failedChunks: [ChunkEntry] {
    chunks.filter { $0.uploadStatus == .failed }
  }

  var pendingChunks: [ChunkEntry] {
    chunks.filter { $0.uploadStatus == .pending }
  }

  var uploadProgress: Double {
    guard !chunks.isEmpty else { return 0.0 }
    return Double(completedChunks.count) / Double(chunks.count)
  }

  var totalSizeBytes: Int64 {
    chunks.reduce(0) { $0 + $1.fileSizeBytes }
  }

  var uploadedSizeBytes: Int64 {
    completedChunks.reduce(0) { $0 + $1.fileSizeBytes }
  }

  var isFullyUploaded: Bool {
    !chunks.isEmpty && chunks.allSatisfy(\.isCompleted)
  }

  var hasFailures: Bool {
    chunks.contains { $0.uploadStatus == .failed }
  }

  // MARK: - Initialization

  init(recordingId: String, userId: String, chunkPaths: [String]) {
    self.recordingId = recordingId
    self.userId = userId
    self.createdAt = Date()
    self.updatedAt = Date()
    self.overallStatus = .pending

    self.chunks = chunkPaths.enumerated().map { index, path in
      let chunkId = String(format: "chunk_%03d", index)
      let s3Key = AWSConfig.S3Config.chunkKey(
        userId: userId, recordingId: recordingId, chunkId: chunkId)

      return ChunkEntry(
        id: chunkId,
        localPath: path,
        s3Key: s3Key,
        fileSizeBytes: Self.fileSize(at: path),
        checksum: Self.calculateChecksum(at: path),
        uploadStatus: .pending,
        uploadAttempts: 0,
        lastUploadAttempt: nil,
        lastError: nil,
        uploadedAt: nil
      )
    }
  }

  // MARK: - Mutation Methods

  mutating func updateChunkStatus(_ chunkId: String, status: UploadStatus, error: String? = nil) {
    guard let index = chunks.firstIndex(where: { $0.id == chunkId }) else { return }

    chunks[index].uploadStatus = status
    chunks[index].lastUploadAttempt = Date()
    chunks[index].lastError = error

    if status == .completed {
      chunks[index].uploadedAt = Date()
    } else if status == .failed {
      chunks[index].uploadAttempts += 1
    }

    updateOverallStatus()
    updatedAt = Date()
  }

  mutating func markChunkCompleted(_ chunkId: String) {
    updateChunkStatus(chunkId, status: .completed)
  }

  mutating func markChunkFailed(_ chunkId: String, error: String) {
    updateChunkStatus(chunkId, status: .failed, error: error)
  }

  private mutating func updateOverallStatus() {
    if isFullyUploaded {
      overallStatus = .completed
    } else if hasFailures && pendingChunks.isEmpty {
      overallStatus = .failed
    } else if chunks.contains(where: { $0.uploadStatus == .uploading }) {
      overallStatus = .uploading
    } else {
      overallStatus = .pending
    }
  }

  // MARK: - Persistence

  static func manifestPath(for recordingId: String) -> URL {
    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let manifestsDir = documentsPath.appendingPathComponent("upload_manifests", isDirectory: true)

    // Ensure directory exists
    try? FileManager.default.createDirectory(at: manifestsDir, withIntermediateDirectories: true)

    return manifestsDir.appendingPathComponent("\(recordingId).json")
  }

  func save() throws {
    let url = Self.manifestPath(for: recordingId)
    let data = try JSONEncoder().encode(self)
    try data.write(to: url)
  }

  static func load(recordingId: String) throws -> UploadManifest {
    let url = manifestPath(for: recordingId)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(UploadManifest.self, from: data)
  }

  func delete() throws {
    let url = Self.manifestPath(for: recordingId)
    try FileManager.default.removeItem(at: url)
  }

  // MARK: - File Utilities

  private static func fileSize(at path: String) -> Int64 {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    } catch {
      return 0
    }
  }

  private static func calculateChecksum(at path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else {
      return ""
    }

    let hash = data.withUnsafeBytes { bytes in
      var hasher = Hasher()
      hasher.combine(
        bytes: UnsafeRawBufferPointer(
          start: bytes.bindMemory(to: UInt8.self).baseAddress, count: data.count))
      return hasher.finalize()
    }

    return String(hash)
  }
}
