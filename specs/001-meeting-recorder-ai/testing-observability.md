# Testing & Observability Strategy

**Created**: 2025-11-15
**Status**: Implementation Guide
**Related**: Phase 3.5 (T028f-g), Phase 4 (T029-T032)

## Overview

This document defines the comprehensive testing and observability strategy for the Meeting Recorder AI processing pipeline. It covers unit tests, integration tests, X-Ray tracing, CloudWatch monitoring, and local development testing approaches.

## Table of Contents

1. [Testing Pyramid](#testing-pyramid)
2. [X-Ray Tracing Setup](#x-ray-tracing-setup)
3. [CloudWatch Logs Insights](#cloudwatch-logs-insights)
4. [CloudWatch Dashboards](#cloudwatch-dashboards)
5. [Alarms & Alerts](#alarms--alerts)
6. [Local Testing Strategy](#local-testing-strategy)
7. [Integration Testing](#integration-testing)
8. [Contract Testing](#contract-testing)
9. [Performance Testing](#performance-testing)

---

## Testing Pyramid

```
                    ┌─────────────────┐
                    │   E2E Tests     │  ← Deployment validation
                    │   (Manual)      │
                    └─────────────────┘
                  ┌───────────────────────┐
                  │  Integration Tests    │  ← AWS services interaction
                  │  (SAM Local / AWS)    │
                  └───────────────────────┘
              ┌───────────────────────────────┐
              │      Contract Tests            │  ← JSON schema validation
              │      (pytest)                  │
              └───────────────────────────────┘
          ┌─────────────────────────────────────┐
          │          Unit Tests                  │  ← Lambda handlers, utilities
          │          (pytest, moto)              │
          └─────────────────────────────────────┘
```

### Test Coverage Goals

- **Unit Tests**: 80%+ code coverage for Lambda handlers
- **Contract Tests**: 100% schema coverage (transcript, summary, actions)
- **Integration Tests**: Critical paths (S3 → EventBridge → Lambda → Step Functions)
- **E2E Tests**: Smoke tests on deployment

---

## X-Ray Tracing Setup

### Lambda Configuration

**File**: `infra/terraform/lambda.tf`

```hcl
resource "aws_lambda_function" "chunk_upload_handler" {
  # ... existing configuration ...

  tracing_config {
    mode = "Active"  # Enable X-Ray tracing
  }

  environment {
    variables = {
      AWS_XRAY_CONTEXT_MISSING = "LOG_ERROR"
      AWS_XRAY_TRACING_NAME    = "ChunkUploadHandler"
    }
  }
}

resource "aws_lambda_function" "session_completion_detector" {
  # ... existing configuration ...

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      AWS_XRAY_CONTEXT_MISSING = "LOG_ERROR"
      AWS_XRAY_TRACING_NAME    = "SessionCompletionDetector"
    }
  }
}
```

### Step Functions X-Ray

**File**: `infra/terraform/stepfunctions.tf`

```hcl
resource "aws_sfn_state_machine" "ai_processing" {
  # ... existing configuration ...

  tracing_configuration {
    enabled = true
  }
}
```

### IAM Permissions

**File**: `infra/terraform/iam.tf`

```hcl
data "aws_iam_policy_document" "lambda_xray" {
  statement {
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  for_each = toset([
    aws_iam_role.chunk_upload_handler.name,
    aws_iam_role.session_completion_detector.name,
    aws_iam_role.start_processing.name,
    aws_iam_role.start_transcribe.name,
    aws_iam_role.bedrock_summarize.name
  ])

  role       = each.value
  policy_arn = aws_iam_policy.lambda_xray.arn
}
```

### Python SDK Instrumentation

**File**: `processing/lambdas/chunk_upload_handler/handler.py`

```python
import boto3
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch AWS SDK clients for X-Ray tracing
patch_all()

dynamodb = boto3.client('dynamodb')
s3 = boto3.client('s3')

@xray_recorder.capture('validate_chunk')
def validate_chunk(s3_key, expected_size):
    """Validate chunk with X-Ray subsegment"""
    # Validation logic
    pass

@xray_recorder.capture('update_chunk_tracking')
def update_chunk_tracking(recording_id, chunk_metadata):
    """Update DynamoDB with X-Ray tracing"""
    dynamodb.put_item(
        TableName='meeting-recorder-chunks',
        Item=chunk_metadata
    )

def handler(event, context):
    """Main handler with automatic X-Ray root segment"""
    # X-Ray automatically creates trace for Lambda invocation
    recording_id = extract_recording_id(event)

    # Custom subsegments for granular tracing
    with xray_recorder.capture('parse_event'):
        chunk_data = parse_s3_event(event)

    validate_chunk(chunk_data['s3_key'], chunk_data['size'])
    update_chunk_tracking(recording_id, chunk_data)
```

### X-Ray Service Map

Expected trace flow:

```
S3 → EventBridge → ChunkUploadHandler → DynamoDB
                       ↓
              SessionCompletionDetector → Step Functions → Fargate
                                                          ↓
                                                    Transcribe → Bedrock
```

### Sample X-Ray Queries

**Query 1: End-to-End Latency**
```
service("ChunkUploadHandler") AND annotation.recordingId = "rec_123"
```

**Query 2: Error Analysis**
```
error = true AND service("SessionCompletionDetector")
```

**Query 3: Performance Bottlenecks**
```
service("ChunkUploadHandler") AND responsetime > 1
```

---

## CloudWatch Logs Insights

### Structured Logging Format

**File**: `processing/shared/logger.py`

```python
import json
import logging
from datetime import datetime

class StructuredLogger:
    """Structured JSON logger for CloudWatch"""

    def __init__(self, service_name):
        self.service_name = service_name
        self.logger = logging.getLogger(service_name)
        self.logger.setLevel(logging.INFO)

    def log(self, level, message, **kwargs):
        """Log structured JSON"""
        log_entry = {
            'timestamp': datetime.utcnow().isoformat(),
            'service': self.service_name,
            'level': level,
            'message': message,
            **kwargs
        }
        self.logger.log(getattr(logging, level), json.dumps(log_entry))

    def info(self, message, **kwargs):
        self.log('INFO', message, **kwargs)

    def error(self, message, **kwargs):
        self.log('ERROR', message, **kwargs)

    def debug(self, message, **kwargs):
        self.log('DEBUG', message, **kwargs)

# Usage
logger = StructuredLogger('ChunkUploadHandler')

logger.info('Chunk uploaded', recordingId='rec_123', chunkIndex=5, fileSize=1024000)
# Output: {"timestamp": "2025-11-15T18:30:00", "service": "ChunkUploadHandler", "level": "INFO", "message": "Chunk uploaded", "recordingId": "rec_123", "chunkIndex": 5, "fileSize": 1024000}
```

### CloudWatch Insights Queries

#### Query 1: Chunk Upload Latency

```sql
fields @timestamp, recordingId, chunkIndex, @duration
| filter service = "ChunkUploadHandler"
| filter level = "INFO"
| filter message = "Chunk uploaded"
| stats avg(@duration), max(@duration), pct(@duration, 95) by bin(5m)
```

**Purpose**: Monitor upload processing time
**Alert Threshold**: p95 > 500ms

#### Query 2: Session Completion Rate

```sql
fields @timestamp, recordingId, uploadedChunks, expectedChunks
| filter service = "SessionCompletionDetector"
| filter message = "Session complete"
| stats count() as completedSessions by bin(1h)
```

**Purpose**: Track processing throughput
**Alert Threshold**: < 1 session/hour in production

#### Query 3: Failed Chunks

```sql
fields @timestamp, recordingId, chunkIndex, error
| filter level = "ERROR"
| filter service = "ChunkUploadHandler"
| sort @timestamp desc
| limit 50
```

**Purpose**: Debug upload failures
**Alert Threshold**: > 5 errors/minute

#### Query 4: Step Functions Execution Duration

```sql
fields @timestamp, recordingId, executionArn, @duration
| filter service = "StepFunctions"
| filter message = "Execution complete"
| stats avg(@duration/1000/60) as avgMinutes, max(@duration/1000/60) as maxMinutes by bin(1h)
```

**Purpose**: Monitor processing pipeline duration
**Alert Threshold**: > 15 minutes average

#### Query 5: Bedrock Token Usage

```sql
fields @timestamp, recordingId, inputTokens, outputTokens
| filter service = "BedrockSummarize"
| stats sum(inputTokens) as totalInput, sum(outputTokens) as totalOutput, count() as requests by bin(1d)
```

**Purpose**: Track Bedrock costs
**Alert Threshold**: > $100/day

#### Query 6: Missing Chunks Detection

```sql
fields @timestamp, recordingId, missingIndices
| filter level = "WARNING"
| filter message like /missing chunks/
| sort @timestamp desc
```

**Purpose**: Identify incomplete sessions
**Alert Threshold**: Any occurrence

---

## CloudWatch Dashboards

### Dashboard 1: Upload Pipeline Health

**File**: `infra/terraform/cloudwatch_dashboards.tf`

```hcl
resource "aws_cloudwatch_dashboard" "upload_pipeline" {
  dashboard_name = "MeetingRecorder-UploadPipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title = "Chunk Upload Rate"
          metrics = [
            ["AWS/Lambda", "Invocations", { stat = "Sum", label = "Uploads/min" }]
          ]
          period = 60
          stat   = "Sum"
          region = var.aws_region
        }
      },
      {
        type = "metric"
        properties = {
          title = "Upload Handler Errors"
          metrics = [
            ["AWS/Lambda", "Errors", { stat = "Sum", label = "Errors" }]
          ]
          period = 60
          stat   = "Sum"
          region = var.aws_region
        }
      },
      {
        type = "log"
        properties = {
          title = "Session Completion Events"
          query = "fields @timestamp, recordingId | filter message = 'Session complete'"
          region = var.aws_region
        }
      }
    ]
  })
}
```

### Dashboard 2: AI Processing Performance

Metrics:
- Step Functions execution duration
- Transcribe job latency
- Bedrock summarization latency
- DynamoDB write latency
- S3 artifact upload throughput

### Dashboard 3: Cost Tracking

Metrics:
- Lambda invocations (by function)
- Transcribe minutes consumed
- Bedrock tokens consumed (input + output)
- S3 storage (GB)
- DynamoDB read/write units

---

## Alarms & Alerts

**File**: `infra/terraform/monitoring.tf`

```hcl
# Alarm 1: High Error Rate
resource "aws_cloudwatch_metric_alarm" "chunk_upload_errors" {
  alarm_name          = "ChunkUploadHandler-HighErrorRate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Chunk upload errors exceed 5/minute"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.chunk_upload_handler.function_name
  }
}

# Alarm 2: DLQ Messages
resource "aws_cloudwatch_metric_alarm" "eventbridge_dlq" {
  alarm_name          = "EventBridge-DLQNotEmpty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "EventBridge DLQ has messages"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.eventbridge_dlq.name
  }
}

# Alarm 3: Step Functions Failures
resource "aws_cloudwatch_metric_alarm" "step_functions_failures" {
  alarm_name          = "StepFunctions-ExecutionsFailed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Step Functions execution failed"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.ai_processing.arn
  }
}

# Alarm 4: Missing Chunks (Custom Metric)
resource "aws_cloudwatch_metric_alarm" "missing_chunks" {
  alarm_name          = "Sessions-MissingChunks"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "MissingChunks"
  namespace           = "MeetingRecorder"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Session has missing chunks"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# SNS Topic for Alerts
resource "aws_sns_topic" "alerts" {
  name = "meeting-recorder-alerts"
}

resource "aws_sns_topic_subscription" "email_alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

---

## Local Testing Strategy

### 1. Lambda Unit Tests (pytest + moto)

**File**: `processing/tests/unit/test_chunk_upload_handler.py`

```python
import pytest
import json
from moto import mock_dynamodb, mock_s3
from lambdas.chunk_upload_handler import handler

@mock_dynamodb
@mock_s3
def test_chunk_upload_success():
    """Test successful chunk upload handling"""
    # Setup
    setup_mock_dynamodb()
    setup_mock_s3()

    event = create_s3_event('users/u1/chunks/rec_123/chunk_000.mp4')

    # Execute
    response = handler.handler(event, context=None)

    # Assert
    assert response['statusCode'] == 200
    assert dynamodb_item_exists('rec_123', 0)

def create_s3_event(s3_key):
    """Generate EventBridge S3 event"""
    return {
        'detail-type': 'Object Created',
        'source': 'aws.s3',
        'detail': {
            'bucket': {'name': 'test-bucket'},
            'object': {'key': s3_key, 'size': 1024000, 'etag': 'abc123'}
        }
    }
```

**Run locally**:
```bash
cd processing
python -m pytest tests/unit/ -v --cov=lambdas --cov-report=html
```

### 2. Docker for Fargate Testing

**File**: `processing/fargate/test_local.sh`

```bash
#!/bin/bash
# Test FFmpeg processing locally with Docker

# Build container
docker build -t meeting-recorder-ffmpeg .

# Create test input
mkdir -p /tmp/test_chunks
for i in {0..2}; do
  ffmpeg -f lavfi -i testsrc=duration=10:size=1280x720:rate=30 \
    -f lavfi -i sine=frequency=1000:duration=10 \
    /tmp/test_chunks/chunk_$(printf "%03d" $i).mp4
done

# Run container
docker run -v /tmp/test_chunks:/input \
           -v /tmp/test_output:/output \
           -e RECORDING_ID=test_rec \
           -e CHUNK_COUNT=3 \
           meeting-recorder-ffmpeg
```

### 3. SAM Local for Lambda Testing

**File**: `processing/template.yaml` (SAM template)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31

Resources:
  ChunkUploadHandler:
    Type: AWS::Serverless::Function
    Properties:
      Handler: handler.handler
      Runtime: python3.11
      CodeUri: lambdas/chunk_upload_handler/
      Events:
        S3Event:
          Type: EventBridgeRule
          Properties:
            Pattern:
              source:
                - aws.s3
              detail-type:
                - Object Created
```

**Run locally**:
```bash
sam local invoke ChunkUploadHandler \
  -e events/s3-chunk-upload.json \
  --docker-network host
```

### 4. LocalStack for AWS Services (Optional)

**Docker Compose**: `processing/docker-compose.yml`

```yaml
version: '3.8'
services:
  localstack:
    image: localstack/localstack:latest
    environment:
      - SERVICES=s3,dynamodb,sqs,lambda,stepfunctions
      - DEBUG=1
      - DATA_DIR=/tmp/localstack/data
    ports:
      - "4566:4566"
    volumes:
      - "./localstack:/tmp/localstack"
```

**Run**:
```bash
docker-compose up -d
aws --endpoint-url=http://localhost:4566 s3 mb s3://test-bucket
```

---

## Integration Testing

### Test Suite: Upload to Processing Flow

**File**: `processing/tests/integration/test_upload_flow.py`

```python
import boto3
import pytest
import time
from decimal import Decimal

@pytest.mark.integration
def test_end_to_end_upload_and_trigger():
    """Test S3 upload → EventBridge → Lambda → Step Functions"""

    s3 = boto3.client('s3')
    dynamodb = boto3.client('dynamodb')
    sfn = boto3.client('stepfunctions')

    recording_id = f'test_rec_{int(time.time())}'
    chunk_count = 3

    # 1. Upload chunks to S3
    for i in range(chunk_count):
        s3.put_object(
            Bucket='meeting-recordings-dev',
            Key=f'users/test_user/chunks/{recording_id}/chunk_{i:03d}.mp4',
            Body=b'test video data'
        )

    # 2. Wait for EventBridge propagation (up to 10s)
    time.sleep(2)

    # 3. Verify chunks in DynamoDB
    for i in range(chunk_count):
        response = dynamodb.get_item(
            TableName='meeting-recorder-chunks',
            Key={
                'recordingId': {'S': recording_id},
                'chunkIndex': {'N': str(i)}
            }
        )
        assert 'Item' in response, f"Chunk {i} not found in DynamoDB"

    # 4. Mark session as complete
    dynamodb.update_item(
        TableName='meeting-recorder-catalog',
        Key={'recordingId': {'S': recording_id}},
        UpdateExpression='SET expectedChunkCount = :count',
        ExpressionAttributeValues={':count': {'N': str(chunk_count)}}
    )

    # 5. Wait for Session Completion Detector (up to 5s)
    time.sleep(2)

    # 6. Verify Step Functions started
    executions = sfn.list_executions(
        stateMachineArn='arn:aws:states:us-east-1:123456789012:stateMachine:ai-processing',
        maxResults=10
    )

    execution_ids = [e['name'] for e in executions['executions']]
    assert any(recording_id in e_id for e_id in execution_ids), \
        f"Step Functions not triggered for {recording_id}"

@pytest.mark.integration
def test_missing_chunks_detection():
    """Test missing chunk detection logic"""

    recording_id = f'test_missing_{int(time.time())}'

    # Upload chunks 0, 1, 3 (skip 2)
    for i in [0, 1, 3]:
        upload_chunk(recording_id, i)

    # Mark session complete
    set_expected_chunks(recording_id, 4)

    # Wait for detection
    time.sleep(2)

    # Verify session marked incomplete
    catalog = get_catalog_session(recording_id)
    assert catalog['status'] == 'incomplete_chunks'
```

**Run integration tests**:
```bash
# Requires AWS credentials for dev environment
export AWS_PROFILE=meeting-recorder-dev
python -m pytest tests/integration/ -v --tb=short
```

---

## Contract Testing

### Schema Validation Tests (T029-T030)

**File**: `processing/tests/contracts/test_transcript_schema.py`

```python
import pytest
import json
from jsonschema import validate, ValidationError

TRANSCRIPT_SCHEMA = {
    "type": "object",
    "required": ["recordingId", "duration", "speakers", "segments"],
    "properties": {
        "recordingId": {"type": "string"},
        "duration": {"type": "number"},
        "speakers": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["speakerId", "displayName"],
                "properties": {
                    "speakerId": {"type": "string"},
                    "displayName": {"type": "string"}
                }
            }
        },
        "segments": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["startTime", "endTime", "speakerId", "text"],
                "properties": {
                    "startTime": {"type": "number"},
                    "endTime": {"type": "number"},
                    "speakerId": {"type": "string"},
                    "text": {"type": "string"}
                }
            }
        }
    }
}

def test_transcript_schema_valid():
    """Test valid transcript matches schema"""
    transcript = {
        "recordingId": "rec_123",
        "duration": 3600.5,
        "speakers": [
            {"speakerId": "spk_0", "displayName": "Alice"},
            {"speakerId": "spk_1", "displayName": "Bob"}
        ],
        "segments": [
            {
                "startTime": 0.0,
                "endTime": 5.2,
                "speakerId": "spk_0",
                "text": "Hello everyone"
            }
        ]
    }

    validate(instance=transcript, schema=TRANSCRIPT_SCHEMA)  # Should not raise

def test_transcript_schema_missing_field():
    """Test schema rejects missing required field"""
    invalid_transcript = {
        "recordingId": "rec_123",
        # Missing duration
        "speakers": [],
        "segments": []
    }

    with pytest.raises(ValidationError):
        validate(instance=invalid_transcript, schema=TRANSCRIPT_SCHEMA)
```

**File**: `processing/tests/contracts/test_summary_schema.py`

```python
SUMMARY_SCHEMA = {
    "type": "object",
    "required": ["recordingId", "summary", "actionItems", "decisions"],
    "properties": {
        "recordingId": {"type": "string"},
        "summary": {"type": "string"},
        "actionItems": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["description", "timestamp"],
                "properties": {
                    "description": {"type": "string"},
                    "owner": {"type": "string"},
                    "dueDate": {"type": "string"},
                    "timestamp": {"type": "number"}
                }
            }
        },
        "decisions": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["description", "timestamp"],
                "properties": {
                    "description": {"type": "string"},
                    "timestamp": {"type": "number"}
                }
            }
        }
    }
}
# Similar test structure as transcript
```

---

## Performance Testing

### Load Test: Concurrent Chunk Uploads

**File**: `processing/tests/performance/load_test.py`

```python
import boto3
import concurrent.futures
import time

def upload_chunk(recording_id, chunk_index):
    """Upload a single chunk"""
    s3 = boto3.client('s3')
    s3.put_object(
        Bucket='meeting-recordings-dev',
        Key=f'users/test_user/chunks/{recording_id}/chunk_{chunk_index:03d}.mp4',
        Body=b'x' * (1024 * 1024)  # 1 MB
    )

def test_concurrent_uploads():
    """Test 100 concurrent chunk uploads"""
    recording_id = f'load_test_{int(time.time())}'

    start = time.time()

    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as executor:
        futures = [
            executor.submit(upload_chunk, recording_id, i)
            for i in range(100)
        ]
        concurrent.futures.wait(futures)

    duration = time.time() - start
    throughput = 100 / duration

    print(f"Uploaded 100 chunks in {duration:.2f}s ({throughput:.2f} chunks/s)")
    assert duration < 60, "Should complete within 60 seconds"
```

**Run load test**:
```bash
python tests/performance/load_test.py
```

---

## Summary

### Testing Checklist

- [ ] Unit tests written for all Lambda handlers (80%+ coverage)
- [ ] Contract tests validate JSON schemas (T029-T030)
- [ ] Integration tests cover S3 → EventBridge → Lambda flow
- [ ] X-Ray enabled on all Lambdas and Step Functions
- [ ] CloudWatch Logs Insights queries saved for key metrics
- [ ] CloudWatch Dashboards created for upload and processing pipelines
- [ ] CloudWatch Alarms configured for errors, DLQ, and failures
- [ ] Local testing strategy documented (Docker, SAM, pytest)
- [ ] Performance/load tests validate throughput

### Key Metrics to Monitor

1. **Latency**: Chunk upload → DynamoDB write (target: <200ms p95)
2. **Throughput**: Chunks uploaded/minute (scale test: 100 chunks/min)
3. **Error Rate**: Lambda errors < 1% of invocations
4. **Completeness**: Missing chunks = 0
5. **Cost**: Daily Bedrock token spend < $100

### Next Steps

1. Implement X-Ray configuration (T028g)
2. Deploy CloudWatch dashboards
3. Write integration tests
4. Run load tests in dev environment
5. Validate monitoring before production deployment
