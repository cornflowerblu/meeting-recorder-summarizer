# EventBridge User Events Architecture

## Overview

Implement event-driven architecture for user authentication events using AWS EventBridge. This decouples authentication from user profile management and enables extensibility for future features.

## Architecture

```
Desktop App
  ↓
Token Exchange Lambda
  ├─→ Returns AWS credentials (synchronous)
  └─→ Emits "user.signed_in" event to EventBridge (async, fire-and-forget)

EventBridge
  ├─→ UserProfile Lambda: Create/update Users table
  ├─→ Future: Analytics Lambda
  └─→ Future: Welcome email Lambda
```

## Benefits

- **Single Responsibility**: Each Lambda has one clear purpose
- **Decoupled**: Lambdas don't depend on each other
- **Extensible**: Add features by subscribing to events, not modifying code
- **Resilient**: UserProfile failure doesn't block token exchange
- **Async**: User doesn't wait for DynamoDB writes

## Implementation Plan

### 1. EventBridge Infrastructure (Terraform)

**File**: `infra/terraform/eventbridge.tf`

```hcl
# EventBridge Event Bus
resource "aws_cloudwatch_event_bus" "auth_events" {
  name = "${local.resource_prefix}-auth-events"

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-auth-events"
    Description = "Event bus for authentication events"
  })
}

# EventBridge Rule: user.signed_in -> UserProfile Lambda
resource "aws_cloudwatch_event_rule" "user_signed_in" {
  name           = "${local.resource_prefix}-user-signed-in"
  description    = "Route user sign-in events to UserProfile Lambda"
  event_bus_name = aws_cloudwatch_event_bus.auth_events.name

  event_pattern = jsonencode({
    source      = ["interview-companion.auth"]
    detail-type = ["user.signed_in"]
  })

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-user-signed-in-rule"
  })
}

# EventBridge Target: UserProfile Lambda
resource "aws_cloudwatch_event_target" "user_profile_lambda" {
  rule           = aws_cloudwatch_event_rule.user_signed_in.name
  event_bus_name = aws_cloudwatch_event_bus.auth_events.name
  arn            = aws_lambda_function.user_profile.arn
}

# Allow EventBridge to invoke UserProfile Lambda
resource "aws_lambda_permission" "allow_eventbridge_user_profile" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.user_profile.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.user_signed_in.arn
}
```

**Update IAM**: Add EventBridge permissions to Token Exchange Lambda

```hcl
# File: infra/terraform/iam.tf
# Add to auth_exchange_lambda role

resource "aws_iam_role_policy" "auth_exchange_eventbridge" {
  name = "eventbridge-publish"
  role = aws_iam_role.auth_exchange_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Action = [
          "events:PutEvents"
        ]
        Resource = aws_cloudwatch_event_bus.auth_events.arn
      }
    ]
  })
}
```

### 2. UserProfile Lambda

**File**: `lambdas/user_profile/handler.py`

**Purpose**: Handle `user.signed_in` events and create/update Users table

**Event Schema**:

```json
{
  "version": "0",
  "id": "uuid",
  "detail-type": "user.signed_in",
  "source": "interview-companion.auth",
  "time": "2025-11-14T20:00:00Z",
  "region": "us-east-1",
  "resources": [],
  "detail": {
    "userId": "firebase_uid_abc123",
    "email": "user@example.com",
    "displayName": "John Doe",
    "photoURL": "https://...",
    "provider": "google.com",
    "timestamp": "2025-11-14T20:00:00Z"
  }
}
```

**Lambda Function**:

```python
import boto3
import os
from datetime import datetime

dynamodb = boto3.resource('dynamodb')
users_table = dynamodb.Table(os.environ['USERS_TABLE_NAME'])

def handler(event, context):
    """
    Handle user.signed_in events from EventBridge

    Creates or updates user profile in DynamoDB Users table
    """
    detail = event['detail']

    # Extract user data from event
    user_id = detail['userId']
    email = detail.get('email', '')
    display_name = detail.get('displayName')
    photo_url = detail.get('photoURL')
    provider = detail.get('provider')
    timestamp = detail['timestamp']

    # Check if user exists
    response = users_table.get_item(Key={'userId': user_id})

    # Preserve createdAt if user exists, otherwise use current timestamp
    created_at = response.get('Item', {}).get('createdAt', timestamp)

    # Build item
    item = {
        'userId': user_id,
        'email': email,
        'lastLoginDate': timestamp,
        'createdAt': created_at
    }

    # Add optional fields
    if display_name:
        item['displayName'] = display_name
    if photo_url:
        item['photoURL'] = photo_url
    if provider:
        item['provider'] = provider

    # Write to DynamoDB
    users_table.put_item(Item=item)

    print(f"User profile updated: {user_id} ({email})")

    return {
        'statusCode': 200,
        'body': f'User profile updated for {user_id}'
    }
```

**Terraform**:

```hcl
# File: infra/terraform/lambda.tf

resource "aws_lambda_function" "user_profile" {
  filename         = data.archive_file.user_profile_lambda.output_path
  function_name    = "${local.resource_prefix}-user-profile"
  role             = aws_iam_role.user_profile_lambda.arn
  handler          = "handler.handler"
  source_code_hash = data.archive_file.user_profile_lambda.output_base64sha256
  runtime          = "python3.11"
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      USERS_TABLE_NAME = aws_dynamodb_table.users.name
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-user-profile"
  })
}

data "archive_file" "user_profile_lambda" {
  type        = "zip"
  source_file = "${path.module}/../../lambdas/user_profile/handler.py"
  output_path = "${path.module}/../../.build/user_profile.zip"
}

# IAM Role
resource "aws_iam_role" "user_profile_lambda" {
  name = "${local.resource_prefix}-user-profile-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-user-profile-lambda-role"
  })
}

# Attach CloudWatch logs policy
resource "aws_iam_role_policy_attachment" "user_profile_lambda_basic" {
  role       = aws_iam_role.user_profile_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB access policy
resource "aws_iam_role_policy" "user_profile_lambda_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.user_profile_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowUsersTableAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.users.arn
      }
    ]
  })
}
```

### 3. Update Token Exchange Lambda

**File**: `lambdas/auth_exchange/handler.py`

**Add EventBridge SDK and emit event after successful token exchange**:

```python
import boto3

# Add EventBridge client
eventbridge = boto3.client('events')
EVENT_BUS_NAME = os.environ.get('EVENT_BUS_NAME', 'default')

def handler(event, context):
    # ... existing token exchange logic ...

    # After successful credential exchange
    credentials = assume_role_response['Credentials']

    # Emit user.signed_in event
    try:
        emit_user_signed_in_event(
            user_id=firebase_user_id,
            email=firebase_user_email,
            display_name=firebase_user.get('name'),
            photo_url=firebase_user.get('picture'),
            provider=firebase_user.get('firebase', {}).get('sign_in_provider')
        )
    except Exception as e:
        # Log error but don't fail the token exchange
        print(f"Failed to emit event: {e}")

    # Return credentials
    return {
        'statusCode': 200,
        'body': json.dumps({
            'credentials': {
                'AccessKeyId': credentials['AccessKeyId'],
                'SecretAccessKey': credentials['SecretAccessKey'],
                'SessionToken': credentials['SessionToken'],
                'Expiration': credentials['Expiration'].isoformat()
            }
        })
    }

def emit_user_signed_in_event(user_id, email, display_name=None, photo_url=None, provider=None):
    """Emit user.signed_in event to EventBridge"""

    detail = {
        'userId': user_id,
        'email': email,
        'timestamp': datetime.utcnow().isoformat() + 'Z'
    }

    if display_name:
        detail['displayName'] = display_name
    if photo_url:
        detail['photoURL'] = photo_url
    if provider:
        detail['provider'] = provider

    eventbridge.put_events(
        Entries=[
            {
                'Source': 'interview-companion.auth',
                'DetailType': 'user.signed_in',
                'Detail': json.dumps(detail),
                'EventBusName': EVENT_BUS_NAME
            }
        ]
    )

    print(f"Emitted user.signed_in event for {user_id}")
```

**Update Terraform to add EVENT_BUS_NAME environment variable**:

```hcl
# File: infra/terraform/lambda.tf
# Update auth_exchange Lambda environment

resource "aws_lambda_function" "auth_exchange" {
  # ... existing config ...

  environment {
    variables = {
      MACOS_APP_ROLE_ARN = aws_iam_role.macos_app.arn
      EVENT_BUS_NAME     = aws_cloudwatch_event_bus.auth_events.name  # ADD THIS
    }
  }
}
```

### 4. Desktop App Changes

**Remove UserService integration from AuthService**:

```swift
// File: macos/InterviewCompanion/InterviewCompanion/Services/AuthService.swift

// REMOVE these calls:
// try await recordUserSignIn(user: authResult.user)

// DELETE this method:
// private func recordUserSignIn(user: User) async throws { ... }
```

**Keep UserService.swift for future direct queries if needed**, but don't call it during auth.

## Event Schema Standards

All authentication events follow this schema:

```json
{
  "source": "interview-companion.auth",
  "detail-type": "user.{action}",
  "detail": {
    "userId": "string",
    "email": "string",
    "timestamp": "ISO8601"
    // ... action-specific fields
  }
}
```

**Current Events**:

- `user.signed_in`: User authenticated successfully

**Future Events**:

- `user.signed_out`: User signed out
- `user.credentials_refreshed`: AWS credentials refreshed
- `user.profile_updated`: User updated their profile

## Testing

### Test EventBridge Flow

```bash
# 1. Send test event to EventBridge
aws events put-events \
  --entries '[{
    "Source": "interview-companion.auth",
    "DetailType": "user.signed_in",
    "Detail": "{\"userId\":\"test-123\",\"email\":\"test@example.com\",\"timestamp\":\"2025-11-14T20:00:00Z\"}"
  }]'

# 2. Check UserProfile Lambda logs
aws logs tail /aws/lambda/meeting-recorder-dev-user-profile --follow

# 3. Verify DynamoDB Users table
aws dynamodb get-item \
  --table-name meeting-recorder-dev-users \
  --key '{"userId": {"S": "test-123"}}'
```

### Integration Test

1. Sign in to desktop app
2. Check CloudWatch logs for token exchange Lambda
3. Verify event was emitted
4. Check UserProfile Lambda was invoked
5. Verify Users table contains user record

## Rollout Plan

1. **Deploy Infrastructure**: Terraform apply (EventBridge, UserProfile Lambda)
2. **Deploy Lambda Code**: Update auth_exchange Lambda to emit events
3. **Test**: Verify events flow through system
4. **Deploy App**: Remove UserService calls from desktop app
5. **Monitor**: Watch CloudWatch for any errors

## Future Extensions

### Analytics Lambda

Subscribe to `user.signed_in` events to track:

- Daily/monthly active users
- Sign-in frequency
- Provider distribution (Google vs Email)

### Welcome Email Lambda

Send welcome email on first sign-in:

- Check if `createdAt == timestamp` (first sign-in)
- Send personalized welcome email via SES

### Security Monitoring Lambda

Track unusual sign-in patterns:

- Multiple sign-ins from different IPs
- Sign-ins from new countries
- Rapid credential refresh attempts

## Costs

- EventBridge: $1.00 per million events ($0.000001 per event)
- UserProfile Lambda: ~1ms execution time, negligible cost
- DynamoDB: On-demand, ~$1.25 per million writes

**Estimated cost for 10,000 sign-ins/month**: ~$0.02

## References

- [AWS EventBridge Documentation](https://docs.aws.amazon.com/eventbridge/)
- [Lambda Event Source Mappings](https://docs.aws.amazon.com/lambda/latest/dg/invocation-eventsourcemapping.html)
- [EventBridge Event Patterns](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-patterns.html)
