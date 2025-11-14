import AWSS3
import Foundation

@testable import MeetingRecorder

/// Mock S3 client for testing multipart upload flows without real AWS calls
///
/// This mock simulates AWS S3 multipart upload operations:
/// 1. createMultipartUpload - initiates upload, returns uploadId
/// 2. uploadPart - uploads individual parts (5MB each)
/// 3. completeMultipartUpload - finalizes upload
/// 4. abortMultipartUpload - cleans up failed uploads
final class MockS3Client: S3ClientProtocol, @unchecked Sendable {
  // MARK: - Configuration Properties

  /// Upload ID to return from createMultipartUpload
  var uploadIdToReturn: String = "default-upload-id"

  /// ETag to return from uploadPart and completeMultipartUpload
  var etagToReturn: String = "default-etag"

  /// Error to throw from any operation
  var errorToThrow: Error?

  /// Part number that should fail (1-indexed)
  var failOnPartNumber: Int?

  /// Whether createMultipartUpload should fail
  var failOnCreate: Bool = false

  /// Whether completeMultipartUpload should fail
  var failOnComplete: Bool = false

  /// Whether abortMultipartUpload should fail
  var failOnAbort: Bool = false

  // MARK: - Call Tracking

  var createMultipartUploadCallCount = 0
  var uploadPartCallCount = 0
  var completeMultipartUploadCallCount = 0
  var abortMultipartUploadCallCount = 0

  /// Last metadata passed to createMultipartUpload
  var lastMetadata: [String: String]?

  /// Last content type passed to createMultipartUpload
  var lastContentType: String?

  /// Last encryption setting passed to createMultipartUpload
  var lastEncryption: S3ClientTypes.ServerSideEncryption?

  /// Last upload ID that was aborted
  var lastAbortedUploadId: String?

  /// Parts uploaded (for verification)
  var uploadedParts: [(partNumber: Int, data: Data)] = []

  // MARK: - S3ClientProtocol Implementation

  func createMultipartUpload(input: CreateMultipartUploadInput) async throws
    -> CreateMultipartUploadOutput
  {
    createMultipartUploadCallCount += 1
    lastContentType = input.contentType
    lastMetadata = input.metadata
    lastEncryption = input.serverSideEncryption

    // Check if createMultipartUpload should fail
    if failOnCreate, let error = errorToThrow {
      throw error
    }

    return CreateMultipartUploadOutput(
      bucket: input.bucket,
      key: input.key,
      uploadId: uploadIdToReturn
    )
  }

  func uploadPart(input: UploadPartInput) async throws -> UploadPartOutput {
    uploadPartCallCount += 1

    // Check if this specific part should fail
    if let failPart = failOnPartNumber, input.partNumber == failPart {
      if let error = errorToThrow {
        throw error
      }
    }

    // Extract data for tracking (if available)
    if case .data(let data) = input.body, let data = data {
      uploadedParts.append((input.partNumber ?? 0, data))
    }

    return UploadPartOutput(eTag: "\(etagToReturn)-part\(input.partNumber ?? 0)")
  }

  func completeMultipartUpload(input: CompleteMultipartUploadInput) async throws
    -> CompleteMultipartUploadOutput
  {
    completeMultipartUploadCallCount += 1

    if failOnComplete {
      if let error = errorToThrow {
        throw error
      }
    }

    return CompleteMultipartUploadOutput(
      bucket: input.bucket,
      eTag: etagToReturn,
      key: input.key
    )
  }

  func abortMultipartUpload(input: AbortMultipartUploadInput) async throws
    -> AbortMultipartUploadOutput
  {
    abortMultipartUploadCallCount += 1
    lastAbortedUploadId = input.uploadId

    if failOnAbort {
      if let error = errorToThrow {
        throw error
      }
    }

    return AbortMultipartUploadOutput()
  }

  // MARK: - Test Helpers

  /// Reset all tracking state between tests
  func reset() {
    createMultipartUploadCallCount = 0
    uploadPartCallCount = 0
    completeMultipartUploadCallCount = 0
    abortMultipartUploadCallCount = 0
    lastMetadata = nil
    lastContentType = nil
    lastEncryption = nil
    lastAbortedUploadId = nil
    uploadedParts = []
    errorToThrow = nil
    failOnCreate = false
    failOnPartNumber = nil
    failOnComplete = false
    failOnAbort = false
  }
}
