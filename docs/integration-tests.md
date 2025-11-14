# Integration Tests

**Date**: 2025-11-14
**Status**: Implemented ✅
**Location**: `macos/Tests/MeetingRecorderIntegrationTests/`

---

## Overview

Integration tests verify actual AWS SDK behavior with real S3 services. Unlike unit tests that use mocks, these tests:

- ✅ Test real S3 multipart uploads
- ✅ Verify ETags, metadata, and object storage
- ✅ Catch AWS SDK integration bugs (like the `BufferedStream` issue)
- ✅ Validate path sanitization and security measures
- ✅ Confirm error handling with real AWS errors

---

## Test Coverage

### S3IntegrationTests

| Test                            | Description                                       | Size |
| ------------------------------- | ------------------------------------------------- | ---- |
| `testMultipartUploadWithRealS3` | Uploads 10MB file (2 parts), verifies metadata    | 10MB |
| `testSmallFileUpload`           | Uploads 1MB file (single part)                    | 1MB  |
| `testLargeMultipartUpload`      | Uploads 25MB file (5 parts), measures performance | 25MB |
| `testUploadToNonExistentBucket` | Verifies error handling for missing bucket        | -    |
| `testUploadNonExistentFile`     | Verifies error handling for missing file          | -    |
| `testPathTraversalPrevention`   | Validates path sanitization against malicious IDs | 1MB  |

**Total**: 6 integration tests

---

## Running Locally

### Prerequisites

1. **AWS Credentials**: Test-only IAM user with S3 access
2. **Test S3 Bucket**: Create a bucket for integration tests
3. **Environment Variables**: Configure credentials

### Setup

#### 1. Create Test S3 Bucket

```bash
# Using AWS CLI
aws s3api create-bucket \
  --bucket meeting-recorder-test-integration \
  --region us-east-1

# Add lifecycle policy to auto-delete test objects after 1 day
aws s3api put-bucket-lifecycle-configuration \
  --bucket meeting-recorder-test-integration \
  --lifecycle-configuration file://test-bucket-lifecycle.json
```

**test-bucket-lifecycle.json**:

```json
{
  "Rules": [
    {
      "ID": "DeleteTestObjectsAfter1Day",
      "Status": "Enabled",
      "Filter": {
        "Prefix": ""
      },
      "Expiration": {
        "Days": 1
      },
      "AbortIncompleteMultipartUpload": {
        "DaysAfterInitiation": 1
      }
    }
  ]
}
```

#### 2. Create Test IAM User

```bash
# Create IAM user for integration tests
aws iam create-user --user-name meeting-recorder-integration-tests

# Attach S3 access policy
aws iam put-user-policy \
  --user-name meeting-recorder-integration-tests \
  --policy-name S3IntegrationTestPolicy \
  --policy-document file://test-iam-policy.json

# Create access key
aws iam create-access-key --user-name meeting-recorder-integration-tests
```

**test-iam-policy.json**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:HeadObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::meeting-recorder-test-integration",
        "arn:aws:s3:::meeting-recorder-test-integration/*"
      ]
    }
  ]
}
```

#### 3. Set Environment Variables

```bash
# Add to ~/.zshrc or ~/.bashrc
export AWS_ACCESS_KEY_ID=AKIAXXXXXXXXXXXXXXXX
export AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export AWS_REGION=us-east-1
export TEST_S3_BUCKET=meeting-recorder-test-integration

# Reload shell
source ~/.zshrc
```

### Run Tests

```bash
cd macos

# Run all integration tests
swift test --filter IntegrationTests

# Run specific test
swift test --filter S3IntegrationTests.testMultipartUploadWithRealS3

# Run with verbose output
swift test --filter IntegrationTests --verbose
```

### Expected Output

```
✅ S3 Integration Tests configured:
   Bucket: meeting-recorder-test-integration
   Region: us-east-1
   Recording ID: test-rec-12345678-1234-1234-1234-123456789012

Test Suite 'S3IntegrationTests' started.
Test Case 'testMultipartUploadWithRealS3' started.
✅ Multipart upload succeeded:
   S3 Key: users/integration-test-user/raw-chunks/test-rec-.../part-0001-abcd1234.mp4
   ETag: "abc123..."
   Duration: 2.34s
🗑️  Cleaned up S3 object: users/integration-test-user/...
Test Case 'testMultipartUploadWithRealS3' passed (3.45 seconds).

Test Suite 'S3IntegrationTests' passed.
	 Executed 6 tests, with 0 failures in 15.23 seconds
```

---

## CI/CD Integration

### GitHub Actions

Integration tests run automatically on every pull request if AWS credentials are configured.

#### Setup Secrets

Go to: **Settings → Secrets and variables → Actions → New repository secret**

Add:

1. `AWS_TEST_ACCESS_KEY_ID` - Access key for test IAM user
2. `AWS_TEST_SECRET_ACCESS_KEY` - Secret key for test IAM user

#### Workflow Behavior

```yaml
# Runs only on PRs
if: github.event_name == 'pull_request'

# Skips gracefully if no credentials
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
  echo "⚠️  AWS credentials not configured, skipping"
  exit 0
fi

# Runs after unit tests pass
needs: test

# Fails PR if integration tests fail (but not if skipped)
```

### Viewing Results

1. **PR Checks**: Shows "Integration Tests" status
2. **Job Summary**: Displays test results in PR
3. **Artifacts**: Download `integration-test-results` for full output

---

## Troubleshooting

### Tests Skipped

**Error**: `AWS credentials not available. Set AWS_ACCESS_KEY_ID...`

**Solution**: Set environment variables (see Setup above)

### Permission Denied

**Error**: `Access Denied` or `403 Forbidden`

**Solution**: Verify IAM policy grants required S3 permissions

### Bucket Not Found

**Error**: `NoSuchBucket` or `404 Not Found`

**Solution**:

```bash
# Create the bucket
aws s3api create-bucket \
  --bucket meeting-recorder-test-integration \
  --region us-east-1
```

### Tests Fail with "Index out of range"

**Error**: `Fatal error: Index out of range`

**Solution**: This usually indicates an AWS SDK integration bug (like the `BufferedStream` issue). Check test output for specific error messages.

---

## Test Data Cleanup

### Automatic Cleanup

Tests clean up their own S3 objects in `tearDown()`:

```swift
for key in createdObjects {
    let deleteInput = DeleteObjectInput(bucket: testBucket, key: key)
    _ = try await s3Client.deleteObject(input: deleteInput)
}
```

### Manual Cleanup

If tests fail and leave objects:

```bash
# List test objects
aws s3 ls s3://meeting-recorder-test-integration/ --recursive | grep integration-test

# Delete all test objects
aws s3 rm s3://meeting-recorder-test-integration/ --recursive --exclude "*" --include "integration-test*"

# Delete all incomplete multipart uploads
aws s3api list-multipart-uploads \
  --bucket meeting-recorder-test-integration \
  --query 'Uploads[].{Key:Key,Id:UploadId}' \
  --output json | \
  jq -r '.[] | "aws s3api abort-multipart-upload --bucket meeting-recorder-test-integration --key \(.Key) --upload-id \(.Id)"' | \
  bash
```

### Lifecycle Policy

The bucket should have a lifecycle policy that auto-deletes objects after 1 day. Verify:

```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket meeting-recorder-test-integration
```

---

## Cost Considerations

**Typical Cost** (per PR):

- S3 storage: ~$0.001 (36MB stored for <1 hour)
- S3 requests: ~$0.0001 (15 PUT requests)
- Data transfer: $0 (same region)

**Monthly Cost** (20 PRs/month):

- ~$0.02/month

**S3 Free Tier** (first 12 months):

- 5 GB storage
- 20,000 GET requests
- 2,000 PUT requests

Integration tests should stay well within free tier limits.

---

## Performance Benchmarks

Typical run times on macOS 14 (M-series):

| Test       | Size | Parts | Time  |
| ---------- | ---- | ----- | ----- |
| Small file | 1MB  | 1     | ~1.5s |
| Multipart  | 10MB | 2     | ~2.5s |
| Large      | 25MB | 5     | ~5.0s |

**Total Suite**: ~15-20 seconds (including setup/teardown)

---

## Security Considerations

### IAM Permissions

- ✅ Test IAM user has **read/write access only to test bucket**
- ✅ No access to production buckets
- ✅ No destructive permissions (DeleteBucket, PutBucketPolicy)
- ✅ Keys rotated quarterly

### GitHub Secrets

- ✅ Secrets encrypted at rest
- ✅ Only accessible to Actions workflows
- ✅ Not visible in logs or PR comments
- ✅ Use test-only credentials (not production)

### Test Data

- ✅ No PII in test data
- ✅ Random data generated for uploads
- ✅ Auto-cleanup prevents data accumulation
- ✅ Lifecycle policy as safety net

---

## Future Enhancements

**Planned**:

- [ ] DynamoDB integration tests (catalog operations)
- [ ] STS integration tests (credential refresh)
- [ ] End-to-end flow tests (record → upload → catalog)
- [ ] Performance benchmarking (track upload speeds over time)
- [ ] Retry/resilience testing (network failures, throttling)

**Nice to Have**:

- [ ] LocalStack support (local S3 emulator for faster tests)
- [ ] Parallel test execution
- [ ] Test data generators (realistic video files)
- [ ] Chaos testing (random failures)

---

## References

- [AWS SDK for Swift Docs](https://docs.aws.amazon.com/sdk-for-swift/)
- [S3 Multipart Upload Guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)
- [XCTest Documentation](https://developer.apple.com/documentation/xctest)
- [GitHub Actions Docs](https://docs.github.com/en/actions)

---

**Last Updated**: 2025-11-14
**Maintainer**: Development Team
