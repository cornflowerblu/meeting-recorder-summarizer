# VPC Gateway Endpoints for S3 and DynamoDB
# AWS Solutions Architect Audit Recommendation - Phase 4
# 
# Benefits:
# - FREE (no additional cost)
# - No data transfer charges for S3/DynamoDB access
# - Better security (traffic stays within AWS network)
# - Improved latency

# Get route tables for the VPC
data "aws_route_tables" "vpc_routes" {
  vpc_id = local.vpc_id
}

#############################################################################
# S3 Gateway Endpoint (FREE)
#############################################################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = local.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  
  # Gateway endpoints are free and route traffic through route tables
  vpc_endpoint_type = "Gateway"
  
  # Associate with all route tables in the VPC
  route_table_ids = data.aws_route_tables.vpc_routes.ids
  
  # Endpoint policy (restrict to our bucket for security)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3Access"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.recordings.arn,
          "${aws_s3_bucket.recordings.arn}/*"
        ]
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-s3-endpoint"
    Description = "S3 VPC Gateway Endpoint (FREE)"
    Service     = "S3"
  })
}

#############################################################################
# DynamoDB Gateway Endpoint (FREE)
#############################################################################

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id       = local.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.dynamodb"
  
  # Gateway endpoints are free
  vpc_endpoint_type = "Gateway"
  
  # Associate with all route tables in the VPC
  route_table_ids = data.aws_route_tables.vpc_routes.ids
  
  # Endpoint policy (restrict to our tables for security)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowDynamoDBAccess"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem"
        ]
        Resource = [
          aws_dynamodb_table.meetings.arn,
          "${aws_dynamodb_table.meetings.arn}/index/*",
          aws_dynamodb_table.users.arn,
          "${aws_dynamodb_table.users.arn}/index/*"
        ]
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-dynamodb-endpoint"
    Description = "DynamoDB VPC Gateway Endpoint (FREE)"
    Service     = "DynamoDB"
  })
}

#############################################################################
# Outputs
#############################################################################

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 VPC Gateway Endpoint"
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_vpc_endpoint_id" {
  description = "ID of the DynamoDB VPC Gateway Endpoint"
  value       = aws_vpc_endpoint.dynamodb.id
}

output "vpc_endpoints_configured" {
  description = "Confirmation that VPC endpoints are configured"
  value       = "S3 and DynamoDB Gateway Endpoints enabled (FREE, reduces data transfer costs)"
}
