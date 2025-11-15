# Core Variables

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "meeting-recorder"
}

# Application Configuration

variable "enable_point_in_time_recovery" {
  description = "Enable point-in-time recovery for DynamoDB"
  type        = bool
  default     = true
}

variable "use_customer_managed_kms" {
  description = "Use customer-managed KMS key for encryption (recommended for production)"
  type        = bool
  default     = false
}

variable "s3_versioning_enabled" {
  description = "Enable versioning for S3 bucket"
  type        = bool
  default     = true
}

variable "s3_lifecycle_days" {
  description = "Days before transitioning objects to Glacier"
  type        = number
  default     = 90
}

# Network Configuration for ECS

variable "vpc_id" {
  description = "VPC ID for ECS tasks (use default VPC if not specified)"
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks (use default subnets if not specified)"
  type        = list(string)
  default     = []
}

# Common Tags

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "meeting-recorder"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# Firebase Configuration

variable "firebase_project_id" {
  description = "Firebase project ID for authentication"
  type        = string
  default     = ""
}

# Tags

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
