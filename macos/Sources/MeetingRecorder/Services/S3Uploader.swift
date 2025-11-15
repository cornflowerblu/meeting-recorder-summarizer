//
//  S3Uploader.swift
//  MeetingRecorder
//
//  S3 uploader with multipart support, retry logic, and progress tracking
//

import Foundation
import AWSS3
import ClientRuntime

// MARK: - Upload Result

struct UploadResult: Sendable {
    let s3Key: String
    let etag: String
    let fileSize: Int64
    let uploadDuration: TimeInterval
}

// MARK: - Upload Progress

struct UploadProgress: Sendable {
    let bytesUploaded: Int64
    let totalBytes: Int64
    let percentage: Double

    init(bytesUploaded: Int64, totalBytes: Int64) {
        self.bytesUploaded = bytesUploaded
        self.totalBytes = totalBytes
        self.percentage = totalBytes > 0 ? Double(bytesUploaded) / Double(totalBytes) : 0
    }
}

// MARK: - S3 Uploader

actor S3Uploader {

    // MARK: - Configuration

    private let clientFactory = S3ClientFactory.shared
    private let bucketName: String
    private let multipartThreshold: Int64
    private let partSize: Int64 = 5 * 1024 * 1024 // 5 MB parts
    private let maxRetries: Int
    private let retryDelay: TimeInterval

    // MARK: - Progress Tracking

    var onProgress: ((String, UploadProgress) -> Void)?

    // MARK: - Errors

    enum S3UploaderError: Error, LocalizedError {
        case fileNotFound(URL)
        case fileReadError(Error)
        case uploadFailed(String, Error)
        case multipartUploadFailed(String)
        case invalidETag

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "File not found: \(url.path)"
            case .fileReadError(let error):
                return "Failed to read file: \(error.localizedDescription)"
            case .uploadFailed(let key, let error):
                return "Upload failed for \(key): \(error.localizedDescription)"
            case .multipartUploadFailed(let reason):
                return "Multipart upload failed: \(reason)"
            case .invalidETag:
                return "Invalid or missing ETag in upload response"
            }
        }
    }

    // MARK: - Initialization

    init(
        bucketName: String? = nil,
        multipartThreshold: Int64? = nil,
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 2.0
    ) {
        self.bucketName = bucketName ?? AWSConfig.s3BucketName
        self.multipartThreshold = multipartThreshold ?? Config.shared.multipartUploadThresholdBytes
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay

        Task {
            await Logger.shared.debug("S3Uploader initialized", metadata: [
                "bucket": self.bucketName,
                "multipartThreshold": String(self.multipartThreshold)
            ])
        }
    }

    // MARK: - Public API

    /// Upload a file to S3 with automatic multipart handling
    /// - Parameters:
    ///   - fileURL: Local file path to upload
    ///   - s3Key: Destination S3 key
    ///   - contentType: MIME type of the file
    /// - Returns: Upload result with ETag and metadata
    func upload(
        fileURL: URL,
        s3Key: String,
        contentType: String = "video/mp4"
    ) async throws -> UploadResult {
        let startTime = Date()

        await Logger.shared.info("Starting S3 upload", metadata: [
            "s3Key": s3Key,
            "fileURL": fileURL.lastPathComponent
        ])

        // Verify file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw S3UploaderError.fileNotFound(fileURL)
        }

        // Get file size
        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw S3UploaderError.fileReadError(error)
        }

        // Choose upload strategy based on file size
        let result: UploadResult
        if fileSize > multipartThreshold {
            result = try await uploadMultipart(
                fileURL: fileURL,
                s3Key: s3Key,
                contentType: contentType,
                fileSize: fileSize
            )
        } else {
            result = try await uploadSinglePart(
                fileURL: fileURL,
                s3Key: s3Key,
                contentType: contentType,
                fileSize: fileSize
            )
        }

        let duration = Date().timeIntervalSince(startTime)

        await Logger.shared.info("S3 upload completed", metadata: [
            "s3Key": s3Key,
            "fileSize": String(fileSize),
            "duration": String(format: "%.2f", duration),
            "etag": result.etag
        ])

        return UploadResult(
            s3Key: s3Key,
            etag: result.etag,
            fileSize: fileSize,
            uploadDuration: duration
        )
    }

    // MARK: - Single-Part Upload

    private func uploadSinglePart(
        fileURL: URL,
        s3Key: String,
        contentType: String,
        fileSize: Int64
    ) async throws -> UploadResult {
        await Logger.shared.debug("Using single-part upload", metadata: [
            "s3Key": s3Key,
            "fileSize": String(fileSize)
        ])

        // Read file data
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw S3UploaderError.fileReadError(error)
        }

        // Get S3 client
        let client = try await clientFactory.getClient()

        // Create put object input
        let input = PutObjectInput(
            body: .data(data),
            bucket: bucketName,
            contentType: contentType,
            key: s3Key,
            serverSideEncryption: .aes256,
            storageClass: .standard
        )

        // Upload with retry
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let output = try await client.putObject(input: input)

                guard let etag = output.eTag else {
                    throw S3UploaderError.invalidETag
                }

                // Report completion
                onProgress?(s3Key, UploadProgress(bytesUploaded: fileSize, totalBytes: fileSize))

                return UploadResult(
                    s3Key: s3Key,
                    etag: etag,
                    fileSize: fileSize,
                    uploadDuration: 0 // Calculated by caller
                )
            } catch {
                lastError = error

                if attempt < maxRetries {
                    await Logger.shared.warning("Upload attempt failed, retrying", metadata: [
                        "attempt": String(attempt + 1),
                        "maxRetries": String(maxRetries),
                        "error": error.localizedDescription
                    ])

                    try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(NSEC_PER_SEC)))
                }
            }
        }

        throw S3UploaderError.uploadFailed(s3Key, lastError ?? NSError(domain: "Unknown", code: -1))
    }

    // MARK: - Multipart Upload

    private func uploadMultipart(
        fileURL: URL,
        s3Key: String,
        contentType: String,
        fileSize: Int64
    ) async throws -> UploadResult {
        await Logger.shared.debug("Using multipart upload", metadata: [
            "s3Key": s3Key,
            "fileSize": String(fileSize),
            "partSize": String(partSize)
        ])

        let client = try await clientFactory.getClient()

        // Step 1: Initiate multipart upload
        let createInput = CreateMultipartUploadInput(
            bucket: bucketName,
            contentType: contentType,
            key: s3Key,
            serverSideEncryption: .aes256,
            storageClass: .standard
        )

        let createOutput = try await client.createMultipartUpload(input: createInput)

        guard let uploadId = createOutput.uploadId else {
            throw S3UploaderError.multipartUploadFailed("Missing upload ID")
        }

        await Logger.shared.info("Multipart upload initiated", metadata: [
            "uploadId": uploadId,
            "s3Key": s3Key
        ])

        do {
            // Step 2: Upload parts
            let completedParts = try await uploadParts(
                client: client,
                fileURL: fileURL,
                s3Key: s3Key,
                uploadId: uploadId,
                fileSize: fileSize
            )

            // Step 3: Complete multipart upload
            let completeInput = CompleteMultipartUploadInput(
                bucket: bucketName,
                key: s3Key,
                multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completedParts),
                uploadId: uploadId
            )

            let completeOutput = try await client.completeMultipartUpload(input: completeInput)

            guard let etag = completeOutput.eTag else {
                throw S3UploaderError.invalidETag
            }

            await Logger.shared.info("Multipart upload completed", metadata: [
                "uploadId": uploadId,
                "parts": String(completedParts.count),
                "etag": etag
            ])

            return UploadResult(
                s3Key: s3Key,
                etag: etag,
                fileSize: fileSize,
                uploadDuration: 0 // Calculated by caller
            )
        } catch {
            // Abort multipart upload on error
            await Logger.shared.error("Multipart upload failed, aborting", metadata: [
                "uploadId": uploadId,
                "error": error.localizedDescription
            ])

            let abortInput = AbortMultipartUploadInput(
                bucket: bucketName,
                key: s3Key,
                uploadId: uploadId
            )

            try? await client.abortMultipartUpload(input: abortInput)

            throw error
        }
    }

    private func uploadParts(
        client: S3Client,
        fileURL: URL,
        s3Key: String,
        uploadId: String,
        fileSize: Int64
    ) async throws -> [S3ClientTypes.CompletedPart] {
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw S3UploaderError.fileReadError(error)
        }

        defer {
            try? fileHandle.close()
        }

        var completedParts: [S3ClientTypes.CompletedPart] = []
        var uploadedBytes: Int64 = 0
        var partNumber = 1

        while uploadedBytes < fileSize {
            let remainingBytes = fileSize - uploadedBytes
            let currentPartSize = min(partSize, remainingBytes)

            // Read part data
            let partData: Data
            do {
                if #available(macOS 10.15.4, *) {
                    partData = try fileHandle.read(upToCount: Int(currentPartSize)) ?? Data()
                } else {
                    partData = fileHandle.readData(ofLength: Int(currentPartSize))
                }
            } catch {
                throw S3UploaderError.fileReadError(error)
            }

            // Upload part with retry
            let uploadedPart = try await uploadPartWithRetry(
                client: client,
                bucket: bucketName,
                key: s3Key,
                uploadId: uploadId,
                partNumber: partNumber,
                data: partData
            )

            completedParts.append(uploadedPart)
            uploadedBytes += currentPartSize
            partNumber += 1

            // Report progress
            let progress = UploadProgress(bytesUploaded: uploadedBytes, totalBytes: fileSize)
            onProgress?(s3Key, progress)

            await Logger.shared.debug("Part uploaded", metadata: [
                "partNumber": String(partNumber - 1),
                "uploadedBytes": String(uploadedBytes),
                "totalBytes": String(fileSize),
                "progress": String(format: "%.1f%%", progress.percentage * 100)
            ])
        }

        return completedParts
    }

    private func uploadPartWithRetry(
        client: S3Client,
        bucket: String,
        key: String,
        uploadId: String,
        partNumber: Int,
        data: Data
    ) async throws -> S3ClientTypes.CompletedPart {
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                let input = UploadPartInput(
                    body: .data(data),
                    bucket: bucket,
                    key: key,
                    partNumber: partNumber,
                    uploadId: uploadId
                )

                let output = try await client.uploadPart(input: input)

                guard let etag = output.eTag else {
                    throw S3UploaderError.invalidETag
                }

                return S3ClientTypes.CompletedPart(eTag: etag, partNumber: partNumber)
            } catch {
                lastError = error

                if attempt < maxRetries {
                    await Logger.shared.warning("Part upload failed, retrying", metadata: [
                        "partNumber": String(partNumber),
                        "attempt": String(attempt + 1),
                        "error": error.localizedDescription
                    ])

                    try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(NSEC_PER_SEC)))
                }
            }
        }

        throw S3UploaderError.uploadFailed(key, lastError ?? NSError(domain: "Unknown", code: -1))
    }
}

// MARK: - Convenience Extensions

extension S3Uploader {
    /// Create an S3 uploader with default configuration
    static func standard() -> S3Uploader {
        S3Uploader()
    }
}
