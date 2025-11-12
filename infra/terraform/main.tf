terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.17.0"  # Compatible with Terraform 1.5.7
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "s3" {
    bucket         = "meeting-recorder-terraform-state"
    key            = "meeting-recorder/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "meeting-recorder-terraform-lock"
    profile        = "admin"
  }
}

# AWS Provider Configuration
provider "aws" {
  region = var.aws_region
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
