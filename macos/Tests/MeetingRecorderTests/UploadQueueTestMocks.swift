import Foundation
@testable import MeetingRecorder

// MARK: - Mock Dependencies for Upload Queue Tests

final class MockS3Uploader: S3UploaderProtocol {
    struct UploadedFile {
        let filePath: URL
        let s3Key: String
        let etag: String
    }
    
    var uploadedFiles: [UploadedFile] = []
    var failureCount = 0
    var alwaysFail = false
    var uploadDelay: TimeInterval = 0
    var totalAttempts = 0
    
    // Concurrency tracking
    var trackConcurrency = false
    var currentConcurrentUploads = 0
    var maxObservedConcurrency = 0
    
    func uploadChunk(_ chunk: ChunkMetadata, to s3Key: String) async throws -> String {
        totalAttempts += 1
        
        if trackConcurrency {
            currentConcurrentUploads += 1
            maxObservedConcurrency = max(maxObservedConcurrency, currentConcurrentUploads)
        }
        
        defer {
            if trackConcurrency {
                currentConcurrentUploads -= 1
            }
        }
        
        if uploadDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(uploadDelay * 1_000_000_000))
        }
        
        if alwaysFail || failureCount > 0 {
            if !alwaysFail {
                failureCount -= 1
            }
            throw MockS3Error.uploadFailed
        }
        
        // Verify file exists
        guard FileManager.default.fileExists(atPath: chunk.filePath.path) else {
            throw MockS3Error.fileNotFound
        }
        
        let etag = "mock-etag-\(UUID().uuidString)"
        uploadedFiles.append(UploadedFile(filePath: chunk.filePath, s3Key: s3Key, etag: etag))
        
        return etag
    }
}

final class MockUploadManifestStore: UploadManifestStoreProtocol {
    private var manifests: [String: UploadManifest] = [:]
    
    func loadManifest(recordingId: String) async throws -> UploadManifest {
        return manifests[recordingId] ?? UploadManifest(recordingId: recordingId, chunks: [])
    }
    
    func saveManifest(_ manifest: UploadManifest) async throws {
        manifests[manifest.recordingId] = manifest
    }
    
    func deleteManifest(recordingId: String) async throws {
        manifests.removeValue(forKey: recordingId)
    }
}

enum MockS3Error: Error {
    case uploadFailed
    case fileNotFound
    case networkError
}

// MARK: - Supporting Types (These will be defined in implementation)

struct UploadProgress {
    let completedChunks: Int
    let totalChunks: Int
    let bytesUploaded: Int64
    let totalBytes: Int64
    
    var percentage: Double {
        guard totalChunks > 0 else { return 0.0 }
        return Double(completedChunks) / Double(totalChunks)
    }
}

protocol S3UploaderProtocol {
    func uploadChunk(_ chunk: ChunkMetadata, to s3Key: String) async throws -> String
}

protocol UploadManifestStoreProtocol {
    func loadManifest(recordingId: String) async throws -> UploadManifest
    func saveManifest(_ manifest: UploadManifest) async throws
    func deleteManifest(recordingId: String) async throws
}
