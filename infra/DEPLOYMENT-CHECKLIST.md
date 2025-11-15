# Terraform Deployment Checklist

Use this checklist before deploying the AWS architecture improvements.

## Pre-Deployment Validation

### 1. Prerequisites
- [ ] Terraform >= 1.5.0 installed
- [ ] AWS CLI configured with credentials
- [ ] Firebase project created
- [ ] S3 backend bucket created (if using remote state)
- [ ] DynamoDB lock table created (if using remote state)

### 2. Configuration Files
- [ ] `terraform.tfvars` created from `terraform.tfvars.example`
- [ ] `alert_email` set in `terraform.tfvars`
- [ ] `monthly_budget_limit` set in `terraform.tfvars`
- [ ] `firebase_project_id` set in `terraform.tfvars`
- [ ] Review all variables for your environment

### 3. Terraform Validation
```bash
cd infra/terraform

# Initialize (download providers)
terraform init

# Validate syntax
terraform validate

# Format code
terraform fmt -recursive

# Plan (review changes)
terraform plan -out=tfplan

# Review the plan output carefully
```

### 4. Expected New Resources

#### Cost Monitoring (`cost-monitoring.tf`)
- [ ] `aws_sns_topic.cost_alerts`
- [ ] `aws_sns_topic_subscription.cost_alerts_email`
- [ ] `aws_ce_anomaly_monitor.service_monitor`
- [ ] `aws_ce_anomaly_subscription.cost_alerts`
- [ ] `aws_budgets_budget.monthly_budget`

#### CloudWatch Alarms (`cloudwatch-alarms.tf`)
- [ ] `aws_sns_topic.operational_alerts`
- [ ] `aws_sns_topic_subscription.operational_alerts_email`
- [ ] `aws_cloudwatch_metric_alarm.auth_exchange_errors`
- [ ] `aws_cloudwatch_metric_alarm.auth_exchange_duration`
- [ ] `aws_cloudwatch_metric_alarm.user_profile_errors`
- [ ] `aws_cloudwatch_metric_alarm.step_functions_failed`
- [ ] `aws_cloudwatch_metric_alarm.step_functions_timeout`
- [ ] `aws_cloudwatch_metric_alarm.step_functions_duration`
- [ ] `aws_cloudwatch_metric_alarm.dynamodb_throttles`
- [ ] `aws_cloudwatch_metric_alarm.s3_4xx_errors`
- [ ] `aws_cloudwatch_metric_alarm.s3_5xx_errors`
- [ ] `aws_cloudwatch_composite_alarm.system_health`

#### VPC Endpoints (`vpc-endpoints.tf`)
- [ ] `aws_vpc_endpoint.s3` (Gateway type, FREE)
- [ ] `aws_vpc_endpoint.dynamodb` (Gateway type, FREE)

#### Backup (`backup.tf`)
- [ ] `aws_backup_vault.main`
- [ ] `aws_backup_plan.dynamodb_daily`
- [ ] `aws_iam_role.backup`
- [ ] `aws_backup_selection.dynamodb_tables`
- [ ] `aws_sns_topic.backup_notifications` (if email provided)
- [ ] `aws_backup_vault_notifications.main` (if email provided)

#### Modified Resources
- [ ] S3 lifecycle configuration updated (5 new rules)
- [ ] S3 access logging enabled (no longer conditional)
- [ ] Step Functions IAM policy tightened
- [ ] DynamoDB encryption comments updated

### 5. Cost Impact Check

**Expected Monthly Cost Changes:**
- Cost Anomaly Detection: FREE
- AWS Budgets (2 budgets): FREE (first 2 budgets are free)
- CloudWatch Alarms (~12 alarms): +$1.20/month
- VPC Endpoints: FREE
- AWS Backup: ~$0.10/GB-month (minimal for DynamoDB)
- S3 lifecycle optimization: -$6.50/month
- KMS savings (if using AWS-managed): -$2.00/month

**Net Impact**: Approximately **-$7.30/month savings**

### 6. Security Review
- [ ] IAM policies reviewed (no overly permissive `Resource = "*"`)
- [ ] VPC endpoint policies restrict access to our resources only
- [ ] S3 bucket policy enforces TLS
- [ ] CloudWatch alarms cover critical security events
- [ ] Backup notifications enabled

---

## Deployment

### Step 1: Initialize
```bash
terraform init
```
**Expected**: Providers download successfully

### Step 2: Plan
```bash
terraform plan -out=tfplan
```
**Review**:
- [ ] Number of resources to add (expected: ~25-30)
- [ ] Number of resources to change (expected: 3-5)
- [ ] Number of resources to destroy (expected: 0)
- [ ] No unexpected deletions
- [ ] All new resource names follow naming convention

### Step 3: Apply
```bash
terraform apply tfplan
```
**Monitor**: Watch for any errors during creation

### Step 4: Verify Outputs
```bash
terraform output
```
**Expected outputs**:
- [ ] `cost_alerts_topic_arn`
- [ ] `operational_alerts_topic_arn`
- [ ] `s3_vpc_endpoint_id`
- [ ] `dynamodb_vpc_endpoint_id`
- [ ] `backup_vault_arn`
- [ ] All existing outputs still present

---

## Post-Deployment Validation

### 1. Email Confirmations (Critical!)
Check your email for subscription confirmations:
- [ ] Cost anomaly alerts subscription → **CONFIRM**
- [ ] Operational alerts subscription → **CONFIRM**
- [ ] Backup notifications subscription → **CONFIRM** (if email provided)

**Note**: Alarms won't send emails until subscriptions are confirmed!

### 2. CloudWatch Validation
```bash
# List alarms
aws cloudwatch describe-alarms \
  --region us-east-1 \
  --query 'MetricAlarms[?starts_with(AlarmName, `meeting-recorder-dev`)].AlarmName' \
  --output table

# Check alarm states (should be "INSUFFICIENT_DATA" initially)
aws cloudwatch describe-alarms \
  --region us-east-1 \
  --alarm-names "meeting-recorder-dev-system-health"
```
- [ ] All alarms created
- [ ] Alarms in INSUFFICIENT_DATA state initially (normal)
- [ ] Composite alarm configured

### 3. VPC Endpoints Validation
```bash
# List VPC endpoints
aws ec2 describe-vpc-endpoints \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=meeting-recorder-dev-*" \
  --query 'VpcEndpoints[].{Name:Tags[?Key==`Name`].Value|[0], Service:ServiceName, State:State}' \
  --output table
```
- [ ] S3 endpoint status: Available
- [ ] DynamoDB endpoint status: Available
- [ ] Route tables associated

### 4. Cost Monitoring Validation
```bash
# Check anomaly monitor
aws ce get-anomaly-monitors \
  --region us-east-1 \
  --query 'AnomalyMonitors[?starts_with(MonitorName, `meeting-recorder-dev`)].{Name:MonitorName, Type:MonitorType}' \
  --output table

# Check budget
aws budgets describe-budgets \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --query 'Budgets[?starts_with(BudgetName, `meeting-recorder-dev`)].{Name:BudgetName, Limit:BudgetLimit.Amount}' \
  --output table
```
- [ ] Anomaly monitor active
- [ ] Budget configured with correct limit
- [ ] Notifications configured

### 5. Backup Validation
```bash
# Check backup plan
aws backup list-backup-plans \
  --region us-east-1 \
  --query 'BackupPlansList[?starts_with(BackupPlanName, `meeting-recorder-dev`)].{Name:BackupPlanName, Id:BackupPlanId}' \
  --output table

# Check backup selections
aws backup list-backup-selections \
  --backup-plan-id <plan-id-from-above> \
  --region us-east-1 \
  --output table
```
- [ ] Backup plan created
- [ ] DynamoDB tables selected
- [ ] Schedule: Daily at 2 AM UTC

### 6. S3 Lifecycle Validation
```bash
# Check lifecycle configuration
aws s3api get-bucket-lifecycle-configuration \
  --bucket $(terraform output -raw recordings_bucket_name) \
  --query 'Rules[].{ID:ID, Status:Status}' \
  --output table
```
- [ ] 5 lifecycle rules present
- [ ] delete-processed-chunks rule active
- [ ] intelligent-tiering-videos rule active
- [ ] abort-incomplete-multipart-uploads set to 1 day

### 7. S3 Access Logging Validation
```bash
# Check logging configuration
aws s3api get-bucket-logging \
  --bucket $(terraform output -raw recordings_bucket_name)
```
- [ ] Logging enabled
- [ ] Target bucket configured
- [ ] Target prefix: `logs/s3-access/`

---

## Monitoring Setup (Week 1)

### Day 1-2: Baseline Establishment
- [ ] Cost Anomaly Detection will establish baseline (24-48 hours)
- [ ] Initial alerts may be noisy (expected)
- [ ] CloudWatch alarms in INSUFFICIENT_DATA (normal until traffic flows)

### Day 3-7: Monitor & Tune
- [ ] Review Cost Explorer for any unexpected charges
- [ ] Check CloudWatch Logs for alarm triggers
- [ ] Adjust alarm thresholds if too sensitive
- [ ] Verify backup jobs running successfully

---

## Rollback Plan

If issues occur, rollback in reverse order:

### 1. Disable New Features (Quick)
```bash
# Disable backup plan
aws backup delete-backup-plan --backup-plan-id <plan-id>

# Delete alarms
aws cloudwatch delete-alarms --alarm-names <alarm-name> <alarm-name> ...

# Delete VPC endpoints (caution: may affect running tasks)
terraform destroy -target=aws_vpc_endpoint.s3 -target=aws_vpc_endpoint.dynamodb
```

### 2. Revert Lifecycle Rules (If S3 issues)
```bash
cd infra/terraform
git checkout HEAD~1 -- s3.tf
terraform apply -target=aws_s3_bucket_lifecycle_configuration.recordings
```

### 3. Full Rollback (Last Resort)
```bash
# Revert to previous commit
git checkout HEAD~2

# Destroy new resources
terraform plan -destroy -target=module.cost_monitoring
terraform destroy -target=module.cost_monitoring
```

---

## Success Criteria

After 1 week of deployment:
- [ ] No unexpected cost spikes (check Cost Explorer)
- [ ] CloudWatch alarms functioning (test by triggering intentional error)
- [ ] Daily backup jobs completing successfully
- [ ] VPC endpoints reducing data transfer costs
- [ ] Email alerts working (confirm by triggering test alarm)
- [ ] S3 lifecycle rules deleting old chunks (check object count)

---

## Troubleshooting

### Issue: "Email not receiving alerts"
**Solution**: 
1. Check SNS subscription status: `aws sns list-subscriptions-by-topic --topic-arn <topic-arn>`
2. Confirm subscription in email (check spam folder)
3. Test with: `aws sns publish --topic-arn <topic-arn> --message "Test"`

### Issue: "VPC endpoint creation fails"
**Solution**: 
1. Check route table exists: `aws ec2 describe-route-tables --vpc-id <vpc-id>`
2. Verify service name correct: `aws ec2 describe-vpc-endpoint-services --region us-east-1`

### Issue: "Backup failing"
**Solution**:
1. Check IAM role permissions: `aws iam get-role-policy --role-name <backup-role>`
2. Verify DynamoDB table has proper tags: `aws dynamodb describe-table --table-name <table-name>`

### Issue: "Cost anomalies triggering too frequently"
**Solution**:
1. Adjust threshold: Edit `cost-monitoring.tf` line with `threshold_expression`
2. Change from 50% to 75% or higher
3. Apply: `terraform apply`

---

## Next Steps After Successful Deployment

1. **Week 1**: Monitor alerts, tune thresholds if needed
2. **Week 2-3**: Evaluate cost savings in Cost Explorer
3. **Week 4**: Review backup retention policy
4. **Month 2**: Consider Phase 3 (AWS Batch migration)
5. **Month 3**: Consider Phase 4 (Claude Haiku testing)

---

**Checklist Version**: 1.0  
**Last Updated**: 2025-11-15  
**Status**: Ready for use
