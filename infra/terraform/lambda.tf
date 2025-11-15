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
  runtime       = "python3.12"
  timeout       = 10
  memory_size   = 256

  # Lambda deployment package
  filename         = data.archive_file.user_profile_lambda.output_path
  source_code_hash = data.archive_file.user_profile_lambda.output_base64sha256

  environment {
    variables = {
      USERS_TABLE_NAME = aws_dynamodb_table.users.name
      LOG_LEVEL        = var.environment == "prod" ? "INFO" : "DEBUG"
    }
  }

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-user-profile"
    Description = "EventBridge consumer for user events"
  })
}

# Package UserProfile Lambda code
data "archive_file" "user_profile_lambda" {
  type        = "zip"
  source_file = "${path.module}/../../processing/lambdas/user_profile/handler.py"
  output_path = "${path.module}/../../.build/user_profile.zip"
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
