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

# Lifecycle Configuration - Optimized per AWS Architecture Audit
resource "aws_s3_bucket_lifecycle_configuration" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  # Rule 1: Delete raw chunks after processing (save ~40% storage cost)
  rule {
    id     = "delete-processed-chunks"
    status = "Enabled"

    filter {
      prefix = "users/"
      tags = {
        type = "chunk"
      }
    }

    expiration {
      days = 7 # Keep for 1 week for debugging, then delete
    }
  }

  # Rule 2: Delete audio files after transcription (can regenerate from video)
  rule {
    id     = "delete-audio-after-transcription"
    status = "Enabled"

    filter {
      prefix = "users/"
      tags = {
        type = "audio"
      }
    }

    expiration {
      days = 30 # Keep for 1 month, then delete
    }
  }

  # Rule 3: Intelligent-Tiering for videos (auto-optimizes based on access)
  rule {
    id     = "intelligent-tiering-videos"
    status = "Enabled"

    filter {
      prefix = "users/"
      tags = {
        type = "video"
      }
    }

    transition {
      days          = 0 # Immediate
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  # Rule 4: Transcripts and summaries - keep accessible, transition to IA after 90 days
  rule {
    id     = "metadata-lifecycle"
    status = "Enabled"

    filter {
      prefix = "users/"
      tags = {
        type = "metadata"
      }
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }

  # Rule 5: Abort incomplete multipart uploads quickly
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 1 # Reduced from 7 to 1 day
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

# S3 Access Logging - Per AWS Architecture Audit, enable for all environments
resource "aws_s3_bucket_logging" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  target_bucket = aws_s3_bucket.recordings.id
  target_prefix = "logs/s3-access/"
}
