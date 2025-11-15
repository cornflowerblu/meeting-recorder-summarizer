# Security Testing Guide: Token Swap Architecture

**Related Document**: [Security Analysis](./security-analysis-token-swap.md)  
**Version**: 1.0.0  
**Date**: 2025-11-15

## Quick Start

This guide provides practical test cases for validating the Firebase → AWS STS authentication security.

## Test Environment Setup

### Prerequisites

```bash
# Install testing dependencies
cd processing
pip install pytest boto3 moto freezegun

# Set test environment variables
export TEST_FIREBASE_PROJECT_ID="meeting-recorder-test"
export TEST_AWS_REGION="us-east-1"
export TEST_S3_BUCKET="meeting-recorder-test-bucket"
export TEST_DYNAMODB_TABLE="meetings-test"
```

### Test User Setup

Create two test Firebase users for isolation testing:

```bash
# User A credentials (stored securely, not in git)
export TEST_USER_A_UID="test_user_a_firebase_uid_123"
export TEST_USER_A_TOKEN="<firebase_id_token_for_user_a>"

# User B credentials
export TEST_USER_B_UID="test_user_b_firebase_uid_456"
export TEST_USER_B_TOKEN="<firebase_id_token_for_user_b>"
```

## Unit Tests (Lambda)

### Run All Auth Exchange Tests

```bash
cd processing/lambdas/auth_exchange
pytest test_handler.py -v --cov=handler --cov-report=html
```

### Critical Security Tests

**Test 1: Session Name Sanitization**
```python
def test_session_name_prevents_injection():
    """Verify malicious characters are sanitized."""
    malicious_names = [
        "<script>alert('xss')</script>",
        "../../admin/secrets",
        "${AWS::AccountId}",
        "user'; DROP TABLE users; --",
        "../../../etc/passwd"
    ]
    
    for malicious in malicious_names:
        event = {
            "body": json.dumps({
                "id_token": "valid_token_xxx",
                "session_name": malicious
            })
        }
        response = handler.lambda_handler(event, context)
        
        # Should succeed with sanitized name
        assert response["statusCode"] == 200
        
        # Verify dangerous characters removed
        call_args = mock_sts.assume_role_with_web_identity.call_args[1]
        session_name = call_args["RoleSessionName"]
        assert "<" not in session_name
        assert ">" not in session_name
        assert "/" not in session_name
        assert "'" not in session_name
```

**Test 2: Token Expiration Handling**
```python
def test_expired_firebase_token_rejected():
    """Verify expired tokens are rejected by STS."""
    expired_token = create_expired_jwt()
    
    event = {
        "body": json.dumps({
            "id_token": expired_token,
            "session_name": "user_123"
        })
    }
    
    response = handler.lambda_handler(event, context)
    
    assert response["statusCode"] == 401
    assert "expired" in json.loads(response["body"])["error"].lower()
```

**Test 3: No PII in Logs**
```python
def test_no_pii_logged(caplog):
    """Verify Firebase tokens and emails are not logged."""
    event = {
        "body": json.dumps({
            "id_token": "sensitive_firebase_token_abc123",
            "session_name": "user_uid_123",
            "email": "user@example.com"
        })
    }
    
    with caplog.at_level(logging.INFO):
        response = handler.lambda_handler(event, context)
    
    # Check no logs contain the token
    for record in caplog.records:
        assert "sensitive_firebase_token" not in record.message
        assert "user@example.com" not in record.message
    
    # User ID logging is OK (not PII)
    assert any("user_uid_123" in record.message for record in caplog.records)
```

## Integration Tests (AWS Resources)

### Test 1: S3 User Isolation

```python
import boto3
from botocore.exceptions import ClientError

def test_s3_cross_user_access_blocked():
    """Verify User A cannot access User B's S3 objects."""
    
    # Get credentials for both users
    user_a_creds = exchange_firebase_token(TEST_USER_A_TOKEN, TEST_USER_A_UID)
    user_b_creds = exchange_firebase_token(TEST_USER_B_TOKEN, TEST_USER_B_UID)
    
    # Create S3 clients with user credentials
    s3_a = boto3.client(
        's3',
        aws_access_key_id=user_a_creds['AccessKeyId'],
        aws_secret_access_key=user_a_creds['SecretAccessKey'],
        aws_session_token=user_a_creds['SessionToken']
    )
    
    s3_b = boto3.client(
        's3',
        aws_access_key_id=user_b_creds['AccessKeyId'],
        aws_secret_access_key=user_b_creds['SecretAccessKey'],
        aws_session_token=user_b_creds['SessionToken']
    )
    
    # User B uploads a file to their path
    test_key = f"users/{TEST_USER_B_UID}/test-isolation.txt"
    s3_b.put_object(
        Bucket=TEST_S3_BUCKET,
        Key=test_key,
        Body=b"User B's secret data"
    )
    
    # User A attempts to read User B's file
    with pytest.raises(ClientError) as exc:
        s3_a.get_object(Bucket=TEST_S3_BUCKET, Key=test_key)
    
    assert exc.value.response['Error']['Code'] == 'AccessDenied'
    
    # User A attempts to overwrite User B's file
    with pytest.raises(ClientError) as exc:
        s3_a.put_object(
            Bucket=TEST_S3_BUCKET,
            Key=test_key,
            Body=b"User A's malicious data"
        )
    
    assert exc.value.response['Error']['Code'] == 'AccessDenied'
    
    # User A attempts to delete User B's file
    with pytest.raises(ClientError) as exc:
        s3_a.delete_object(Bucket=TEST_S3_BUCKET, Key=test_key)
    
    assert exc.value.response['Error']['Code'] == 'AccessDenied'
    
    # Cleanup: User B can delete their own file
    s3_b.delete_object(Bucket=TEST_S3_BUCKET, Key=test_key)
```

### Test 2: S3 Path Traversal Prevention

```python
def test_s3_path_traversal_blocked():
    """Verify users cannot use path traversal to access other directories."""
    
    user_a_creds = exchange_firebase_token(TEST_USER_A_TOKEN, TEST_USER_A_UID)
    s3_a = boto3.client('s3', **user_a_creds)
    
    # Attempt various path traversal patterns
    attack_keys = [
        f"users/{TEST_USER_A_UID}/../{TEST_USER_B_UID}/secrets.txt",
        f"users/../admin/config.json",
        f"users/{TEST_USER_A_UID}/../../etc/passwd",
        "../../sensitive-data.txt"
    ]
    
    for attack_key in attack_keys:
        with pytest.raises(ClientError) as exc:
            s3_a.get_object(Bucket=TEST_S3_BUCKET, Key=attack_key)
        
        # IAM conditions should block at authorization level
        assert exc.value.response['Error']['Code'] == 'AccessDenied'
```

### Test 3: DynamoDB User Isolation

```python
def test_dynamodb_cross_user_query_blocked():
    """Verify User A cannot query User B's DynamoDB items."""
    
    user_a_creds = exchange_firebase_token(TEST_USER_A_TOKEN, TEST_USER_A_UID)
    user_b_creds = exchange_firebase_token(TEST_USER_B_TOKEN, TEST_USER_B_UID)
    
    ddb_a = boto3.client('dynamodb', **user_a_creds)
    ddb_b = boto3.client('dynamodb', **user_b_creds)
    
    # User B creates an item
    pk = f"{TEST_USER_B_UID}#recording_test_123"
    ddb_b.put_item(
        TableName=TEST_DYNAMODB_TABLE,
        Item={
            'PK': {'S': pk},
            'SK': {'S': 'METADATA'},
            'title': {'S': 'User B Secret Meeting'},
            'user_id': {'S': TEST_USER_B_UID}
        }
    )
    
    # User A attempts to read User B's item
    with pytest.raises(ClientError) as exc:
        ddb_a.get_item(
            TableName=TEST_DYNAMODB_TABLE,
            Key={
                'PK': {'S': pk},
                'SK': {'S': 'METADATA'}
            }
        )
    
    assert exc.value.response['Error']['Code'] == 'AccessDeniedException'
    
    # User A attempts to query with User B's partition key prefix
    with pytest.raises(ClientError) as exc:
        ddb_a.query(
            TableName=TEST_DYNAMODB_TABLE,
            KeyConditionExpression='PK = :pk',
            ExpressionAttributeValues={
                ':pk': {'S': pk}
            }
        )
    
    assert exc.value.response['Error']['Code'] == 'AccessDeniedException'
    
    # Cleanup
    ddb_b.delete_item(
        TableName=TEST_DYNAMODB_TABLE,
        Key={'PK': {'S': pk}, 'SK': {'S': 'METADATA'}}
    )
```

### Test 4: Credential Expiration

```python
from freezegun import freeze_time
from datetime import datetime, timedelta

def test_credential_expiration_enforced():
    """Verify credentials cannot be used after expiration."""
    
    # Get credentials
    user_a_creds = exchange_firebase_token(TEST_USER_A_TOKEN, TEST_USER_A_UID)
    expiration = datetime.fromisoformat(user_a_creds['Expiration'])
    
    s3 = boto3.client('s3', **user_a_creds)
    
    # Should work immediately
    s3.list_objects_v2(
        Bucket=TEST_S3_BUCKET,
        Prefix=f"users/{TEST_USER_A_UID}/"
    )
    
    # Fast-forward time to after expiration
    with freeze_time(expiration + timedelta(minutes=5)):
        with pytest.raises(ClientError) as exc:
            s3.list_objects_v2(
                Bucket=TEST_S3_BUCKET,
                Prefix=f"users/{TEST_USER_A_UID}/"
            )
        
        assert exc.value.response['Error']['Code'] == 'ExpiredToken'
```

## Penetration Testing Scenarios

### Manual Test 1: Token Replay Attack

```bash
#!/bin/bash
# Capture a valid Firebase ID token
FIREBASE_TOKEN="<captured_token>"

# Test immediate use (should succeed)
curl -X POST https://api.example.com/auth/exchange \
  -H "Content-Type: application/json" \
  -d "{\"id_token\": \"$FIREBASE_TOKEN\", \"session_name\": \"user_123\"}"

# Wait 1 hour for token expiration
sleep 3600

# Test expired token (should fail with 401)
curl -X POST https://api.example.com/auth/exchange \
  -H "Content-Type: application/json" \
  -d "{\"id_token\": \"$FIREBASE_TOKEN\", \"session_name\": \"user_123\"}"
# Expected: {"error": "Firebase ID token has expired"}
```

### Manual Test 2: Session Name Manipulation

```bash
# Test various injection attempts
TEST_CASES=(
  "<script>alert('xss')</script>"
  "../../admin"
  "\${AWS::AccountId}"
  "user'; DROP TABLE meetings; --"
  "../../../etc/passwd"
  "user\nmalicious\ncode"
)

for session_name in "${TEST_CASES[@]}"; do
  echo "Testing: $session_name"
  
  curl -X POST https://api.example.com/auth/exchange \
    -H "Content-Type: application/json" \
    -d "{
      \"id_token\": \"valid_firebase_token\",
      \"session_name\": \"$session_name\"
    }" | jq
  
  echo "---"
done
```

### Manual Test 3: Rate Limit Testing

```bash
#!/bin/bash
# Stress test auth_exchange endpoint

ENDPOINT="https://api.example.com/auth/exchange"
VALID_TOKEN="<test_firebase_token>"

# Send 1000 requests in rapid succession
for i in {1..1000}; do
  curl -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "{\"id_token\": \"$VALID_TOKEN\", \"session_name\": \"user_123\"}" \
    > /dev/null 2>&1 &
done

wait

# Expected: API Gateway throttles after limit
# Check CloudWatch metrics for 429 responses
```

## Security Audit Queries

### CloudTrail: Find Cross-User Access Attempts

```sql
-- Run in CloudWatch Logs Insights or Athena

-- Find all S3 access by a specific user
SELECT eventTime, eventName, requestParameters.bucketName, requestParameters.key, sourceIPAddress
FROM cloudtrail_logs
WHERE userIdentity.sessionContext.sessionIssuer.userName = 'meeting-recorder-dev-macos-app-role'
  AND userIdentity.principalId LIKE '%:firebase_uid_123'
  AND eventName IN ('GetObject', 'PutObject', 'DeleteObject')
ORDER BY eventTime DESC
LIMIT 100;

-- Find failed authorization attempts (potential attacks)
SELECT eventTime, eventName, errorCode, errorMessage, 
       userIdentity.principalId, requestParameters
FROM cloudtrail_logs
WHERE errorCode IN ('AccessDenied', 'AccessDeniedException')
  AND eventSource IN ('s3.amazonaws.com', 'dynamodb.amazonaws.com')
  AND userIdentity.sessionContext.sessionIssuer.userName = 'meeting-recorder-dev-macos-app-role'
ORDER BY eventTime DESC
LIMIT 50;

-- Find auth_exchange invocations with errors
SELECT eventTime, errorCode, errorMessage, sourceIPAddress, requestParameters.functionName
FROM cloudtrail_logs
WHERE eventName = 'Invoke'
  AND requestParameters.functionName = 'meeting-recorder-dev-auth-exchange'
  AND errorCode IS NOT NULL
ORDER BY eventTime DESC;
```

### CloudWatch Logs: Find Suspicious Patterns

```python
# Using boto3 CloudWatch Logs client

import boto3
from datetime import datetime, timedelta

logs = boto3.client('logs')

# Find auth_exchange errors in last 24 hours
response = logs.filter_log_events(
    logGroupName='/aws/lambda/meeting-recorder-dev-auth-exchange',
    startTime=int((datetime.now() - timedelta(days=1)).timestamp() * 1000),
    filterPattern='ERROR'
)

for event in response['events']:
    print(f"{event['timestamp']}: {event['message']}")
```

## Automated Security Testing

### CI/CD Pipeline Integration

```yaml
# .github/workflows/security-tests.yml
name: Security Tests

on:
  pull_request:
    paths:
      - 'processing/lambdas/auth_exchange/**'
      - 'infra/terraform/iam.tf'

jobs:
  security-unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.13'
      
      - name: Install dependencies
        run: |
          cd processing
          pip install -r lambdas/requirements.txt
          pip install pytest pytest-cov
      
      - name: Run security-critical tests
        run: |
          cd processing/lambdas/auth_exchange
          pytest test_handler.py::TestInputValidation -v
          pytest test_handler.py::TestSTSErrorScenarios -v
      
      - name: Check test coverage
        run: |
          cd processing/lambdas/auth_exchange
          pytest test_handler.py --cov=handler --cov-fail-under=80

  security-integration-tests:
    runs-on: ubuntu-latest
    needs: security-unit-tests
    # Only run on main branch (requires AWS credentials)
    if: github.ref == 'refs/heads/main'
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          role-to-assume: ${{ secrets.AWS_TEST_ROLE_ARN }}
          aws-region: us-east-1
      
      - name: Run S3 isolation tests
        run: |
          python tests/integration/test_s3_isolation.py
      
      - name: Run DynamoDB isolation tests
        run: |
          python tests/integration/test_dynamodb_isolation.py
```

## Test Results Documentation

After running tests, document results:

```markdown
## Test Run: 2025-11-15

**Environment**: Staging (meeting-recorder-staging)

### Unit Tests
- ✅ Session name sanitization: 15/15 passed
- ✅ Token validation: 10/10 passed
- ✅ STS error handling: 8/8 passed
- ✅ No PII in logs: 5/5 passed

### Integration Tests
- ✅ S3 cross-user access blocked: PASS
- ✅ S3 path traversal blocked: PASS
- ✅ DynamoDB cross-user query blocked: PASS
- ✅ Credential expiration enforced: PASS

### Penetration Tests
- ✅ Token replay attack: Blocked (401)
- ✅ Session name injection: Sanitized successfully
- ⚠️ Rate limit: NOT CONFIGURED (to be implemented)

**Overall Status**: PASS (1 warning)
**Recommendation**: Implement API Gateway rate limiting before production
```

## Continuous Monitoring

### CloudWatch Alarms

```terraform
# Add to infra/terraform/monitoring.tf

resource "aws_cloudwatch_metric_alarm" "auth_exchange_high_error_rate" {
  alarm_name          = "auth-exchange-high-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Alerts on high auth_exchange error rate"
  
  dimensions = {
    FunctionName = "meeting-recorder-dev-auth-exchange"
  }
}

resource "aws_cloudwatch_metric_alarm" "suspicious_access_denied" {
  alarm_name          = "suspicious-access-denied-attempts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "AccessDeniedErrors"
  namespace           = "MeetingRecorder/Security"
  period              = 300
  statistic           = "Sum"
  threshold           = 50
  alarm_description   = "Multiple access denied errors - possible attack"
}
```

---

**Next Steps:**
1. Run all unit tests: `pytest processing/lambdas/auth_exchange/test_handler.py -v`
2. Set up integration test environment with two test Firebase users
3. Execute S3 and DynamoDB isolation tests
4. Perform manual penetration testing scenarios
5. Review CloudTrail logs for anomalies
6. Implement missing security controls (rate limiting, alarms)

**Questions?** See [Security Analysis](./security-analysis-token-swap.md) for detailed context.
