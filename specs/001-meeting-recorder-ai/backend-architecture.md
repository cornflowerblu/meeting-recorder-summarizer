# Backend Architecture: Event-Driven Upload & Processing Pipeline

**Created**: 2025-11-15
**Status**: Design Document
**Related**: Phase 3.5 (T028a-T028g), User Story 1 & 2

## Overview

The Meeting Recorder backend uses an **event-driven architecture** where the macOS client is responsible only for recording and uploading chunks to S3. All orchestration, retry logic, session management, and processing is handled by AWS serverless services.

## Design Principles

1. **Client Simplicity**: Desktop app should emit events, not manage complex workflows
2. **Backend Orchestration**: S3 → EventBridge → Lambda handles all coordination
3. **Scalability**: Serverless components auto-scale based on load
4. **Reliability**: Backend handles retries, error recovery, and state management
5. **Observability**: X-Ray, CloudWatch, and structured logging throughout

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         macOS Desktop Client                         │
│                                                                      │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌─────────────┐    │
│  │ Recorder │──▶│  Chunk   │──▶│   S3     │──▶│  Upload to  │    │
│  │          │   │  Writer  │   │ Uploader │   │  S3 Bucket  │    │
│  └──────────┘   └──────────┘   └──────────┘   └─────────────┘    │
│                                                        │             │
└────────────────────────────────────────────────────────┼────────────┘
                                                         │
                                                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          AWS Backend                                 │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │                   S3 Bucket (EventBridge Enabled)            │  │
│  │                                                               │  │
│  │  users/{userId}/chunks/{recordingId}/chunk_NNN.mp4          │  │
│  └────────────────┬────────────────────────────────────────────┘  │
│                   │ (Object Created Event)                         │
│                   ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │                      EventBridge                             │  │
│  │                                                               │  │
│  │  Rule: s3:ObjectCreated → Chunk Upload Handler              │  │
│  └────────────────┬────────────────────────────────────────────┘  │
│                   │                                                 │
│                   ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │           Lambda: Chunk Upload Handler (T028c)               │  │
│  │                                                               │  │
│  │  • Validate chunk metadata (checksum, size, index)          │  │
│  │  • Update DynamoDB chunk tracking table                      │  │
│  │  • Check for session completeness                            │  │
│  │  • Trigger Session Completion Detector if needed             │  │
│  └────────────────┬────────────────────────────────────────────┘  │
│                   │                                                 │
│                   ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │      Lambda: Session Completion Detector (T028d)             │  │
│  │                                                               │  │
│  │  • Query DynamoDB for all chunks in session                  │  │
│  │  • Verify completeness (all chunk indices present)           │  │
│  │  • Update session status to "ready_for_processing"           │  │
│  │  • Trigger Step Functions processing workflow                │  │
│  └────────────────┬────────────────────────────────────────────┘  │
│                   │                                                 │
│                   ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │              Step Functions: AI Processing (T035)            │  │
│  │                                                               │  │
│  │  1. FFmpeg Fargate: Concatenate chunks → Extract audio      │  │
│  │  2. Transcribe: Generate transcript with speaker labels      │  │
│  │  3. Bedrock: Summarize, extract actions/decisions            │  │
│  │  4. Update DynamoDB catalog with results                     │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. S3 Bucket Configuration (T028a)

**File**: `infra/terraform/s3.tf`

```hcl
resource "aws_s3_bucket" "meeting_recordings" {
  bucket = var.recordings_bucket_name

  # Enable EventBridge notifications
  event_bridge_enabled = true

  # Encryption, versioning, lifecycle policies
  # (existing configuration)
}
```

**Key Features**:
- EventBridge enabled at bucket level
- All object creation events automatically sent to EventBridge
- No need for explicit S3 event notifications

### 2. EventBridge Rules (T028b)

**File**: `infra/terraform/eventbridge.tf`

**Rule 1: Chunk Upload Detection**
```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "bucket": {
      "name": ["${recordings_bucket_name}"]
    },
    "object": {
      "key": [{
        "prefix": "users/"
      }, {
        "suffix": "/chunks/"
      }]
    }
  }
}
```
→ Targets: `ChunkUploadHandler` Lambda

**Rule 2: Processing Completion** (from existing T039)
```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "object": {
      "key": [{
        "suffix": "/processed/audio.wav"
      }]
    }
  }
}
```
→ Targets: Existing `StartProcessing` Lambda (T034)

### 3. DynamoDB Chunk Tracking Table (T028e)

**File**: `infra/terraform/dynamodb.tf`

**Table**: `meeting-recorder-chunks`

```
PK: recordingId (HASH)
SK: chunkIndex (RANGE)

Attributes:
- uploadedAt: timestamp
- s3Key: string
- fileSize: number
- checksum: string
- status: enum [uploaded, validated, failed]
- retryCount: number
- lastError: string (optional)

GSI1:
- PK: userId (HASH)
- SK: uploadedAt (RANGE)
- Purpose: User-level chunk queries
```

**Design Notes**:
- One item per chunk uploaded
- Session completion determined by querying all chunks for a recordingId
- Supports retry tracking and error diagnostics

### 4. Lambda: Chunk Upload Handler (T028c)

**File**: `processing/lambdas/chunk_upload_handler/handler.py`

**Responsibilities**:
1. Receive EventBridge event for S3 chunk upload
2. Extract metadata from S3 object (size, etag, key)
3. Parse recordingId and chunkIndex from S3 key
4. Validate chunk:
   - File size > 0
   - S3 object exists and is accessible
   - Optional: checksum validation (if provided)
5. Write/update DynamoDB chunk tracking record
6. Check if session is complete (invoke Session Completion Detector)

**Error Handling**:
- Malformed S3 keys → log warning, skip
- DynamoDB write failures → retry with exponential backoff
- S3 access errors → mark chunk as failed, alert

**Example Event**:
```json
{
  "version": "0",
  "id": "event-id",
  "detail-type": "Object Created",
  "source": "aws.s3",
  "account": "123456789012",
  "time": "2025-11-15T18:30:00Z",
  "region": "us-east-1",
  "resources": ["arn:aws:s3:::bucket"],
  "detail": {
    "bucket": {
      "name": "meeting-recordings-bucket"
    },
    "object": {
      "key": "users/user_123/chunks/rec_456/chunk_002.mp4",
      "size": 1048576,
      "etag": "abc123def456"
    }
  }
}
```

**Implementation**:
```python
def handler(event, context):
    """Handle S3 chunk upload event"""
    detail = event['detail']
    s3_key = detail['object']['key']

    # Parse: users/{userId}/chunks/{recordingId}/chunk_{index}.mp4
    match = re.match(r'users/(.+)/chunks/(.+)/chunk_(\d{3})\.mp4', s3_key)
    if not match:
        logger.warning(f"Invalid S3 key format: {s3_key}")
        return

    user_id, recording_id, chunk_index = match.groups()
    chunk_index = int(chunk_index)

    # Validate chunk
    chunk_metadata = {
        'recordingId': recording_id,
        'chunkIndex': chunk_index,
        's3Key': s3_key,
        'fileSize': detail['object']['size'],
        'etag': detail['object']['etag'],
        'uploadedAt': event['time'],
        'status': 'validated'
    }

    # Write to DynamoDB
    dynamodb.put_item(
        TableName='meeting-recorder-chunks',
        Item=chunk_metadata
    )

    # Check session completeness
    check_session_completeness(recording_id, user_id)
```

### 5. Lambda: Session Completion Detector (T028d)

**File**: `processing/lambdas/session_completion_detector/handler.py`

**Responsibilities**:
1. Invoked by Chunk Upload Handler after each chunk upload
2. Query DynamoDB for all chunks in a recording session
3. Determine if session is complete:
   - Option A: Check catalog metadata for expected chunk count
   - Option B: Wait for explicit "end recording" signal from client
4. If complete:
   - Update session status in catalog to "ready_for_processing"
   - Trigger Step Functions processing workflow (T035)
5. If incomplete:
   - No action (wait for more chunks)

**Completeness Logic**:

**Option A: Expected Chunk Count** (preferred for MVP)
- CatalogService writes `expectedChunkCount` to DynamoDB when recording stops
- Session complete when: `COUNT(chunks) == expectedChunkCount`

**Option B: End Recording Signal**
- Client writes special "end.marker" object to S3 when recording stops
- Session complete when: end.marker exists AND all chunks uploaded

**Implementation**:
```python
def check_session_completeness(recording_id, user_id):
    """Check if all chunks uploaded for a session"""

    # Get session metadata from catalog
    catalog = get_catalog_session(recording_id)
    expected_chunks = catalog.get('expectedChunkCount')

    if not expected_chunks:
        logger.info(f"Session {recording_id} still recording (no expected count)")
        return

    # Count uploaded chunks
    chunks = query_chunks(recording_id)
    uploaded_count = len([c for c in chunks if c['status'] == 'validated'])

    logger.info(f"Session {recording_id}: {uploaded_count}/{expected_chunks} chunks")

    if uploaded_count == expected_chunks:
        logger.info(f"Session {recording_id} complete, triggering processing")

        # Update catalog status
        update_catalog_status(recording_id, 'ready_for_processing')

        # Trigger Step Functions
        step_functions.start_execution(
            stateMachineArn=PROCESSING_STATE_MACHINE_ARN,
            input=json.dumps({
                'recordingId': recording_id,
                'userId': user_id,
                'chunkCount': uploaded_count
            })
        )
```

### 6. Integration with Existing Step Functions (T035)

The Session Completion Detector triggers the existing Step Functions workflow from T035:

```
Step Functions: AI Processing
├─ State 1: FFmpeg Fargate (T033)
│  └─ Input: recordingId, chunkCount
│  └─ Downloads chunks from S3, concatenates, extracts audio
│
├─ State 2: Start Transcribe (T036)
│  └─ Input: audio S3 key
│  └─ Starts Transcribe job with speaker diarization
│
├─ State 3: Wait for Transcribe
│  └─ Polls Transcribe job status
│
├─ State 4: Bedrock Summarize (T037)
│  └─ Input: transcript S3 key
│  └─ Generates summary, actions, decisions
│
└─ State 5: Update Catalog
   └─ Marks session as "completed"
```

**Key Change**: Step Functions is now triggered by Session Completion Detector (T028d) instead of manual client invocation.

## Error Handling & Retry Strategy

### Chunk Upload Failures

**Scenario**: S3 upload fails mid-recording (network loss)

**Handling**:
1. Client queues chunk locally (existing behavior)
2. Client retries upload when network restored
3. EventBridge fires event on successful upload
4. Chunk Upload Handler validates and records
5. No special backend retry needed (client handles)

### Missing Chunks

**Scenario**: Session marked complete but chunks missing (data corruption, race condition)

**Handling**:
1. Session Completion Detector queries DynamoDB for all chunks
2. Detects gap in chunk indices (e.g., 0, 1, 3, 4 - missing 2)
3. Marks session status as "incomplete_chunks"
4. Alerts monitoring (CloudWatch alarm)
5. Manual intervention or client re-upload required

### Lambda Failures

**Scenario**: Chunk Upload Handler Lambda crashes

**Handling**:
1. EventBridge retries Lambda invocation (up to 185 days retention)
2. DLQ captures failed events after max retries
3. CloudWatch alarm on DLQ depth > 0
4. Manual replay from DLQ after fix

### Step Functions Failures

**Scenario**: FFmpeg processing fails (corrupted chunk)

**Handling**:
- Existing error handling from T035 (Step Functions retry logic)
- Session status updated to "processing_failed"
- User can retry from macOS client (future feature)

## Observability & Monitoring

### X-Ray Tracing

**Trace Segments**:
1. S3 chunk upload → EventBridge
2. EventBridge → Chunk Upload Handler
3. Chunk Upload Handler → DynamoDB write
4. Session Completion Detector → Step Functions trigger
5. Step Functions → Full processing pipeline

**Sample Trace**:
```
[0ms] S3 PutObject
[5ms] → EventBridge rule evaluation
[10ms] → Lambda: ChunkUploadHandler
[25ms]   → DynamoDB PutItem
[50ms]   → Lambda: SessionCompletionDetector
[75ms]     → DynamoDB Query (count chunks)
[100ms]    → Step Functions StartExecution
[150ms] → Fargate: FFmpeg processing
...
```

### CloudWatch Logs Insights Queries

**Query 1: Chunk Upload Latency**
```
filter @type = "REPORT"
| filter @message like /ChunkUploadHandler/
| stats avg(@duration), max(@duration), p99(@duration) by bin(5m)
```

**Query 2: Session Completion Rate**
```
fields @timestamp, recordingId, expectedChunks, uploadedChunks
| filter action = "session_complete"
| stats count() by bin(1h)
```

**Query 3: Failed Chunks**
```
filter status = "failed"
| fields recordingId, chunkIndex, lastError
| sort @timestamp desc
| limit 50
```

### CloudWatch Alarms

1. **Missing Chunks Alert**
   - Metric: Custom metric `SessionsWithMissingChunks`
   - Threshold: > 0
   - Action: SNS notification

2. **Chunk Upload Handler Errors**
   - Metric: Lambda errors
   - Threshold: > 5 errors/minute
   - Action: SNS notification

3. **DLQ Depth**
   - Metric: EventBridge DLQ message count
   - Threshold: > 0
   - Action: SNS notification + PagerDuty

## Testing Strategy

### Unit Tests

**File**: `processing/tests/unit/test_chunk_upload_handler.py`

```python
def test_chunk_upload_handler_valid_event():
    """Test successful chunk upload handling"""
    event = create_s3_event('users/u1/chunks/r1/chunk_000.mp4')
    response = handler(event, context)

    assert response['statusCode'] == 200
    assert dynamodb_item_exists('r1', 0)

def test_chunk_upload_handler_invalid_key():
    """Test handling of malformed S3 key"""
    event = create_s3_event('invalid/key/format.mp4')
    response = handler(event, context)

    assert response['statusCode'] == 200  # Skip, don't fail
    assert 'Invalid S3 key' in logs
```

**File**: `processing/tests/unit/test_session_completion_detector.py`

```python
def test_session_complete_triggers_processing():
    """Test Step Functions triggered when session complete"""
    setup_chunks('rec_123', count=10)
    setup_catalog('rec_123', expectedChunkCount=10)

    check_session_completeness('rec_123', 'user_1')

    assert step_functions_execution_started('rec_123')
    assert catalog_status('rec_123') == 'ready_for_processing'

def test_session_incomplete_waits():
    """Test no trigger when chunks still uploading"""
    setup_chunks('rec_456', count=5)
    setup_catalog('rec_456', expectedChunkCount=10)

    check_session_completeness('rec_456', 'user_1')

    assert not step_functions_execution_started('rec_456')
```

### Integration Tests

**File**: `processing/tests/integration/test_upload_to_processing_flow.py`

```python
@pytest.mark.integration
def test_end_to_end_upload_flow():
    """Test complete flow: S3 upload → EventBridge → Processing"""

    # 1. Upload 3 chunks to S3
    for i in range(3):
        upload_chunk(f'chunk_{i:03d}.mp4', recording_id='test_rec')

    # 2. Wait for EventBridge propagation
    time.sleep(2)

    # 3. Verify chunks recorded in DynamoDB
    chunks = query_chunks('test_rec')
    assert len(chunks) == 3

    # 4. Mark session complete
    update_catalog('test_rec', expectedChunkCount=3)

    # 5. Wait for Session Completion Detector
    time.sleep(1)

    # 6. Verify Step Functions started
    executions = list_step_functions_executions()
    assert any(e['recordingId'] == 'test_rec' for e in executions)
```

### Local Testing

**Docker for Lambda Testing**:
```bash
# Run Chunk Upload Handler locally
cd processing/lambdas/chunk_upload_handler
docker run -v $(pwd):/var/task \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  public.ecr.aws/lambda/python:3.11 \
  handler.handler < test_event.json
```

**SAM Local for EventBridge**:
```bash
# Test EventBridge → Lambda integration
sam local invoke ChunkUploadHandler \
  -e events/s3-chunk-upload.json \
  --docker-network host
```

## Cost Estimation

### Per Recording Session (60 minutes, 60 chunks)

| Component | Usage | Cost |
|-----------|-------|------|
| S3 Storage | 60 chunks × 10MB | $0.014/month |
| S3 PUT Requests | 60 uploads | $0.0003 |
| EventBridge Events | 60 events | $0.00006 |
| Lambda (Chunk Handler) | 60 invocations × 200ms | $0.0002 |
| Lambda (Completion Detector) | 1 invocation × 500ms | $0.000008 |
| DynamoDB Writes | 60 chunks + 1 catalog | $0.0076 |
| Step Functions | 1 execution | $0.025 |
| **Total Upload/Orchestration** | | **$0.047** |

**Note**: Does not include Transcribe/Bedrock costs (covered in T037 docs)

## Deployment Order

1. **T028a**: Deploy S3 bucket with EventBridge enabled
2. **T028e**: Create DynamoDB chunk tracking table
3. **T028b**: Deploy EventBridge rules
4. **T028c**: Deploy Chunk Upload Handler Lambda
5. **T028d**: Deploy Session Completion Detector Lambda
6. **T028f**: Add error handling & DLQ
7. **T028g**: Integration testing

## Open Questions & Decisions

1. **Session Completeness Signal**: How does client signal "recording stopped"?
   - **Decision**: Client writes `expectedChunkCount` to catalog when recording stops
   - **Alternative**: Client writes special "end.marker" S3 object

2. **Chunk Validation**: Checksum validation on backend?
   - **Decision**: Optional for MVP, rely on S3 etag for integrity
   - **Future**: Add SHA256 checksum validation

3. **Missing Chunk Handling**: Auto-retry or manual intervention?
   - **Decision**: Manual for MVP (alert on missing chunks)
   - **Future**: Auto-request re-upload from client

4. **Chunk Retention**: Delete chunks after processing?
   - **Decision**: Keep for 30 days (allow reprocessing), then lifecycle delete
   - **Implementation**: S3 lifecycle policy (existing)

## References

- **Tasks**: T028a-T028g in `tasks.md`
- **Related Code**: `UploadQueue.swift` (simplified client implementation)
- **Related Docs**: `spec.md` (event-driven design decision)
- **AWS Docs**:
  - [S3 EventBridge Integration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/EventBridge.html)
  - [EventBridge Event Patterns](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-patterns.html)
  - [Lambda DLQ Best Practices](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async.html#invocation-dlq)
