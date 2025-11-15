# AWS Backup Configuration for DynamoDB Tables
# AWS Solutions Architect Audit Recommendation - Phase 4

# Backup Vault
resource "aws_backup_vault" "main" {
  name = "${local.resource_prefix}-backup-vault"

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-backup-vault"
    Description = "Backup vault for DynamoDB tables"
  })
}

# Backup Plan - Daily backups with 30-day retention
resource "aws_backup_plan" "dynamodb_daily" {
  name = "${local.resource_prefix}-dynamodb-daily"

  rule {
    rule_name         = "daily_backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 2 * * ? *)" # 2 AM UTC daily

    lifecycle {
      delete_after = 30 # Retain for 30 days
    }

    # Enable continuous backup (Point-in-Time Recovery)
    enable_continuous_backup = true
  }

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-dynamodb-daily"
    Description = "Daily backup plan for DynamoDB tables"
  })
}

# IAM Role for AWS Backup
resource "aws_iam_role" "backup" {
  name = "${local.resource_prefix}-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-backup-role"
  })
}

# Attach AWS managed policy for DynamoDB backup
resource "aws_iam_role_policy_attachment" "backup_dynamodb" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# Backup Selection - Include both DynamoDB tables
resource "aws_backup_selection" "dynamodb_tables" {
  name         = "${local.resource_prefix}-dynamodb-selection"
  plan_id      = aws_backup_plan.dynamodb_daily.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [
    aws_dynamodb_table.meetings.arn,
    aws_dynamodb_table.users.arn
  ]

  # Selection by tag (optional - backup all resources tagged with Backup=true)
  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "true"
  }
}

# Backup Notifications (optional)
resource "aws_sns_topic" "backup_notifications" {
  count = var.alert_email != "" ? 1 : 0

  name = "${local.resource_prefix}-backup-notifications"

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-backup-notifications"
  })
}

resource "aws_sns_topic_subscription" "backup_notifications_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.backup_notifications[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_backup_vault_notifications" "main" {
  count = var.alert_email != "" ? 1 : 0

  backup_vault_name   = aws_backup_vault.main.name
  sns_topic_arn       = aws_sns_topic.backup_notifications[0].arn
  backup_vault_events = ["BACKUP_JOB_FAILED", "RESTORE_JOB_FAILED"]
}

#############################################################################
# Outputs
#############################################################################

output "backup_vault_arn" {
  description = "ARN of the AWS Backup vault"
  value       = aws_backup_vault.main.arn
}

output "backup_plan_id" {
  description = "ID of the backup plan"
  value       = aws_backup_plan.dynamodb_daily.id
}
