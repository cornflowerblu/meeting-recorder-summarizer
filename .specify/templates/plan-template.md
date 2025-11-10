# Implementation Plan: [FEATURE]

**Branch**: `[###-feature-name]` | **Date**: [DATE] | **Spec**: [link]
**Input**: Feature specification from `/specs/[###-feature-name]/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.github/prompts/speckit.plan.prompt.md` for the execution workflow.

## Summary

[Extract from feature spec: primary requirement + technical approach from research]

## Technical Context

## Core Technologies

**macOS Application**

- Language: Swift 6.1
- UI Framework: SwiftUI
- Recording: AVFoundation (AVCaptureScreenInput, AVAssetWriter)
- AWS Integration: AWS SDK for Swift
- Testing: XCTest, XCUITest (UI automation if needed)

**Backend Processing**

- Container Runtime: AWS Fargate (ECS)
- Video Processing: FFmpeg (binary)
- Container Language: Rust 1.91 (lightweight entrypoint, optional)
- Orchestration: AWS Step Functions
- Event Triggers: EventBridge

**AWS Services**

- Storage: S3 (Standard → Glacier IR lifecycle)
- Transcription: Amazon Transcribe (batch mode, custom vocabulary)
- AI: Bedrock (Claude Sonnet 4.5)
- Database: DynamoDB (on-demand)
- Functions: Lambda (glue code between services)

**Testing Strategy**

- Unit Tests: XCTest for Swift logic
- Integration Tests: Mock AWS SDK calls with LocalStack
- UI Tests: XCUITest for critical user flows
- Manual Testing: Dogfooding (you're the primary user)

## Performance Targets

**Recording**

- Frame rate: 30 fps minimum, 60 fps target
- Resolution: 1080p (user configurable down to 720p)
- Chunk size: 60-second segments (~50-80MB each)
- Upload latency: < 60 seconds per chunk

**Processing**

- Full pipeline: < 30 minutes for 1-hour recording
- Transcribe: ~30 minutes (AWS service time)
- Bedrock summary: < 2 minutes
- FFmpeg concat/compress: < 5 minutes

**UI Responsiveness**

- Start/stop recording: < 500ms
- Form submission: < 1 second
- Search results: < 2 seconds

## Constraints

**Cost**

- Target: < $1.50 per hour of recording
- Maximum: $2.00 per hour (triggers cost review)

**Resource Usage**

- macOS app memory: < 500MB during recording
- Temp storage: < 2GB (auto-cleanup after upload)
- Network: 1-2 Mbps upload minimum required

**Reliability**

- Recording must never drop frames (priority over upload)
- Failed uploads queue for retry (up to 24 hours)
- Graceful degradation if AWS services unavailable

**Data Flow**

1. Recording → S3 Upload
   macOS App uses AWS SDK for Swift → Direct S3 multipart upload
   (No API needed - direct S3 access with IAM credentials)

2. Processing Trigger
   S3 Event → EventBridge → Step Functions
   (No API needed - AWS service-to-service integration)

3. Querying Meetings
   macOS App → DynamoDB directly via AWS SDK
   (No API needed - direct DynamoDB query with IAM credentials)

**Processing Pipeline**

Lambda 1: Start Processing
python# Triggered by S3 event when last chunk uploads
import boto3
import json

def handler(event, context):
    # Parse S3 event
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']
    
    # Extract recording_id from key
    recording_id = extract_recording_id(key)
    
    # Start Step Function execution
    stepfunctions = boto3.client('stepfunctions')
    stepfunctions.start_execution(
        stateMachineArn=os.environ['STATE_MACHINE_ARN'],
        input=json.dumps({
            'recording_id': recording_id,
            'bucket': bucket
        })
    )
Lambda 2: Start Transcribe Job
python# Called by Step Functions
import boto3

def handler(event, context):
    transcribe = boto3.client('transcribe')
    
    # Start Transcribe job
    transcribe.start_transcription_job(
        TranscriptionJobName=f"meeting-{event['recording_id']}",
        Media={'MediaFileUri': f"s3://{event['bucket']}/{event['audio_key']}"},
        MediaFormat='mp3',
        LanguageCode='en-US',
        Settings={
            'VocabularyName': 'aws-meetings-vocab',
            'ShowSpeakerLabels': True,
            'MaxSpeakerLabels': 5
        }
    )
    
    return {'job_name': f"meeting-{event['recording_id']}"}
Lambda 3: Bedrock Summarization
python# Called by Step Functions after Transcribe completes
import boto3
import json

def handler(event, context):
    # Get transcript from S3
    s3 = boto3.client('s3')
    transcript_obj = s3.get_object(
        Bucket=event['bucket'],
        Key=f"transcripts/{event['recording_id']}.json"
    )
    transcript = json.loads(transcript_obj['Body'].read())
    
    # Get participant names from DynamoDB
    dynamodb = boto3.resource('dynamodb')
    table = dynamodb.Table('meetings')
    meeting = table.get_item(Key={'recording_id': event['recording_id']})
    participants = meeting['Item']['participants']
    
    # Call Bedrock for summarization
    bedrock = boto3.client('bedrock-runtime')
    prompt = build_summary_prompt(transcript, participants)
    
    response = bedrock.invoke_model(
        modelId='anthropic.claude-sonnet-4-5-v2:0',
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 4000,
            "messages": [{
                "role": "user",
                "content": prompt
            }]
        })
    )
    
    # Parse and store summary
    result = json.loads(response['body'].read())
    summary = result['content'][0]['text']
    
    # Update DynamoDB with summary
    table.update_item(
        Key={'recording_id': event['recording_id']},
        UpdateExpression='SET summary = :s, status = :status',
        ExpressionAttributeValues={
            ':s': summary,
            ':status': 'completed'
        }
    )
    
    return {'status': 'success'}
Fargate Container (Heavy Video Processing)
For FFmpeg work (concatenating chunks, compressing, extracting audio), you need a container:
Dockerfile:
dockerfileFROM public.ecr.aws/amazonlinux/amazonlinux:2023

# Install FFmpeg
RUN yum install -y ffmpeg python3.11 pip

# Install AWS SDK
RUN pip3 install boto3

# Copy processing script
COPY process_video.py /app/
WORKDIR /app

CMD ["python3", "process_video.py"]
process_video.py (runs in Fargate):
pythonimport boto3
import subprocess
import os
import json

def process_recording(recording_id, bucket):
    s3 = boto3.client('s3')
    
    # 1. Download all chunks
    chunks = download_chunks(s3, bucket, recording_id)
    
    # 2. Create concat list for FFmpeg
    concat_file = create_concat_list(chunks)
    
    # 3. Concatenate chunks
    output_video = f"/tmp/{recording_id}_full.mp4"
    subprocess.run([
        'ffmpeg', '-f', 'concat', '-safe', '0',
        '-i', concat_file,
        '-c', 'copy',
        output_video
    ], check=True)
    
    # 4. Extract audio for Transcribe
    audio_file = f"/tmp/{recording_id}.mp3"
    subprocess.run([
        'ffmpeg', '-i', output_video,
        '-ar', '16000',  # 16kHz for Transcribe
        '-ac', '1',      # Mono
        '-b:a', '128k',
        audio_file
    ], check=True)
    
    # 5. Compress video
    compressed_video = f"/tmp/{recording_id}_compressed.mp4"
    subprocess.run([
        'ffmpeg', '-i', output_video,
        '-c:v', 'libx264',
        '-crf', '23',
        '-preset', 'medium',
        '-c:a', 'aac',
        '-b:a', '128k',
        compressed_video
    ], check=True)
    
    # 6. Upload results back to S3
    s3.upload_file(
        audio_file,
        bucket,
        f"audio/{recording_id}.mp3"
    )
    s3.upload_file(
        compressed_video,
        bucket,
        f"videos/{recording_id}.mp4"
    )
    
    # 7. Clean up chunks
    cleanup_chunks(s3, bucket, recording_id)
    
    return {
        'audio_key': f"audio/{recording_id}.mp3",
        'video_key': f"videos/{recording_id}.mp4"
    }

if __name__ == '__main__':
    # ECS task gets recording_id from environment
    recording_id = os.environ['RECORDING_ID']
    bucket = os.environ['BUCKET']
    
    result = process_recording(recording_id, bucket)
    print(json.dumps(result))
```


## Technology breakdown:

| Component | Language | Why |
|-----------|----------|-----|
| macOS App | Swift 6.1 | Native performance, AVFoundation, AWS SDK |
| Lambda Functions | **Python 3.13** | Simple, fast cold starts, excellent AWS SDK (boto3) |
| Fargate Container | **Python 3.13** | Need it to orchestrate FFmpeg and AWS SDK calls |
| API Layer | **None** | Not needed - direct AWS SDK usage |

## Why Python for Lambda/Fargate?

**Lambda**:
- Fastest cold start times for short-lived functions (except Node.js)
- boto3 is the best AWS SDK (most complete, best documented)
- Perfect for glue code between AWS services
- You're not doing heavy computation, just orchestrating

**Fargate Container**:
- Need something to orchestrate FFmpeg (which is a binary)
- Python makes AWS SDK calls simple
- Could use Rust/Go here for performance, but Python is fine since FFmpeg does the heavy lifting

## Alternative: Pure Rust/Go for Containers?

You *could* use Rust for the Fargate container:

**Pros**:
- Faster startup
- Lower memory usage
- Single static binary

**Cons**:
- More complex AWS SDK usage (aws-sdk-rust is less mature)
- More code for the same functionality
- Harder for future contributors (if you expand)

**Language Recommendation for Lambda and Fargate**: Use **Python 3.13 for Lambda and Fargate**. The processing is IO-bound (waiting on S3, FFmpeg), not CPU-bound, so Python's speed doesn't matter. Save Rust for when you have a real performance bottleneck.

## Revised Architecture Diagram
```
┌─────────────────────────────────────────────────────────────┐
│ macOS App (Swift 6.1)                                       │
│  - Records screen with AVFoundation                         │
│  - Uploads chunks to S3 (AWS SDK for Swift)                 │
│  - Queries DynamoDB directly (AWS SDK for Swift)            │
│  - No API calls needed                                      │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │  S3 Bucket    │
                    │  (chunks)     │
                    └───────────────┘
                            │
                            ▼ (S3 Event)
                    ┌───────────────┐
                    │ EventBridge   │
                    └───────────────┘
                            │
                            ▼
                ┌───────────────────────┐
                │  Step Functions       │
                │  (orchestrates flow)  │
                └───────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ Fargate Task │   │ Lambda       │   │ Lambda       │
│ (Python 3.13)│   │ (Python 3.13)│   │ (Python 3.13)│
│              │   │              │   │              │
│ - FFmpeg     │   │ Start        │   │ Bedrock      │
│ - Concat     │   │ Transcribe   │   │ Summary      │
│ - Extract    │   │              │   │              │
│   audio      │   │              │   │              │
└──────────────┘   └──────────────┘   └──────────────┘
        │                   │                   │
        ▼                   ▼                   ▼
    ┌───────────────────────────────────────────────┐
    │  S3 (videos, audio, transcripts, summaries)   │
    └───────────────────────────────────────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │  DynamoDB     │
                    │  (metadata)   │
                    └───────────────┘
                            ▲
                            │
            (Direct queries via AWS SDK)
                            │
                    ┌───────────────┐
                    │  macOS App    │
                    └───────────────┘
```


## Scale & Scope (MVP)

**Users**: 1 (personal use)
**Concurrent Recordings**: 1 per device
**Storage**: ~500GB/year (10 hours/week)
**Catalog**: Support 1000+ meetings
**Search**: Sub-second for meeting metadata queries

## Future Considerations (Post-MVP)

**iOS Version**: Explore if valuable for mobile screen recording
**Web Interface**: For searching/viewing from non-Mac devices
**Multi-user**: If team adoption desired (would require auth, user isolation)
**Advanced Features**: Speaker diarization, video chapters, AI chat interface

**Language/Version**: [Python 3.13, Swift 6.1, Rust 1.91.0]  
**Primary Dependencies**: [FastAPI, SwiftUI, LLVM, AWS SDK]  
**Storage**: [Dyanmo DB in AWS]  
**Testing**: [pytest, XCTest, XCUITest cargo test]
**Target Platform**: [Linux server, MacOS, Maybe iOS but we need to investigate further]
**Project Type**: [Mac desktop application leveraging AWS Cloud. I am open to a web version especially if that helps us with automated testing. iOS could be cool but it needs further discussion/exploration and should NOT be part of MVP]  
**Performance Goals**: [1/ Screen recording: 30 fps minimum, 60 fps target (1080p), 2/ Chunk upload: Complete within 60s of chunk creation (< S3 multipart timeout), 3/ Processing: Full pipeline (concat + transcribe + summarize) < 30 minutes for 1-hour meeting, and 4/ UI responsiveness: < 100ms for all user interactions].
**Constraints**: [1/ Memory: < 500MB during recording (macOS app), 2/ Storage: < 2GB disk space for temp chunks before upload, 3/ Network: Graceful degradation if upload fails (queue for retry), and 4/ Cost: < $2 per hour of recording (all AWS services)]  
**Scale/Scope**: [1/ Users: 1 (you) for MVP, 10-50 for future expansion, 2/ Concurrent recordings: 1 per user (no need to optimize for multiple simultaneous recordings), 3/ Storage: ~5-10 hours/week = 250-500GB/year, and 4/ Meetings catalog: Support 1000+ meetings searchable in DynamoDB]

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

Validate against `/.specify/memory/constitution.md`:

- [ ] Privacy & Consent: Recording requires explicit consent; redaction controls planned; no PII in logs
- [ ] Security & Retention: Encryption approach defined; retention defaults and deletion paths documented
- [ ] Quality Evaluation: Baseline metrics and datasets identified; success thresholds and regression policy set
- [ ] Transparency: Summaries link back to timestamps/speakers; model/pipeline version surfaced
- [ ] Observability & Versioning: Structured, redacted logging; required SemVer bumps and changelog entries captured

## Project Structure

### Documentation (this feature)

```text
specs/[###-feature]/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

<!--
  ACTION REQUIRED: Replace the placeholder tree below with the concrete layout
  for this feature. Delete unused options and expand the chosen structure with
  real paths (apps/admin, packages/something). The delivered plan must
  not include Option labels.
-->

```text
# [REMOVE IF UNUSED] Option 1: Single project (DEFAULT)
src/
├── models/
├── services/
├── cli/
└── lib/

tests/
├── contract/
├── integration/
└── unit/

# [REMOVE IF UNUSED] Option 2: Web application (when "frontend" + "backend" detected)
backend/
├── src/
│   ├── models/
│   ├── services/
│   └── api/
└── tests/

frontend/
├── src/
│   ├── components/
│   ├── pages/
│   └── services/
└── tests/

# [REMOVE IF UNUSED] Option 3: Mobile + API (when "iOS/Android" detected)
api/
└── [same as backend above]

ios/ or android/
└── [platform-specific structure: feature modules, UI flows, platform tests]
```

**Structure Decision**: [Document the selected structure and reference the real
directories captured above]

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation            | Why Needed         | Simpler Alternative Rejected Because |
| -------------------- | ------------------ | ------------------------------------ |
| [4th project]        | [current need]     | [why 3 projects insufficient]        |
| [Repository pattern] | [specific problem] | [why direct DB access insufficient]  |
