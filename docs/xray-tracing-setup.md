# AWS X-Ray Tracing Implementation Plan

## Overview

This document outlines the implementation plan for AWS X-Ray distributed tracing across the Interview Companion event-driven architecture.

## Current State

- **No X-Ray configuration exists** in any Lambda, IAM, or Terraform files
- Event-driven architecture with EventBridge connecting auth_exchange → user_profile Lambdas
- Cost impact: **$0/month** (well within 100k free tier traces)

## Architecture Components Requiring Tracing

### Currently Deployed

**Lambda Functions:**
- `auth_exchange` - Firebase ID token to AWS credentials exchange
- `user_profile` - Handle user.signed_in events from EventBridge

**AWS Services:**
- API Gateway (HTTP API v2) - `/auth/exchange` endpoint
- EventBridge - `auth-events` custom event bus
- DynamoDB - `meetings` and `users` tables
- S3 - `recordings` bucket

### Future (Phase 4)

- Step Functions - Processing pipeline orchestration
- Additional Lambdas: `start_processing`, `start_transcribe`, `bedrock_summarize`
- Amazon Transcribe - Batch transcription jobs
- Amazon Bedrock - Claude Sonnet 4.5 summarization

## Phase 1: Enable Lambda X-Ray Tracing (Immediate)

### 1. Update Lambda Terraform Configuration

**File:** `infra/terraform/lambda.tf`

Add tracing configuration to both Lambda functions:

```hcl
# auth_exchange Lambda - Add tracing config
resource "aws_lambda_function" "auth_exchange" {
  # ... existing configuration ...

  tracing_config {
    mode = "Active"  # "Active" or "PassThrough"
  }
}

# user_profile Lambda - Add tracing config
resource "aws_lambda_function" "user_profile" {
  # ... existing configuration ...

  tracing_config {
    mode = "Active"
  }
}
```

### 2. Add X-Ray IAM Permissions

**File:** `infra/terraform/iam.tf`

Add X-Ray write permissions to Lambda execution roles:

```hcl
# X-Ray write permissions for auth_exchange Lambda
resource "aws_iam_role_policy_attachment" "auth_exchange_lambda_xray" {
  role       = aws_iam_role.auth_exchange_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# X-Ray write permissions for user_profile Lambda
resource "aws_iam_role_policy_attachment" "user_profile_lambda_xray" {
  role       = aws_iam_role.user_profile_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
```

### 3. Add Python X-Ray SDK Dependency

**Files:**
- `processing/lambdas/requirements.txt`
- `processing/lambdas/auth_exchange/requirements.txt`

Add the following dependency:

```
aws-xray-sdk>=2.12.0
```

### 4. Instrument Lambda Code

#### auth_exchange Lambda

**File:** `processing/lambdas/auth_exchange/handler.py`

```python
# Add at top of file after existing imports
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch all AWS SDK calls (boto3) - auto-traces STS, EventBridge, etc.
patch_all()

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Exchange Firebase ID token for temporary AWS credentials."""
    try:
        # ... existing parsing and validation ...

        # Custom subsegment for STS call
        with xray_recorder.capture('sts_assume_role'):
            response = sts_client.assume_role_with_web_identity(
                RoleArn=MACOS_APP_ROLE_ARN,
                RoleSessionName=session_name,
                WebIdentityToken=id_token,
                DurationSeconds=SESSION_DURATION,
            )

        credentials = response['Credentials']

        # Custom subsegment for EventBridge
        with xray_recorder.capture('emit_user_signed_in_event'):
            _emit_user_signed_in_event(
                user_id=session_name,
                email=email,
                display_name=display_name,
                photo_url=photo_url,
                provider=provider
            )

        # Add searchable annotations
        xray_recorder.put_annotation('user_id', session_name)
        xray_recorder.put_annotation('auth_result', 'success')

        # Add metadata (not searchable, but visible in trace details)
        if provider:
            xray_recorder.put_metadata('firebase_provider', provider)

        return _success_response(credentials, response['AssumedRoleUser'])

    except ValueError as e:
        xray_recorder.put_annotation('auth_result', 'validation_error')
        xray_recorder.put_annotation('error_type', 'ValueError')
        return _error_response(400, str(e))

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        xray_recorder.put_annotation('auth_result', 'failure')
        xray_recorder.put_annotation('error_code', error_code)
        # ... existing error handling ...
```

#### user_profile Lambda

**File:** `processing/lambdas/user_profile/handler.py`

```python
# Add at top of file
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch all AWS SDK calls (auto-traces DynamoDB)
patch_all()

def handler(event, context):
    """Handle user.signed_in events from EventBridge."""
    detail = event.get('detail', {})
    user_id = detail.get('userId')
    email = detail.get('email', '')
    timestamp = detail.get('timestamp')

    # Add searchable annotation
    xray_recorder.put_annotation('user_id', user_id)
    xray_recorder.put_annotation('event_source', 'EventBridge')

    # Check if user exists (DynamoDB call auto-traced by patch_all)
    with xray_recorder.capture('dynamodb_get_user'):
        response = users_table.get_item(Key={'userId': user_id})

    existing_user = response.get('Item')
    created_at = existing_user.get('createdAt') if existing_user else timestamp
    is_new_user = existing_user is None

    # Add annotation for whether this is a new user
    xray_recorder.put_annotation('action', 'created' if is_new_user else 'updated')

    # Build user item
    item = {
        'userId': user_id,
        'email': email,
        'lastLoginDate': timestamp,
        'createdAt': created_at
    }

    # Add optional fields
    if display_name := detail.get('displayName'):
        item['displayName'] = display_name
    if photo_url := detail.get('photoURL'):
        item['photoURL'] = photo_url
    if provider := detail.get('provider'):
        item['provider'] = provider

    # Write to DynamoDB (auto-traced)
    with xray_recorder.capture('dynamodb_put_user'):
        users_table.put_item(Item=item)

    # Add metadata
    xray_recorder.put_metadata('user_email', email)

    print(f"User profile {'created' if is_new_user else 'updated'}: {user_id} ({email})")

    return {
        'statusCode': 200,
        'body': f'User profile updated for {user_id}'
    }
```

### 5. Deploy Changes

**Steps:**

1. **Rebuild Lambda deployment packages** with new dependency:
   ```bash
   cd processing/lambdas/auth_exchange
   pip install -r requirements.txt -t .
   zip -r deployment.zip .
   ```

2. **Apply Terraform changes**:
   ```bash
   cd infra/terraform
   terraform plan
   terraform apply
   ```

3. **Test auth flow**:
   - Sign in to the macOS app
   - Triggers auth_exchange Lambda
   - Emits EventBridge event
   - Triggers user_profile Lambda

4. **Verify traces in AWS X-Ray console**:
   - Open AWS Console → X-Ray → Service Map
   - Should see: API Gateway → Lambda (auth_exchange) → EventBridge → Lambda (user_profile) → DynamoDB

## What You'll Get

### End-to-End Trace Visibility

**Authentication Flow:**
```
API Gateway Request
  └─ auth_exchange Lambda
      ├─ STS AssumeRoleWithWebIdentity (custom subsegment)
      ├─ EventBridge PutEvents (custom subsegment)
      └─ Response

EventBridge Rule Trigger
  └─ user_profile Lambda
      ├─ DynamoDB GetItem - Users table (auto-traced)
      ├─ DynamoDB PutItem - Users table (auto-traced)
      └─ Response
```

### Searchable Annotations

Filter traces by:
- `user_id` - Firebase UID
- `auth_result` - success/failure/validation_error
- `error_code` - InvalidIdentityToken, ExpiredTokenException, etc.
- `action` - created/updated (for user profile)
- `event_source` - EventBridge

### Service Map

Visual dependency graph showing:
- API Gateway → auth_exchange Lambda
- auth_exchange → STS
- auth_exchange → EventBridge
- EventBridge → user_profile Lambda
- user_profile → DynamoDB Users table

### Performance Insights

- Lambda cold start vs warm start duration
- STS AssumeRoleWithWebIdentity latency
- EventBridge event delivery time
- DynamoDB query performance (GetItem, PutItem)
- End-to-end authentication flow duration

### Error Tracking

- Automatic capture of exceptions with stack traces
- Error rate by annotation (e.g., all `auth_result=failure` traces)
- Throttling and retry visualization

## Cost Analysis

### AWS X-Ray Pricing (2025)

**Free Tier (Monthly):**
- First 100,000 traces recorded: **FREE**
- First 1,000,000 traces retrieved/scanned: **FREE**

**Pay-As-You-Go:**
- Traces recorded: **$5.00 per million traces** ($0.000005 per trace)
- Traces retrieved: **$0.50 per million traces**
- Traces scanned: **$0.50 per million traces**

### Cost Estimation

**MVP (1 user - Roger):**
```
Monthly Traces:
- Auth flows: 40 meetings × 1 trace = 40 traces
- User profile events: 40 meetings × 1 trace = 40 traces
- Catalog queries: ~100 searches = 100 traces
─────────────────────────────────────────────────
Total: ~180 traces/month

Cost: $0.00/month (within free tier)
```

**Small Scale (100 users):**
```
Monthly Traces:
- Auth: 4,000 traces
- User profiles: 4,000 traces
- Queries: 10,000 traces
─────────────────────────────────────────────────
Total: ~18,000 traces/month

Cost: $0.00/month (within free tier)
```

**Production Scale (1,000 users):**
```
Monthly Traces:
- Auth: 40,000 traces
- Processing (future): 200,000 traces
- Queries: 100,000 traces
─────────────────────────────────────────────────
Total: ~340,000 traces/month
Billable: 340,000 - 100,000 = 240,000 traces

Cost: 240,000 × $0.000005 = $1.20/month
```

**Verdict:** X-Ray cost is **NEGLIGIBLE** for MVP and small-scale usage.

## Testing After Deployment

### 1. Test Authentication Flow

```bash
# Sign in to the macOS app
# This triggers the full auth flow
```

### 2. View Traces in AWS X-Ray Console

**Service Map:**
1. AWS Console → X-Ray → Service Map
2. Select time range: Last 5 minutes
3. Verify connections: API Gateway → Lambda → EventBridge → Lambda → DynamoDB

**Traces:**
1. X-Ray → Traces
2. Filter by annotation: `user_id = "your-firebase-uid"`
3. Click on a trace to see detailed timeline
4. Verify custom subsegments appear: `sts_assume_role`, `emit_user_signed_in_event`, `dynamodb_get_user`, `dynamodb_put_user`

**Analytics:**
1. X-Ray → Analytics
2. Group by: `auth_result`
3. View error rate distribution
4. Check p50, p90, p99 latencies

### 3. Verify Annotations

Search for traces using:
- `annotation.user_id = "abc123"`
- `annotation.auth_result = "failure"`
- `annotation.error_code = "InvalidIdentityToken"`

### 4. Check Service Map Dependencies

Verify automatic detection of:
- STS service calls
- EventBridge integration
- DynamoDB table access (Users table)

## Optional Enhancements (Future)

### Sampling Rules for Cost Control

**File:** `infra/terraform/xray.tf` (new file)

```hcl
# X-Ray Sampling Rule for cost control
resource "aws_xray_sampling_rule" "default" {
  rule_name      = "${local.resource_prefix}-default-sampling"
  priority       = 1000
  version        = 1
  reservoir_size = 1  # Always trace first request per second
  fixed_rate     = 0.05  # Then sample 5% of additional requests
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-xray-sampling"
  })
}

# High-priority sampling for auth flow
resource "aws_xray_sampling_rule" "auth_flow" {
  rule_name      = "${local.resource_prefix}-auth-sampling"
  priority       = 100
  version        = 1
  reservoir_size = 5
  fixed_rate     = 0.10  # Sample 10% of auth requests
  url_path       = "/auth/*"
  host           = "*"
  http_method    = "POST"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-auth-xray-sampling"
  })
}
```

### API Gateway Detailed Metrics

**File:** `infra/terraform/api_gateway.tf`

```hcl
resource "aws_apigatewayv2_stage" "default" {
  # ... existing configuration ...

  default_route_settings {
    throttling_burst_limit   = 100
    throttling_rate_limit    = 50
    detailed_metrics_enabled = true  # Enable detailed metrics
  }
}
```

### Step Functions Tracing (Phase 4)

When implementing the processing pipeline:

```hcl
resource "aws_sfn_state_machine" "processing_pipeline" {
  name     = "${local.resource_prefix}-processing-pipeline"
  role_arn = aws_iam_role.step_functions.arn

  tracing_configuration {
    enabled = true
  }

  # ... state machine definition ...
}

# Add X-Ray permissions to Step Functions role
resource "aws_iam_role_policy_attachment" "step_functions_xray" {
  role       = aws_iam_role.step_functions.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
```

## Troubleshooting

### No traces appearing in X-Ray console

**Check:**
1. Lambda has `tracing_config { mode = "Active" }`
2. Lambda execution role has `AWSXRayDaemonWriteAccess` policy attached
3. Lambda code has `patch_all()` called at module level
4. Lambda function was invoked (check CloudWatch Logs)
5. Wait 1-2 minutes for traces to propagate to X-Ray console

### Traces appear but missing subsegments

**Check:**
1. Custom subsegments are wrapped in `with xray_recorder.capture('name'):`
2. No exceptions are being silently caught that skip subsegment code
3. Lambda timeout isn't interrupting subsegment creation

### "Subsegment not found" errors in Lambda logs

**Fix:**
- Ensure `patch_all()` is called **before** creating boto3 clients
- Move boto3 client initialization to after `patch_all()`

### High X-Ray costs

**Solutions:**
1. Implement sampling rules (5% fixed_rate reduces cost by 95%)
2. Disable tracing in non-prod environments
3. Use conditional tracing (only trace errors/slow requests)
4. Set shorter trace retention period

## References

- [AWS X-Ray Developer Guide](https://docs.aws.amazon.com/xray/latest/devguide/)
- [X-Ray Python SDK Documentation](https://docs.aws.amazon.com/xray-sdk-for-python/latest/reference/)
- [X-Ray Pricing](https://aws.amazon.com/xray/pricing/)
- [Lambda X-Ray Integration](https://docs.aws.amazon.com/lambda/latest/dg/services-xray.html)
- [EventBridge X-Ray Tracing](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-monitoring.html)
