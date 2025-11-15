# Infrastructure Outputs

output "aws_region" {
  description = "AWS region where resources are deployed"
  value       = var.aws_region
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

# S3 Outputs (will be populated by s3.tf)

output "recordings_bucket_name" {
  description = "Name of the S3 bucket for meeting recordings"
  value       = try(aws_s3_bucket.recordings.id, "")
}

output "recordings_bucket_arn" {
  description = "ARN of the S3 bucket for meeting recordings"
  value       = try(aws_s3_bucket.recordings.arn, "")
}

# DynamoDB Outputs (will be populated by dynamodb.tf)

output "meetings_table_name" {
  description = "Name of the DynamoDB meetings table"
  value       = try(aws_dynamodb_table.meetings.name, "")
}

output "meetings_table_arn" {
  description = "ARN of the DynamoDB meetings table"
  value       = try(aws_dynamodb_table.meetings.arn, "")
}

# IAM Outputs (will be populated by iam.tf)

output "macos_app_role_arn" {
  description = "ARN of the IAM role for macOS app"
  value       = try(aws_iam_role.macos_app.arn, "")
}

output "auth_exchange_lambda_role_arn" {
  description = "ARN of the IAM role for auth exchange Lambda"
  value       = try(aws_iam_role.auth_exchange_lambda.arn, "")
}

# Lambda Outputs

output "auth_exchange_lambda_arn" {
  description = "ARN of the Firebase auth exchange Lambda function"
  value       = try(aws_lambda_function.auth_exchange.arn, "")
}

output "auth_exchange_lambda_name" {
  description = "Name of the Firebase auth exchange Lambda function"
  value       = try(aws_lambda_function.auth_exchange.function_name, "")
}

# API Gateway Outputs

output "auth_api_endpoint" {
  description = "HTTPS endpoint URL for the auth API"
  value       = try(aws_apigatewayv2_api.auth.api_endpoint, "")
}

output "auth_exchange_url" {
  description = "Full URL for the auth exchange endpoint (use this in the macOS app)"
  value       = try("${aws_apigatewayv2_api.auth.api_endpoint}/auth/exchange", "")
}

# KMS Outputs

output "dynamodb_kms_key_id" {
  description = "ID of the KMS key used for DynamoDB encryption (empty if using AWS-managed key)"
  value       = var.use_customer_managed_kms ? aws_kms_key.dynamodb[0].id : ""
}

output "dynamodb_kms_key_arn" {
  description = "ARN of the KMS key used for DynamoDB encryption (empty if using AWS-managed key)"
  value       = var.use_customer_managed_kms ? aws_kms_key.dynamodb[0].arn : ""
}

# SSM Parameter Store Outputs

output "ssm_parameter_prefix" {
  description = "SSM Parameter Store prefix for runtime configuration"
  value       = "/${var.project_name}/${var.environment}"
}

output "ssm_s3_bucket_name_parameter" {
  description = "SSM parameter name for S3 bucket"
  value       = aws_ssm_parameter.s3_bucket_name.name
}

output "ssm_dynamodb_table_name_parameter" {
  description = "SSM parameter name for DynamoDB table"
  value       = aws_ssm_parameter.dynamodb_table_name.name
}

output "ssm_aws_region_parameter" {
  description = "SSM parameter name for AWS region"
  value       = aws_ssm_parameter.aws_region.name
}
