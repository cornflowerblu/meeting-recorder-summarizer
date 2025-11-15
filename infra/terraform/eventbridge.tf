# AWS EventBridge for Authentication Events
# Event-driven architecture for user authentication flows

# EventBridge Event Bus for Authentication Events
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
    Name        = "${local.resource_prefix}-user-signed-in-rule"
    Description = "Route user.signed_in events to UserProfile Lambda"
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

# Output EventBridge event bus ARN for use in other resources
output "auth_event_bus_arn" {
  description = "ARN of the authentication events EventBridge bus"
  value       = aws_cloudwatch_event_bus.auth_events.arn
}

output "auth_event_bus_name" {
  description = "Name of the authentication events EventBridge bus"
  value       = aws_cloudwatch_event_bus.auth_events.name
}
