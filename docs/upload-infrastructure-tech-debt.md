# Upload Infrastructure - Technical Debt

**Date**: 2025-11-14 (Updated)
**Phase**: Phase 3, PR Group 2
**Status**: High & Medium priority items completed ✅

---

## Overview

This document tracks technical debt and improvement opportunities identified during the Phase 3 code review for the upload infrastructure. All critical security issues have been addressed.

**Update**: High and medium priority items have been completed. Remaining items are performance optimizations and integration tests that can be tackled in future PRs.

---

## Completed Items ✅

### High Priority
1. ✅ **Add Jitter to Exponential Backoff** - Prevents thundering herd problem
2. ✅ **Improve Error Mapping** - Enhanced with additional S3-specific error patterns
3. ✅ **Add UploadQueue Processing Synchronization** - Prevents concurrent processQueue() calls
4. ✅ **Add Disk Space Checks** - Validates disk space before enqueueing chunks
5. ✅ **Add Consistent Error Logging** - All errors logged before re-throwing

### Medium Priority Completed
6. ✅ **Add disk space validation** in `enqueue()`
7. ✅ **Processing synchronization guard** with `isProcessing` flag

---

## Remaining High Priority 🔴

### 1. Switch to KMS Encryption for S3 Objects

**Current State**: Using AES256 (SSE-S3) encryption
**Issue**: No audit trail, cannot rotate keys, no key policies

**Recommendation**:
```swift
// In S3Uploader.swift, initiateMultipartUpload()
let input = CreateMultipartUploadInput(
    bucket: bucketName,
    contentType: "video/mp4",
    key: key,
    metadata: metadata,
    serverSideEncryption: .awsKms,  // Changed from .aes256
    ssekmsKeyId: AWSConfig.kmsKeyId  // Add this constant
)
```

**Benefits**:
- CloudTrail audit logs of encryption key usage
- Key rotation capabilities
- Fine-grained access control via key policies
- Compliance requirements (HIPAA, SOC 2)

**Prerequisites**:
1. Create KMS key in AWS
2. Add key ARN to AWSConfig.swift
3. Update IAM policies to grant kms:GenerateDataKey permission

**Estimated Effort**: 2-3 hours
**Priority**: High (needed for compliance)

---

### 2. Add S3 Integration Tests

**Current State**: Only unit tests with mocked S3Client

**Issue**: Real AWS SDK behavior isn't tested (ETags, multipart uploads, abort logic)

**Recommendation**:
Create integration test suite using LocalStack or MinIO:

```swift
// macos/Tests/MeetingRecorderIntegrationTests/S3IntegrationTests.swift
final class S3IntegrationTests: XCTestCase {
    var s3Client: S3Client!
    var uploader: S3Uploader!

    override func setUp() async throws {
        // Skip if AWS credentials not available
        guard ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] != nil else {
            throw XCTSkip("AWS credentials not available")
        }

        s3Client = S3Client(region: "us-east-1")
        uploader = S3Uploader(
            s3Client: s3Client,
            bucketName: "meeting-recorder-test-integration"
        )
    }

    func testMultipartUploadWithRealS3() async throws {
        let testData = Data(count: 10_000_000) // 10MB
        // Create test chunk and upload
        // Verify object exists with HeadObject
        // Cleanup
    }
}
```

**Prerequisites**:
1. Set up test S3 bucket with lifecycle policy (delete after 1 day)
2. Configure GitHub Actions secrets for AWS credentials
3. Add integration test job to CI workflow

**Estimated Effort**: 5-8 hours
**Priority**: Medium-High

---

## Medium Priority 🟡

### 4. Parallelize Multipart Upload Parts

**Current State**: Parts uploaded sequentially

**Issue**: For large files, sequential uploads underutilize bandwidth

**Performance Impact**:
- 50MB file: Sequential = ~10s, Concurrent (3 parts) = ~4s (2.5x faster)
- 500MB file: Sequential = ~100s, Concurrent = ~35s (3x faster)

**Recommendation**:
```swift
// In S3Uploader.swift, uploadParts()
private func uploadParts(...) async throws -> [S3ClientTypes.CompletedPart] {
    var completedParts: [S3ClientTypes.CompletedPart] = []

    await withThrowingTaskGroup(of: (Int, S3ClientTypes.CompletedPart).self) { group in
        for partNumber in 1...partCount {
            // Limit concurrent uploads
            while group.activeTaskCount >= maxConcurrentParts {
                let (_, part) = try await group.next()!
                completedParts.append(part)
            }

            group.addTask {
                let part = try await self.uploadSinglePart(
                    partNumber: partNumber,
                    key: key,
                    uploadId: uploadId,
                    fileURL: fileURL
                )
                return (partNumber, part)
            }
        }

        // Collect remaining
        while let (_, part) = try await group.next() {
            completedParts.append(part)
        }
    }

    // Sort by part number
    completedParts.sort { $0.partNumber! < $1.partNumber! }
    return completedParts
}
```

**Estimated Effort**: 3-4 hours
**Priority**: Medium (performance optimization)

---

### 5. Batch Manifest Saves to Reduce Disk I/O

**Current State**: Manifest saved after every operation (100+ saves for 100 chunks)

**Issue**: Excessive disk writes, SSD wear, potential corruption if interrupted

**Recommendation**:
```swift
// In UploadQueue.swift
private var manifestNeedsSave = false
private var lastManifestSave = Date()
private let manifestSaveInterval: TimeInterval = 5.0

private func scheduleManifestSave() {
    manifestNeedsSave = true
}

private func saveManifestIfNeeded() {
    guard manifestNeedsSave else { return }

    let timeSinceLastSave = Date().timeIntervalSince(lastManifestSave)
    guard timeSinceLastSave >= manifestSaveInterval else { return }

    try? manifest.save()
    manifestNeedsSave = false
    lastManifestSave = Date()
}
```

Call `scheduleManifestSave()` instead of `manifest.save()` throughout. Save immediately only on app termination or all chunks complete.

**Estimated Effort**: 2 hours
**Priority**: Medium

---

---

## Low Priority 🔵

### 9. Add Edge Case Tests

**Missing Test Coverage**:
- Empty file upload (0 bytes)
- File exactly 5MB (boundary case)
- File just under/over part size
- Non-existent file
- Corrupted MP4 file

**Recommendation**:
```swift
func testUploadEmptyFile() async throws {
    let chunk = createTestChunk(index: 0, size: 0)
    await uploadQueue.enqueue(chunk)
    await uploadQueue.start()
    // Should fail gracefully or skip
}

func testUploadExactlyPartSize() async throws {
    let chunk = createTestChunk(index: 0, size: 5_242_880) // Exactly 5MB
    // Should upload as single part
}
```

**Estimated Effort**: 2-3 hours
**Priority**: Low

---

### 10. Fix Backoff Timing Test to Be Less Brittle

**Current State**: Test asserts absolute timing (fails on slow CI)

**Recommendation**:
```swift
// Verify exponential relationship, not absolute timing
XCTAssertGreaterThan(delay2, delay1 * 1.5, "Second delay should be ~2x first")
XCTAssertLessThan(delay2, delay1 * 2.5, "Should not exceed 2.5x")
```

**Estimated Effort**: 30 minutes
**Priority**: Low

---

### 11. Remove Force Unwrap in Test Helper

**Current State**: Force unwrap in concurrent upload test

**Recommendation**:
```swift
// In UploadQueueTests.swift, testConcurrentUploadLimit()
while activeCount >= maxConcurrentUploads {
    guard let _ = await group.next() else {
        XCTFail("Unexpected end of task group")
        break
    }
    activeCount -= 1
}
```

**Estimated Effort**: 15 minutes
**Priority**: Low

---

### 12. Add Consistent Error Logging

**Current State**: Some errors logged, others not

**Recommendation**: Add logging at all error throw/catch sites:
```swift
} catch {
    Logger.upload.error(
        "Operation failed: \(error)",
        file: #file,
        function: #function,
        line: #line
    )
    throw mapS3Error(error)
}
```

**Estimated Effort**: 1-2 hours
**Priority**: Low

---

### 13. Update AVFoundationCaptureService Documentation

**Current State**: Warning says "will be completed in Phase 3, PR Group 2" but we're in that phase

**Recommendation**: Update to:
```swift
/// ⚠️ **WARNING: Partial Implementation**
/// Sample buffer processing is not yet implemented.
/// This will be completed in a future PR (Phase 3, PR Group 3).
```

**Estimated Effort**: 5 minutes
**Priority**: Low

---

## Documentation

### S3 Lifecycle Policy Recommendation

Add to infrastructure documentation or Terraform:

```hcl
# infra/terraform/s3.tf
resource "aws_s3_bucket_lifecycle_configuration" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "cleanup-test-data"
    status = "Enabled"

    filter {
      prefix = "integration-test-"
    }

    expiration {
      days = 1
    }
  }
}
```

This prevents orphaned multipart uploads from accumulating storage costs.

---

## Summary

**Completed** (Critical Issues):
- ✅ S3 key sanitization and anti-enumeration
- ✅ @unchecked Sendable documented as tech debt
- ✅ FileHandle resource leak fixed
- ✅ Abort multipart upload proper logging
- ✅ Metadata security concerns documented
- ✅ Magic numbers extracted to AWSConfig

**Completed**: ✅
- ✅ All critical security issues (5 items)
- ✅ High Priority: Jitter, error mapping, synchronization, disk checks, logging (5 items)
- ✅ Magic numbers extracted to config

**Remaining**:
- 🔴 High Priority: 2 items (KMS encryption, integration tests)
- 🟡 Medium Priority: 2 items (parallel uploads, batched saves)
- 🔵 Low Priority: 5 items (edge cases, test fixes, docs)

**Total Estimated Effort for Remaining**: 12-18 hours

---

**Recommendation**: Address high-priority items in next sprint. Medium and low priority can be tackled as time permits or when performance/maintainability becomes an issue.

---

*Created: 2025-11-14*
*Review Reference: Phase 3 Code Review - Upload Infrastructure*
