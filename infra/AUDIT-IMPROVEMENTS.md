# AWS Architecture Audit Improvements

This document summarizes the infrastructure improvements made based on the AWS Solutions Architect audit conducted on 2025-11-15.

## Quick Links

- [Full Audit Report](../docs/aws-architecture-audit.md)
- [Implementation Guide](../docs/aws-architecture-improvements.md)

## Summary of Changes

### Phase 1: Critical Security & Monitoring ✅ COMPLETED

#### 1. Cost Anomaly Detection
**File**: `terraform/cost-monitoring.tf`

- ✅ AWS Cost Explorer anomaly detection (alerts on 50%+ cost increases)
- ✅ AWS Budgets with 80%, 90%, 100% thresholds
- ✅ SNS topic for cost alerts
- ✅ Daily anomaly reports

**Cost**: FREE (Cost Explorer and Budgets are free services)

#### 2. CloudWatch Alarms
**File**: `terraform/cloudwatch-alarms.tf`

Added comprehensive monitoring:
- ✅ Lambda error rate alarms (auth_exchange, user_profile)
- ✅ Lambda latency alarms (detect slow STS calls)
- ✅ Step Functions failure/timeout alarms
- ✅ DynamoDB throttle detection
- ✅ S3 error rate monitoring (4xx and 5xx)
- ✅ Composite health alarm (triggers if multiple systems fail)

**Cost**: ~$0.10/month per alarm (10 alarms = $1/month)

#### 3. VPC Gateway Endpoints
**File**: `terraform/vpc-endpoints.tf`

- ✅ S3 Gateway Endpoint (FREE)
- ✅ DynamoDB Gateway Endpoint (FREE)

**Benefits**:
- No data transfer charges
- Better security (traffic stays in AWS network)
- Reduced latency

**Cost**: **FREE**

#### 4. Security Hardening
**Files**: `terraform/stepfunctions.tf`, `terraform/iam.tf`

- ✅ Tightened IAM policies (removed `Resource = "*"` where possible)
- ✅ Added Sid statements for better auditability
- ✅ Scoped Step Functions log permissions to specific log groups

---

### Phase 2: Cost Optimization ✅ COMPLETED

#### 1. S3 Lifecycle Improvements
**File**: `terraform/s3.tf`

**Before**:
- Kept all objects indefinitely
- Transitioned to expensive Deep Archive
- 7-day multipart upload abort window

**After**:
- ✅ Delete raw chunks after 7 days (saves 40% storage)
- ✅ Delete audio files after 30 days (can regenerate from video)
- ✅ Use Intelligent-Tiering for videos (auto-optimizes, no retrieval delays)
- ✅ Keep metadata accessible with IA transition at 90 days
- ✅ 1-day multipart abort window

**Estimated Savings**: $6.50/month

#### 2. S3 Access Logging
**File**: `terraform/s3.tf`

- ✅ Enabled for ALL environments (was prod-only)
- ✅ Logs stored in same bucket under `logs/s3-access/`

**Cost**: Minimal (~$0.05/month for log storage)

#### 3. DynamoDB Encryption
**File**: `terraform/dynamodb.tf`

- ✅ Updated comments to recommend AWS-managed keys for MVP
- ✅ Customer-managed KMS only if compliance requires
- ✅ `use_customer_managed_kms = false` by default

**Savings**: $2/month (KMS key + requests)

#### 4. AWS Backup
**File**: `terraform/backup.tf`

- ✅ Daily automated backups at 2 AM UTC
- ✅ 30-day retention
- ✅ Point-in-Time Recovery enabled
- ✅ Backup failure notifications

**Cost**: ~$0.10/GB-month (minimal for DynamoDB metadata)

---

## Configuration Required

### 1. Set Alert Email
Edit `terraform.tfvars`:

```hcl
alert_email = "your-email@example.com"
monthly_budget_limit = 100
```

### 2. Confirm SNS Subscriptions
After `terraform apply`, check your email and confirm:
- Cost alert subscription
- Operational alert subscription
- Backup notification subscription (if email provided)

### 3. Tag Resources for Object Lifecycle
When uploading to S3, tag objects appropriately:

```swift
// Swift SDK example
let tags = [
    "type": "chunk"   // Will be deleted after 7 days
    // OR "type": "video"     // Will use Intelligent-Tiering
    // OR "type": "audio"     // Will be deleted after 30 days
    // OR "type": "metadata"  // Will transition to IA after 90 days
]
```

---

## Cost Impact

### Current Architecture (Before Audit)
| Service | Monthly Cost |
|---------|--------------|
| Fargate | $15.00 |
| Lambda | $0.50 |
| S3 Storage | $11.50 |
| DynamoDB | $3.00 |
| KMS | $2.00 |
| Transcribe | $14.40 |
| Bedrock | $7.50 |
| Other | $1.29 |
| **TOTAL** | **$55.69** |

### After Phase 1 & 2 Improvements
| Service | Monthly Cost | Change |
|---------|--------------|--------|
| Fargate | $15.00 | - |
| Lambda | $0.50 | - |
| S3 Storage | $5.00 | **-$6.50** |
| DynamoDB | $3.00 | - |
| KMS | $0.00 | **-$2.00** |
| Transcribe | $14.40 | - |
| Bedrock | $7.50 | - |
| Monitoring | $1.00 | **+$1.00** |
| Other | $0.79 | -$0.50 |
| **TOTAL** | **$47.19** | **-$8.50 (15%)** |

### After Phase 3 (Future - AWS Batch Migration)
| Service | Monthly Cost | Change |
|---------|--------------|--------|
| AWS Batch (Spot) | $3.00 | **-$12.00** |
| Other services | (same) | - |
| **TOTAL** | **$35.19** | **-$20.50 (37%)** |

### After Phase 4 (Future - Claude Haiku + GSI Removal)
| Service | Monthly Cost | Change |
|---------|--------------|--------|
| Bedrock | $1.50 | **-$6.00** |
| DynamoDB | $1.00 | **-$2.00** |
| Other services | (same) | - |
| **TOTAL** | **$26.69** | **-$29.00 (52%)** |

---

## Deployment Instructions

### Prerequisites
1. Terraform >= 1.5.0
2. AWS credentials configured
3. Existing infrastructure deployed

### Steps

1. **Review Changes**
   ```bash
   cd infra/terraform
   terraform plan
   ```

2. **Update Configuration**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your email and settings
   vim terraform.tfvars
   ```

3. **Apply Changes**
   ```bash
   terraform apply
   ```

4. **Confirm SNS Subscriptions**
   - Check email for 3 confirmation links
   - Click each to activate alerts

5. **Verify Alarms**
   ```bash
   aws cloudwatch describe-alarms --region us-east-1 | grep meeting-recorder
   ```

6. **Test Cost Alert**
   - Wait 24 hours for Cost Anomaly Detection to establish baseline
   - Initial alerts may be noisy as baseline is established

---

## Rollback Plan

If issues arise, rollback specific features:

### Rollback S3 Lifecycle
```bash
cd infra/terraform
git checkout HEAD~1 -- s3.tf
terraform apply
```

### Rollback VPC Endpoints
```bash
# Remove vpc-endpoints.tf
rm vpc-endpoints.tf
terraform apply
```

### Rollback Monitoring
```bash
# Remove monitoring files
rm cost-monitoring.tf cloudwatch-alarms.tf
terraform apply
```

---

## Next Steps

### Phase 3: Compute Optimization (Future)
- [ ] Test AWS Batch for FFmpeg processing
- [ ] Benchmark Spot instance stability
- [ ] Migrate from Fargate to Batch
- **Estimated Savings**: $12/month

### Phase 4: Additional Optimizations (Future)
- [ ] Test Claude Haiku for action item extraction
- [ ] Evaluate removing DynamoDB GSI-2 and GSI-3
- [ ] Replace API Gateway with Lambda Function URL
- **Estimated Savings**: $8/month

---

## Monitoring & Alerts

After deployment, you will receive alerts for:

### Cost Alerts
- Daily anomaly reports (50%+ cost increases)
- 80% of monthly budget
- 90% of monthly budget (forecast)
- 100% of monthly budget

### Operational Alerts
- Lambda errors (>5 in 5 minutes)
- Step Functions failures (any)
- DynamoDB throttles (>10 in 5 minutes)
- S3 errors (>50 4xx or >5 5xx in 5 minutes)
- System health composite alarm

### Backup Alerts
- Backup job failures
- Restore job failures

---

## Support & Questions

For questions about these improvements:
1. Review the [Full Audit Report](../docs/aws-architecture-audit.md)
2. Check the [Implementation Guide](../docs/aws-architecture-improvements.md)
3. Review Terraform plan output before applying

---

**Version**: 1.0  
**Last Updated**: 2025-11-15  
**Status**: Phase 1 & 2 Complete, Phase 3 & 4 Planned
