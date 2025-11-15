# API Gateway for Auth Exchange
# HTTP API (API Gateway v2) for authentication endpoints

#############################################################################
# HTTP API
#############################################################################

resource "aws_apigatewayv2_api" "auth" {
  name          = "${local.resource_prefix}-auth-api"
  description   = "Authentication API for Firebase token exchange"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"] # TODO: Restrict to specific origins in production
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-auth-api"
    Description = "HTTP API for authentication"
  })
}

#############################################################################
# Lambda Integration
#############################################################################

resource "aws_apigatewayv2_integration" "auth_exchange" {
  api_id             = aws_apigatewayv2_api.auth.id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.auth_exchange.invoke_arn

  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

#############################################################################
# Routes
#############################################################################

resource "aws_apigatewayv2_route" "auth_exchange" {
  api_id    = aws_apigatewayv2_api.auth.id
  route_key = "POST /auth/exchange"
  target    = "integrations/${aws_apigatewayv2_integration.auth_exchange.id}"
}

#############################################################################
# Stages
#############################################################################

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.auth.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_auth.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      errorMessage   = "$context.error.message"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-auth-api-default-stage"
  })
}

# CloudWatch Log Group for API Gateway access logs
resource "aws_cloudwatch_log_group" "api_gateway_auth" {
  name              = "/aws/apigateway/${aws_apigatewayv2_api.auth.name}"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-api-gateway-auth-logs"
  })
}
