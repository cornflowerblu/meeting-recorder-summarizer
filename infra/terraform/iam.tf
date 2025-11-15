# IAM Roles and Policies
# MR-16 (T009)

#############################################################################
# Firebase OIDC Identity Provider
#############################################################################

# Create OIDC identity provider for Firebase authentication
resource "aws_iam_openid_connect_provider" "firebase" {
  url = "https://securetoken.google.com/${var.firebase_project_id}"

  client_id_list = [
    var.firebase_project_id
  ]

  # Firebase uses Google's certificate
  thumbprint_list = [
    "6b67fabc6672c5aa9a583de1b1021a9ff6e5ef87" # Google root CA thumbprint
  ]

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-firebase-oidc"
    Description = "OIDC provider for Firebase authentication"
  })
}

#############################################################################
# macOS App Role (Assumed via Firebase STS Exchange)
#############################################################################

# IAM Role for macOS app (assumed via web identity/STS)
resource "aws_iam_role" "macos_app" {
  name = "${local.resource_prefix}-macos-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.firebase.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "securetoken.google.com/${var.firebase_project_id}:aud" = var.firebase_project_id
          }
        }
      }
    ]
  })

  max_session_duration = 3600 # 1 hour sessions

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-macos-app-role"
    Description = "IAM role for macOS app assumed via Firebase auth"
  })
}

# Policy for macOS app S3 access
# IMPORTANT: Uses aws:username for user isolation, which maps to RoleSessionName.
# The auth exchange Lambda MUST pass the Firebase user ID as the session name.
resource "aws_iam_role_policy" "macos_app_s3" {
  name = "s3-access"
  role = aws_iam_role.macos_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowUserPrefixOperations"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.recordings.arn}/users/$${aws:username}/*",
          "${aws_s3_bucket.recordings.arn}"
        ]
        Condition = {
          StringLike = {
            "s3:prefix" = ["users/$${aws:username}/*"]
          }
        }
      },
      {
        Sid    = "DenyNonTLS"
        Effect = "Deny"
        Action = "s3:*"
        Resource = [
          "${aws_s3_bucket.recordings.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# Policy for macOS app DynamoDB access (meetings table)
# SECURITY: Users can ONLY access items where partition key starts with their Firebase UID
# RoleSessionName is set to Firebase UID in auth_exchange Lambda
resource "aws_iam_role_policy" "macos_app_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.macos_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowUserItemOperations"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem"
        ]
        Resource = aws_dynamodb_table.meetings.arn
        Condition = {
          "ForAllValues:StringLike" = {
            "dynamodb:LeadingKeys" = ["$${aws:username}#*"]
          }
        }
      },
      {
        Sid    = "AllowUserQueryOperations"
        Effect = "Allow"
        Action = [
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.meetings.arn,
          "${aws_dynamodb_table.meetings.arn}/index/*"
        ]
        Condition = {
          "ForAllValues:StringLike" = {
            "dynamodb:LeadingKeys" = ["$${aws:username}"]
          }
        }
      }
    ]
  })
}

# Note: Users table access removed - user profile management now handled by
# user_profile Lambda via EventBridge. App only needs meetings table access.

# Policy for macOS app SSM Parameter Store access
resource "aws_iam_role_policy" "macos_app_ssm" {
  name = "ssm-parameter-access"
  role = aws_iam_role.macos_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowParameterStoreRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/${var.environment}/*"
      }
    ]
  })
}

#############################################################################
# Lambda Execution Roles
#############################################################################

# Auth Exchange Lambda Role
resource "aws_iam_role" "auth_exchange_lambda" {
  name = "${local.resource_prefix}-auth-exchange-lambda-role"

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
    Name        = "${local.resource_prefix}-auth-exchange-lambda-role"
    Description = "IAM role for Firebase auth exchange Lambda"
  })
}

# Attach AWS managed policy for Lambda basic execution
resource "aws_iam_role_policy_attachment" "auth_exchange_lambda_basic" {
  role       = aws_iam_role.auth_exchange_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attach AWS X-Ray write permissions for tracing
resource "aws_iam_role_policy_attachment" "auth_exchange_lambda_xray" {
  role       = aws_iam_role.auth_exchange_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# Policy for auth exchange Lambda to assume web identity
resource "aws_iam_role_policy" "auth_exchange_lambda_sts" {
  name = "sts-assume-role"
  role = aws_iam_role.auth_exchange_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeRoleWithWebIdentity"
        Effect = "Allow"
        Action = [
          "sts:AssumeRoleWithWebIdentity",
          "sts:GetFederationToken"
        ]
        Resource = aws_iam_role.macos_app.arn
      }
    ]
  })
}

# Policy for auth exchange Lambda to publish events to EventBridge
resource "aws_iam_role_policy" "auth_exchange_lambda_eventbridge" {
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

#############################################################################
# Processing Lambda Roles (Phase 4)
#############################################################################

# Start Processing Lambda Role
resource "aws_iam_role" "start_processing_lambda" {
  name = "${local.resource_prefix}-start-processing-lambda-role"

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
    Name        = "${local.resource_prefix}-start-processing-lambda-role"
    Description = "IAM role for start processing Lambda"
  })
}

resource "aws_iam_role_policy_attachment" "start_processing_lambda_basic" {
  role       = aws_iam_role.start_processing_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Start Transcribe Lambda Role
resource "aws_iam_role" "start_transcribe_lambda" {
  name = "${local.resource_prefix}-start-transcribe-lambda-role"

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
    Name        = "${local.resource_prefix}-start-transcribe-lambda-role"
    Description = "IAM role for start transcribe Lambda"
  })
}

resource "aws_iam_role_policy_attachment" "start_transcribe_lambda_basic" {
  role       = aws_iam_role.start_transcribe_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Bedrock Summarize Lambda Role
resource "aws_iam_role" "bedrock_summarize_lambda" {
  name = "${local.resource_prefix}-bedrock-summarize-lambda-role"

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
    Name        = "${local.resource_prefix}-bedrock-summarize-lambda-role"
    Description = "IAM role for Bedrock summarize Lambda"
  })
}

resource "aws_iam_role_policy_attachment" "bedrock_summarize_lambda_basic" {
  role       = aws_iam_role.bedrock_summarize_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Bedrock access policy
resource "aws_iam_role_policy" "bedrock_summarize_lambda_bedrock" {
  name = "bedrock-access"
  role = aws_iam_role.bedrock_summarize_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-*"
      }
    ]
  })
}

# S3 and DynamoDB access for processing Lambdas
resource "aws_iam_role_policy" "processing_lambdas_data_access" {
  for_each = toset([
    aws_iam_role.start_processing_lambda.name,
    aws_iam_role.start_transcribe_lambda.name,
    aws_iam_role.bedrock_summarize_lambda.name
  ])

  name = "data-access"
  role = each.key

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.recordings.arn,
          "${aws_s3_bucket.recordings.arn}/*"
        ]
      },
      {
        Sid    = "AllowDynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.meetings.arn,
          "${aws_dynamodb_table.meetings.arn}/index/*"
        ]
      },
      {
        Sid    = "AllowTranscribeAccess"
        Effect = "Allow"
        Action = [
          "transcribe:StartTranscriptionJob",
          "transcribe:GetTranscriptionJob",
          "transcribe:ListTranscriptionJobs"
        ]
        Resource = "*"
      }
    ]
  })
}

#############################################################################
# Data Sources
#############################################################################

data "aws_caller_identity" "current" {}

#############################################################################
# Outputs (added to outputs.tf in next commit)
#############################################################################

# These will be referenced by other resources
