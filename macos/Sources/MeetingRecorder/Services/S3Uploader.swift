import AWSS3
import AWSClientRuntime
import Foundation

/// S3 uploader for recording chunks with multipart upload support
/// Handles large file uploads with retry logic and progress tracking
final class S3Uploader: S3UploaderProtocol, @unchecked Sendable {
    // MARK: - Properties

    private let s3Client: S3Client
    private let bucketName: String

    // Multipart upload configuration
    private let partSize: Int64
    private let maxConcurrentParts: Int

    // MARK: - Initialization

    init(s3Client: S3Client, bucketName: String? = nil) {
        self.s3Client = s3Client
        self.bucketName = bucketName ?? AWSConfig.s3BucketName
        self.partSize = Int64(AWSConfig.multipartChunkSize)
        self.maxConcurrentParts = 3
    }

    // MARK: - S3UploaderProtocol

    func uploadChunk(
        recordingId: String,
        chunkMetadata: ChunkMetadata,
        userId: String
    ) async throws -> S3UploadResult {
        let startTime = Date()

        // Generate S3 key
        let s3Key = generateS3Key(
            userId: userId,
            recordingId: recordingId,
            chunkIndex: chunkMetadata.index
        )

        Logger.upload.info(
            "Starting upload for chunk \(chunkMetadata.chunkId) to s3://\(bucketName)/\(s3Key)",
            file: #file,
            function: #function,
            line: #line
        )

        do {
            // Use multipart upload for chunks
            let etag = try await multipartUpload(
                key: s3Key,
                fileURL: chunkMetadata.filePath,
                metadata: createUploadMetadata(chunkMetadata: chunkMetadata, recordingId: recordingId)
            )

            let uploadDuration = Date().timeIntervalSince(startTime)

            Logger.upload.info(
                "Uploaded chunk \(chunkMetadata.chunkId) in \(String(format: "%.2f", uploadDuration))s",
                file: #file,
                function: #function,
                line: #line
            )

            return S3UploadResult(
                s3Key: s3Key,
                etag: etag,
                uploadDuration: uploadDuration
            )

        } catch {
            throw mapS3Error(error)
        }
    }

    // MARK: - Private Methods - Multipart Upload

    private func multipartUpload(
        key: String,
        fileURL: URL,
        metadata: [String: String]
    ) async throws -> String {
        // Step 1: Initiate multipart upload
        let uploadId = try await initiateMultipartUpload(key: key, metadata: metadata)

        do {
            // Step 2: Upload parts
            let partETags = try await uploadParts(
                key: key,
                uploadId: uploadId,
                fileURL: fileURL
            )

            // Step 3: Complete multipart upload
            let etag = try await completeMultipartUpload(
                key: key,
                uploadId: uploadId,
                parts: partETags
            )

            return etag

        } catch {
            // If anything fails, abort the multipart upload
            try? await abortMultipartUpload(key: key, uploadId: uploadId)
            throw error
        }
    }

    private func initiateMultipartUpload(
        key: String,
        metadata: [String: String]
    ) async throws -> String {
        let input = CreateMultipartUploadInput(
            bucket: bucketName,
            contentType: "video/mp4",
            key: key,
            metadata: metadata,
            serverSideEncryption: .aes256
        )

        let output = try await s3Client.createMultipartUpload(input: input)

        guard let uploadId = output.uploadId else {
            throw UploadError.uploadFailed("No upload ID returned from S3")
        }

        Logger.upload.debug(
            "Initiated multipart upload: \(uploadId)",
            file: #file,
            function: #function,
            line: #line
        )

        return uploadId
    }

    private func uploadParts(
        key: String,
        uploadId: String,
        fileURL: URL
    ) async throws -> [S3ClientTypes.CompletedPart] {
        // Get file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = fileAttributes[.size] as? Int64 else {
            throw UploadError.invalidChunk("Cannot determine file size")
        }

        // Calculate number of parts
        let partCount = Int((fileSize + partSize - 1) / partSize) // Ceiling division

        Logger.upload.debug(
            "Uploading \(partCount) parts for file of size \(fileSize) bytes",
            file: #file,
            function: #function,
            line: #line
        )

        // Open file handle
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        // Upload parts sequentially (for now - can be parallelized later)
        var completedParts: [S3ClientTypes.CompletedPart] = []

        for partNumber in 1...partCount {
            let offset = Int64(partNumber - 1) * partSize
            let length = min(partSize, fileSize - offset)

            // Read part data
            try fileHandle.seek(toOffset: UInt64(offset))
            guard let partData = try fileHandle.read(upToCount: Int(length)) else {
                throw UploadError.invalidChunk("Failed to read part \(partNumber)")
            }

            // Upload part
            let input = UploadPartInput(
                body: .data(partData),
                bucket: bucketName,
                key: key,
                partNumber: partNumber,
                uploadId: uploadId
            )

            let output = try await s3Client.uploadPart(input: input)

            guard let etag = output.eTag else {
                throw UploadError.uploadFailed("No ETag returned for part \(partNumber)")
            }

            completedParts.append(
                S3ClientTypes.CompletedPart(
                    eTag: etag,
                    partNumber: partNumber
                )
            )

            Logger.upload.debug(
                "Uploaded part \(partNumber)/\(partCount)",
                file: #file,
                function: #function,
                line: #line
            )
        }

        return completedParts
    }

    private func completeMultipartUpload(
        key: String,
        uploadId: String,
        parts: [S3ClientTypes.CompletedPart]
    ) async throws -> String {
        let input = CompleteMultipartUploadInput(
            bucket: bucketName,
            key: key,
            multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: parts),
            uploadId: uploadId
        )

        let output = try await s3Client.completeMultipartUpload(input: input)

        guard let etag = output.eTag else {
            throw UploadError.uploadFailed("No ETag returned from complete multipart upload")
        }

        Logger.upload.debug(
            "Completed multipart upload with ETag: \(etag)",
            file: #file,
            function: #function,
            line: #line
        )

        return etag
    }

    private func abortMultipartUpload(key: String, uploadId: String) async throws {
        let input = AbortMultipartUploadInput(
            bucket: bucketName,
            key: key,
            uploadId: uploadId
        )

        _ = try await s3Client.abortMultipartUpload(input: input)

        Logger.upload.warning(
            "Aborted multipart upload: \(uploadId)",
            file: #file,
            function: #function,
            line: #line
        )
    }

    // MARK: - Private Methods - Helpers

    private func generateS3Key(userId: String, recordingId: String, chunkIndex: Int) -> String {
        let fileName = "part-\(String(format: "%04d", chunkIndex + 1)).mp4"
        return AWSConfig.s3ChunksPath(userId: userId, recordingId: recordingId) + fileName
    }

    private func createUploadMetadata(
        chunkMetadata: ChunkMetadata,
        recordingId: String
    ) -> [String: String] {
        return [
            "checksum-sha256": chunkMetadata.checksum,
            "recording-id": recordingId,
            "chunk-id": chunkMetadata.chunkId,
            "chunk-index": String(chunkMetadata.index),
            "duration-seconds": String(format: "%.2f", chunkMetadata.durationSeconds)
        ]
    }

    private func mapS3Error(_ error: Error) -> UploadError {
        // Check for network errors
        if (error as NSError).domain == NSURLErrorDomain {
            return .networkError("Network connection failed: \(error.localizedDescription)")
        }

        // Check if error message contains credential-related keywords
        let errorMessage = error.localizedDescription.lowercased()
        if errorMessage.contains("forbidden") || errorMessage.contains("credentials") ||
           errorMessage.contains("unauthorized") {
            return .credentialsExpired
        }

        return .uploadFailed(error.localizedDescription)
    }
}

// MARK: - S3 Upload Protocol

/// Protocol for S3 upload operations (enables testing with mocks)
protocol S3UploaderProtocol: Sendable {
    func uploadChunk(
        recordingId: String,
        chunkMetadata: ChunkMetadata,
        userId: String
    ) async throws -> S3UploadResult
}

// MARK: - S3 Upload Result

/// Result of a successful S3 upload
struct S3UploadResult: Sendable {
    /// S3 object key
    let s3Key: String

    /// S3 ETag for the uploaded object
    let etag: String

    /// Duration of the upload operation
    let uploadDuration: TimeInterval
}

// MARK: - Upload Errors

/// Errors that can occur during upload
enum UploadError: Error, LocalizedError {
    case networkError(String)
    case credentialsExpired
    case uploadFailed(String)
    case invalidChunk(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .credentialsExpired:
            return "AWS credentials expired. Please refresh credentials and try again."
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .invalidChunk(let message):
            return "Invalid chunk: \(message)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .networkError, .credentialsExpired, .uploadFailed:
            return true
        case .invalidChunk:
            return false
        }
    }
}
