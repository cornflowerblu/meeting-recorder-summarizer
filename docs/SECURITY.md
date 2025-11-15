# Security Documentation

This directory contains comprehensive security analysis and guidelines for the Meeting Recorder's authentication and data isolation architecture.

## 📚 Documentation Suite

### 1. [Security Analysis](./security-analysis-token-swap.md) ⭐
**Primary security document** - Complete threat analysis and risk assessment

**Contents:**
- Architecture overview with authentication flow diagrams
- Multi-tenancy security model (S3, DynamoDB isolation via IAM)
- Token security analysis (Firebase JWT, AWS STS credentials)
- Privacy & PII considerations for LLM processing
- STRIDE threat model with 30+ scenarios
- 12 security recommendations (prioritized)
- Compliance analysis (GDPR, CCPA, HIPAA)
- Incident response playbooks

**When to read**: 
- Before implementing authentication changes
- When reviewing IAM policies
- Before production deployment
- During security audits

### 2. [Security Testing Guide](./security-testing-guide.md) 🧪
**Hands-on testing procedures** - Practical test cases and validation

**Contents:**
- Unit test examples for Lambda security validation
- Integration tests for S3/DynamoDB user isolation
- Penetration testing scenarios (token replay, injection, rate limiting)
- CloudTrail audit queries for security monitoring
- CI/CD pipeline security test integration
- Continuous monitoring setup

**When to use**:
- During development (TDD approach)
- In code review (validate security tests exist)
- Before releases (run integration tests)
- During security assessments

### 3. [Security Checklist](./security-checklist.md) ✅
**Quick reference** - Developer-friendly checklists and common pitfalls

**Contents:**
- Pre-commit security checklist
- Code review security guidelines
- Pre-production deployment checklist
- Common security anti-patterns with fixes
- Incident response quick reference
- Testing quick commands

**When to use**:
- Before every commit touching auth/data access
- During code reviews
- Before deployments
- When onboarding new developers

## 🎯 Quick Start

### For Developers

1. **Read**: [Security Checklist](./security-checklist.md) - 15 minutes
2. **Understand**: [Security Analysis](./security-analysis-token-swap.md) Section 1-2 - 30 minutes
3. **Test**: Run unit tests from [Testing Guide](./security-testing-guide.md) - 10 minutes

### For Security Reviewers

1. **Review**: [Security Analysis](./security-analysis-token-swap.md) - Full read (60 minutes)
2. **Validate**: Run integration tests from [Testing Guide](./security-testing-guide.md) - 30 minutes
3. **Audit**: Execute CloudTrail queries from testing guide - 20 minutes

### For Product/Management

1. **Read**: [Security Analysis](./security-analysis-token-swap.md) Executive Summary - 5 minutes
2. **Review**: Sections 4 (Privacy) and 6 (Recommendations) - 20 minutes
3. **Decision**: Review pre-production checklist in Section 10.2 - 10 minutes

## 🔒 Security Architecture Summary

### Authentication Flow

```
User (Google Sign-In) 
  → Firebase Auth (JWT ID Token)
  → Lambda (auth_exchange)
  → AWS STS (AssumeRoleWithWebIdentity)
  → Temporary Credentials (1-hour)
  → macOS App (Keychain storage)
  → AWS SDK (S3, DynamoDB access)
```

### Multi-Tenancy Isolation

**Without traditional multi-tenant infrastructure**:
- Single S3 bucket with IAM policy condition: `users/${aws:username}/*`
- Single DynamoDB table with partition key: `{firebase_uid}#recording_{id}`
- `${aws:username}` resolves to Firebase UID (session name)
- AWS enforces isolation at infrastructure level

**Key Principle**: Users can ONLY access resources prefixed with their Firebase UID

### Security Posture

**Risk Level**: **LOW-MEDIUM** (Acceptable for MVP)

**Strengths** ✅:
- Industry-standard OIDC authentication
- Short-lived credentials (1-hour)
- Infrastructure-level isolation (IAM)
- No long-term credentials in app
- Comprehensive audit trail

**Risks** ⚠️:
- Privacy: LLM processing of sensitive data
- No early credential revocation
- Missing API Gateway rate limiting
- Default data residency (us-east-1)

## 🚨 Critical Security Requirements

Before production deployment:

1. ✅ **IAM User Isolation** - Tested in unit tests (test_handler.py)
2. ⚠️ **API Gateway Rate Limiting** - Needs implementation (Terraform provided)
3. ⚠️ **CloudWatch Alarms** - Needs configuration (examples in testing guide)
4. ⚠️ **Security Headers** - Needs API Gateway configuration

## 🔐 Privacy & Compliance

### PII Handling

**What's collected**:
- Video recordings (HIGH sensitivity)
- Audio transcripts (HIGH sensitivity)
- User email (MEDIUM - not logged)
- Meeting participants (MEDIUM - user-provided)

**Protection measures**:
- ✅ Encryption at rest (SSE-S3, DynamoDB default)
- ✅ Encryption in transit (TLS 1.2+)
- ✅ No PII in logs (Constitution enforced)
- ✅ User-scoped data access (IAM conditions)
- ⚠️ LLM processing (Bedrock) - see privacy analysis

### LLM Privacy Considerations

**Specific to resume/interview use cases**:

| Data Type | Risk | Mitigation |
|-----------|------|------------|
| Resume PII | HIGH | User consent, redaction capability (planned) |
| Meeting participants | MEDIUM | User controls recording |
| Transcripts | HIGH | Bedrock terms (no training, 90-day max retention) |
| Summaries | MEDIUM | Derived data, no direct PII storage |

**Bedrock Data Handling** (AWS Terms):
- Data used for inference only (not training)
- 90-day maximum retention for compliance
- Processed within AWS infrastructure
- Covered by AWS Data Processing Addendum (DPA)

### Regulatory Compliance

- **GDPR (EU)**: ⚠️ Default us-east-1 may violate data residency (recommend region selection)
- **CCPA (California)**: ✅ No data sale, deletion rights supported
- **HIPAA (Healthcare)**: ❌ Bedrock not HIPAA-eligible (as of 2025)
- **SOC 2 (Enterprise)**: Partially aligned (encryption, access controls, audit logs)

## 🛠️ Common Security Tasks

### Test User Isolation

```bash
# Run integration tests
cd processing
pytest tests/integration/test_s3_isolation.py
pytest tests/integration/test_dynamodb_isolation.py
```

### Audit User Activity

```sql
-- CloudTrail query (CloudWatch Logs Insights)
SELECT eventTime, eventName, requestParameters, errorCode
FROM cloudtrail_logs
WHERE userIdentity.principalId LIKE '%:firebase_uid_123'
ORDER BY eventTime DESC
LIMIT 100;
```

### Check for Security Issues

```bash
# Run security-critical unit tests
cd processing/lambdas/auth_exchange
pytest test_handler.py::TestInputValidation -v
pytest test_handler.py::TestSTSErrorScenarios -v

# Check test coverage
pytest test_handler.py --cov=handler --cov-fail-under=80
```

## 📞 Security Contact

For security issues or questions:

1. **Non-urgent**: Review [Security Analysis](./security-analysis-token-swap.md) first
2. **Code review**: Use [Security Checklist](./security-checklist.md)
3. **Testing help**: See [Security Testing Guide](./security-testing-guide.md)
4. **Incidents**: Follow playbooks in Section 9 of Security Analysis

## 🔄 Regular Security Maintenance

### Quarterly (Every 90 days)

- [ ] Review CloudTrail logs for anomalous patterns
- [ ] Audit IAM policies for permission drift
- [ ] Update Firebase OIDC provider thumbprint (if Google rotates)
- [ ] Review Bedrock data retention policies (AWS may update terms)
- [ ] Run full integration test suite with two test users

### Continuous

- [ ] Monitor CloudWatch alarms (Lambda errors, access denied events)
- [ ] Track S3 access patterns (unusual GET/PUT operations)
- [ ] Review DynamoDB metrics (throttling indicates potential abuse)
- [ ] Keep AWS SDK dependencies updated (boto3, AWS SDK Swift)

## 📖 Additional Resources

- **Constitution**: [../.specify/memory/constitution.md](../.specify/memory/constitution.md)
- **IAM Policies**: [../infra/terraform/iam.tf](../infra/terraform/iam.tf)
- **Auth Lambda**: [../processing/lambdas/auth_exchange/handler.py](../processing/lambdas/auth_exchange/handler.py)
- **Auth Tests**: [../processing/lambdas/auth_exchange/test_handler.py](../processing/lambdas/auth_exchange/test_handler.py)
- **Data Model**: [../specs/001-meeting-recorder-ai/data-model.md](../specs/001-meeting-recorder-ai/data-model.md)

---

**Last Updated**: 2025-11-15  
**Next Security Review**: 2026-02-15 (90 days)  
**Document Version**: 1.0.0
