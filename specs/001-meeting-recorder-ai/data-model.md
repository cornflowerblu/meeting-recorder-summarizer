# Phase 1 Data Model

This document defines storage layout, DynamoDB schema, and JSON contracts for artifacts.

## S3 Layout

s3://bucket-name/
users/
{user_id}/
chunks/
{recording_id}/
part-0001.mp4
part-0002.mp4
videos/
{recording_id}.mp4
audio/
{recording_id}.mp3
transcripts/
{recording_id}.json
summaries/
{recording_id}.json

## S3 Lifecycle Policy (Cost-Optimized)

{
"Rules": [
{
"Id": "meeting-recordings-lifecycle",
"Status": "Enabled",
"Filter": {
"Prefix": "users/"
},
"Transitions": [
{
"Days": 5,
"StorageClass": "STANDARD_IA"
},
{
"Days": 15,
"StorageClass": "ONEZONE_IA"
},
{
"Days": 30,
"StorageClass": "GLACIER_IR"
}
],
"Expiration": {
"Days": 60
}
},
{
"Id": "delete-incomplete-multipart-uploads",
"Status": "Enabled",
"AbortIncompleteMultipartUpload": {
"DaysAfterInitiation": 7
}
}
]
}

## Transcript retention policy

{
"Rules": [
{
"Id": "keep-summaries-longer",
"Status": "Enabled",
"Filter": {
"And": {
"Prefix": "users/",
"Tags": [
{
"Key": "content-type",
"Value": "metadata"
}
]
}
},
"Transitions": [
{
"Days": 30,
"StorageClass": "GLACIER_IR"
}
],
"Expiration": {
"Days": 365
}
}
]
}

```

**Or simpler**: Different S3 prefixes:
```

users/{user_id}/
videos/ → 60-day lifecycle (as above)
audio/ → 60-day lifecycle
chunks/ → Delete after 7 days (no longer needed after processing)
transcripts/ → 365-day lifecycle (cheap to keep)
summaries/ → 365-day lifecycle (cheap to keep)

## DynamoDB: meetings

**Primary Key**:

- **PK**: `user_id#recording_id` (e.g., `firebase-uid-123#rec_01JCXYZ123`)
- **SK**: `METADATA` (allows future item types like `TRANSCRIPT_SEGMENT`)

**Attributes**:

- `user_id`: string (Firebase UID)
- `recording_id`: string (ULID or UUID)
- `user_email`: string (for display, from Firebase)
- `recorded_at`: string (ISO8601)
- `duration_ms`: number
- `title`: string
- `participants`: list<string> (not set)
- `tags`: list<string> (not set)
- `status`: string (`pending` | `processing` | `failed` | `completed`)
- `cost_estimate_usd`: number
- `cost_actual_usd`: number
- `s3_paths`: map<string, string>
  - `chunks`: s3://bucket/users/{user_id}/chunks/{recording_id}/
  - `video`: s3://bucket/users/{user_id}/videos/{recording_id}.mp4
  - `audio`: s3://bucket/users/{user_id}/audio/{recording_id}.mp3
  - `transcript`: s3://bucket/users/{user_id}/transcripts/{recording_id}.json
  - `summary`: s3://bucket/users/{user_id}/summaries/{recording_id}.json
- `redactions`: list<map>
- `pipeline_version`: string (SemVer)
- `model_version`: string
- `created_at`: string (ISO8601)
- `updated_at`: string (ISO8601)

**GSIs**:

**GSI-1 (DateSearch)**:

- PK: `user_id`
- SK: `recorded_at` (ISO8601, sortable)
- Projection: ALL
- Purpose: List all meetings for user, sorted by date

**GSI-2 (ParticipantSearch)** - Denormalized:

- PK: `user_id#participant` (e.g., `firebase-uid-123#sarah`)
- SK: `recorded_at`
- Projection: ALL
- Purpose: Find meetings with specific participant
- Note: Requires denormalization (separate item per participant)

**GSI-3 (TagSearch)** - Denormalized:

- PK: `user_id#tag` (e.g., `firebase-uid-123#q4`)
- SK: `recorded_at`
- Projection: ALL
- Purpose: Find meetings with specific tag
- Note: Requires denormalization (separate item per tag)

**Write Pattern (Denormalization)**:
When creating/updating a meeting with participants `["Roger", "Sarah"]` and tags `["Q4", "Strategy"]`:

1. Write main item: `PK = user_id#recording_id, SK = METADATA`
2. Write participant items:
   - `PK = user_id#recording_id, SK = PARTICIPANT#roger`
   - `PK = user_id#recording_id, SK = PARTICIPANT#sarah`
3. Write tag items:
   - `PK = user_id#recording_id, SK = TAG#q4`
   - `PK = user_id#recording_id, SK = TAG#strategy`

With GSI-2/GSI-3 projecting these denormalized items.

**Alternative (Simpler for MVP)**: Skip GSI-2/GSI-3, just use GSI-1 (date sort) and filter in application code. Add participant/tag GSIs post-MVP when you have >100 meetings.

## DynamoDB: meetings

Primary key:

- PK: recording_id (string, ULID or UUID)

Attributes:

- recorded_at: ISO8601 string
- duration_ms: number
- title: string
- participants: set<string>
- tags: set<string>
- status: enum("pending","processing","failed","completed")
- cost_estimate_usd: number
- cost_actual_usd: number
- video_key: string (S3 key)
- audio_key: string (S3 key)
- transcript_key: string (S3 key)
- summary_key: string (S3 key)
- redactions: list<RedactionRule>
- pipeline_version: string (SemVer)
- model_version: string

GSIs:

- GSI1 by_participant: PK participant_lower, SK recorded_at desc
- GSI2 by_tag: PK tag_lower, SK recorded_at desc
- GSI3 by_date: PK yyyy-mm, SK recorded_at desc

Write model:

- On save, expand participants/tags into GSI projector items via denormalization (1 item per participant & per tag if using single-table design), or use DDB streams + Lambda to materialize (defer for MVP; simple denorm writes acceptable).

## JSON Contracts

### Transcript (transcripts/{recording_id}.json)

{
"$schema": "https://json-schema.org/draft/2020-12/schema",
"title": "Transcript",
"type": "object",
"required": ["recording_id","segments","pipeline_version","model_version"],
"properties": {
"recording_id": {"type": "string"},
"segments": {
"type": "array",
"items": {
"type": "object",
"required": ["start_ms","end_ms","speaker_label","text"],
"properties": {
"start_ms": {"type": "integer", "minimum": 0},
"end_ms": {"type": "integer", "minimum": 0},
"speaker_label": {"type": "string"},
"text": {"type": "string"},
"confidence": {"type": "number", "minimum": 0, "maximum": 1}
}
}
},
"speaker_map": {"type": "object", "additionalProperties": {"type": "string"}},
"redactions": {
"type": "array",
"items": {
"type": "object",
"required": ["start_ms","end_ms"],
"properties": {
"start_ms": {"type": "integer", "minimum": 0},
"end_ms": {"type": "integer", "minimum": 0},
"reason": {"type": "string"},
"created_at": {"type": "string", "format": "date-time"}
}
}
},
"pipeline_version": {"type": "string"},
"model_version": {"type": "string"}
}
}

### Summary (summaries/{recording_id}.json)

{
"$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Summary",
  "type": "object",
  "required": ["recording_id","summary","actions","decisions","pipeline_version","model_version"],
  "properties": {
    "recording_id": {"type": "string"},
    "summary": {"type": "array", "items": {"$ref": "#/definitions/summaryItem"}},
"actions": {"type": "array", "items": {"$ref": "#/definitions/actionItem"}},
    "decisions": {"type": "array", "items": {"$ref": "#/definitions/decisionItem"}},
"pipeline_version": {"type": "string"},
"model_version": {"type": "string"}
},
"definitions": {
"summaryItem": {
"type": "object",
"required": ["text","timestamp_ms"],
"properties": {
"text": {"type": "string"},
"timestamp_ms": {"type": "integer", "minimum": 0},
"speaker_label": {"type": "string"}
}
},
"actionItem": {
"type": "object",
"required": ["description"],
"properties": {
"description": {"type": "string"},
"owner": {"type": "string"},
"due_date": {"type": "string", "format": "date"},
"source_timestamp_ms": {"type": "integer", "minimum": 0}
}
},
"decisionItem": {
"type": "object",
"required": ["text"],
"properties": {
"text": {"type": "string"},
"source_timestamp_ms": {"type": "integer", "minimum": 0}
}
}
}
}

## IAM Policy (User Isolation)

{
"Version": "2012-10-17",
"Statement": [
{
"Effect": "Allow",
"Action": [
"s3:PutObject",
"s3:GetObject",
"s3:DeleteObject"
],
"Resource": "arn:aws:s3:::meeting-recordings/users/${cognito-identity.amazonaws.com:sub}/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/meetings",
      "Condition": {
        "ForAllValues:StringEquals": {
          "dynamodb:LeadingKeys": ["${cognito-identity.amazonaws.com:sub}"]
}
}
}
]
}

## Deletion & Retention

- Retention default: 30 days (Constitution). User-configurable policies per FR-012.
- Deletion workflow: On request, remove S3 objects (video/audio/transcript/summary) and the DynamoDB item. Complete within 24h.
- Logs must not include PII and must not leak content segments.

## Versioning

- All artifacts include `pipeline_version` and `model_version`.
- Breaking change to any artifact → bump MAJOR and migrate existing items opportunistically when opened or via batch job.
