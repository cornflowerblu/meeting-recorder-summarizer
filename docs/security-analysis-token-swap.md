# Security Analysis: Firebase IDC Token Swap with AWS STS

**Version**: 1.0.0  
**Date**: 2025-11-15  
**Status**: Initial Security Assessment  
**Reviewers**: Security team review required before production deployment

## Executive Summary

This document provides a comprehensive security analysis of the Meeting Recorder's authentication architecture, which uses Firebase Auth (Google Identity as a Service) as an Identity Provider (IdP) with AWS Security Token Service (STS) to provide temporary, user-scoped credentials for multi-tenant data isolation.

**Key Findings:**
- ✅ **Strong multi-tenancy model**: User data isolation achieved via IAM policy conditions using session names
- ✅ **No long-term credentials**: Temporary STS credentials (1-hour lifetime) minimize exposure
- ✅ **Industry-standard OIDC flow**: Firebase OIDC provider validated by AWS STS
- ⚠️ **Privacy considerations**: LLM processing requires additional safeguards for sensitive content
- ⚠️ **Token refresh strategy**: Needs robust handling for long-running operations
- ⚠️ **Audit trail**: EventBridge events provide basic tracking but need enhancement

**Overall Risk Level**: **LOW-MEDIUM** (acceptable for MVP with recommended improvements)

## 1. Architecture Overview

### 1.1 Authentication Flow

```
┌─────────────────┐
│   macOS App     │
│  (Swift Client) │
└────────┬────────┘
         │ 1. User signs in with Google
         ▼
┌─────────────────┐
│ Firebase Auth   │
│  (Google IdP)   │
└────────┬────────┘
         │ 2. Returns Firebase ID Token (JWT)
         ▼
┌─────────────────┐
│   macOS App     │
└────────┬────────┘
         │ 3. POST /auth/exchange
         │    { "id_token": "...", "session_name": "firebase_uid_123" }
         ▼
┌─────────────────────────────────────────────────────────────┐
│ Lambda: auth_exchange                                        │
│ - Validates request                                          │
│ - Sanitizes session_name (Firebase UID)                     │
│ - Calls STS AssumeRoleWithWebIdentity                       │
│ - Emits user.signed_in event to EventBridge (async)         │
└────────┬────────────────────────────────────────────────────┘
         │ 4. STS validates token via OIDC
         ▼
┌─────────────────┐
│   AWS STS       │
│ ┌─────────────┐ │
│ │ OIDC Provider│ │
│ │ Firebase    │ │
│ └─────────────┘ │
└────────┬────────┘
         │ 5. Returns temporary credentials
         │    - AccessKeyId
         │    - SecretAccessKey
         │    - SessionToken (expires in 1 hour)
         ▼
┌─────────────────┐
│ Lambda Response │
└────────┬────────┘
         │ 6. Credentials returned to app
         ▼
┌─────────────────┐
│   macOS App     │
│ Stores in       │
│ macOS Keychain  │
└────────┬────────┘
         │ 7. Uses credentials for AWS SDK calls
         │
         ├──────────────────┬─────────────────────────┐
         ▼                  ▼                         ▼
    ┌────────┐        ┌──────────┐           ┌──────────────┐
    │   S3   │        │ DynamoDB │           │ SSM Params   │
    └────────┘        └──────────┘           └──────────────┘
```

### 1.2 Key Components

| Component | Purpose | Security Role |
|-----------|---------|---------------|
| **Firebase Auth** | Identity provider (Google Sign-In) | Issues JWT ID tokens with verified user identity |
| **OIDC Provider** | AWS IAM trust relationship | Enables AWS to validate Firebase tokens |
| **auth_exchange Lambda** | Token exchange service | Broker between Firebase and AWS STS |
| **AWS STS** | Temporary credential service | Issues short-lived AWS credentials |
| **IAM Role (macos_app)** | Assumed by users | Defines permissions with user-scoped conditions |
| **macOS Keychain** | Secure credential storage | Protects credentials at rest on device |
| **EventBridge** | Event bus | Tracks authentication events (optional) |

## 2. Multi-Tenancy Security Model

### 2.1 User Isolation Strategy

The architecture achieves multi-tenancy **without a traditional multi-tenant database** through IAM policy conditions that scope access to user-specific data paths.

#### S3 Isolation

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::meeting-recordings/users/${aws:username}/*",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["users/${aws:username}/*"]
        }
      }
    }
  ]
}
```

**Key Security Properties:**
- `${aws:username}` resolves to the `RoleSessionName` passed during `AssumeRoleWithWebIdentity`
- The Lambda **MUST** set `RoleSessionName` to the Firebase user ID (not email)
- Users can **ONLY** access objects under `users/{their_firebase_uid}/`
- S3 bucket policies enforce this at the AWS infrastructure level

**Critical Security Requirement:**
```python
# In auth_exchange Lambda handler.py line 97-98
sanitized_session_name = re.sub(r'[^a-zA-Z0-9=,.@_-]', '_', session_name[:64])
```
This sanitization prevents injection attacks where a malicious user could manipulate the session name to access other users' data.

#### DynamoDB Isolation

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"],
      "Resource": "arn:aws:dynamodb:*:*:table/meetings",
      "Condition": {
        "ForAllValues:StringLike": {
          "dynamodb:LeadingKeys": ["${aws:username}"]
        }
      }
    }
  ]
}
```

**Data Model:**
- Primary Key: `user_id#recording_id` (composite)
- Sort Key: `METADATA`
- The partition key **MUST** start with the Firebase UID to match `${aws:username}`

**Security Notes:**
- DynamoDB `LeadingKeys` condition validates partition key prefix
- Application code MUST construct keys as `{firebase_uid}#recording_{id}`
- GSI queries are scoped by including user ID in query predicates (application-enforced)

### 2.2 Cross-User Attack Vectors

| Attack Vector | Mitigation | Residual Risk |
|---------------|------------|---------------|
| **Path Traversal** | S3 prefix condition prevents `../` attacks | LOW - AWS validates conditions |
| **Session Name Injection** | Regex sanitization in Lambda removes dangerous chars | LOW - Tested in unit tests |
| **Credential Theft** | 1-hour expiration, stored in macOS Keychain | LOW - Short-lived credentials |
| **Token Replay** | Firebase tokens validated by AWS STS | LOW - STS validates exp claim |
| **GSI Query Manipulation** | Application must include user_id in queries | MEDIUM - App-level enforcement |

## 3. Token Security Analysis

### 3.1 Firebase ID Token (JWT)

**Structure:**
```json
{
  "iss": "https://securetoken.google.com/{project_id}",
  "aud": "{project_id}",
  "sub": "{firebase_uid}",
  "email": "user@example.com",
  "exp": 1700000000,
  "iat": 1699996400
}
```

**Security Properties:**
- ✅ Signed by Google's private keys (RS256)
- ✅ Short-lived (default 1 hour expiration)
- ✅ Audience (`aud`) validated by AWS STS against Firebase project ID
- ✅ Issuer (`iss`) validated against OIDC provider URL
- ❌ **Not encrypted** - Contains email in plaintext (transmitted over TLS)

**Threats:**
1. **Man-in-the-Middle (MiTM)**: Mitigated by TLS 1.2+ for all HTTP communications
2. **Token Leakage**: Mitigated by:
   - No logging of tokens (Lambda explicitly avoids logging `id_token`)
   - macOS Keychain storage (encrypted at OS level)
   - Short expiration (1 hour)
3. **Token Substitution**: Mitigated by `sub` claim validation in STS

### 3.2 AWS STS Temporary Credentials

**Credential Components:**
- `AccessKeyId`: Public identifier (starts with `ASIA`)
- `SecretAccessKey`: Secret key material
- `SessionToken`: Session-specific token
- `Expiration`: Timestamp (default 1 hour from issuance)

**Security Properties:**
- ✅ Short-lived (1 hour max, configurable via `SESSION_DURATION`)
- ✅ Cannot be extended without re-authentication
- ✅ Scoped to specific IAM role with minimal permissions
- ✅ Session name embedded in CloudTrail logs for audit
- ⚠️ **Cannot be revoked early** - Must wait for expiration

**Credential Lifecycle:**

```
0. User signs in with Google
   ↓
1. Firebase issues ID token (expires in 1h)
   ↓
2. Lambda calls STS (within 1h window)
   ↓
3. STS issues credentials (expires in 1h)
   ↓
4. App uses credentials (up to 1h)
   ↓
5. Credentials expire
   ↓
6. App must refresh (gets new Firebase token, calls Lambda again)
```

**Credential Refresh Strategy (from AuthSession.swift):**
```swift
// Line 121-124: Credentials marked expired 10 minutes before actual expiration
func isExpired(bufferMinutes: Int = 10) -> Bool {
    let bufferDate = Date().addingTimeInterval(TimeInterval(bufferMinutes * 60))
    return expiration <= bufferDate
}
```

This 10-minute buffer ensures:
- App refreshes credentials before they expire
- No failed API calls due to race conditions
- Seamless user experience during long operations

### 3.3 Token Storage Security

**macOS Keychain (AuthSession.swift):**
```swift
// Line 242: Accessibility level
kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
```

**Security Analysis:**
- ✅ Credentials encrypted by macOS using device-specific keys
- ✅ Requires device unlock (first unlock after boot)
- ✅ Protected against process-level tampering
- ⚠️ Accessible to any process by the same user (macOS sandbox limitation)
- ❌ Not protected if device is jailbroken (out of scope)

**Recommendation:**
For production, consider upgrading to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
```swift
kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
```
This prevents keychain items from being backed up to iCloud.

## 4. Privacy and PII Considerations

### 4.1 Sensitive Data Flows

Given the use case (meeting recordings with transcripts uploaded to LLMs for summarization), the following data requires protection:

| Data Type | Location | Sensitivity | Protection |
|-----------|----------|-------------|------------|
| **Video Recordings** | S3 (`users/{uid}/chunks/`, `users/{uid}/videos/`) | HIGH | SSE-S3, user-scoped paths |
| **Audio Extracted** | S3 (`users/{uid}/audio/`) | HIGH | SSE-S3, user-scoped paths |
| **Transcripts** | S3 (`users/{uid}/transcripts/`), DynamoDB | HIGH | SSE-S3, DynamoDB encryption at rest |
| **Summaries (LLM output)** | S3 (`users/{uid}/summaries/`), DynamoDB | MEDIUM | SSE-S3, may contain PII inference |
| **User Email** | DynamoDB, EventBridge events | MEDIUM | No logging (Constitution), structured metadata only |
| **Meeting Participants** | DynamoDB metadata | MEDIUM | User-provided, not logged in plaintext |
| **Firebase Tokens** | In-transit only (Lambda) | HIGH | TLS, never logged |
| **AWS Credentials** | macOS Keychain | HIGH | OS-level encryption, 1-hour lifetime |

### 4.2 PII Handling Analysis

**Current Controls (from Constitution v1.1.0 and Lambda code):**

1. **No PII in Logs** (✅ Enforced):
   ```python
   # Lambda handler.py line 149: EventBridge emission logged with user ID only
   print(f"Emitted user.signed_in event for user: {user_id}")
   # Email, display_name, photo_url NOT logged
   ```

2. **Structured Logging** (✅ Implemented):
   - Swift Logger.swift uses structured metadata
   - Python Lambdas use structured print statements
   - X-Ray tracing enabled for distributed tracing (no PII in trace data)

3. **Transcript/Summary Privacy** (⚠️ Partial):
   - Transcripts stored in user-scoped S3 paths (isolated)
   - Summaries sent to Bedrock (Claude) - **data leaves AWS account temporarily**
   - No client-side encryption for meeting content (SSE-S3 only)

**Privacy Risks for LLM Processing:**

| Risk | Description | Mitigation Status |
|------|-------------|-------------------|
| **PII Leakage to Bedrock** | Transcripts with names, emails sent to Claude | ⚠️ NOT MITIGATED - Inherent to feature |
| **Resume Data Exposure** | Job interviews may include resume details | ⚠️ NOT MITIGATED - User awareness required |
| **Sensitive Topics** | Medical, financial, legal discussions | ⚠️ User control: Pause recording or redact |
| **Participant Consent** | Other people on calls being recorded | ⚠️ User responsibility (Constitution Principle I) |

**Recommended Privacy Controls:**

1. **User Consent Flow** (Constitution requirement):
   - ✅ Explicit per-session consent (spec.md line 151, FR-001)
   - ✅ Persistent visible indicator (spec.md line 151)
   - ✅ First-run responsibility acknowledgment
   - ⚠️ **Need**: Participant notification mechanism (future enhancement)

2. **Redaction Capability**:
   - ✅ Planned in spec (spec.md line 133-134, data-model.md line 194-203)
   - ❌ Not yet implemented
   - **Recommendation**: Prioritize for resume/sensitive data use cases

3. **Data Residency**:
   - ✅ All data in user's AWS account (us-east-1 default)
   - ⚠️ Bedrock processes data in AWS region but doesn't retain it (per AWS terms)
   - **Recommendation**: Document Bedrock data processing terms for users

4. **Client-Side Encryption** (Optional Enhancement):
   - Currently using SSE-S3 (AWS-managed keys)
   - Consider SSE-KMS for user-controlled keys
   - Or implement client-side encryption before upload

### 4.3 GDPR and Compliance Considerations

**Right to Deletion** (✅ Planned):
- FR-011 (spec.md line 175-180): User can delete individual sessions
- FR-012 (spec.md line 181-186): Bulk retention management
- **Gap**: Need confirmation deletion propagates to:
  - ✅ S3 (direct delete)
  - ✅ DynamoDB (direct delete)
  - ⚠️ Bedrock logs? (Check AWS retention policies)
  - ⚠️ CloudWatch logs? (Set retention period)

**Data Portability** (⚠️ Partially Addressed):
- Users own their AWS account → Full data access
- JSON schemas defined (data-model.md) → Exportable format
- **Gap**: No export UI (acceptable for MVP)

**Purpose Limitation**:
- ✅ Data used only for transcription/summarization
- ✅ No analytics or tracking beyond user.signed_in events
- ✅ EventBridge events minimal (userId, timestamp, email optional)

**International Data Transfers**:
- ⚠️ If user in EU, data may leave EU (us-east-1 default)
- **Recommendation**: Support AWS region selection in config

## 5. Threat Model and Attack Scenarios

### 5.1 STRIDE Analysis

#### Spoofing Identity
| Threat | Attack Vector | Likelihood | Impact | Mitigation |
|--------|---------------|------------|--------|------------|
| Fake Firebase token | Attacker generates JWT with forged signature | LOW | HIGH | AWS STS validates signature against Google public keys |
| Impersonate another user | Attacker obtains legitimate user's Firebase token | LOW | HIGH | TLS, short expiration, no token sharing mechanism |
| Session hijacking | Steal AWS credentials from keychain | MEDIUM | HIGH | OS-level keychain encryption, 1-hour expiration |

#### Tampering
| Threat | Attack Vector | Likelihood | Impact | Mitigation |
|--------|---------------|------------|--------|------------|
| Modify S3 objects | Attacker changes another user's recordings | LOW | HIGH | IAM conditions prevent cross-user access |
| DynamoDB item tampering | Attacker modifies meeting metadata | LOW | MEDIUM | IAM LeadingKeys condition enforces isolation |
| Lambda code injection | Malicious session_name parameter | LOW | HIGH | Regex sanitization, input validation |

#### Repudiation
| Threat | Attack Vector | Likelihood | Impact | Mitigation |
|--------|---------------|------------|--------|------------|
| User denies action | Claims didn't upload/delete file | LOW | LOW | CloudTrail logs all API calls with session name |
| Auth event repudiation | Disputes sign-in event | LOW | LOW | EventBridge events, CloudTrail Lambda invocations |

#### Information Disclosure
| Threat | Attack Vector | Likelihood | Impact | Mitigation |
|--------|---------------|------------|--------|------------|
| Cross-user data access | Path traversal in S3 key | LOW | CRITICAL | IAM prefix conditions, key validation |
| Token leakage in logs | Firebase/AWS tokens in CloudWatch | LOW | HIGH | Explicit no-logging of tokens in code |
| Bedrock data retention | Transcripts stored by LLM provider | MEDIUM | HIGH | AWS Bedrock terms (90-day retention, no training) |
| Resume PII exposure | Sensitive resume data in transcripts | HIGH | MEDIUM | User education, redaction capability |

#### Denial of Service
| Threat | Attack Vector | Likelihood | Impact | Mitigation |
|--------|---------------|------------|--------|------------|
| Lambda abuse | Flood auth_exchange with requests | MEDIUM | MEDIUM | API Gateway rate limiting (not yet configured) |
| S3 cost attack | Attacker uploads massive files | LOW | MEDIUM | IAM policies enforce user-scoped paths only |
| DynamoDB throttling | Excessive query operations | LOW | LOW | Provisioned capacity, auto-scaling |

#### Elevation of Privilege
| Threat | Attack Vector | Likelihood | Impact | Mitigation |
|--------|---------------|------------|--------|------------|
| Assume other user's role | Manipulate AssumeRole call | LOW | CRITICAL | AWS STS validates token, session name immutable after issue |
| Escalate IAM permissions | Modify IAM policies via credentials | LOW | CRITICAL | STS credentials scoped to macos_app role (no IAM write) |
| Lambda privilege escalation | Exploit Lambda execution role | LOW | HIGH | Lambda role has minimal permissions, separate from user role |

### 5.2 Critical Security Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│ BOUNDARY 1: Firebase → AWS STS (OIDC Trust)                 │
│ Control: AWS validates JWT signature against Google keys    │
│ Attack: Forge JWT or compromise Firebase project            │
│ Defense: Google-managed signing keys, audience validation   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ BOUNDARY 2: Lambda → IAM Conditions (User Isolation)        │
│ Control: RoleSessionName MUST be Firebase UID               │
│ Attack: Inject malicious characters in session_name         │
│ Defense: Regex sanitization, AWS validates conditions       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ BOUNDARY 3: macOS App → AWS Services (Temporary Creds)      │
│ Control: IAM policies with ${aws:username} conditions       │
│ Attack: Access other users' S3 paths or DynamoDB items      │
│ Defense: AWS enforces IAM conditions at infrastructure level│
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ BOUNDARY 4: User Data → Bedrock (LLM Processing)            │
│ Control: AWS Bedrock data handling agreement                │
│ Attack: Bedrock retains sensitive transcript data           │
│ Defense: AWS contractual terms (no training, 90-day limit)  │
└─────────────────────────────────────────────────────────────┘
```

## 6. Security Recommendations

### 6.1 Critical (Must Implement Before Production)

1. **API Gateway Rate Limiting** (HIGH PRIORITY)
   ```terraform
   # Add to infra/terraform/api_gateway.tf
   resource "aws_api_gateway_usage_plan" "auth_exchange_limit" {
     name = "auth-exchange-rate-limit"
     
     throttle_settings {
       burst_limit = 100
       rate_limit  = 50  # 50 requests per second
     }
     
     quota_settings {
       limit  = 10000  # 10k requests per day per user
       period = "DAY"
     }
   }
   ```

2. **IAM Condition Audit** (HIGH PRIORITY)
   - [ ] Verify all S3 policies include `${aws:username}` conditions
   - [ ] Test DynamoDB `LeadingKeys` condition enforcement
   - [ ] Validate SSM Parameter Store access is read-only
   - [ ] Review Lambda execution role has no escalation paths

3. **CloudWatch Alarms** (MEDIUM PRIORITY)
   ```terraform
   # Add monitoring for suspicious activity
   resource "aws_cloudwatch_metric_alarm" "auth_exchange_high_error_rate" {
     alarm_name          = "auth-exchange-high-error-rate"
     comparison_operator = "GreaterThanThreshold"
     evaluation_periods  = 2
     metric_name         = "Errors"
     namespace           = "AWS/Lambda"
     period              = 60
     statistic           = "Sum"
     threshold           = 10  # 10 errors in 2 minutes
     alarm_description   = "Alerts on high auth_exchange error rate"
   }
   ```

4. **Security Headers** (MEDIUM PRIORITY)
   - Add to API Gateway responses:
     - `Strict-Transport-Security: max-age=31536000; includeSubDomains`
     - `X-Content-Type-Options: nosniff`
     - `X-Frame-Options: DENY`
     - `X-XSS-Protection: 1; mode=block`

### 6.2 Important (Should Implement Soon)

5. **Enhanced Token Validation** (MEDIUM PRIORITY)
   ```python
   # Add to auth_exchange/handler.py
   def _validate_firebase_token_claims(decoded_token: dict) -> bool:
       """Validate Firebase token claims beyond signature."""
       required_claims = ['sub', 'aud', 'exp', 'iat', 'iss']
       if not all(claim in decoded_token for claim in required_claims):
           return False
       
       # Validate issuer
       expected_issuer = f"https://securetoken.google.com/{FIREBASE_PROJECT_ID}"
       if decoded_token['iss'] != expected_issuer:
           return False
       
       # Validate audience
       if decoded_token['aud'] != FIREBASE_PROJECT_ID:
           return False
       
       return True
   ```

6. **Session Name Validation Hardening** (MEDIUM PRIORITY)
   ```python
   # Current: line 97 in handler.py
   sanitized_session_name = re.sub(r'[^a-zA-Z0-9=,.@_-]', '_', session_name[:64])
   
   # Enhanced version:
   def _validate_and_sanitize_session_name(session_name: str) -> str:
       """Validate session name is a valid Firebase UID format."""
       # Firebase UIDs are 28 alphanumeric characters
       if not re.match(r'^[a-zA-Z0-9]{20,28}$', session_name):
           raise ValueError("Invalid Firebase UID format")
       return session_name[:64]
   ```

7. **Credential Rotation Monitoring** (LOW PRIORITY)
   - Track credential refresh failures in CloudWatch
   - Alert if user's credentials expire without refresh (stuck session)

8. **DynamoDB Backup Strategy** (MEDIUM PRIORITY)
   ```terraform
   # Add to dynamodb.tf
   resource "aws_dynamodb_table" "meetings" {
     # ... existing config ...
     
     point_in_time_recovery {
       enabled = true  # Enable PITR for disaster recovery
     }
   }
   ```

### 6.3 Nice to Have (Future Enhancements)

9. **Client-Side Encryption**
   - Use AWS Encryption SDK to encrypt recordings before S3 upload
   - User controls encryption keys via KMS
   - Zero-knowledge architecture (AWS cannot decrypt)

10. **Multi-Region Support**
    - Allow users to select AWS region for data residency
    - Update IAM policies to be region-agnostic

11. **Advanced Audit Trail**
    - Store EventBridge events in S3 for long-term retention
    - Provide user-facing audit log UI

12. **Participant Notification**
    - Optional feature to email meeting participants
    - Include recording disclosure and access info

## 7. Security Testing Recommendations

### 7.1 Unit Test Coverage (Already Implemented ✅)

Existing tests in `processing/lambdas/auth_exchange/test_handler.py`:
- ✅ Session name sanitization (line 233-266)
- ✅ Token validation (line 127-196)
- ✅ STS error handling (line 340-435)
- ✅ Input validation (line 124-338)
- ✅ EventBridge emission (line 511-681)

**Additional Tests Needed:**
```python
# Add to test_handler.py

def test_cross_user_session_name_attack():
    """Test that user cannot assume another user's session name."""
    event = {
        "body": json.dumps({
            "id_token": "valid_token_for_user_A",
            "session_name": "user_B_firebase_uid"  # Attempt to impersonate
        })
    }
    # Should fail: AWS STS validates token 'sub' matches session name
    # Or: Lambda should enforce this validation

def test_path_traversal_in_session_name():
    """Test that path traversal characters are sanitized."""
    event = {
        "body": json.dumps({
            "id_token": "valid_token",
            "session_name": "../../admin"
        })
    }
    response = handler.lambda_handler(event, context)
    # Verify sanitized to "__/__admin"
```

### 7.2 Integration Tests

**S3 User Isolation Test:**
```python
import boto3

def test_s3_cross_user_access_blocked(user_a_credentials, user_b_credentials):
    """Verify User A cannot access User B's S3 objects."""
    s3_a = boto3.client('s3', **user_a_credentials)
    s3_b = boto3.client('s3', **user_b_credentials)
    
    # User B uploads a file
    s3_b.put_object(
        Bucket='meeting-recordings',
        Key='users/user_b_firebase_uid/test.txt',
        Body=b'secret data'
    )
    
    # User A attempts to read User B's file
    with pytest.raises(ClientError) as exc:
        s3_a.get_object(
            Bucket='meeting-recordings',
            Key='users/user_b_firebase_uid/test.txt'
        )
    
    assert exc.value.response['Error']['Code'] == 'AccessDenied'
```

**DynamoDB User Isolation Test:**
```python
def test_dynamodb_cross_user_query_blocked(user_a_credentials, user_b_credentials):
    """Verify User A cannot query User B's DynamoDB items."""
    ddb_a = boto3.client('dynamodb', **user_a_credentials)
    
    # User A attempts to query with User B's partition key
    with pytest.raises(ClientError) as exc:
        ddb_a.query(
            TableName='meetings',
            KeyConditionExpression='PK = :pk',
            ExpressionAttributeValues={
                ':pk': {'S': 'user_b_firebase_uid#recording_123'}
            }
        )
    
    assert exc.value.response['Error']['Code'] == 'AccessDeniedException'
```

### 7.3 Penetration Testing Scenarios

Before production launch, conduct manual penetration testing:

1. **Token Replay Attack**:
   - Capture a valid Firebase ID token
   - Wait until it expires
   - Attempt to exchange it for AWS credentials
   - Expected: STS rejects with `ExpiredTokenException`

2. **Credential Theft Simulation**:
   - Extract AWS credentials from macOS Keychain
   - Attempt to use from different device/IP
   - Expected: Works (by design), but expires in 1 hour
   - Validate CloudTrail logs show different source IP

3. **Session Name Injection**:
   - Send malicious characters in `session_name`: `<script>`, `../../`, `${env}`
   - Expected: Sanitized to underscores, no command injection

4. **Rate Limit Testing**:
   - Send 1000 requests/second to auth_exchange
   - Expected: API Gateway throttles after limit (once implemented)

5. **S3 Path Traversal**:
   - Attempt to access `users/../admin/secrets.txt` using valid credentials
   - Expected: IAM conditions prevent access to paths outside user prefix

## 8. Compliance and Audit

### 8.1 CloudTrail Logging

**Logged Events:**
- ✅ `AssumeRoleWithWebIdentity` (STS) - Includes session name, Firebase UID
- ✅ `PutObject` / `GetObject` (S3) - User identity via assumed role
- ✅ `PutItem` / `GetItem` (DynamoDB) - User identity via assumed role
- ✅ `InvokeModel` (Bedrock) - When summary generated (no transcript content logged)

**Audit Queries:**
```sql
-- Find all S3 access by a specific user
SELECT eventTime, eventName, requestParameters.bucketName, requestParameters.key
FROM cloudtrail_logs
WHERE userIdentity.sessionContext.sessionIssuer.userName = 'meeting-recorder-dev-macos-app-role'
  AND userIdentity.principalId LIKE '%:firebase_uid_123'
ORDER BY eventTime DESC;

-- Find auth_exchange invocations with errors
SELECT eventTime, errorCode, errorMessage, sourceIPAddress
FROM cloudtrail_logs
WHERE eventName = 'Invoke'
  AND requestParameters.functionName = 'meeting-recorder-dev-auth-exchange'
  AND errorCode IS NOT NULL;
```

### 8.2 Regulatory Considerations

**GDPR (EU)**:
- ✅ Right to Access: Users own AWS account, full S3/DynamoDB access
- ✅ Right to Deletion: FR-011, FR-012 in spec
- ⚠️ Data Processor Agreement: Need DPA with AWS (standard AWS terms)
- ⚠️ International Transfers: Default us-east-1 may violate EU data residency

**CCPA (California)**:
- ✅ Data Sale Prohibition: No data sold (single-user app)
- ✅ Deletion Rights: Same as GDPR

**HIPAA (Healthcare - Future)**:
- ❌ Not compliant: Bedrock is not HIPAA-eligible (as of 2025)
- ❌ BAA Required: Cannot use for medical meeting recordings
- **Recommendation**: Add disclaimer for healthcare use cases

**SOC 2 (Enterprise - Future)**:
- Partially aligned: Encryption, access controls, audit logs
- Gap: No formal access reviews, incident response plan

## 9. Incident Response Plan

### 9.1 Credential Compromise Scenarios

**Scenario 1: Firebase Token Leaked**
1. **Detection**: User reports suspicious activity
2. **Containment**: 
   - Token expires in 1 hour (self-healing)
   - User signs out → clears Keychain
   - User changes Google password → invalidates refresh token
3. **Eradication**: 
   - Review CloudTrail for unauthorized API calls
   - Delete any objects uploaded by attacker (user's S3 path)
4. **Recovery**: User signs back in with new token
5. **Lessons Learned**: Review why token was exposed

**Scenario 2: AWS Credentials Stolen from Keychain**
1. **Detection**: CloudTrail shows API calls from unusual IP/device
2. **Containment**:
   - Credentials expire in 1 hour (self-healing)
   - User signs out → clears cached credentials
   - User changes Google password (prevents re-auth)
3. **Eradication**:
   - Review CloudTrail for all API calls during exposure window
   - Check for data exfiltration (S3 GetObject calls)
4. **Recovery**: User signs back in, new credentials issued
5. **Lessons Learned**: Investigate how keychain was accessed

**Scenario 3: Lambda Compromised (Code Injection)**
1. **Detection**: CloudWatch alarms on high error rate or unusual STS calls
2. **Containment**:
   - Disable Lambda function (update env var to fail fast)
   - Existing user credentials still valid (don't revoke unless necessary)
3. **Eradication**:
   - Audit Lambda code changes in git history
   - Review CloudTrail for STS calls during compromise window
   - Roll back to known good Lambda version
4. **Recovery**: Re-deploy clean Lambda code
5. **Lessons Learned**: Implement Lambda code signing, tighter CI/CD controls

### 9.2 Data Breach Response

**If User Data Accessed by Unauthorized Party:**
1. **Identify**: Run CloudTrail query for cross-user access attempts
2. **Notify**: 
   - Inform affected users (via email)
   - Document breach timeline
   - Report to authorities if required (GDPR: 72 hours)
3. **Contain**: 
   - Review IAM policies for misconfiguration
   - Patch any bypassed isolation controls
4. **Prevent**: 
   - Implement additional IAM conditions
   - Add anomaly detection (e.g., CloudWatch Insights queries)

## 10. Conclusion

### 10.1 Security Posture Summary

The Firebase IDC to AWS STS token exchange architecture provides a **strong foundation** for multi-tenant data isolation without traditional multi-tenant database complexity.

**Strengths:**
- ✅ Industry-standard OIDC authentication flow
- ✅ Short-lived credentials (1-hour max)
- ✅ Infrastructure-level user isolation (IAM conditions)
- ✅ No long-term credentials in client app
- ✅ Comprehensive audit trail (CloudTrail)
- ✅ Encryption in transit (TLS 1.2+) and at rest (SSE-S3, DynamoDB default)

**Weaknesses:**
- ⚠️ Privacy risk: Sensitive data (resumes, meetings) sent to Bedrock LLM
- ⚠️ No early credential revocation (must wait for 1-hour expiration)
- ⚠️ Application-level GSI query enforcement (DynamoDB)
- ⚠️ Default data residency (us-east-1) may not meet all compliance needs
- ⚠️ No rate limiting on auth_exchange endpoint (DoS risk)

**Overall Risk Rating**: **LOW-MEDIUM** (Acceptable for MVP with recommended mitigations)

### 10.2 Pre-Production Checklist

Before launching to production:

- [ ] **Critical**: Implement API Gateway rate limiting on auth_exchange
- [ ] **Critical**: Validate IAM conditions in production environment (integration tests)
- [ ] **Critical**: Enable CloudWatch alarms for high error rates
- [ ] **Important**: Add security response headers to API Gateway
- [ ] **Important**: Enable DynamoDB point-in-time recovery
- [ ] **Important**: Document Bedrock data handling for users (privacy policy)
- [ ] **Important**: Add session name validation against Firebase UID format
- [ ] **Nice to Have**: Implement client-side encryption for recordings
- [ ] **Nice to Have**: Support multi-region deployment for data residency

### 10.3 Ongoing Security Maintenance

**Quarterly Reviews:**
- Review CloudTrail logs for anomalous access patterns
- Audit IAM policies for unintended permission drift
- Update Firebase OIDC provider thumbprint if Google rotates keys
- Review Bedrock data retention policies (AWS may change terms)

**Continuous Monitoring:**
- CloudWatch alarms for Lambda errors, high latency, throttling
- S3 access logging for unusual GET/PUT patterns
- DynamoDB capacity metrics (throttling indicates potential abuse)

**Dependency Updates:**
- Keep boto3 (Python AWS SDK) up to date for security patches
- Monitor Firebase SDK security advisories
- Review AWS SDK Swift security bulletins

---

**Document Version**: 1.0.0  
**Last Updated**: 2025-11-15  
**Next Review Date**: 2026-02-15 (90 days)  
**Owner**: Security Team / Platform Engineering
