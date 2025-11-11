terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # Backend configuration for state management
  # Uncomment and configure after initial setup
  # backend "s3" {
  #   bucket         = "meeting-recorder-terraform-state"
  #   key            = "meeting-recorder/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "meeting-recorder-terraform-lock"
  # }
}

# AWS Provider Configuration
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "MeetingRecorder"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

# Random provider for unique resource naming
provider "random" {}

# Generate unique suffix for globally unique resource names
resource "random_id" "suffix" {
  byte_length = 4
}

# Local values for resource naming
locals {
  resource_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Repository  = "meeting-recorder-summarizer"
  }
}
