# Firebase Auth Exchange Lambda

Exchanges Firebase ID tokens for temporary AWS credentials using STS AssumeRoleWithWebIdentity.

## Purpose

Enables the macOS app to authenticate users via Firebase Google Sign-In and obtain temporary AWS credentials for accessing S3 and DynamoDB without embedding long-term credentials in the app.

## Flow

```
macOS App (Firebase Auth)
    ↓ (Firebase ID Token)
Auth Exchange Lambda
    ↓ (STS AssumeRoleWithWebIdentity)
AWS STS
    ↓ (Temporary Credentials)
macOS App (AWS SDK)
```

## Request Format

```http
POST /auth/exchange
Content-Type: application/json

{
  "id_token": "<firebase_id_token>",
  "session_name": "user@example.com"  // Optional
}
```

## Response Format

### Success (200)
```json
{
  "credentials": {
    "AccessKeyId": "ASIA...",
    "SecretAccessKey": "...",
    "SessionToken": "...",
    "Expiration": "2025-11-10T19:00:00Z"
  },
  "assumed_role_user": {
    "AssumedRoleId": "AROA...:session-name",
    "Arn": "arn:aws:sts::123456789012:assumed-role/..."
  }
}
```

### Error (4xx/5xx)
```json
{
  "error": "Invalid Firebase ID token"
}
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MACOS_APP_ROLE_ARN` | Yes | - | ARN of the IAM role to assume |
| `SESSION_DURATION` | No | 3600 | Session duration in seconds (max: 3600) |

## IAM Permissions Required

The Lambda execution role needs:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sts:AssumeRoleWithWebIdentity"
      ],
      "Resource": "arn:aws:iam::ACCOUNT_ID:role/meeting-recorder-dev-macos-app-role"
    }
  ]
}
```

## Error Codes

| Status | Error | Cause |
|--------|-------|-------|
| 400 | Missing required field: id_token | Request missing id_token |
| 401 | Invalid Firebase ID token | Token validation failed |
| 401 | Firebase ID token has expired | Token expired |
| 403 | Access denied: Unable to assume role | IAM permissions issue |
| 500 | Server misconfiguration | Missing env vars |
| 500 | Internal server error | Unexpected error |

## Deployment

```bash
# Package Lambda
cd processing/lambdas/auth_exchange
zip -r auth_exchange.zip handler.py

# Deploy with Terraform
cd ../../../infra/terraform
terraform apply
```

## Testing

### Unit Tests
```bash
cd processing
pytest tests/unit/test_auth_exchange.py -v
```

### Integration Test (requires AWS credentials)
```bash
# Set test Firebase token
export TEST_FIREBASE_TOKEN="<test_token>"

# Invoke Lambda
aws lambda invoke \
  --function-name meeting-recorder-dev-auth-exchange \
  --payload '{"body": "{\"id_token\": \"'$TEST_FIREBASE_TOKEN'\"}"}' \
  response.json

# View response
cat response.json | jq
```

## Security Considerations

- ✅ ID token validated by AWS STS (via Firebase OIDC provider)
- ✅ Credentials scoped to single user (via IAM conditions)
- ✅ Short session duration (1 hour max)
- ✅ No logging of tokens or credentials
- ✅ HTTPS-only (API Gateway)

## CloudWatch Logs

Logs include:
- Request IDs for tracing
- Error messages (no PII)
- STS API calls (CloudTrail)

## Monitoring

Recommended CloudWatch alarms:
- High error rate (> 5%)
- High invocation count (potential abuse)
- Long duration (> 500ms)

---

**Phase**: 2 (Foundational)
**Task**: MR-17 (T010)
**Dependencies**: MR-16 (IAM roles)
