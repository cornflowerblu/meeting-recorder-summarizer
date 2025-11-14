// swiftlint:disable type_body_length
import AWSS3
import XCTest

@testable import MeetingRecorder

@MainActor
final class S3UploaderTests: XCTestCase {
  var mockS3Client: MockS3Client!
  var uploader: S3Uploader!
  var testUserId: String!
  var testRecordingId: String!
  var tempDirectory: URL!

  override func setUp() async throws {
    testUserId = "test-user-123"
    testRecordingId = "rec_01JCXYZ123"

    // Create temp directory for test files
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("S3UploaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tempDirectory,
      withIntermediateDirectories: true
    )

    mockS3Client = MockS3Client()
    uploader = S3Uploader(
      s3Client: mockS3Client,
      bucketName: "test-bucket"
    )
  }

  override func tearDown() async throws {
    uploader = nil
    mockS3Client = nil

    // Clean up temp directory
    try? FileManager.default.removeItem(at: tempDirectory)
  }

  // MARK: - Successful Multipart Upload Flow Tests

  func testSuccessfulMultipartUploadFlow() async throws {
    // Given: A chunk file with typical size (50MB)
    let chunkFile = try createTestFile(size: 50_000_000)  // 50MB
    let chunk = createChunkMetadata(
      index: 0,
      filePath: chunkFile,
      sizeBytes: 50_000_000
    )

    mockS3Client.uploadIdToReturn = "test-upload-id-123"
    mockS3Client.etagToReturn = "test-etag-456"

    // When: Upload is performed
    let result = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then: Multipart upload workflow completes successfully
    XCTAssertEqual(
      mockS3Client.createMultipartUploadCallCount, 1,
      "Should initiate multipart upload once"
    )
    XCTAssertEqual(
      mockS3Client.uploadPartCallCount, 10,
      "Should upload 10 parts for 50MB file (5MB each)"
    )
    XCTAssertEqual(
      mockS3Client.completeMultipartUploadCallCount, 1,
      "Should complete multipart upload once"
    )
    XCTAssertEqual(
      mockS3Client.abortMultipartUploadCallCount, 0,
      "Should not abort on success"
    )

    // Verify result
    XCTAssertEqual(result.etag, "test-etag-456")
    XCTAssertTrue(result.s3Key.hasPrefix("users/\(testUserId!)/raw-chunks/\(testRecordingId!)/"))
    XCTAssertTrue(result.uploadDuration > 0)
  }

  func testMultipartUploadWithSmallFile() async throws {
    // Given: A small chunk file (1MB - single part)
    let chunkFile = try createTestFile(size: 1_000_000)  // 1MB
    let chunk = createChunkMetadata(
      index: 0,
      filePath: chunkFile,
      sizeBytes: 1_000_000
    )

    mockS3Client.uploadIdToReturn = "upload-small"
    mockS3Client.etagToReturn = "etag-small"

    // When
    _ = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then: Only one part uploaded for small file
    XCTAssertEqual(mockS3Client.uploadPartCallCount, 1, "Should upload 1 part for 1MB file")
    XCTAssertEqual(mockS3Client.completeMultipartUploadCallCount, 1)
  }

  func testMultipartUploadWithLargeFile() async throws {
    // Given: A large chunk file (100MB - 20 parts)
    let chunkFile = try createTestFile(size: 100_000_000)  // 100MB
    let chunk = createChunkMetadata(
      index: 0,
      filePath: chunkFile,
      sizeBytes: 100_000_000
    )

    mockS3Client.uploadIdToReturn = "upload-large"
    mockS3Client.etagToReturn = "etag-large"

    // When
    _ = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then: Multiple parts uploaded for large file
    XCTAssertEqual(
      mockS3Client.uploadPartCallCount, 20,
      "Should upload 20 parts for 100MB file (5MB each)"
    )
  }

  // MARK: - S3 Key Format Validation Tests

  func testS3KeyFormatMatchesExpectedPattern() async throws {
    // Given
    let chunk = createChunkMetadata(index: 0)

    // When
    let result = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then: Key follows users/{userId}/raw-chunks/{recordingId}/part-XXXX-{random}.mp4
    let expectedPrefix = "users/\(testUserId!)/raw-chunks/\(testRecordingId!)/part-"
    XCTAssertTrue(
      result.s3Key.hasPrefix(expectedPrefix),
      "S3 key should start with \(expectedPrefix)"
    )
    XCTAssertTrue(result.s3Key.hasSuffix(".mp4"), "S3 key should end with .mp4")

    // Verify pattern: part-0001-{8chars}.mp4
    let pattern =
      "^users/\(testUserId!)/raw-chunks/\(testRecordingId!)/part-\\d{4}-[a-zA-Z0-9]{8}\\.mp4$"
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(result.s3Key.startIndex..., in: result.s3Key)
    XCTAssertNotNil(
      regex.firstMatch(in: result.s3Key, range: range),
      "S3 key '\(result.s3Key)' should match pattern"
    )
  }

  func testS3KeyContainsChunkIndex() async throws {
    // Given: Chunks with different indices
    let testCases: [(index: Int, expected: String)] = [
      (0, "0001"),
      (5, "0006"),
      (99, "0100"),
    ]

    for testCase in testCases {
      let chunk = createChunkMetadata(index: testCase.index)

      // When
      let result = try await uploader.uploadChunk(
        recordingId: testRecordingId,
        chunkMetadata: chunk,
        userId: testUserId
      )

      // Then: Key contains zero-padded chunk index (1-indexed)
      XCTAssertTrue(
        result.s3Key.contains("part-\(testCase.expected)-"),
        "S3 key should contain part-\(testCase.expected)- for chunk index \(testCase.index)"
      )
    }
  }

  func testS3KeySanitizesPathTraversalAttempts() async throws {
    // Given: Malicious user/recording IDs with path traversal attempts
    let maliciousUserId = "../../../etc/passwd"
    let maliciousRecordingId = "../../secrets"
    let chunk = createChunkMetadata(index: 0)

    // When
    let result = try await uploader.uploadChunk(
      recordingId: maliciousRecordingId,
      chunkMetadata: chunk,
      userId: maliciousUserId
    )

    // Then: Path traversal sequences are removed
    XCTAssertFalse(result.s3Key.contains(".."), "S3 key should not contain '..'")
    XCTAssertTrue(result.s3Key.hasPrefix("users/etcpasswd/"), "Should sanitize userId")
    XCTAssertTrue(result.s3Key.contains("raw-chunks/secrets/"), "Should sanitize recordingId")
  }

  func testS3KeyIncludesRandomSuffixForAntiEnumeration() async throws {
    // Given: Same chunk uploaded twice
    let chunk = createChunkMetadata(index: 0)

    // When: Upload same chunk twice (simulating retry or duplicate)
    let result1 = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )
    mockS3Client.reset()
    let result2 = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then: Keys should differ due to random suffix (anti-enumeration)
    XCTAssertNotEqual(result1.s3Key, result2.s3Key, "Keys should have different random suffixes")

    // Extract random suffix (8 chars after last dash before .mp4)
    let suffix1 = extractRandomSuffix(from: result1.s3Key)
    let suffix2 = extractRandomSuffix(from: result2.s3Key)
    XCTAssertNotEqual(suffix1, suffix2, "Random suffixes should differ")
    XCTAssertEqual(suffix1.count, 8, "Random suffix should be 8 characters")
    XCTAssertEqual(suffix2.count, 8, "Random suffix should be 8 characters")
  }

  // MARK: - Metadata Attachment Tests

  func testMetadataContainsRequiredFields() async throws {
    // Given
    let chunk = createChunkMetadata(
      index: 3,
      checksum: "abc123def456",
      durationSeconds: 60.5
    )

    // When
    _ = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then: Metadata should contain all required fields
    guard let metadata = mockS3Client.lastMetadata else {
      XCTFail("No metadata was attached to upload")
      return
    }

    XCTAssertEqual(metadata["checksum-sha256"], "abc123def456")
    XCTAssertEqual(metadata["recording-id"], testRecordingId)
    XCTAssertEqual(metadata["chunk-id"], chunk.chunkId)
    XCTAssertEqual(metadata["chunk-index"], "3")
    XCTAssertEqual(metadata["duration-seconds"], "60.50")
  }

  func testMetadataDoesNotContainPII() async throws {
    // Given
    let chunk = createChunkMetadata(index: 0)

    // When
    _ = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then: Metadata should NOT contain PII (email, names, etc.)
    guard let metadata = mockS3Client.lastMetadata else {
      XCTFail("No metadata was attached")
      return
    }

    XCTAssertNil(metadata["user-email"], "Should not include user email")
    XCTAssertNil(metadata["user-name"], "Should not include user name")
    XCTAssertNil(metadata["user-id"], "Should not include user ID (PII)")
  }

  func testMetadataContentTypeIsVideoMp4() async throws {
    // Given
    let chunk = createChunkMetadata(index: 0)

    // When
    _ = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then
    XCTAssertEqual(mockS3Client.lastContentType, "video/mp4")
  }

  func testServerSideEncryptionEnabled() async throws {
    // Given
    let chunk = createChunkMetadata(index: 0)

    // When
    _ = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then
    XCTAssertEqual(mockS3Client.lastEncryption, .aes256, "Should use AES-256 encryption")
  }

  // MARK: - Error Mapping Tests

  func testNetworkErrorMapping() async throws {
    // Given: Network error from AWS SDK
    mockS3Client.failOnCreate = true
    mockS3Client.errorToThrow = createNetworkError()
    let chunk = createChunkMetadata(index: 0)

    // When/Then
    await assertThrowsUploadError(
      expectedType: .networkError(""),
      errorMessage: "Network connection failed"
    ) {
      try await uploader.uploadChunk(
        recordingId: testRecordingId,
        chunkMetadata: chunk,
        userId: testUserId
      )
    }
  }

  func testCredentialsExpiredErrorMapping() async throws {
    // Given: Various credential-related errors
    let credentialErrors = [
      "Access Denied: Invalid credentials",
      "Request forbidden by IAM policy",
      "SecurityTokenExpired",
      "The provided token is expired",
    ]

    for errorMessage in credentialErrors {
      mockS3Client.reset()
      mockS3Client.failOnCreate = true
      mockS3Client.errorToThrow = createAWSError(code: 403, message: errorMessage)
      let chunk = createChunkMetadata(index: 0)

      // When/Then
      await assertThrowsUploadError(expectedType: .credentialsExpired) {
        try await uploader.uploadChunk(
          recordingId: testRecordingId,
          chunkMetadata: chunk,
          userId: testUserId
        )
      }
    }
  }

  func testServiceUnavailableErrorMapping() async throws {
    // Given: S3 service unavailable
    let serviceError = "ServiceUnavailable: Please reduce your request rate"
    mockS3Client.failOnCreate = true
    mockS3Client.errorToThrow = createAWSError(code: 503, message: serviceError)
    let chunk = createChunkMetadata(index: 0)

    // When/Then
    await assertThrowsUploadError(
      expectedType: .networkError(""),
      errorMessage: "temporarily unavailable"
    ) {
      try await uploader.uploadChunk(
        recordingId: testRecordingId,
        chunkMetadata: chunk,
        userId: testUserId
      )
    }
  }

  func testGenericUploadFailureMapping() async throws {
    // Given: Generic S3 error
    mockS3Client.failOnCreate = true
    mockS3Client.errorToThrow = createAWSError(
      code: 500,
      message: "InternalError: Something went wrong"
    )
    let chunk = createChunkMetadata(index: 0)

    // When/Then
    await assertThrowsUploadError(
      expectedType: .uploadFailed(""),
      errorMessage: "InternalError"
    ) {
      try await uploader.uploadChunk(
        recordingId: testRecordingId,
        chunkMetadata: chunk,
        userId: testUserId
      )
    }
  }

  func testErrorIsRetryableFlag() {
    // Network errors are retryable
    let networkError = UploadError.networkError("Connection lost")
    XCTAssertTrue(networkError.isRetryable)

    // Credentials expired is retryable (after refresh)
    let credentialsError = UploadError.credentialsExpired
    XCTAssertTrue(credentialsError.isRetryable)

    // Generic upload failures are retryable
    let uploadError = UploadError.uploadFailed("Temporary failure")
    XCTAssertTrue(uploadError.isRetryable)

    // Invalid chunk is NOT retryable
    let invalidChunkError = UploadError.invalidChunk("Corrupted file")
    XCTAssertFalse(invalidChunkError.isRetryable)

    // Insufficient storage is NOT retryable
    let storageError = UploadError.insufficientStorage("Quota exceeded")
    XCTAssertFalse(storageError.isRetryable)
  }

  // MARK: - Multipart Upload Cleanup Tests

  func testMultipartUploadAbortedOnPartUploadFailure() async throws {
    // Given: Upload initialized but part upload fails
    mockS3Client.uploadIdToReturn = "upload-to-abort"
    mockS3Client.failOnPartNumber = 3  // Fail on 3rd part
    mockS3Client.errorToThrow = createAWSError(code: 500, message: "Part upload failed")

    let chunkFile = try createTestFile(size: 20_000_000)  // 20MB = 4 parts
    let chunk = createChunkMetadata(
      index: 0,
      filePath: chunkFile,
      sizeBytes: 20_000_000
    )

    // When
    do {
      _ = try await uploader.uploadChunk(
        recordingId: testRecordingId,
        chunkMetadata: chunk,
        userId: testUserId
      )
      XCTFail("Should throw upload error")
    } catch {
      // Then: Abort should be called to clean up orphaned parts
      XCTAssertEqual(mockS3Client.abortMultipartUploadCallCount, 1, "Should abort multipart upload")
      XCTAssertEqual(mockS3Client.completeMultipartUploadCallCount, 0, "Should not complete upload")

      // Verify abort was called with correct uploadId
      XCTAssertEqual(mockS3Client.lastAbortedUploadId, "upload-to-abort")
    }
  }

  func testMultipartUploadAbortedOnCompleteFailure() async throws {
    // Given: Parts uploaded successfully but complete fails
    mockS3Client.uploadIdToReturn = "upload-complete-fail"
    mockS3Client.failOnComplete = true
    mockS3Client.errorToThrow = createAWSError(code: 500, message: "Complete failed")

    let chunk = createChunkMetadata(index: 0)

    // When
    do {
      _ = try await uploader.uploadChunk(
        recordingId: testRecordingId,
        chunkMetadata: chunk,
        userId: testUserId
      )
      XCTFail("Should throw upload error")
    } catch {
      // Then: Should attempt abort
      XCTAssertEqual(mockS3Client.abortMultipartUploadCallCount, 1)
    }
  }

  func testMultipartUploadCleanupLogsAbortFailure() async throws {
    // Given: Upload fails AND abort also fails
    mockS3Client.uploadIdToReturn = "double-failure"
    mockS3Client.failOnPartNumber = 1
    mockS3Client.failOnAbort = true
    mockS3Client.errorToThrow = createAWSError(code: 500, message: "Everything is broken")

    let chunk = createChunkMetadata(index: 0)

    // When: Upload fails
    do {
      _ = try await uploader.uploadChunk(
        recordingId: testRecordingId,
        chunkMetadata: chunk,
        userId: testUserId
      )
      XCTFail("Should throw upload error")
    } catch {
      // Then: Abort was attempted (even though it failed)
      XCTAssertEqual(mockS3Client.abortMultipartUploadCallCount, 1)
      // Original error should be thrown, not abort error
      XCTAssertTrue(error.localizedDescription.contains("Everything is broken"))
    }
  }

  func testNoAbortOnSuccessfulUpload() async throws {
    // Given: Successful upload
    let chunk = createChunkMetadata(index: 0)

    // When
    _ = try await uploader.uploadChunk(
      recordingId: testRecordingId,
      chunkMetadata: chunk,
      userId: testUserId
    )

    // Then: No abort called
    XCTAssertEqual(mockS3Client.abortMultipartUploadCallCount, 0)
    XCTAssertEqual(mockS3Client.completeMultipartUploadCallCount, 1)
  }

  // MARK: - Helper Methods

  private func createTestFile(size: Int) throws -> URL {
    let fileURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    let data = Data(repeating: 0x42, count: size)  // Fill with 'B' bytes
    try data.write(to: fileURL)
    return fileURL
  }

  private func createChunkMetadata(
    index: Int,
    filePath: URL? = nil,
    sizeBytes: Int64? = nil,
    checksum: String = "test-checksum-abc123",
    durationSeconds: TimeInterval = 60.0
  ) -> ChunkMetadata {
    let actualFilePath =
      filePath
      ?? {
        let url = tempDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let data = Data(repeating: 0x00, count: 1000)
        try? data.write(to: url)
        return url
      }()

    let actualSize =
      sizeBytes
      ?? {
        let attributes = try? FileManager.default.attributesOfItem(
          atPath: actualFilePath.path
        )
        return Int64((attributes?[.size] as? Int64) ?? 1000)
      }()

    return ChunkMetadata(
      chunkId: "chunk-\(index)",
      filePath: actualFilePath,
      sizeBytes: actualSize,
      checksum: checksum,
      durationSeconds: durationSeconds,
      index: index,
      recordingId: testRecordingId
    )
  }

  private func extractRandomSuffix(from s3Key: String) -> String {
    // Extract 8-char random suffix between last '-' and '.mp4'
    let components = s3Key.components(separatedBy: "-")
    guard let lastComponent = components.last else { return "" }
    return lastComponent.replacingOccurrences(of: ".mp4", with: "")
  }

  private func createNetworkError() -> NSError {
    return NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorNotConnectedToInternet,
      userInfo: [NSLocalizedDescriptionKey: "Not connected to internet"]
    )
  }

  private func createAWSError(code: Int, message: String) -> NSError {
    return NSError(
      domain: "AWSSDKError",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  private func assertThrowsUploadError(
    expectedType: UploadError,
    errorMessage: String? = nil,
    file: StaticString = #file,
    line: UInt = #line,
    _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Should throw UploadError", file: file, line: line)
    } catch let error as UploadError {
      switch (error, expectedType) {
      case (.networkError(let msg), .networkError):
        if let expectedMsg = errorMessage {
          XCTAssertTrue(msg.contains(expectedMsg), file: file, line: line)
        }
      case (.credentialsExpired, .credentialsExpired):
        break
      case (.uploadFailed(let msg), .uploadFailed):
        if let expectedMsg = errorMessage {
          XCTAssertTrue(msg.contains(expectedMsg), file: file, line: line)
        }
      default:
        XCTFail("Expected \(expectedType), got \(error)", file: file, line: line)
      }
    } catch {
      XCTFail("Expected UploadError, got \(error)", file: file, line: line)
    }
  }
}
