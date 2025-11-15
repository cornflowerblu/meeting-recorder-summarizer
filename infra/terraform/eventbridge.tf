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

#############################################################################
# Phase 3.5: Chunk Upload Event Rules (T028b)
#############################################################################

# EventBridge Rule: S3 Chunk Upload → Chunk Upload Handler Lambda
resource "aws_cloudwatch_event_rule" "chunk_uploaded" {
  name        = "${local.resource_prefix}-chunk-uploaded"
  description = "Trigger chunk validation when chunk uploaded to S3"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.recordings.id]
      }
      object = {
        key = [{
          prefix = "users/",
          suffix = ".mp4"
        }]
      }
    }
  })

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-chunk-uploaded-rule"
    Description = "Chunk upload detection rule"
  })
}

# EventBridge Target: Chunk Upload Handler Lambda
resource "aws_cloudwatch_event_target" "chunk_upload_handler" {
  rule = aws_cloudwatch_event_rule.chunk_uploaded.name
  arn  = aws_lambda_function.chunk_upload_handler.arn

  # Add DLQ for failed invocations
  dead_letter_config {
    arn = aws_sqs_queue.chunk_upload_dlq.arn
  }

  # Retry configuration
  retry_policy {
    maximum_age_in_seconds = 3600 # 1 hour
    maximum_retry_attempts = 3
  }
}

# Allow EventBridge to invoke Chunk Upload Handler Lambda
resource "aws_lambda_permission" "allow_eventbridge_chunk_upload" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chunk_upload_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.chunk_uploaded.arn
}

# DLQ for failed chunk upload events (T028f)
resource "aws_sqs_queue" "chunk_upload_dlq" {
  name                       = "${local.resource_prefix}-chunk-upload-dlq"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 300

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-chunk-upload-dlq"
    Description = "Dead letter queue for failed chunk upload events"
  })
}

# SQS Queue Policy: Allow EventBridge to send messages
resource "aws_sqs_queue_policy" "chunk_upload_dlq" {
  queue_url = aws_sqs_queue.chunk_upload_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgeToSendMessage"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.chunk_upload_dlq.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.chunk_uploaded.arn
        }
      }
    }]
  })
}

# CloudWatch Alarm for DLQ depth (T028f)
resource "aws_cloudwatch_metric_alarm" "chunk_upload_dlq_depth" {
  alarm_name          = "${local.resource_prefix}-chunk-upload-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Alert when chunk upload DLQ has messages"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.chunk_upload_dlq.name
  }

  # TODO: Add SNS topic for alerts
  # alarm_actions = [aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-chunk-upload-dlq-alarm"
  })
}
