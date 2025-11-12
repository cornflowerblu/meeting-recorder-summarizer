# DynamoDB Table for Meetings Metadata and Catalog
# MR-15 (T008)

resource "aws_dynamodb_table" "meetings" {
  name         = "${local.resource_prefix}-meetings"
  billing_mode = "PAY_PER_REQUEST" # On-demand pricing for variable workload
  hash_key     = "pk"              # Partition key: user_id#recording_id
  range_key    = "sk"              # Sort key: METADATA or other item types

  # Primary Key Attributes
  attribute {
    name = "pk"
    type = "S" # String: user_id#recording_id
  }

  attribute {
    name = "sk"
    type = "S" # String: METADATA, CHUNK#001, etc.
  }

  # GSI-1: Date Search (by user_id + created_at)
  attribute {
    name = "gsi1pk"
    type = "S" # String: USER#user_id
  }

  attribute {
    name = "gsi1sk"
    type = "S" # String: created_at ISO8601 timestamp
  }

  # GSI-2: Participant Search (by user_id + participant)
  attribute {
    name = "gsi2pk"
    type = "S" # String: USER#user_id
  }

  attribute {
    name = "gsi2sk"
    type = "S" # String: PARTICIPANT#name
  }

  # GSI-3: Tag Search (by user_id + tag)
  attribute {
    name = "gsi3pk"
    type = "S" # String: USER#user_id
  }

  attribute {
    name = "gsi3sk"
    type = "S" # String: TAG#tag_name
  }

  # Global Secondary Index 1: DateSearch
  global_secondary_index {
    name            = "DateSearchIndex"
    hash_key        = "gsi1pk"
    range_key       = "gsi1sk"
    projection_type = "ALL"
  }

  # Global Secondary Index 2: ParticipantSearch
  global_secondary_index {
    name            = "ParticipantSearchIndex"
    hash_key        = "gsi2pk"
    range_key       = "gsi2sk"
    projection_type = "ALL"
  }

  # Global Secondary Index 3: TagSearch
  global_secondary_index {
    name            = "TagSearchIndex"
    hash_key        = "gsi3pk"
    range_key       = "gsi3sk"
    projection_type = "ALL"
  }

  # Point-in-Time Recovery
  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  # Server-Side Encryption
  # Uses customer-managed KMS key for production (better control, audit trails)
  # Falls back to AWS-managed key for non-production environments
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.use_customer_managed_kms ? aws_kms_key.dynamodb[0].arn : null
  }

  # TTL Configuration (for temporary/expired items)
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # Tags
  tags = merge(local.common_tags, {
    Name        = "${local.resource_prefix}-meetings"
    Description = "Meeting metadata catalog with search indexes"
  })

  # Prevent accidental deletion
  lifecycle {
    prevent_destroy = false # Set to true in production
  }
}

# DynamoDB Table Item Example (for documentation)
# {
#   "pk": "user_12345#recording_abc-123",
#   "sk": "METADATA",
#   "recording_id": "abc-123",
#   "user_id": "user_12345",
#   "created_at": "2025-11-10T18:00:00Z",
#   "duration_seconds": 3600,
#   "status": "completed",
#   "title": "Team Standup",
#   "participants": ["Alice", "Bob", "Charlie"],
#   "tags": ["standup", "engineering"],
#   "s3_paths": {
#     "chunks": ["s3://bucket/users/user_12345/raw-chunks/..."],
#     "video": "s3://bucket/users/user_12345/processed/video.mp4",
#     "audio": "s3://bucket/users/user_12345/audio/audio.m4a",
#     "transcript": "s3://bucket/users/user_12345/transcripts/transcript.json",
#     "summary": "s3://bucket/users/user_12345/summaries/summary.json"
#   },
#   "cost_estimate_usd": 1.25,
#   "processing_time_seconds": 120,
#   "gsi1pk": "USER#user_12345",
#   "gsi1sk": "2025-11-10T18:00:00Z",
#   "gsi2pk": "USER#user_12345",
#   "gsi2sk": "PARTICIPANT#Alice"  // Denormalized for each participant
#   "gsi3pk": "USER#user_12345",
#   "gsi3sk": "TAG#standup"  // Denormalized for each tag
# }
