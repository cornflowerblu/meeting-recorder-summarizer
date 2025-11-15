# Security Tests

Critical security tests that validate multi-tenant isolation through IAM policy enforcement.

## Overview

These tests verify that the Firebase UID-based multi-tenancy architecture properly isolates user data. **All tests MUST pass before production deployment.**

Reference: [Security Analysis PR #30](https://github.com/cornflowerblu/meeting-recorder-summarizer/pull/30)

## Tests Included

### 1. `test_s3_cross_user_access_blocked`
**Validates**: User A cannot read User B's S3 objects

**IAM Policy**:
```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject"],
  "Resource": "arn:aws:s3:::BUCKET/users/${aws:userid}/*"
}
```

**Expected**: `AccessDenied` when User A attempts to read/write User B's objects

---

### 2. `test_dynamodb_cross_user_query_blocked`
**Validates**: User A cannot query User B's DynamoDB partition (LeadingKeys enforcement)

**IAM Policy**:
```json
{
  "Effect": "Allow",
  "Action": ["dynamodb:GetItem", "dynamodb:Query"],
  "Resource": "arn:aws:dynamodb:*:*:table/TABLE_NAME",
  "Condition": {
    "ForAllValues:StringLike": {
      "dynamodb:LeadingKeys": ["${aws:userid}#*"]
    }
  }
}
```

**Expected**: `AccessDeniedException` when User A queries User B's partition key

---

### 3. `test_s3_path_traversal_blocked`
**Validates**: Path traversal attacks (`../../`) are prevented

**Attack Scenarios**:
- `users/user-a/../user-b/secret.txt`
- `users/user-a/../../other-user/data.mp4`

**Expected**: `AccessDenied` for all path traversal attempts

---

### 4. `test_s3_list_objects_scoped_to_user`
**Validates**: ListObjects only returns objects in user's own directory

**IAM Policy**:
```json
{
  "Effect": "Allow",
  "Action": "s3:ListBucket",
  "Resource": "arn:aws:s3:::BUCKET",
  "Condition": {
    "StringLike": {
      "s3:prefix": ["users/${aws:userid}/*"]
    }
  }
}
```

**Expected**: User A can only list objects under `users/user-a/`

---

## Prerequisites

### 1. IAM Policies Configured

Ensure the `macos_app` IAM role (used by `AssumeRoleWithWebIdentity`) has the following policies:

**S3 Policy**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UserScopedS3Access",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/users/${aws:userid}/*"
    },
    {
      "Sid": "UserScopedListBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["users/${aws:userid}/*"]
        }
      }
    }
  ]
}
```

**DynamoDB Policy**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UserScopedDynamoDBAccess",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/${TABLE_NAME}",
      "Condition": {
        "ForAllValues:StringLike": {
          "dynamodb:LeadingKeys": ["${aws:userid}#*"]
        }
      }
    }
  ]
}
```

**CRITICAL**: `${aws:userid}` is populated from the `RoleSessionName` parameter in `AssumeRoleWithWebIdentity`, which MUST be set to the Firebase UID.

---

### 2. Test User Setup

Create two test Firebase users:

```bash
# User A
firebase auth:create user-a@test.com --password TestPass123!

# User B
firebase auth:create user-b@test.com --password TestPass456!
```

---

### 3. Get Temporary Credentials

For each test user, get Firebase ID tokens and exchange for AWS credentials:

```bash
# Sign in User A
curl -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=FIREBASE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "user-a@test.com",
    "password": "TestPass123!",
    "returnSecureToken": true
  }'

# Extract idToken from response, then exchange:
curl -X POST "https://API_GATEWAY_URL/auth/exchange" \
  -H "Content-Type: application/json" \
  -d '{"idToken": "FIREBASE_ID_TOKEN"}'

# Response contains AWS credentials:
{
  "AccessKeyId": "ASIA...",
  "SecretAccessKey": "...",
  "SessionToken": "...",
  "Expiration": "2025-11-15T19:30:00Z"
}
```

Repeat for User B.

---

## Running the Tests

### Set Environment Variables

```bash
export USER_A_ACCESS_KEY="ASIA..."
export USER_A_SECRET_KEY="..."
export USER_A_SESSION_TOKEN="..."
export USER_A_UID="firebase-uid-user-a-123"

export USER_B_ACCESS_KEY="ASIA..."
export USER_B_SECRET_KEY="..."
export USER_B_SESSION_TOKEN="..."
export USER_B_UID="firebase-uid-user-b-456"

export TEST_S3_BUCKET="meeting-recorder-dev-recordings-abc123"
export TEST_DYNAMODB_TABLE="meeting-recorder-dev-meetings"
```

### Run Tests

```bash
cd processing

# Run all security tests
pytest tests/security/test_multi_tenant_isolation.py -v -m security

# Run specific test
pytest tests/security/test_multi_tenant_isolation.py::test_s3_cross_user_access_blocked -v

# Run with detailed output
pytest tests/security/ -v -s -m security
```

---

## Expected Results

### ✅ PASS (Correct Behavior)

All tests should **PASS**, with each test demonstrating that:
- User A **cannot** access User B's data
- Path traversal attacks are **blocked**
- IAM conditions properly **restrict** access

Example output:
```
tests/security/test_multi_tenant_isolation.py::test_s3_cross_user_access_blocked PASSED
  ✓ User B can read their own object
  ✓ User A correctly blocked from reading User B's object
  Error message: Access Denied
```

### ❌ FAIL (Security Issue)

If ANY test FAILS (i.e., access is NOT denied when it should be):

**THIS IS A CRITICAL SECURITY BUG**

Possible causes:
1. IAM policy missing `${aws:userid}` condition
2. `RoleSessionName` not set to Firebase UID in auth_exchange Lambda
3. S3 bucket policy allowing public access
4. DynamoDB LeadingKeys condition not enforced

**DO NOT DEPLOY TO PRODUCTION until all tests pass.**

---

## Troubleshooting

### Test Fails: "NoCredentials" or "InvalidAccessKeyId"

**Cause**: Environment variables not set or credentials expired (1-hour TTL)

**Fix**: Re-run credential exchange and update environment variables

---

### Test Fails: User A CAN access User B's data

**Cause**: IAM policy not enforcing `${aws:userid}` restriction

**Fix**:
1. Check `auth_exchange` Lambda sets `RoleSessionName` to Firebase UID
2. Verify IAM role policy includes `${aws:userid}` variable in Resource/Condition
3. Test with `aws sts get-caller-identity` to verify `UserId` contains Firebase UID

---

### Test Fails: "AccessDenied" on User's OWN data

**Cause**: IAM policy too restrictive or `${aws:userid}` not matching Firebase UID

**Fix**:
1. Verify `RoleSessionName` in `AssumeRoleWithWebIdentity` matches Firebase UID exactly
2. Check S3 key format: `users/{firebase-uid}/...` (must match policy)
3. Verify DynamoDB partition key format: `{firebase-uid}#recording-id`

---

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Security Tests

on:
  pull_request:
    paths:
      - 'infra/terraform/iam.tf'
      - 'processing/lambdas/auth_exchange/**'

jobs:
  security-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: pip install pytest boto3

      - name: Get test credentials
        id: get-creds
        run: |
          # Script to exchange Firebase tokens for AWS creds
          # Store in GitHub Secrets

      - name: Run security tests
        env:
          USER_A_ACCESS_KEY: ${{ secrets.TEST_USER_A_ACCESS_KEY }}
          USER_A_SECRET_KEY: ${{ secrets.TEST_USER_A_SECRET_KEY }}
          USER_A_SESSION_TOKEN: ${{ secrets.TEST_USER_A_SESSION_TOKEN }}
          USER_B_ACCESS_KEY: ${{ secrets.TEST_USER_B_ACCESS_KEY }}
          USER_B_SECRET_KEY: ${{ secrets.TEST_USER_B_SECRET_KEY }}
          USER_B_SESSION_TOKEN: ${{ secrets.TEST_USER_B_SESSION_TOKEN }}
        run: pytest tests/security/ -v -m security

      - name: Fail if tests don't pass
        if: failure()
        run: |
          echo "❌ SECURITY TESTS FAILED - DO NOT MERGE"
          exit 1
```

---

## References

- [Security Analysis (PR #30)](https://github.com/cornflowerblu/meeting-recorder-summarizer/pull/30)
- [AWS IAM Policy Variables](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html)
- [DynamoDB Fine-Grained Access Control](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/specifying-conditions.html)
- [S3 Condition Keys](https://docs.aws.amazon.com/AmazonS3/latest/userguide/amazon-s3-policy-keys.html)

---

## Pre-Production Checklist

Before deploying to production, verify:

- [ ] All 4 security tests pass
- [ ] IAM policies use `${aws:userid}` variable
- [ ] `auth_exchange` Lambda sets `RoleSessionName` to Firebase UID
- [ ] S3 key structure: `users/{firebase-uid}/...`
- [ ] DynamoDB partition key structure: `{firebase-uid}#recording-id`
- [ ] API Gateway rate limiting enabled (50 req/sec)
- [ ] CloudWatch alarms for access denials
- [ ] Security testing automated in CI/CD
