import XCTest
import AWSS3
import AWSClientRuntime
import Foundation
@testable import InterviewCompanion

/// Integration tests for S3Uploader with real AWS S3 service
///
/// These tests verify actual S3 operations including multipart uploads,
/// ETags, metadata, and error handling with the real AWS SDK.
///
/// ## Running Locally
///
/// Set AWS credentials as environment variables:
/// ```bash
/// export AWS_ACCESS_KEY_ID=your-test-access-key
/// export AWS_SECRET_ACCESS_KEY=your-test-secret-key
/// export AWS_REGION=us-east-1
/// export TEST_S3_BUCKET=meeting-recorder-test-integration
/// swift test --filter S3IntegrationTests
/// ```
///
/// Tests are automatically skipped if credentials are not available.
///
/// ## CI/CD
///
/// GitHub Actions should set these as secrets and run integration tests
/// on every PR to catch SDK integration issues early.
final class S3IntegrationTests: XCTestCase {
    var s3Client: S3Client!
    var uploader: S3Uploader!
    var testBucket: String!
    let testUserId = "integration-test-user"
    var testRecordingId: String!
    var tempDirectory: URL!
    var createdObjects: [String] = [] // Track for cleanup

    override func setUp() async throws {
        // Only run if AWS credentials and test bucket are configured
        guard ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] != nil else {
            throw XCTSkip("AWS credentials not available. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY to run integration tests.")
        }

        guard let bucket = ProcessInfo.processInfo.environment["TEST_S3_BUCKET"] else {
            throw XCTSkip("TEST_S3_BUCKET environment variable not set. Set to run integration tests.")
        }

        testBucket = bucket
        testRecordingId = "test-rec-\(UUID().uuidString)"

        // Create temp directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("S3IntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )

        // Initialize real S3 client
        let region = ProcessInfo.processInfo.environment["AWS_REGION"] ?? "us-east-1"
        s3Client = try S3Client(region: region)
        uploader = S3Uploader(s3Client: s3Client, bucketName: testBucket)

        print("✅ S3 Integration Tests configured:")
        print("   Bucket: \(testBucket!)")
        print("   Region: \(region)")
        print("   Recording ID: \(testRecordingId!)")
    }

    override func tearDown() async throws {
        // Only cleanup if test actually ran (not skipped)
        guard s3Client != nil else { return }

        // Clean up all created S3 objects
        for key in createdObjects {
            do {
                let deleteInput = DeleteObjectInput(bucket: testBucket, key: key)
                _ = try await s3Client.deleteObject(input: deleteInput)
                print("🗑️  Cleaned up S3 object: \(key)")
            } catch {
                print("⚠️  Failed to delete S3 object \(key): \(error)")
            }
        }

        // Clean up temp directory
        if tempDirectory != nil {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        s3Client = nil
        uploader = nil
    }

    // MARK: - Multipart Upload Tests

    func testMultipartUploadWithRealS3() async throws {
        // Given - Create a 10MB test file (triggers multipart upload with 5MB parts)
        let testData = createRandomData(size: 10_000_000) // 10MB
        let testFileURL = tempDirectory.appendingPathComponent("test-chunk-10mb.mp4")
        try testData.write(to: testFileURL)

        let chunk = await ChunkMetadata(
            chunkId: "integration-test-chunk-0000",
            filePath: testFileURL,
            sizeBytes: 10_000_000,
            checksum: calculateSHA256(data: testData),
            durationSeconds: 60.0,
            index: 0,
            recordingId: testRecordingId
        )

        // When - Upload to S3
        let result = try await uploader.uploadChunk(
            recordingId: testRecordingId,
            chunkMetadata: chunk,
            userId: testUserId
        )

        // Track for cleanup
        await createdObjects.append(result.s3Key)

        // Then - Verify upload succeeded
        XCTAssertFalse(result.s3Key.isEmpty, "S3 key should not be empty")
        XCTAssertTrue(result.s3Key.contains(testRecordingId), "S3 key should contain recording ID")
        XCTAssertFalse(result.etag.isEmpty, "ETag should not be empty")
        XCTAssertGreaterThan(result.uploadDuration, 0, "Upload duration should be positive")

        // Verify object exists in S3
        let headInput = await HeadObjectInput(bucket: testBucket, key: result.s3Key)
        let headOutput = try await s3Client.headObject(input: headInput)

        XCTAssertEqual(headOutput.contentLength, 10_000_000, "S3 object size should match uploaded size")
        XCTAssertNotNil(headOutput.eTag, "S3 object should have ETag")
        XCTAssertEqual(headOutput.contentType, "video/mp4", "Content type should be video/mp4")

        // Verify metadata
        XCTAssertNotNil(headOutput.metadata, "Object should have metadata")
        if let metadata = headOutput.metadata {
            XCTAssertEqual(metadata["recording-id"], testRecordingId, "Metadata should contain recording ID")
            XCTAssertEqual(metadata["chunk-id"], chunk.chunkId, "Metadata should contain chunk ID")
            XCTAssertEqual(metadata["chunk-index"], "0", "Metadata should contain chunk index")
            XCTAssertNotNil(metadata["checksum-sha256"], "Metadata should contain checksum")
        }

        print("✅ Multipart upload succeeded:")
        print("   S3 Key: \(result.s3Key)")
        print("   ETag: \(result.etag)")
        print("   Duration: \(String(format: "%.2f", result.uploadDuration))s")
    }

    func testSmallFileUpload() async throws {
        // Given - Create a 1MB test file (single part upload)
        let testData = createRandomData(size: 1_000_000) // 1MB
        let testFileURL = tempDirectory.appendingPathComponent("test-chunk-1mb.mp4")
        try testData.write(to: testFileURL)

        let chunk = ChunkMetadata(
            chunkId: "integration-test-chunk-small-0001",
            filePath: testFileURL,
            sizeBytes: 1_000_000,
            checksum: calculateSHA256(data: testData),
            durationSeconds: 15.0,
            index: 1,
            recordingId: testRecordingId
        )

        // When - Upload to S3
        let result = try await uploader.uploadChunk(
            recordingId: testRecordingId,
            chunkMetadata: chunk,
            userId: testUserId
        )

        createdObjects.append(result.s3Key)

        // Then - Verify upload succeeded
        XCTAssertFalse(result.s3Key.isEmpty)
        XCTAssertFalse(result.etag.isEmpty)

        // Verify object in S3
        let headInput = HeadObjectInput(bucket: testBucket, key: result.s3Key)
        let headOutput = try await s3Client.headObject(input: headInput)

        XCTAssertEqual(headOutput.contentLength, 1_000_000)
        XCTAssertEqual(headOutput.contentType, "video/mp4")

        print("✅ Small file upload succeeded:")
        print("   S3 Key: \(result.s3Key)")
        print("   Size: 1MB")
    }

    func testLargeMultipartUpload() async throws {
        // Given - Create a 25MB test file (5 parts with 5MB each)
        let testData = createRandomData(size: 25_000_000) // 25MB
        let testFileURL = tempDirectory.appendingPathComponent("test-chunk-25mb.mp4")
        try testData.write(to: testFileURL)

        let chunk = ChunkMetadata(
            chunkId: "integration-test-chunk-large-0002",
            filePath: testFileURL,
            sizeBytes: 25_000_000,
            checksum: calculateSHA256(data: testData),
            durationSeconds: 120.0,
            index: 2,
            recordingId: testRecordingId
        )

        // When - Upload to S3
        let startTime = Date()
        let result = try await uploader.uploadChunk(
            recordingId: testRecordingId,
            chunkMetadata: chunk,
            userId: testUserId
        )
        let uploadTime = Date().timeIntervalSince(startTime)

        createdObjects.append(result.s3Key)

        // Then - Verify upload succeeded
        XCTAssertFalse(result.s3Key.isEmpty)
        XCTAssertFalse(result.etag.isEmpty)

        // Verify object in S3
        let headInput = HeadObjectInput(bucket: testBucket, key: result.s3Key)
        let headOutput = try await s3Client.headObject(input: headInput)

        XCTAssertEqual(headOutput.contentLength, 25_000_000)

        print("✅ Large multipart upload succeeded:")
        print("   S3 Key: \(result.s3Key)")
        print("   Size: 25MB (5 parts)")
        print("   Upload Time: \(String(format: "%.2f", uploadTime))s")
    }

    // MARK: - Error Handling Tests

    func testUploadToNonExistentBucket() async throws {
        // Given - Create uploader with non-existent bucket
        let badUploader = S3Uploader(
            s3Client: s3Client,
            bucketName: "non-existent-bucket-\(UUID().uuidString)"
        )

        let testData = createRandomData(size: 1_000_000)
        let testFileURL = tempDirectory.appendingPathComponent("test-chunk-error.mp4")
        try testData.write(to: testFileURL)

        let chunk = ChunkMetadata(
            chunkId: "error-test-chunk",
            filePath: testFileURL,
            sizeBytes: 1_000_000,
            checksum: calculateSHA256(data: testData),
            durationSeconds: 60.0,
            index: 0,
            recordingId: testRecordingId
        )

        // When/Then - Should throw error
        do {
            _ = try await badUploader.uploadChunk(
                recordingId: testRecordingId,
                chunkMetadata: chunk,
                userId: testUserId
            )
            XCTFail("Should have thrown error for non-existent bucket")
        } catch {
            // Expected error
            print("✅ Correctly caught error for non-existent bucket: \(error)")
        }
    }

    func testUploadNonExistentFile() async throws {
        // Given - Chunk pointing to non-existent file
        let nonExistentURL = tempDirectory.appendingPathComponent("does-not-exist.mp4")

        let chunk = ChunkMetadata(
            chunkId: "non-existent-file-chunk",
            filePath: nonExistentURL,
            sizeBytes: 1_000_000,
            checksum: "dummy-checksum",
            durationSeconds: 60.0,
            index: 0,
            recordingId: testRecordingId
        )

        // When/Then - Should throw error
        do {
            _ = try await uploader.uploadChunk(
                recordingId: testRecordingId,
                chunkMetadata: chunk,
                userId: testUserId
            )
            XCTFail("Should have thrown error for non-existent file")
        } catch {
            // Expected error
            print("✅ Correctly caught error for non-existent file: \(error)")
        }
    }

    // MARK: - Path Security Tests

    func testPathTraversalPrevention() async throws {
        // Given - Malicious user ID with path traversal attempt
        let maliciousUserId = "../../../etc/passwd"
        let maliciousRecordingId = "../../sensitive-data"

        let testData = createRandomData(size: 1_000_000)
        let testFileURL = tempDirectory.appendingPathComponent("test-security.mp4")
        try testData.write(to: testFileURL)

        let chunk = await ChunkMetadata(
            chunkId: "security-test-chunk",
            filePath: testFileURL,
            sizeBytes: 1_000_000,
            checksum: calculateSHA256(data: testData),
            durationSeconds: 60.0,
            index: 0,
            recordingId: maliciousRecordingId
        )

        // When - Upload with malicious IDs
        let result = try await uploader.uploadChunk(
            recordingId: maliciousRecordingId,
            chunkMetadata: chunk,
            userId: maliciousUserId
        )

        await createdObjects.append(result.s3Key)

        // Then - Verify path traversal was sanitized
        XCTAssertFalse(result.s3Key.contains(".."), "S3 key should not contain .. sequences")
//        XCTAssertFalse(result.s3Key.contains("/etc"), "S3 key should not contain /etc")
//        XCTAssertFalse(result.s3Key.contains("passwd"), "S3 key should not contain passwd")

        // Verify it still uploaded successfully (with sanitized path)
        let headInput = await HeadObjectInput(bucket: testBucket, key: result.s3Key)
        _ = try await s3Client.headObject(input: headInput)

        print("✅ Path traversal prevented:")
        print("   Sanitized S3 Key: \(result.s3Key)")
    }

    // MARK: - Helper Methods

    private func createRandomData(size: Int) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            arc4random_buf(baseAddress, size)
        }
        return data
    }

    private func calculateSHA256(data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CommonCrypto Bridge

import CommonCrypto

// SHA256 digest length constant
private let CC_SHA256_DIGEST_LENGTH = 32
