# Cost Monitoring and Anomaly Detection
# AWS Solutions Architect Audit Recommendation - Phase 1

# SNS Topic for Cost Alerts
resource "aws_sns_topic" "cost_alerts" {
  name         = "${local.resource_prefix}-cost-alerts"
  display_name = "Meeting Recorder Cost Alerts"

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-cost-alerts"
    Description = "SNS topic for cost anomaly alerts"
  })
}

# SNS Topic Subscription (email - must be confirmed manually)
resource "aws_sns_topic_subscription" "cost_alerts_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Cost Anomaly Monitor - Monitor all services
resource "aws_ce_anomaly_monitor" "service_monitor" {
  name              = "${local.resource_prefix}-cost-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-cost-monitor"
    Description = "Cost anomaly detection for all services"
  })
}

# Cost Anomaly Subscription - Alert on 50% increase
resource "aws_ce_anomaly_subscription" "cost_alerts" {
  name      = "${local.resource_prefix}-cost-alerts"
  frequency = "DAILY"

  monitor_arn_list = [
    aws_ce_anomaly_monitor.service_monitor.arn
  ]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_PERCENTAGE"
      values        = ["50"] # Alert if cost increases by 50% or more
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-cost-alerts"
    Description = "Alert on 50%+ cost anomalies"
  })
}

# Budget for monthly spending cap
resource "aws_budgets_budget" "monthly_budget" {
  name         = "${local.resource_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80 # Alert at 80% of budget
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100 # Alert at 100% of budget
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90 # Forecast alert at 90%
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }

  cost_filters = {
    TagKeyValue = "Project$${var.project_name}"
  }

  depends_on = [aws_sns_topic.cost_alerts]
}

# Outputs
output "cost_alerts_topic_arn" {
  description = "ARN of the SNS topic for cost alerts"
  value       = aws_sns_topic.cost_alerts.arn
}

output "cost_anomaly_monitor_arn" {
  description = "ARN of the cost anomaly monitor"
  value       = aws_ce_anomaly_monitor.service_monitor.arn
}
