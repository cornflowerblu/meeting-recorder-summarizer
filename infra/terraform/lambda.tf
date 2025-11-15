# Lambda Functions
# Auth Exchange Lambda for Firebase token exchange

#############################################################################
# Auth Exchange Lambda
#############################################################################

# Lambda function for Firebase ID token to AWS credentials exchange
resource "aws_lambda_function" "auth_exchange" {
  function_name = "${local.resource_prefix}-auth-exchange"
  description   = "Exchange Firebase ID tokens for AWS temporary credentials"
  role          = aws_iam_role.auth_exchange_lambda.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.11"
  timeout       = 30
  memory_size   = 256

  # Lambda deployment package (ZIP file with code + dependencies)
  filename         = "${path.module}/../../processing/lambdas/auth_exchange/deployment.zip"
  source_code_hash = fileexists("${path.module}/../../processing/lambdas/auth_exchange/deployment.zip") ? filebase64sha256("${path.module}/../../processing/lambdas/auth_exchange/deployment.zip") : null

  environment {
    variables = {
      MACOS_APP_ROLE_ARN = aws_iam_role.macos_app.arn
      SESSION_DURATION   = "3600" # 1 hour
      LOG_LEVEL          = var.environment == "prod" ? "INFO" : "DEBUG"
      EVENT_BUS_NAME     = aws_cloudwatch_event_bus.auth_events.name
    }
  }

  # Enable AWS X-Ray tracing for observability
  tracing_config {
    mode = "Active" # Active tracing mode creates trace for every request
  }

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-auth-exchange"
    Description = "Firebase auth token exchange"
  })
}

# CloudWatch Log Group for auth exchange Lambda
resource "aws_cloudwatch_log_group" "auth_exchange" {
  name              = "/aws/lambda/${aws_lambda_function.auth_exchange.function_name}"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-auth-exchange-logs"
  })
}

# Lambda permission for API Gateway to invoke
resource "aws_lambda_permission" "auth_exchange_api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_exchange.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.auth.execution_arn}/*/*"
}

#############################################################################
# UserProfile Lambda (EventBridge consumer)
#############################################################################

# Lambda function for handling user.signed_in events
resource "aws_lambda_function" "user_profile" {
  function_name = "${local.resource_prefix}-user-profile"
  description   = "Handle user.signed_in events and update Users table"
  role          = aws_iam_role.user_profile_lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  timeout       = 10
  memory_size   = 256

  # Lambda deployment package (ZIP file with code + dependencies)
  filename         = "${path.module}/../../processing/lambdas/user_profile/deployment.zip"
  source_code_hash = fileexists("${path.module}/../../processing/lambdas/user_profile/deployment.zip") ? filebase64sha256("${path.module}/../../processing/lambdas/user_profile/deployment.zip") : null

  environment {
    variables = {
      USERS_TABLE_NAME = aws_dynamodb_table.users.name
      LOG_LEVEL        = var.environment == "prod" ? "INFO" : "DEBUG"
    }
  }

  # Enable AWS X-Ray tracing for observability
  tracing_config {
    mode = "Active" # Active tracing mode creates trace for every request
  }

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-user-profile"
    Description = "EventBridge consumer for user events"
  })
}

# CloudWatch Log Group for UserProfile Lambda
resource "aws_cloudwatch_log_group" "user_profile" {
  name              = "/aws/lambda/${aws_lambda_function.user_profile.function_name}"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-user-profile-logs"
  })
}

# IAM Role for UserProfile Lambda
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
    Name        = "${local.resource_prefix}-user-profile-lambda-role"
    Description = "IAM role for UserProfile Lambda"
  })
}

# Attach CloudWatch Logs policy to UserProfile Lambda
resource "aws_iam_role_policy_attachment" "user_profile_lambda_basic" {
  role       = aws_iam_role.user_profile_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attach AWS X-Ray write permissions for tracing
resource "aws_iam_role_policy_attachment" "user_profile_lambda_xray" {
  role       = aws_iam_role.user_profile_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# DynamoDB access policy for UserProfile Lambda
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

#############################################################################
# Phase 3.5: Chunk Upload Handler Lambda (T028c)
#############################################################################

resource "aws_lambda_function" "chunk_upload_handler" {
  function_name = "${local.resource_prefix}-chunk-upload-handler"
  description   = "Validate and track chunk uploads from S3 events"
  role          = aws_iam_role.chunk_upload_handler_lambda.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.11"
  timeout       = 30
  memory_size   = 256

  filename         = "${path.module}/../../processing/lambdas/chunk_upload_handler/deployment.zip"
  source_code_hash = fileexists("${path.module}/../../processing/lambdas/chunk_upload_handler/deployment.zip") ? filebase64sha256("${path.module}/../../processing/lambdas/chunk_upload_handler/deployment.zip") : null

  environment {
    variables = {
      CHUNKS_TABLE_NAME            = aws_dynamodb_table.chunks.name
      MEETINGS_TABLE_NAME          = aws_dynamodb_table.meetings.name
      SESSION_COMPLETION_LAMBDA_ARN = aws_lambda_function.session_completion_detector.arn
      LOG_LEVEL                    = var.environment == "prod" ? "INFO" : "DEBUG"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-chunk-upload-handler"
    Description = "Chunk upload validation"
  })
}

resource "aws_cloudwatch_log_group" "chunk_upload_handler" {
  name              = "/aws/lambda/${aws_lambda_function.chunk_upload_handler.function_name}"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-chunk-upload-handler-logs"
  })
}

# IAM Role for Chunk Upload Handler
resource "aws_iam_role" "chunk_upload_handler_lambda" {
  name = "${local.resource_prefix}-chunk-upload-handler-lambda-role"

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
    Name = "${local.resource_prefix}-chunk-upload-handler-lambda-role"
  })
}

resource "aws_iam_role_policy_attachment" "chunk_upload_handler_basic" {
  role       = aws_iam_role.chunk_upload_handler_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "chunk_upload_handler_xray" {
  role       = aws_iam_role.chunk_upload_handler_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# DynamoDB and Lambda invoke permissions
resource "aws_iam_role_policy" "chunk_upload_handler_permissions" {
  name = "chunk-upload-handler-permissions"
  role = aws_iam_role.chunk_upload_handler_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          aws_dynamodb_table.chunks.arn,
          aws_dynamodb_table.meetings.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectMetadata"
        ]
        Resource = "${aws_s3_bucket.recordings.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.session_completion_detector.arn
      }
    ]
  })
}

#############################################################################
# Phase 3.5: Session Completion Detector Lambda (T028d)
#############################################################################

resource "aws_lambda_function" "session_completion_detector" {
  function_name = "${local.resource_prefix}-session-completion-detector"
  description   = "Detect when all chunks uploaded and trigger processing"
  role          = aws_iam_role.session_completion_detector_lambda.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.11"
  timeout       = 60
  memory_size   = 512

  filename         = "${path.module}/../../processing/lambdas/session_completion_detector/deployment.zip"
  source_code_hash = fileexists("${path.module}/../../processing/lambdas/session_completion_detector/deployment.zip") ? filebase64sha256("${path.module}/../../processing/lambdas/session_completion_detector/deployment.zip") : null

  environment {
    variables = {
      CHUNKS_TABLE_NAME   = aws_dynamodb_table.chunks.name
      MEETINGS_TABLE_NAME = aws_dynamodb_table.meetings.name
      LOG_LEVEL           = var.environment == "prod" ? "INFO" : "DEBUG"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-session-completion-detector"
    Description = "Session completion detection"
  })
}

resource "aws_cloudwatch_log_group" "session_completion_detector" {
  name              = "/aws/lambda/${aws_lambda_function.session_completion_detector.function_name}"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-session-completion-detector-logs"
  })
}

# IAM Role for Session Completion Detector
resource "aws_iam_role" "session_completion_detector_lambda" {
  name = "${local.resource_prefix}-session-completion-detector-lambda-role"

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
    Name = "${local.resource_prefix}-session-completion-detector-lambda-role"
  })
}

resource "aws_iam_role_policy_attachment" "session_completion_detector_basic" {
  role       = aws_iam_role.session_completion_detector_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "session_completion_detector_xray" {
  role       = aws_iam_role.session_completion_detector_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# DynamoDB and Step Functions permissions
resource "aws_iam_role_policy" "session_completion_detector_permissions" {
  name = "session-completion-detector-permissions"
  role = aws_iam_role.session_completion_detector_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          aws_dynamodb_table.chunks.arn,
          aws_dynamodb_table.meetings.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.ai_processing_pipeline.arn
      }
    ]
  })
}
