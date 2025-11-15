# S3 Bucket for Meeting Recordings and Artifacts
# MR-14 (T007)

# S3 Bucket
resource "aws_s3_bucket" "recordings" {
  bucket = "${local.resource_prefix}-recordings-${random_id.suffix.hex}"

  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-recordings"
    Description = "Meeting recordings transcripts and summaries"
  })
}

# Enable Versioning
resource "aws_s3_bucket_versioning" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  versioning_configuration {
    status = var.s3_versioning_enabled ? "Enabled" : "Suspended"
  }
}

# Enable Server-Side Encryption (SSE-S3)
resource "aws_s3_bucket_server_side_encryption_configuration" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block Public Access
resource "aws_s3_bucket_public_access_block" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle Configuration
resource "aws_s3_bucket_lifecycle_configuration" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  rule {
    id     = "intelligent-tiering"
    status = "Enabled"

    # Transition to Standard-IA after 30 days
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # Transition to One Zone-IA after 60 days
    transition {
      days          = 60
      storage_class = "ONEZONE_IA"
    }

    # Transition to Glacier after 90 days (configurable)
    transition {
      days          = var.s3_lifecycle_days
      storage_class = "GLACIER"
    }

    # Optional: Deep Archive after 180 days for long-term storage
    transition {
      days          = 180
      storage_class = "DEEP_ARCHIVE"
    }

    filter {
      prefix = "users/"
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    filter {}
  }
}

# Bucket Policy - TLS Only + User Prefix Enforcement
resource "aws_s3_bucket_policy" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.recordings.arn,
          "${aws_s3_bucket.recordings.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "DenyUnencryptedObjectUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.recordings.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "AES256"
          }
        }
      }
    ]
  })
}

# CORS Configuration (for web-based access if needed in future)
resource "aws_s3_bucket_cors_configuration" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = ["*"] # Restrict this in production
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# CloudWatch Logging (optional, enabled for monitoring)
resource "aws_s3_bucket_logging" "recordings" {
  count = var.environment == "prod" ? 1 : 0

  bucket = aws_s3_bucket.recordings.id

  target_bucket = aws_s3_bucket.recordings.id
  target_prefix = "logs/s3-access/"
}

# EventBridge Notifications (T028a)
# Enable EventBridge for chunk upload events
resource "aws_s3_bucket_notification" "recordings_eventbridge" {
  bucket      = aws_s3_bucket.recordings.id
  eventbridge = true
}
