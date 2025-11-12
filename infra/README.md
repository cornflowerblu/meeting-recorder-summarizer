# Infrastructure as Code (Terraform)

This directory contains Terraform configuration for deploying the Meeting Recorder AWS infrastructure.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5.0
- AWS CLI configured with appropriate credentials
- Firebase project created (for authentication)

## Directory Structure

```
infra/terraform/
├── main.tf              # Provider configuration and common resources
├── variables.tf         # Input variables
├── outputs.tf           # Output values
├── s3.tf               # S3 bucket for recordings
├── dynamodb.tf         # DynamoDB tables for metadata
├── kms.tf              # KMS keys for encryption (optional)
├── iam.tf              # IAM roles and policies
├── ssm.tf              # SSM Parameter Store values
├── stepfunctions.tf    # Step Functions workflow (Phase 4)
├── events.tf           # EventBridge rules (Phase 4)
└── terraform.tfvars    # Variable values (gitignored, create from example)
```

## Getting Started

### 1. Configure Variables

Copy the example tfvars file and customize:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:
- `aws_region`: Your preferred AWS region
- `environment`: Environment name (dev, staging, prod)
- `firebase_project_id`: Your Firebase project ID
- `use_customer_managed_kms`: Set to `true` for production to use customer-managed KMS keys
- Other configuration as needed

### 2. Initialize Terraform

```bash
terraform init
```

This downloads required provider plugins and initializes the backend.

### 3. Review the Plan

```bash
terraform plan
```

Review the resources that will be created. Ensure everything looks correct.

### 4. Apply the Configuration

```bash
terraform apply
```

Type `yes` when prompted to create the resources.

### 5. View Outputs

```bash
terraform output
```

This displays important values like bucket names, table names, and IAM role ARNs.

## Resource Overview

### Phase 2 (Foundational)

| Resource | Purpose | File |
|----------|---------|------|
| S3 Bucket | Store meeting recordings and artifacts | `s3.tf` |
| DynamoDB Table | Meetings metadata and catalog | `dynamodb.tf` |
| KMS Key | Customer-managed encryption key (optional) | `kms.tf` |
| IAM Roles | macOS app, Lambda execution roles | `iam.tf` |
| Lambda (Auth) | Firebase → AWS STS token exchange | (deployed separately) |

### Future Phases

| Resource | Purpose | Phase |
|----------|---------|-------|
| Step Functions | Processing orchestration | Phase 4 |
| EventBridge Rules | S3 event triggers | Phase 4 |
| Lambda (Processing) | Transcribe, Bedrock invocations | Phase 4 |
| Fargate Task | FFmpeg video processing | Phase 4 |

## State Management

### Local State (Default)

By default, Terraform state is stored locally in `terraform.tfstate`. This is fine for single-developer projects but not recommended for teams.

### Remote State (Recommended)

For production or team use, configure remote state:

1. Create an S3 bucket and DynamoDB table for state:
   ```bash
   aws s3 mb s3://meeting-recorder-terraform-state
   aws dynamodb create-table \
     --table-name meeting-recorder-terraform-lock \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST
   ```

2. Uncomment the backend configuration in `main.tf`

3. Re-initialize:
   ```bash
   terraform init -migrate-state
   ```

## Common Operations

### Update Infrastructure

After modifying `.tf` files:
```bash
terraform plan
terraform apply
```

### Destroy Infrastructure

**WARNING**: This deletes all resources!
```bash
terraform destroy
```

### View Current State

```bash
terraform show
```

### Format Code

```bash
terraform fmt -recursive
```

### Validate Configuration

```bash
terraform validate
```

## Cost Estimation

Terraform resources incur AWS costs:

| Service | Estimated Cost/Month (dev) |
|---------|---------------------------|
| S3 (1GB) | ~$0.023 |
| DynamoDB (on-demand, light usage) | Free tier |
| IAM | Free |
| **Total** | **~$0.50-1/month** |

Processing costs (Transcribe, Bedrock) are usage-based and added in Phase 4.

## Security Best Practices

- ✅ Encryption at rest (SSE-S3, optional customer-managed KMS for DynamoDB)
- ✅ Encryption in transit (TLS 1.2+)
- ✅ Least-privilege IAM policies
- ✅ No hardcoded credentials
- ✅ DynamoDB point-in-time recovery enabled
- ✅ S3 versioning enabled
- ✅ Customer-managed KMS keys for production (configurable via `use_customer_managed_kms`)

### KMS Encryption Configuration

The infrastructure supports both AWS-managed and customer-managed KMS keys for DynamoDB encryption:

**AWS-Managed Keys (Default)**
- Suitable for development and staging environments
- No additional cost
- Automatic key rotation managed by AWS
- Set `use_customer_managed_kms = false` in `terraform.tfvars`

**Customer-Managed Keys (Recommended for Production)**
- Enhanced security and compliance
- Full control over key policies and rotation
- Detailed audit trails via CloudTrail
- Ability to disable/delete keys if needed
- Set `use_customer_managed_kms = true` in `terraform.tfvars`

The KMS key policy grants:
- Full administrative access to the AWS account root
- DynamoDB service permissions for encryption operations
- CloudWatch Logs permissions for encrypted log groups

## Troubleshooting

### Issue: "Error acquiring the state lock"

Another Terraform process is running. Wait for it to complete or:
```bash
terraform force-unlock <LOCK_ID>
```

### Issue: "AccessDenied" errors

Check your AWS credentials:
```bash
aws sts get-caller-identity
```

Ensure your IAM user/role has sufficient permissions.

### Issue: Resource already exists

Import existing resources:
```bash
terraform import <resource_type>.<name> <resource_id>
```

## Phase 2 Deployment Checklist

- [ ] `terraform init` successful
- [ ] `terraform plan` shows expected resources
- [ ] `terraform apply` completes without errors
- [ ] S3 bucket created with encryption
- [ ] DynamoDB table created with GSI
- [ ] IAM roles created with correct policies
- [ ] Outputs display correct ARNs and names
- [ ] macOS app can assume IAM role (Phase 3 test)

## Next Steps

After Phase 2 infrastructure is deployed:
1. Deploy auth exchange Lambda function
2. Test Firebase authentication flow
3. Proceed to Phase 3 (User Story 1)

---

**Documentation**: See `/docs/phase2-execution-plan.md` for task breakdown
**Spec**: See `/specs/001-meeting-recorder-ai/plan.md` for architecture details
