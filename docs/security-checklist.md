# Security Checklist: Token Swap Architecture

**Quick Reference for Developers**  
**Related**: [Security Analysis](./security-analysis-token-swap.md) | [Testing Guide](./security-testing-guide.md)

## Pre-Commit Checklist

Before committing code that touches authentication or data access:

### Authentication Code (Lambda, Swift)

- [ ] **No tokens logged**: Verify Firebase tokens, AWS credentials never printed/logged
- [ ] **Input sanitization**: All user inputs sanitized before use in AWS API calls
- [ ] **Error messages**: No sensitive data in error responses (token values, credentials)
- [ ] **Session name validation**: Firebase UID validated/sanitized before STS call
- [ ] **TLS enforcement**: All HTTP calls use HTTPS (no HTTP fallback)

```python
# ❌ BAD - Token in logs
print(f"Received token: {firebase_token}")

# ✅ GOOD - No token details
print("Token exchange requested")
```

### IAM Policy Changes (Terraform)

- [ ] **User isolation**: All policies include `${aws:username}` conditions
- [ ] **Least privilege**: Only necessary permissions granted
- [ ] **Resource ARNs specific**: Avoid wildcards where possible
- [ ] **Deny non-TLS**: S3/DynamoDB policies deny non-HTTPS access
- [ ] **Test with two users**: Verify cross-user access blocked

```json
// ✅ GOOD - User-scoped policy
{
  "Resource": "arn:aws:s3:::bucket/users/${aws:username}/*"
}

// ❌ BAD - No user scoping
{
  "Resource": "arn:aws:s3:::bucket/users/*"
}
```

### Data Access Code (Swift, Python)

- [ ] **User ID in paths**: All S3 keys include `users/{firebase_uid}/`
- [ ] **DynamoDB keys**: Partition keys start with Firebase UID
- [ ] **No hardcoded credentials**: Use STS temporary credentials only
- [ ] **Credential refresh**: Handle `ExpiredToken` errors gracefully
- [ ] **PII redaction**: Email/names only in structured metadata (not logs)

```swift
// ✅ GOOD - User-scoped S3 key
let key = "users/\(firebaseUID)/videos/\(recordingID).mp4"

// ❌ BAD - No user isolation
let key = "videos/\(recordingID).mp4"
```

## Code Review Checklist

When reviewing PRs:

### Security Critical Areas

- [ ] **Token handling**: No tokens in logs, error messages, or comments
- [ ] **IAM conditions**: All resource policies include user isolation
- [ ] **Input validation**: User inputs validated/sanitized before AWS calls
- [ ] **Error handling**: Sensitive details not exposed in error responses
- [ ] **Test coverage**: Security tests added for new authentication code

### Privacy Considerations

- [ ] **PII logging**: No email, names, transcript content in logs
- [ ] **Structured logging**: Use metadata fields, not string interpolation
- [ ] **Bedrock calls**: User aware of LLM processing (consent flow)
- [ ] **Data deletion**: Ensure deletion propagates to all storage layers

## Pre-Production Checklist

Before deploying to production:

### Critical (Must Complete)

- [ ] **API Gateway rate limiting**: Throttle auth_exchange endpoint (50 req/sec)
- [ ] **IAM policy audit**: Test user isolation with two real Firebase users
- [ ] **CloudWatch alarms**: Monitor Lambda errors, access denied events
- [ ] **Security headers**: HSTS, X-Frame-Options configured on API Gateway
- [ ] **Integration tests pass**: S3/DynamoDB isolation tests green

### Important (Should Complete)

- [ ] **DynamoDB PITR enabled**: Point-in-time recovery for disaster recovery
- [ ] **CloudTrail logging verified**: Confirm events logged with session names
- [ ] **Bedrock terms reviewed**: Document data retention policy for users
- [ ] **Keychain accessibility**: Use `WhenUnlockedThisDeviceOnly` for prod
- [ ] **Session name validation**: Enforce Firebase UID format (28 alphanumeric)

### Nice to Have (Future)

- [ ] **Client-side encryption**: Consider AWS Encryption SDK for recordings
- [ ] **Multi-region support**: Allow users to select data residency region
- [ ] **Advanced audit UI**: User-facing log of their AWS API calls
- [ ] **Participant notification**: Optional email to meeting participants

## Incident Response Quick Reference

### Scenario 1: Suspected Token Compromise

1. **Check CloudTrail**: Look for API calls from unusual IPs
   ```sql
   SELECT eventTime, sourceIPAddress, eventName, requestParameters
   FROM cloudtrail_logs
   WHERE userIdentity.principalId LIKE '%:suspected_firebase_uid'
   ORDER BY eventTime DESC
   LIMIT 100;
   ```

2. **User actions**: 
   - User signs out (clears keychain)
   - User changes Google password (invalidates refresh tokens)
   - Credentials expire in 1 hour (self-healing)

3. **Review for exfiltration**: Check for unusual S3 GetObject calls

### Scenario 2: Cross-User Access Detected

1. **Immediate containment**:
   - Disable Lambda function (set env var to fail all requests)
   - Review IAM policies for misconfiguration
   
2. **Investigation**:
   ```sql
   SELECT eventTime, userIdentity.principalId, requestParameters, errorCode
   FROM cloudtrail_logs
   WHERE errorCode = 'AccessDenied'
     AND eventSource IN ('s3.amazonaws.com', 'dynamodb.amazonaws.com')
   ORDER BY eventTime DESC;
   ```

3. **Fix and re-deploy**: 
   - Patch IAM policy conditions
   - Add integration tests for new scenario
   - Re-enable Lambda

### Scenario 3: Rate Limit Abuse

1. **Check metrics**:
   - CloudWatch → Lambda → Invocations metric
   - Look for spikes in auth_exchange calls

2. **Temporary mitigation**:
   - API Gateway throttling (if configured)
   - Consider adding WAF rules for IP-based blocking

3. **Long-term fix**: Implement per-user API quotas

## Testing Quick Commands

```bash
# Run security-critical unit tests
cd processing/lambdas/auth_exchange
pytest test_handler.py::TestInputValidation -v
pytest test_handler.py::TestSTSErrorScenarios -v

# Run with coverage
pytest test_handler.py --cov=handler --cov-report=html

# Integration tests (requires AWS credentials)
export AWS_PROFILE=meeting-recorder-test
python tests/integration/test_s3_isolation.py
python tests/integration/test_dynamodb_isolation.py

# Manual penetration test
./scripts/security-test-auth-exchange.sh
```

## Common Security Issues

### Issue 1: Session Name Not Sanitized

```python
# ❌ DANGEROUS
sts.assume_role_with_web_identity(
    RoleSessionName=request.get('session_name')  # Direct user input
)

# ✅ SAFE
session_name = re.sub(r'[^a-zA-Z0-9=,.@_-]', '_', request.get('session_name')[:64])
sts.assume_role_with_web_identity(RoleSessionName=session_name)
```

### Issue 2: S3 Key Without User Prefix

```swift
// ❌ NO USER ISOLATION
let key = "chunks/\(recordingID)/part-0001.mp4"

// ✅ USER-SCOPED
let userID = await AuthSession.shared.loadFirebaseCredentials().userId
let key = "users/\(userID)/chunks/\(recordingID)/part-0001.mp4"
```

### Issue 3: DynamoDB Key Without User Prefix

```python
# ❌ NO USER ISOLATION
pk = f"recording_{recording_id}"

# ✅ USER-SCOPED
pk = f"{firebase_uid}#recording_{recording_id}"
```

### Issue 4: Token Logged in Error

```python
# ❌ TOKEN IN ERROR MESSAGE
raise ValueError(f"Invalid token: {firebase_token}")

# ✅ NO TOKEN DETAILS
raise ValueError("Invalid Firebase token format")
```

### Issue 5: Credentials in Git

```bash
# ❌ NEVER COMMIT
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"

# ✅ USE KEYCHAIN/ENV
# macOS: Stored in Keychain via AuthSession.swift
# CI/CD: Use GitHub Secrets
```

## Resources

- **Security Analysis**: [security-analysis-token-swap.md](./security-analysis-token-swap.md)
- **Testing Guide**: [security-testing-guide.md](./security-testing-guide.md)
- **Constitution**: [../.specify/memory/constitution.md](../.specify/memory/constitution.md)
- **IAM Policies**: [../infra/terraform/iam.tf](../infra/terraform/iam.tf)
- **Auth Lambda**: [../processing/lambdas/auth_exchange/handler.py](../processing/lambdas/auth_exchange/handler.py)

## Questions or Issues?

1. Review [security-analysis-token-swap.md](./security-analysis-token-swap.md) Section 5 (Threat Model)
2. Check existing tests: `processing/lambdas/auth_exchange/test_handler.py`
3. Ask security team for review before implementing:
   - New authentication flows
   - IAM policy changes
   - Data access patterns
   - LLM integration changes

---

**Remember**: Security is everyone's responsibility. When in doubt, ask for review!
