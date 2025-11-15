# CloudWatch Alarms for Operational Monitoring
# AWS Solutions Architect Audit Recommendation - Phase 1

# SNS Topic for Operational Alerts (reuse cost alerts or create separate)
resource "aws_sns_topic" "operational_alerts" {
  name         = "${local.resource_prefix}-operational-alerts"
  display_name = "Meeting Recorder Operational Alerts"

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-operational-alerts"
    Description = "SNS topic for operational alerts (errors, failures)"
  })
}

resource "aws_sns_topic_subscription" "operational_alerts_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.operational_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

#############################################################################
# Lambda Function Alarms
#############################################################################

# Auth Exchange Lambda - Error Rate
resource "aws_cloudwatch_metric_alarm" "auth_exchange_errors" {
  alarm_name          = "${local.resource_prefix}-auth-exchange-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300 # 5 minutes
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Alert when auth exchange Lambda errors exceed 5 in 5 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.auth_exchange.function_name
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-auth-exchange-errors"
  })
}

# User Profile Lambda - Error Rate
resource "aws_cloudwatch_metric_alarm" "user_profile_errors" {
  alarm_name          = "${local.resource_prefix}-user-profile-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Alert when user profile Lambda errors exceed 3 in 5 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.user_profile.function_name
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-user-profile-errors"
  })
}

# Auth Exchange Lambda - High Duration (Latency)
resource "aws_cloudwatch_metric_alarm" "auth_exchange_duration" {
  alarm_name          = "${local.resource_prefix}-auth-exchange-slow"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Average"
  threshold           = 3000 # 3 seconds
  alarm_description   = "Alert when auth exchange Lambda average duration exceeds 3 seconds"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.auth_exchange.function_name
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-auth-exchange-slow"
  })
}

#############################################################################
# Step Functions Alarms
#############################################################################

# Step Functions - Execution Failures
resource "aws_cloudwatch_metric_alarm" "step_functions_failed" {
  alarm_name          = "${local.resource_prefix}-step-functions-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Alert when any Step Functions execution fails"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.ai_processing_pipeline.arn
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-step-functions-failed"
  })
}

# Step Functions - Execution Timeouts
resource "aws_cloudwatch_metric_alarm" "step_functions_timeout" {
  alarm_name          = "${local.resource_prefix}-step-functions-timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsTimedOut"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Alert when Step Functions execution times out"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.ai_processing_pipeline.arn
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-step-functions-timeout"
  })
}

# Step Functions - Long Running Executions
resource "aws_cloudwatch_metric_alarm" "step_functions_duration" {
  alarm_name          = "${local.resource_prefix}-step-functions-slow"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionTime"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Average"
  threshold           = 3600000 # 1 hour in milliseconds
  alarm_description   = "Alert when Step Functions execution exceeds 1 hour"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.ai_processing_pipeline.arn
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-step-functions-slow"
  })
}

#############################################################################
# DynamoDB Alarms
#############################################################################

# DynamoDB - Throttled Requests
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  alarm_name          = "${local.resource_prefix}-dynamodb-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UserErrors"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Alert when DynamoDB throttles exceed 10 in 5 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.meetings.name
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-dynamodb-throttles"
  })
}

#############################################################################
# S3 Alarms
#############################################################################

# S3 - 4xx Error Rate
resource "aws_cloudwatch_metric_alarm" "s3_4xx_errors" {
  alarm_name          = "${local.resource_prefix}-s3-4xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "4xxErrors"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Sum"
  threshold           = 50
  alarm_description   = "Alert when S3 4xx errors exceed 50 in 5 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    BucketName = aws_s3_bucket.recordings.id
    FilterId   = "EntireBucket"
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-s3-4xx-errors"
  })
}

# S3 - 5xx Error Rate
resource "aws_cloudwatch_metric_alarm" "s3_5xx_errors" {
  alarm_name          = "${local.resource_prefix}-s3-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5xxErrors"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Alert when S3 5xx errors exceed 5 in 5 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    BucketName = aws_s3_bucket.recordings.id
    FilterId   = "EntireBucket"
  }

  alarm_actions = [aws_sns_topic.operational_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-s3-5xx-errors"
  })
}

#############################################################################
# Composite Alarm (Optional) - Overall Health
#############################################################################

# Composite alarm that triggers if multiple systems are unhealthy
resource "aws_cloudwatch_composite_alarm" "system_health" {
  alarm_name          = "${local.resource_prefix}-system-health"
  alarm_description   = "Overall system health - triggers if multiple components fail"
  actions_enabled     = true
  alarm_actions       = [aws_sns_topic.operational_alerts.arn]
  ok_actions          = [aws_sns_topic.operational_alerts.arn]

  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.auth_exchange_errors.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.step_functions_failed.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.dynamodb_throttles.alarm_name})"
  ])

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-system-health"
    Description = "Composite alarm for overall system health"
  })
}

#############################################################################
# Outputs
#############################################################################

output "operational_alerts_topic_arn" {
  description = "ARN of the SNS topic for operational alerts"
  value       = aws_sns_topic.operational_alerts.arn
}
