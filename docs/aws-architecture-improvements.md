# AWS Architecture Improvements Implementation Guide

This document provides step-by-step implementation instructions for the improvements identified in the AWS Architecture Audit.

## Phase 1: Critical Security Fixes (Completed ✅)

### 1.1 IAM Session Name Validation
**Status**: ✅ Already implemented in `processing/lambdas/auth_exchange/handler.py`

The auth_exchange Lambda already validates and sanitizes the session name:
- Lines 88-101: Validates session_name is present and sanitizes it
- Line 97: Sanitizes to only allow `[a-zA-Z0-9=,.@_-]` characters
- Line 111: Uses sanitized session name in STS call

**No action required** - this is properly implemented.

### 1.2 Tighten IAM Policies
**Status**: ⚠️ Requires implementation

See `infra/terraform/iam-improvements.tf` for updated policies.

### 1.3 Enable Cost Anomaly Detection
**Status**: ⚠️ Requires implementation

See `infra/terraform/cost-monitoring.tf` for configuration.

### 1.4 Add CloudWatch Alarms
**Status**: ⚠️ Requires implementation

See `infra/terraform/cloudwatch-alarms.tf` for alarm definitions.

---

## Phase 2: Quick Cost Wins

### 2.1 Update S3 Lifecycle Rules
**Status**: ⚠️ Requires implementation

See improved lifecycle rules in `infra/terraform/s3-lifecycle-improvements.tf`.

**Key Changes**:
1. Delete raw chunks after 7 days (save ~40% of storage)
2. Delete audio files after 30 days (can regenerate from video)
3. Use Intelligent-Tiering for videos instead of aggressive Glacier transitions
4. Reduce multipart upload abortion from 7 days to 1 day

**Estimated Savings**: $6.50/month

### 2.2 Optimize DynamoDB GSIs
**Status**: ⚠️ Requires testing before implementation

**Recommendation**: Remove GSI-2 (ParticipantSearch) and GSI-3 (TagSearch)

**Rationale**:
- Single-user MVP likely has <1000 meetings
- Client-side filtering is acceptable for this scale
- Eliminates data denormalization overhead

**Implementation Steps**:
1. Test current query performance with GSI-1 only
2. Implement client-side filtering in macOS app
3. Remove GSI-2 and GSI-3 from Terraform
4. Deploy and validate

**Estimated Savings**: $2/month in write costs

### 2.3 Switch to AWS-Managed KMS Keys
**Status**: ⚠️ Requires implementation

**Current**: Customer-managed KMS key for DynamoDB
**Proposed**: AWS-managed encryption key

**Implementation**:
```terraform
# dynamodb.tf - Change line 86-88
server_side_encryption {
  enabled     = true
  # kms_key_arn removed - uses AWS-managed key
}
```

**Estimated Savings**: $2/month

### 2.4 Test Claude Haiku for Action Items
**Status**: 🧪 Requires experimentation

**Proposal**: Use Claude Haiku (80% cheaper) for structured extraction tasks

**Test Plan**:
1. Create test Lambda with Claude Haiku
2. Compare output quality vs Sonnet 4.5 for 10 sample transcripts
3. Measure token usage and cost difference
4. If quality acceptable, update bedrock_summarize Lambda

**Estimated Savings**: $6/month (if quality acceptable)

---

## Phase 3: Compute Optimization

### 3.1 Migrate to AWS Batch with Spot Instances
**Status**: ⚠️ Major architectural change - requires careful implementation

**Current**: Fargate ECS (2 vCPU, 4GB) at $0.12/hour
**Proposed**: AWS Batch with Spot instances (1 vCPU, 2GB) at $0.025/hour

**Estimated Savings**: $12/month (80% reduction in compute costs)

See `infra/terraform/batch-migration.tf` for AWS Batch implementation.

**Implementation Steps**:
1. Create AWS Batch Compute Environment with Spot instances
2. Create Job Definition for FFmpeg container
3. Create Job Queue with Spot preference
4. Update Step Functions to use Batch instead of ECS RunTask
5. Test with sample recordings
6. Monitor for Spot interruptions (should be rare for <30 min jobs)
7. Migrate production traffic

**Risk Mitigation**:
- Keep Fargate as fallback for first 2 weeks
- Monitor Spot interruption rate
- Add retry logic for Spot interruptions

---

## Phase 4: Network & Monitoring

### 4.1 Add VPC Gateway Endpoints
**Status**: ⚠️ Requires implementation

VPC Gateway Endpoints for S3 and DynamoDB are **FREE** and improve security.

See `infra/terraform/vpc-endpoints.tf` for implementation.

**Benefits**:
- No data transfer charges for S3/DynamoDB access
- Traffic stays within AWS network
- Better security (no internet exposure)

### 4.2 Enable S3 Access Logging
**Status**: ⚠️ Already enabled in prod, extend to all environments

**Current**: Only enabled when `var.environment == "prod"` (line 147 of s3.tf)
**Proposed**: Enable for all environments

```terraform
# s3.tf - Remove the count condition
resource "aws_s3_bucket_logging" "recordings" {
  # count = var.environment == "prod" ? 1 : 0  # REMOVE THIS
  bucket = aws_s3_bucket.recordings.id
  target_bucket = aws_s3_bucket.recordings.id
  target_prefix = "logs/s3-access/"
}
```

### 4.3 Add Custom CloudWatch Metrics
**Status**: 🧪 Requires Lambda code updates

**Metrics to Add**:
1. Processing duration per meeting (end-to-end)
2. Token usage per summary (input + output)
3. S3 storage growth rate per user
4. FFmpeg processing time vs video duration ratio

**Implementation**: Update Lambda functions to emit custom metrics using `put_metric_data`

### 4.4 Set Up AWS Backup
**Status**: ⚠️ Requires implementation

See `infra/terraform/backup.tf` for automated DynamoDB backup configuration.

---

## Implementation Priority Matrix

| Task | Priority | Effort | Savings/Impact | Status |
|------|----------|--------|----------------|--------|
| Cost Anomaly Detection | 🔴 Critical | 30 min | Prevent cost spikes | ⚠️ Todo |
| CloudWatch Alarms | 🔴 Critical | 2 hours | Catch failures early | ⚠️ Todo |
| S3 Lifecycle Improvements | 🟠 High | 2 hours | $6.50/month | ⚠️ Todo |
| AWS-Managed KMS | 🟠 High | 1 hour | $2/month | ⚠️ Todo |
| Remove Extra GSIs | 🟠 High | 4 hours | $2/month | ⚠️ Todo |
| Test Claude Haiku | 🟠 High | 4 hours | $6/month | 🧪 Testing |
| VPC Endpoints | 🟡 Medium | 2 hours | Security + $$ | ⚠️ Todo |
| S3 Access Logging | 🟡 Medium | 30 min | Security | ⚠️ Todo |
| Migrate to AWS Batch | 🟡 Medium | 12 hours | $12/month | ⚠️ Todo |
| AWS Backup Setup | 🟢 Low | 2 hours | Reliability | ⚠️ Todo |
| Custom Metrics | 🟢 Low | 6 hours | Observability | ⚠️ Todo |

---

## Total Cost Impact Summary

### Current Monthly Cost: $55.69

**After Phase 1 & 2 (Quick Wins)**:
- S3 lifecycle improvements: -$6.50
- AWS-managed KMS: -$2.00
- Remove extra GSIs: -$2.00
- Claude Haiku (if successful): -$6.00
- **New Total: ~$39.19/month (30% reduction)**

**After Phase 3 (Compute Migration)**:
- AWS Batch with Spot: -$12.00
- **New Total: ~$27.19/month (51% reduction)**

**After Phase 4 (Network Optimization)**:
- VPC Endpoints: -$0.50 (data transfer savings)
- **Final Total: ~$26.69/month (52% reduction)**

---

## Rollback Plans

Each major change has a rollback strategy:

### S3 Lifecycle Changes
**Rollback**: Update lifecycle rules to restore previous configuration
**Risk**: Low (can restore from Glacier if needed)

### AWS Batch Migration
**Rollback**: Update Step Functions to use Fargate task definition
**Risk**: Medium (requires testing)

### DynamoDB GSI Removal
**Rollback**: Re-add GSIs via Terraform (requires data backfill)
**Risk**: High (test thoroughly before removing)

### KMS Key Change
**Rollback**: Re-enable customer-managed key in Terraform
**Risk**: Low (transparent to application)

---

## Testing Checklist

Before deploying each change to production:

- [ ] Test in dev environment
- [ ] Verify no errors in CloudWatch Logs
- [ ] Validate functionality with sample recordings
- [ ] Measure performance impact
- [ ] Confirm cost savings in AWS Cost Explorer
- [ ] Document any issues encountered
- [ ] Get approval from stakeholder

---

## Monitoring Post-Deployment

After implementing changes, monitor:

1. **CloudWatch Alarms**: Ensure no new failures
2. **Cost Explorer**: Verify expected savings appear
3. **X-Ray Traces**: Check for latency increases
4. **S3 Metrics**: Monitor retrieval latency for lifecycle changes
5. **DynamoDB Metrics**: Verify query performance without extra GSIs

---

## Next Steps

1. Review this implementation guide
2. Prioritize which phases to implement first
3. Create Terraform changes (see accompanying .tf files)
4. Test in dev environment
5. Deploy to production incrementally
6. Monitor and validate each change

---

**Document Version**: 1.0  
**Last Updated**: 2025-11-15  
**Owner**: DevOps / Platform Team
