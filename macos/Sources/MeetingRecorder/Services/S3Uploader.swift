import AWSClientRuntime
import AWSS3
import Foundation

// MARK: - S3 Client Protocol

/// Protocol abstraction for S3 client operations to enable testing
protocol S3ClientProtocol {
    func createMultipartUpload(input: CreateMultipartUploadInput) async throws
        -> CreateMultipartUploadOutput
    func uploadPart(input: UploadPartInput) async throws -> UploadPartOutput
    func completeMultipartUpload(input: CompleteMultipartUploadInput) async throws
        -> CompleteMultipartUploadOutput
    func abortMultipartUpload(input: AbortMultipartUploadInput) async throws
        -> AbortMultipartUploadOutput
}

/// Wrapper to make AWS SDK S3Client conform to our protocol
extension S3Client: S3ClientProtocol {}

/// S3 uploader for recording chunks with multipart upload support
/// Handles large file uploads with retry logic and progress tracking
///
/// ## Concurrency Safety
///
/// **TECH DEBT:** This class is marked `@unchecked Sendable` which bypasses Swift's concurrency safety checks.
///
/// ### Current Justification:
/// - AWS SDK's `S3Client` is used concurrently but its thread-safety isn't documented in Swift 6.0
/// - All stored properties are immutable (`let`) or have value semantics (String, Int64)
/// - No mutable state is shared across concurrent calls
///
/// ### Safety Verification Needed:
/// 1. Verify AWS SDK S3Client documentation confirms thread-safety for concurrent operations
/// 2. Test under high concurrency load to detect potential race conditions
/// 3. Consider wrapping in an `actor` if thread-safety cannot be confirmed
///
/// ### Recommended Fix (Future):
/// ```swift
/// actor S3Uploader: S3UploaderProtocol {
///     // Actor automatically serializes access
/// }
/// ```
///
/// **Issue Tracker:** See Phase 3 code review - Critical Issue #2
/// **Priority:** High (should be addressed before production deployment)
///
final class S3Uploader: S3UploaderProtocol, @unchecked Sendable {
    // MARK: - Properties

    private let s3Client: any S3ClientProtocol
    private let bucketName: String

    // Multipart upload configuration
    private let partSize: Int64 = Int64(AWSConfig.multipartChunkSize)
    private let maxConcurrentParts: Int = AWSConfig.maxConcurrentPartUploads

    // MARK: - Initialization

    init(s3Client: any S3ClientProtocol, bucketName: String? = nil) {
        self.s3Client = s3Client
        self.bucketName = bucketName ?? AWSConfig.s3BucketName
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
                metadata: createUploadMetadata(
                    chunkMetadata: chunkMetadata, recordingId: recordingId)
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
            Logger.upload.error(
                "Failed to upload chunk \(chunkMetadata.chunkId): \(error)",
                file: #file,
                function: #function,
                line: #line
            )
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
            // Attempt to abort the multipart upload to prevent orphaned parts in S3
            do {
                try await abortMultipartUpload(key: key, uploadId: uploadId)
                Logger.upload.info(
                    "Successfully aborted incomplete multipart upload: \(uploadId)",
                    file: #file,
                    function: #function,
                    line: #line
                )
            } catch let abortError {
                // Log but don't override original error
                // Orphaned parts will remain in S3 and incur storage costs
                Logger.upload.error(
                    "Failed to abort multipart upload \(uploadId): \(abortError). "
                        + "Orphaned parts may remain in S3. Manual cleanup may be required. "
                        + "Ensure S3 lifecycle policy is configured to delete incomplete multipart uploads.",
                    file: #file,
                    function: #function,
                    line: #line
                )
                // TODO: Track failed aborts for cleanup job or CloudWatch metrics
            }

            // Re-throw original error
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
        let partCount = Int((fileSize + partSize - 1) / partSize)  // Ceiling division

        Logger.upload.debug(
            "Uploading \(partCount) parts for file of size \(fileSize) bytes",
            file: #file,
            function: #function,
            line: #line
        )

        // Open file handle
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        var didCloseSuccessfully = false

        // Ensure FileHandle is always closed, even on errors
        defer {
            if !didCloseSuccessfully {
                do {
                    try fileHandle.close()
                    didCloseSuccessfully = true
                } catch {
                    // Critical: File descriptor leak if this fails
                    Logger.upload.error(
                        "Failed to close file handle for \(fileURL.path): \(error). File descriptor may be leaked.",
                        file: #file,
                        function: #function,
                        line: #line
                    )
                    // Note: Process may need restart if too many file descriptors leak
                }
            }
        }

        // Upload parts sequentially (for now - can be parallelized later)
        // TODO: Parallelize part uploads for better throughput (see code review issue #7)
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

        // Explicitly close file handle before returning
        try fileHandle.close()
        didCloseSuccessfully = true

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

    /// Generates a secure S3 key for a chunk with anti-enumeration measures
    ///
    /// Security measures:
    /// - Sanitizes userId and recordingId to prevent path traversal attacks
    /// - Adds random suffix to prevent enumeration of sequential chunk numbers
    /// - Validates path components don't contain directory navigation sequences
    private func generateS3Key(userId: String, recordingId: String, chunkIndex: Int) -> String {
        // Sanitize inputs to prevent path traversal attacks
        let sanitizedUserId = sanitizePathComponent(userId)
        let sanitizedRecordingId = sanitizePathComponent(recordingId)

        // Add random component to prevent enumeration
        let randomSuffix = UUID().uuidString.prefix(8)
        let fileName = "part-\(String(format: "%04d", chunkIndex + 1))-\(randomSuffix).mp4"

        return AWSConfig.s3ChunksPath(userId: sanitizedUserId, recordingId: sanitizedRecordingId)
            + fileName
    }

    /// Sanitizes a path component to prevent directory traversal and injection attacks
    ///
    /// Removes:
    /// - Directory navigation sequences (.., /)
    /// - Backslashes (Windows path separators)
    /// - Other potentially dangerous characters
    ///
    /// - Parameter component: The path component to sanitize
    /// - Returns: Sanitized path component safe for use in S3 keys
    private func sanitizePathComponent(_ component: String) -> String {
        return
            component
            .replacingOccurrences(of: "..", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\0", with: "")  // Null bytes
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates S3 object metadata for uploaded chunks
    ///
    /// ## Security Considerations:
    ///
    /// **WARNING:** S3 object metadata is accessible to anyone with read permissions on the bucket.
    /// Ensure bucket policies restrict metadata access to authorized users only.
    ///
    /// **Data Sensitivity:**
    /// - `recording-id` and `chunk-id` could enable correlation attacks to identify user recordings
    /// - Do NOT include PII (personally identifiable information) in metadata
    /// - Consider encrypting sensitive metadata fields if additional privacy is required
    ///
    /// **Compliance Requirements:**
    /// - Audit logging should track metadata access for GDPR/CCPA compliance
    /// - Metadata retention should align with data retention policies
    ///
    /// **Bucket Policy Example:**
    /// ```json
    /// {
    ///   "Effect": "Allow",
    ///   "Principal": {"AWS": "arn:aws:iam::ACCOUNT:role/meeting-recorder"},
    ///   "Action": ["s3:GetObjectMetadata"],
    ///   "Resource": "arn:aws:s3:::bucket/users/${aws:userid}/*"
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - chunkMetadata: Chunk metadata to include in S3 object metadata
    ///   - recordingId: Recording identifier (sanitized before use in S3 keys)
    /// - Returns: Dictionary of metadata key-value pairs for S3 object
    private func createUploadMetadata(
        chunkMetadata: ChunkMetadata,
        recordingId: String
    ) -> [String: String] {
        return [
            "checksum-sha256": chunkMetadata.checksum,
            "recording-id": recordingId,
            "chunk-id": chunkMetadata.chunkId,
            "chunk-index": String(chunkMetadata.index),
            "duration-seconds": String(format: "%.2f", chunkMetadata.durationSeconds),
        ]
    }

    /// Maps AWS SDK and system errors to UploadError types
    ///
    /// TODO: AWS SDK for Swift doesn't expose typed S3Error enum yet.
    /// When available, replace string matching with structured error checking.
    ///
    /// - Parameter error: The error to map
    /// - Returns: Typed UploadError for consistent error handling
    private func mapS3Error(_ error: Error) -> UploadError {
        // Check for network errors (URLSession/Foundation errors)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .networkError("Network connection failed: \(error.localizedDescription)")
        }

        // Check error message for credential-related keywords
        // This is less reliable but necessary until AWS SDK provides typed errors
        let errorMessage = error.localizedDescription.lowercased()
        if errorMessage.contains("forbidden") || errorMessage.contains("credentials")
            || errorMessage.contains("unauthorized") || errorMessage.contains("accessdenied")
            || errorMessage.contains("expired") || errorMessage.contains("token")
        {
            return .credentialsExpired
        }

        // Check for S3-specific errors in message
        if errorMessage.contains("nosuchbucket") {
            return .credentialsExpired
        }

        if errorMessage.contains("serviceunavailable") || errorMessage.contains("slowdown") {
            return .networkError("S3 service temporarily unavailable")
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
    case insufficientStorage(String)

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
        case .insufficientStorage(let message):
            return "Insufficient storage: \(message)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .networkError, .credentialsExpired, .uploadFailed:
            return true
        case .invalidChunk, .insufficientStorage:
            return false
        }
    }
}
