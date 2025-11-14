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
