# AWS Systems Manager Parameter Store
# MR-14 (T007) - Runtime configuration for macOS app

# S3 bucket name parameter
resource "aws_ssm_parameter" "s3_bucket_name" {
  name        = "/${var.project_name}/${var.environment}/s3/bucket-name"
  description = "S3 bucket name for meeting recordings"
  type        = "String"
  value       = aws_s3_bucket.recordings.id

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-s3-bucket-name-param"
    Description = "S3 bucket name for runtime config"
  })
}

# DynamoDB table name parameter
resource "aws_ssm_parameter" "dynamodb_table_name" {
  name        = "/${var.project_name}/${var.environment}/dynamodb/table-name"
  description = "DynamoDB table name for meetings metadata"
  type        = "String"
  value       = aws_dynamodb_table.meetings.name

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-dynamodb-table-name-param"
    Description = "DynamoDB table name for runtime config"
  })
}

# AWS region parameter
resource "aws_ssm_parameter" "aws_region" {
  name        = "/${var.project_name}/${var.environment}/aws/region"
  description = "AWS region for all resources"
  type        = "String"
  value       = var.aws_region

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-aws-region-param"
    Description = "AWS region for runtime config"
  })
}

# macOS app role ARN parameter
resource "aws_ssm_parameter" "macos_app_role_arn" {
  name        = "/${var.project_name}/${var.environment}/iam/macos-app-role-arn"
  description = "IAM role ARN for macOS app"
  type        = "String"
  value       = aws_iam_role.macos_app.arn

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-macos-app-role-arn-param"
    Description = "macOS app role ARN for runtime config"
  })
}

# Auth exchange Lambda ARN parameter (for future use when Lambda is deployed)
# Commented out until Lambda function is created in Phase 4
# resource "aws_ssm_parameter" "auth_exchange_lambda_url" {
#   name        = "/${var.project_name}/${var.environment}/lambda/auth-exchange-url"
#   description = "Auth exchange Lambda function URL"
#   type        = "String"
#   value       = aws_lambda_function_url.auth_exchange.function_url
#
#   tags = merge(local.common_tags, {
#     Name        = "${local.resource_prefix}-auth-exchange-url-param"
#     Description = "Auth exchange Lambda URL for runtime config"
#   })
# }
