# Implementation Plan: [FEATURE]

**Branch**: `[###-feature-name]` | **Date**: [DATE] | **Spec**: [link]
**Input**: Feature specification from `/specs/[###-feature-name]/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.github/prompts/speckit.plan.prompt.md` for the execution workflow.

## Summary

Record and process personal meeting screen recordings on macOS with explicit per‑session consent and a persistent indicator; then automatically produce transcript, summary, action items, and key decisions with timestamp provenance and make them searchable by participants, date, and tags. MVP is single user (you), optimized for reliability of capture, secure storage, and fast retrieval (≤2s) for ≤1000 sessions. Technical approach: native macOS Swift app for high‑quality capture + incremental chunk uploads to object storage; an event‑driven AWS pipeline (FFmpeg concat + Amazon Transcribe + Bedrock summarization) writing structured artifacts (transcript, summary, actions, decisions) back to storage + DynamoDB metadata. Direct SDK access (no custom API layer) keeps scope lean; authentication & cross‑device catalog isolation via Firebase Auth with Google Sign-In + Lambda token exchange for AWS credentials.

## Technical Context

### Current State

Single-user macOS desktop application; no existing code. Feature spec finalized (Option B tech‑agnostic posture). Constitution v1.1.0 enforces: consent indicator, encryption, provenance, evaluation, structured redacted logging.

### Implementation Direction (MVP)

- Capture: Swift 6.1 + AVFoundation (`AVCaptureScreenInput`, `AVAssetWriter`) with 60s chunk segmentation (local temp files + background multipart uploads).
- Processing: Event-driven AWS pipeline (S3 event → EventBridge → Step Functions) orchestrating a Fargate task (FFmpeg heavy work) and Python 3.13 Lambdas (Transcribe job start, Bedrock summarization).
- Storage: S3 (raw chunks, compressed video, audio, transcript JSON, summary JSON); DynamoDB table for Meeting catalog & search keys.
- Search: DynamoDB primary key (`recording_id`) + GSIs (by participant, by date, by tag). Local client-side filtering for small result sets.
- Identity: Firebase Auth with Google Sign-In provides user email and unique user_id. macOS app exchanges Firebase ID token via Lambda (Python) for temporary AWS credentials using STS AssumeRole (1-hour session). DynamoDB partition key: `{user_id}#meeting-{id}` ensures cross-device catalog sync and data isolation between users.
- Cost Estimation: Simple formula (duration \* Transcribe rate + Bedrock tokens estimate + storage size). Exact rates pulled from config constants.
- Speaker Attribution: Rely on Transcribe speaker labels; post-process to map names where user supplied participants. Low confidence flagged for manual correction.
- Redaction: User may mark transcript segments for redaction post-processing; summary generation excludes redacted text. (Capture-time exclusion deferred.)
- Evaluation: Metrics & thresholds defined in `docs/eval.md` (WER, ROUGE-L, BERTScore). Initial baseline established after first pipeline run.
- Logging/Observability: Structured JSON logs (no PII, no raw audio/text). Each artifact annotated with `model_version`, `pipeline_version`, `recording_id`, `trace_id`.

### Key Decisions (Confirmed)

| Area                     | Decision                     | Rationale                                        |
| ------------------------ | ---------------------------- | ------------------------------------------------ |
| Recording Tech           | Native Swift + AVFoundation  | Lowest latency, quality, direct OS APIs          |
| Upload Strategy          | 60s chunks → S3 multipart    | Bounds memory, enables resumable retries         |
| Storage                  | S3 for all artifacts         | Durable, cheap, native Transcribe integration    |
| Processing Orchestration | Step Functions + EventBridge | Clear state machine, minimal custom glue         |
| Heavy Processing         | FFmpeg in Fargate (reads S3) | Isolation + avoids Lambda size/runtime limits    |
| Glue Code                | Python 3.13 Lambdas          | Fast iteration + mature boto3 SDK                |
| Transcription            | Amazon Transcribe (from S3)  | Speaker labels, custom vocabulary, $0.72/hour    |
| Model Invocation         | Bedrock (Claude Sonnet 4.5)  | High-quality summarization, speaker mapping      |
| Metadata Store           | DynamoDB                     | Fast queries, pointers to S3 objects             |
| Authentication           | Firebase Auth + Google       | Best UX, Lambda token exchange for AWS creds     |
| No Custom API Layer      | Direct SDK calls (S3 + DDB)  | Cuts scope & latency, native AWS SDK integration |

### Unknowns / Research Targets (Phase 0)

| ID    | Topic                       | What Must Be Answered                                           | Impact if Unresolved                    |
| ----- | --------------------------- | --------------------------------------------------------------- | --------------------------------------- |
| R-001 | ~~Auth Provider~~           | ~~Cognito vs local signed token vs pass-through IAM?~~          | ~~Cross-device catalog viability~~      |
|       | **RESOLVED: Firebase Auth** | **Using Firebase Auth with Google Sign-In + Lambda exchange**   | **N/A - Decision made**                 |
| R-002 | Chunk Upload Retry Strategy | S3 multipart retry policy, local queue implementation (SQLite?) | Data loss risk during recording         |
| R-003 | ~~Encryption Approach~~     | ~~Client-side vs server-side (SSE-S3 / KMS) decision~~          | ~~Security gate compliance~~            |
|       | **RESOLVED: SSE-S3**        | **Use S3 default encryption (SSE-S3), TLS in transit**          | **N/A - Decision made**                 |
| R-004 | Redaction UX                | How are transcript segments selected & marked for redaction?    | Privacy feature completeness (post-MVP) |
| R-005 | Cost Estimation Formula     | Precise duration → cost mapping for Transcribe/Bedrock/storage  | User trust in estimates                 |
| R-006 | DynamoDB GSI Design         | Exact partition/sort keys for participants, tags, date queries  | Search performance (<5s requirement)    |
| R-007 | ~~Baseline Eval Dataset~~   | ~~Source of representative audio for baseline~~                 | ~~Quality regression gating~~           |
|       | **DEFERRED: Post-MVP**      | **Manual spot-checking sufficient for dogfooding phase**        | **N/A - Not in MVP scope**              |
| R-008 | ~~Speaker Correction Flow~~ | ~~UI mechanism & data model updates for corrections~~           | ~~Transcript accuracy & trust~~         |
|       | **DEFERRED: Post-MVP**      | **AI mapping sufficient for MVP; manual edits in future**       | **N/A - Not in MVP scope**              |
| R-009 | ~~Pipeline Versioning~~     | ~~Scheme for semantic version increments & artifact tagging~~   | ~~Observability & provenance~~          |
|       | **DEFERRED: Post-MVP**      | **CloudTrail provides audit trail; explicit versioning later**  | **N/A - Not in MVP scope**              |

**Remaining Research Items (Phase 0)**

| ID    | Topic                       | What Must Be Answered                                                                                                | Impact if Unresolved             |
| ----- | --------------------------- | -------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| R-002 | Chunk Upload Retry Strategy | S3 multipart retry backoff policy, local persistence (SQLite?)                                                       | Data loss risk during recording  |
| R-005 | Cost Estimation Formula     | Duration → Transcribe ($0.012/min batch) + Bedrock (tokens/hr) + S3 rates                                            | User trust in cost preview       |
| R-006 | DynamoDB GSI Design         | GSI-1: `user_id` + `created_at` (date queries) <br> GSI-2: `user_id#participant` + `created_at` (participant filter) | Search latency (<2s requirement) |

### Risks & Mitigations

- Recording Interruption: Local chunk queue with integrity checksum; background retry worker.
- Large Sessions (>3h): Rolling chunk flush; ensure FFmpeg concat list memory constant.
- Transcribe Delay: Parallel post-processing preparation (action item extraction stub waits on transcript). Alert if exceeding SLA.
- Cost Overrun: Pre-processing estimate warning threshold ($1.50 target, >$2.00 triggers review) before user starts processing.
- Privacy Leakage: Automated PII scrub (names/emails) during logging; validate via test cases.

### Initial Data Model Sketch (High-Level)

**DynamoDB Table: `meetings`**

- **PK**: `user_id#recording_id` (e.g., `firebase-uid-123#meeting-abc-2025-11-10`)
- **SK**: `METADATA` (allows future item types like `TRANSCRIPT_SEGMENT`, `COMMENT`)
- **Attributes**:
  - `user_id`: Firebase UID
  - `recording_id`: Unique meeting identifier
  - `title`: Meeting title
  - `participants`: List of names (e.g., `["Roger", "Sarah", "Mike"]`)
  - `tags`: List of tags (e.g., `["Q4", "strategy", "GSP"]`)
  - `created_at`: ISO timestamp (e.g., `2025-11-10T14:30:00Z`)
  - `duration_seconds`: Recording length
  - `status`: `uploading` | `processing` | `completed` | `failed`
  - `s3_paths`: Object with keys `{chunks, video, audio, transcript, summary}`
  - `costs`: Object with keys `{transcribe, bedrock, storage, total}`

**GSIs (Global Secondary Indexes)**:

- **GSI-1 (DateSearch)**:
  - PK: `user_id`
  - SK: `created_at`
  - Purpose: List all meetings for user, sorted by date
- **GSI-2 (ParticipantSearch)**:
  - PK: `user_id#participant` (e.g., `firebase-uid-123#Sarah`)
  - SK: `created_at`
  - Purpose: Find meetings with specific participant
  - Note: Requires denormalization (one item per participant per meeting)
- **GSI-3 (TagSearch)**:
  - PK: `user_id#tag` (e.g., `firebase-uid-123#Q4`)
  - SK: `created_at`
  - Purpose: Find meetings with specific tag
  - Note: Requires denormalization (one item per tag per meeting)

**S3 Structure**:

```
s3://bucket-name/
  users/
    {user_id}/
      chunks/
        {recording_id}/
          chunk-001.mp4
          chunk-002.mp4
      videos/
        {recording_id}.mp4
      audio/
        {recording_id}.mp3
      transcripts/
        {recording_id}.json
      summaries/
        {recording_id}.json
```

**Transcript JSON Schema** (`transcripts/{recording_id}.json`):

```json
{
  "recording_id": "meeting-abc-2025-11-10",
  "duration_seconds": 3600,
  "speakers_detected": 3,
  "segments": [
    {
      "start_ms": 0,
      "end_ms": 3440,
      "speaker_label": "spk_0",
      "speaker_name": "Roger",
      "text": "So let's talk about our Q4 strategy.",
      "confidence": 0.98,
      "words": [
        { "word": "So", "start_ms": 0, "end_ms": 240, "confidence": 0.99 },
        { "word": "let's", "start_ms": 240, "end_ms": 520, "confidence": 0.98 }
      ]
    }
  ],
  "speaker_mapping": {
    "spk_0": "Roger",
    "spk_1": "Sarah",
    "spk_2": "Mike"
  }
}
```

**Summary JSON Schema** (`summaries/{recording_id}.json`):

```json
{
  "recording_id": "meeting-abc-2025-11-10",
  "generated_at": "2025-11-10T15:45:00Z",
  "model_version": "claude-sonnet-4-5-20250514",
  "summary": "Roger led discussion about Q4 strategy focusing on...",
  "action_items": [
    {
      "id": "action-001",
      "owner": "Sarah",
      "task": "Follow up with Accenture leadership on partnership terms",
      "due_date": "2025-11-17",
      "source_segments": [12, 13, 14],
      "timestamp_ms": 145000
    }
  ],
  "key_decisions": [
    {
      "id": "decision-001",
      "decision": "Prioritize GSP partnerships over direct enterprise sales",
      "rationale": "Better leverage and faster market penetration",
      "source_segments": [8, 9],
      "timestamp_ms": 98000
    }
  ]
}
```

**Redaction Model** (Post-MVP):

- Stored in DynamoDB item: `redacted_segments: [{start_ms, end_ms, reason}]`
- Applied dynamically when rendering summary/transcript in UI
- Redacted segments show as `[REDACTED]` in display but remain in S3

### Out-of-Scope (MVP)

- Multi-user team sharing
- Web interface (view/search)
- iOS app
- Offline local-only pipeline
- Advanced diarization beyond Transcribe speaker labels

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

def handler(event, context): # Parse S3 event
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

def handler(event, context): # Get transcript from S3
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

if **name** == '**main**': # ECS task gets recording_id from environment
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
│ macOS App (Swift 6.1) │
│ - Records screen with AVFoundation │
│ - Uploads chunks to S3 (AWS SDK for Swift) │
│ - Queries DynamoDB directly (AWS SDK for Swift) │
│ - No API calls needed │
└─────────────────────────────────────────────────────────────┘
│
▼
┌───────────────┐
│ S3 Bucket │
│ (chunks) │
└───────────────┘
│
▼ (S3 Event)
┌───────────────┐
│ EventBridge │
└───────────────┘
│
▼
┌───────────────────────┐
│ Step Functions │
│ (orchestrates flow) │
└───────────────────────┘
│
┌───────────────────┼───────────────────┐
▼ ▼ ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ Fargate Task │ │ Lambda │ │ Lambda │
│ (Python 3.13)│ │ (Python 3.13)│ │ (Python 3.13)│
│ │ │ │ │ │
│ - FFmpeg │ │ Start │ │ Bedrock │
│ - Concat │ │ Transcribe │ │ Summary │
│ - Extract │ │ │ │ │
│ audio │ │ │ │ │
└──────────────┘ └──────────────┘ └──────────────┘
│ │ │
▼ ▼ ▼
┌───────────────────────────────────────────────┐
│ S3 (videos, audio, transcripts, summaries) │
└───────────────────────────────────────────────┘
│
▼
┌───────────────┐
│ DynamoDB │
│ (metadata) │
└───────────────┘
▲
│
(Direct queries via AWS SDK)
│
┌───────────────┐
│ macOS App │
└───────────────┘

````


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
**Storage**: [DynamoDB in AWS]
**Testing**: [pytest, XCTest, XCUITest cargo test]
**Target Platform**: [Linux server, MacOS, Maybe iOS but we need to investigate further]
**Project Type**: [Mac desktop application leveraging AWS Cloud. I am open to a web version especially if that helps us with automated testing. iOS could be cool but it needs further discussion/exploration and should NOT be part of MVP]
**Performance Goals**: [1/ Screen recording: 30 fps minimum, 60 fps target (1080p), 2/ Chunk upload: Complete within 60s of chunk creation (< S3 multipart timeout), 3/ Processing: Full pipeline (concat + transcribe + summarize) < 30 minutes for 1-hour meeting, and 4/ UI responsiveness: < 100ms for all user interactions].
**Constraints**: [1/ Memory: < 500MB during recording (macOS app), 2/ Storage: < 2GB disk space for temp chunks before upload, 3/ Network: Graceful degradation if upload fails (queue for retry), and 4/ Cost: < $2 per hour of recording (all AWS services)]
**Scale/Scope**: [1/ Users: 1 (you) for MVP, 10-50 for future expansion, 2/ Concurrent recordings: 1 per user (no need to optimize for multiple simultaneous recordings), 3/ Storage: ~5-10 hours/week = 250-500GB/year, and 4/ Meetings catalog: Support 1000+ meetings searchable in DynamoDB]

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

Validate against `/.specify/memory/constitution.md` (v1.1.0):

- [x] Privacy & Consent: Explicit per-session start + persistent indicator; transcript redaction post-processing planned (R-004) → TASK: implement redaction data model & UI before Phase 1 completion.
- [~] Security & Retention: Encryption intent captured (R-003); retention policy placeholders (FR-012) need concrete defaults & deletion workflow tests → TASK: define encryption + retention spec in `research.md` then codify in `data-model.md`.
- [x] Quality Evaluation: Metrics & thresholds documented in `docs/eval.md`; need baseline dataset acquisition (R-007) → TASK: populate dataset & record baseline in CI.
- [x] Transparency: Summary/action/decision artifacts will include timestamp references & speaker labels; pipeline/model version tagging pending versioning scheme (R-009).
- [x] Observability & Versioning: Plan for structured JSON logs, SemVer for pipeline; need concrete versioning policy doc → TASK: add `pipeline-versioning.md` or section in `quickstart.md` (R-009).

Status Legend: [x]=Pass, [~]=Partial (must resolve before Phase 1 exit), [ ]=Fail.

No blockers to begin Phase 0; partial items scheduled for research tasks.

### Phase 0 Exit Criteria
- All R-00x unknowns answered & documented in `research.md`.
- Constitution Check all items [x] or justified with implementation plan & tests.
- Baseline evaluation metrics recorded.

### Phase 1 Exit Criteria
- Data model + contracts reflect redaction, retention, versioning.
- Encryption path chosen & tested.
- Logging format + trace IDs defined; sample logs validated.
- Updated Constitution Check shows full [x] passes.

### Gate Tasks Mapping
| Gate | Task Reference |
|------|----------------|
| Privacy & Consent | R-004 redaction UX + data model |
| Security & Retention | R-003 encryption decision; retention policy test cases |
| Quality Evaluation | R-007 baseline dataset + eval run |
| Transparency | R-009 version tagging scheme + timestamp linking tests |
| Observability & Versioning | Structured log schema + SemVer policy doc |

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
````

### Source Code (repository root)

<!--
  ACTION REQUIRED: Replace the placeholder tree below with the concrete layout
  for this feature. Delete unused options and expand the chosen structure with
  real paths (apps/admin, packages/something). The delivered plan must
  not include Option labels.
-->

```text
macos/                    # Swift macOS app (recording UI, catalog, playback)
    ├── App/                # App entry, SwiftUI scene
    ├── Recording/          # Capture controller, chunk writer
    ├── UI/                 # Views (indicator, metadata form, catalog, playback)
    ├── Services/           # AWS SDK wrappers (S3, DynamoDB)
    ├── Models/             # Local models (Recording, TranscriptSegment, SummaryItem, ActionItem)
    └── Tests/              # XCTest (unit + UI tests)

processing/               # Cloud processing code
    ├── lambdas/            # Python lambda functions (start, transcribe, summarize)
    ├── fargate/            # FFmpeg container (Dockerfile + process_video.py)
    └── shared/             # Shared utilities (logging, S3 helpers)

infra/                    # IaC (Terraform or CloudFormation) - to be decided in R-003
    ├── modules/
    └── envs/

specs/                    # Feature specs & plans (existing)
docs/                     # Evaluation guide, architecture, versioning, quickstart
scripts/                  # Local helper scripts (build, deploy, eval)

tests/                    # Integration/e2e tests (may call processing pipeline locally / mocks)
```

**Structure Decision**: Adopt single-repo, multi-folder layout separating macOS client, processing pipeline, infra-as-code, and shared docs/scripts. No separate API layer (direct SDK). Keeps cognitive load low for single-user MVP while allowing modular growth.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --------- | ---------- | ------------------------------------ |
| (none)    | —          | —                                    |
