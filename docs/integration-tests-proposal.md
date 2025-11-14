# Integration Tests Proposal

**Status**: Proposed for PR Group 2.5 (after upload infrastructure)
**Date**: 2025-11-12

---

## Overview

Add integration tests that verify actual AWS service interactions, complementing existing unit tests with mocks.

## Current State

### ✅ Unit Tests (58 tests)
- **ScreenRecorderTests** (42) - Mocked AVFoundation
- **UploadQueueTests** (16) - Mocked S3Uploader
- Fast, isolated, deterministic
- Run on every PR (~2-3 minutes)

### ⏳ Integration Tests (0 tests)
- No tests hitting real AWS
- No end-to-end flow verification
- Missing: Real S3, DynamoDB, network testing

---

## Proposed Integration Tests

### 1. S3 Upload Integration Tests

**File**: `macos/Tests/MeetingRecorderIntegrationTests/S3IntegrationTests.swift`

**Tests**:
```swift
@MainActor
final class S3IntegrationTests: XCTestCase {
    var s3Client: S3Client!
    var uploader: S3Uploader!
    let testBucket = "meeting-recorder-test-integration"
    let testUserId = "integration-test-user"

    override func setUp() async throws {
        // Only run if AWS credentials available
        guard ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] != nil else {
            throw XCTSkip("AWS credentials not available")
        }

        s3Client = S3Client(region: "us-east-1")
        uploader = S3Uploader(s3Client: s3Client, bucketName: testBucket)
    }

    func testUploadRealChunkToS3() async throws {
        // Create test chunk
        let testData = Data(count: 1_000_000) // 1MB
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-chunk.mp4")
        try testData.write(to: tempURL)

        let chunk = ChunkMetadata(
            chunkId: "integration-test-chunk-0000",
            filePath: tempURL,
            sizeBytes: 1_000_000,
            checksum: "test-checksum",
            durationSeconds: 60.0,
            index: 0,
            recordingId: "integration-test-rec"
        )

        // Upload to S3
        let result = try await uploader.uploadChunk(
            recordingId: "integration-test-rec",
            chunkMetadata: chunk,
            userId: testUserId
        )

        // Verify upload succeeded
        XCTAssertFalse(result.s3Key.isEmpty)
        XCTAssertTrue(result.s3Key.contains("integration-test-rec"))

        // Verify object exists in S3
        let headInput = HeadObjectInput(
            bucket: testBucket,
            key: result.s3Key
        )
        let headOutput = try await s3Client.headObject(input: headInput)
        XCTAssertEqual(headOutput.contentLength, 1_000_000)

        // Cleanup
        try await deleteS3Object(key: result.s3Key)
        try FileManager.default.removeItem(at: tempURL)
    }

    func testMultipartUploadLargeFile() async throws {
        // Test with 100MB file (triggers multipart)
        let testData = Data(count: 100_000_000)
        // ... similar to above
    }

    func testUploadRetriesOnNetworkError() async throws {
        // Simulate network issues and verify retry logic
    }

    // Cleanup helper
    func deleteS3Object(key: String) async throws {
        let deleteInput = DeleteObjectInput(
            bucket: testBucket,
            key: key
        )
        _ = try await s3Client.deleteObject(input: deleteInput)
    }
}
```

### 2. DynamoDB Catalog Integration Tests

**File**: `macos/Tests/MeetingRecorderIntegrationTests/DynamoDBIntegrationTests.swift`

**Tests**:
```swift
func testCreateCatalogEntry() async throws {
    // Write real item to DynamoDB
    // Verify with query
    // Cleanup
}

func testQueryByUserId() async throws {
    // Create multiple items
    // Query by user ID
    // Verify results
    // Cleanup
}

func testGSIQueries() async throws {
    // Test date range queries (GSI-1)
    // Test participant search (GSI-2)
    // Test tag search (GSI-3)
}
```

### 3. End-to-End Flow Tests

**File**: `macos/Tests/MeetingRecorderIntegrationTests/EndToEndTests.swift`

**Tests**:
```swift
func testCompleteRecordingFlow() async throws {
    // 1. Create recording
    // 2. Generate 3 chunks
    // 3. Upload to S3
    // 4. Create catalog entry
    // 5. Verify all pieces
    // 6. Cleanup
}
```

---

## Test Infrastructure Requirements

### 1. AWS Test Resources

**Separate test environment:**
```
meeting-recorder-test-recordings (S3)
meeting-recorder-test-meetings (DynamoDB)
meeting-recorder-test-user (IAM role)
```

**Terraform** (add to `infra/terraform/`):
```hcl
# infra/terraform/test-resources.tf
resource "aws_s3_bucket" "integration_test" {
  bucket = "meeting-recorder-test-integration"

  lifecycle_rule {
    enabled = true
    expiration {
      days = 1  # Auto-cleanup after 1 day
    }
  }
}

resource "aws_dynamodb_table" "integration_test" {
  name = "meeting-recorder-test-meetings"
  # ... same schema as prod
}
```

### 2. CI/CD Integration

**Option A: Run on Every PR** (recommended for now)
```yaml
# .github/workflows/swift-tests.yml

jobs:
  unit-tests:
    # Current fast unit tests (2-3 min)

  integration-tests:
    name: Integration Tests
    runs-on: macos-14
    needs: unit-tests
    if: github.event_name == 'pull_request'

    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_TEST_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_TEST_SECRET_ACCESS_KEY }}
      AWS_REGION: us-east-1
      TEST_S3_BUCKET: meeting-recorder-test-integration
      TEST_DYNAMODB_TABLE: meeting-recorder-test-meetings

    steps:
      - uses: actions/checkout@v4
      - name: Setup Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '16.1'

      - name: Run integration tests
        working-directory: macos
        run: swift test --filter IntegrationTests

      - name: Cleanup test resources
        if: always()
        run: |
          # Delete all objects with prefix "integration-test"
          aws s3 rm s3://meeting-recorder-test-integration/ \
            --recursive --exclude "*" --include "integration-test*"
```

**Option B: Nightly Only** (for later, when tests are slower)
```yaml
# .github/workflows/integration-tests-nightly.yml
on:
  schedule:
    - cron: '0 2 * * *'  # 2 AM daily
  workflow_dispatch:  # Manual trigger
```

### 3. Local Development

**Run integration tests locally:**
```bash
cd macos

# Set up AWS credentials
export AWS_ACCESS_KEY_ID=your-test-key
export AWS_SECRET_ACCESS_KEY=your-test-secret
export AWS_REGION=us-east-1

# Run integration tests only
swift test --filter IntegrationTests

# Or run all tests
swift test
```

**Skip integration tests** (when no AWS creds):
```swift
override func setUp() async throws {
    guard ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] != nil else {
        throw XCTSkip("AWS credentials not available - skipping integration test")
    }
}
```

---

## Test Organization

### Directory Structure
```
macos/Tests/
├── MeetingRecorderTests/          # Unit tests (fast)
│   ├── Recording/
│   │   └── ScreenRecorderTests.swift
│   └── Upload/
│       └── UploadQueueTests.swift
│
└── MeetingRecorderIntegrationTests/  # Integration tests (slow)
    ├── S3IntegrationTests.swift
    ├── DynamoDBIntegrationTests.swift
    └── EndToEndTests.swift
```

### Package.swift
```swift
targets: [
    .testTarget(
        name: "MeetingRecorderTests",
        dependencies: ["MeetingRecorder"]
    ),
    .testTarget(
        name: "MeetingRecorderIntegrationTests",
        dependencies: ["MeetingRecorder"]
    )
]
```

---

## Cost Considerations

**AWS Test Resources:**
- S3: ~$0.01/month (minimal storage)
- DynamoDB: Free tier (25 GB, 200M requests)
- Data transfer: Negligible for tests

**GitHub Actions:**
- Integration tests: +3-5 minutes per PR
- ~150-200 min/month (still within free tier)

**Total**: Effectively $0 📊

---

## Implementation Plan

### Phase 1: S3 Integration Tests (2-3 hours)
1. Create test S3 bucket (Terraform)
2. Add S3IntegrationTests.swift
3. Write 3-5 basic upload tests
4. Update CI to run integration tests
5. Document how to run locally

### Phase 2: DynamoDB Integration Tests (1-2 hours)
1. Create test DynamoDB table (Terraform)
2. Add DynamoDBIntegrationTests.swift
3. Write catalog CRUD tests
4. Test GSI queries

### Phase 3: End-to-End Tests (2-3 hours)
1. Add EndToEndTests.swift
2. Test complete recording flow
3. Performance benchmarks
4. Cleanup verification

**Total Time**: 5-8 hours

---

## Benefits

### 1. **Catch Real-World Issues**
- Network timeouts
- AWS service errors
- Credential problems
- Rate limiting

### 2. **Verify AWS Integration**
- S3 multipart upload actually works
- DynamoDB queries return correct data
- IAM permissions are correct

### 3. **Confidence in Deployment**
- Know that production will work
- Catch breaking changes in AWS SDK
- Verify infrastructure changes

### 4. **Documentation**
- Integration tests serve as examples
- Show how to use services
- Prove the system works end-to-end

---

## Risks & Mitigations

### Risk 1: Slow Tests
- **Impact**: CI takes 5-10 min instead of 2-3 min
- **Mitigation**:
  - Run integration tests only on PR (not every commit)
  - Move to nightly builds later
  - Parallelize where possible

### Risk 2: Flaky Tests (Network Issues)
- **Impact**: Tests fail randomly
- **Mitigation**:
  - Retry logic (2-3 attempts)
  - Clear error messages
  - Mark as flaky in CI

### Risk 3: Test Data Pollution
- **Impact**: Failed tests leave garbage in AWS
- **Mitigation**:
  - Prefix all test data: `integration-test-*`
  - Auto-cleanup in CI (always run)
  - S3 lifecycle rule (expire after 1 day)

### Risk 4: AWS Credentials Leak
- **Impact**: Security breach
- **Mitigation**:
  - Use GitHub Secrets
  - Test-only IAM role (restricted permissions)
  - Rotate keys monthly
  - Monitor usage

---

## Recommendation

**Add integration tests NOW** (after PR #16 merges):

**Why now:**
- ✅ Upload infrastructure is complete
- ✅ Unit tests prove logic works
- ⚠️ Haven't verified AWS actually works
- ⚠️ Don't want to find issues in production

**Start small:**
1. Add 3-5 S3 integration tests
2. Run manually first (verify they work)
3. Add to CI pipeline
4. Expand coverage over time

**Timeline:**
- PR #16 merges (upload infrastructure)
- PR #17: Add S3 integration tests (2-3 hours)
- PR #18-20: Continue with UI (as planned)
- PR #21: Add DynamoDB integration tests

---

## Open Questions

1. **Should we run integration tests on every PR or nightly?**
   - Recommendation: Every PR for now (fast enough)

2. **Separate AWS account for testing?**
   - Recommendation: Same account, different resources (simpler)

3. **How to handle AWS credentials in CI?**
   - Recommendation: GitHub Secrets + test-only IAM role

4. **Should integration tests be optional?**
   - Recommendation: Required on PR, skippable locally (via env var)

---

## Next Steps

**If you want to add integration tests:**

1. ✅ Review this proposal
2. ⏳ Create test AWS resources (Terraform)
3. ⏳ Add S3IntegrationTests.swift
4. ⏳ Update CI workflow
5. ⏳ Document setup for team

**Or defer to later:**
- Continue with PR Groups 3 & 4 (UI, Catalog)
- Add integration tests after Phase 3 complete

---

*Proposal Date: 2025-11-12*
*Author: Claude Code*
