# KMS Key for DynamoDB Encryption
# Customer-managed key for enhanced security and compliance in production

resource "aws_kms_key" "dynamodb" {
  count = var.use_customer_managed_kms ? 1 : 0

  description             = "Customer-managed key for DynamoDB table encryption"
  deletion_window_in_days = var.environment == "prod" ? 30 : 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-dynamodb-key"
    Description = "Customer-managed KMS key for DynamoDB encryption"
    Service     = "DynamoDB"
  })
}

resource "aws_kms_alias" "dynamodb" {
  count = var.use_customer_managed_kms ? 1 : 0

  name          = "alias/${local.resource_prefix}-dynamodb"
  target_key_id = aws_kms_key.dynamodb[0].key_id
}

# KMS Key Policy - Allow DynamoDB service to use the key
resource "aws_kms_key_policy" "dynamodb" {
  count = var.use_customer_managed_kms ? 1 : 0

  key_id = aws_kms_key.dynamodb[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow DynamoDB to use the key"
        Effect = "Allow"
        Principal = {
          Service = "dynamodb.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "dynamodb.${var.aws_region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "Allow CloudWatch Logs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      }
    ]
  })
}
