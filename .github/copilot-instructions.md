# Copilot Instructions: Meeting Recorder with AI Intelligence

## Architecture Overview

**Multi-platform, event-driven system**: Native macOS Swift app uploads recording chunks to S3 → AWS processing pipeline (EventBridge → Step Functions → Fargate/Lambda) → generates transcript/summary artifacts → stores in S3 + DynamoDB catalog.

### Component Boundaries

- **macOS App** (`macos/`): Swift 6.1 + AVFoundation screen capture, Firebase Auth, direct AWS SDK calls (no custom API)
- **Processing Pipeline** (`processing/`): Python 3.13 Lambdas (glue code) + Fargate (FFmpeg video processing)
- **Infrastructure** (`infra/terraform/`): Terraform for S3, DynamoDB, IAM, EventBridge, Step Functions
- **Specs** (`specs/001-meeting-recorder-ai/`): Complete feature spec, 75-task breakdown, JSON schema contracts

### Critical Data Flows

1. **Recording**: AVFoundation → 60s chunks → local queue → S3 multipart upload (`users/{user_id}/chunks/{recording_id}/`)
2. **Auth**: Firebase ID token → Lambda (`auth_exchange`) → STS AssumeRole → temporary AWS credentials (1-hour session)
3. **Processing**: S3 event → EventBridge → Step Functions → Fargate (FFmpeg concat/extract) → Transcribe job → Bedrock summary → artifacts to S3 + DynamoDB metadata
4. **Catalog**: DynamoDB table `meetings` with PK `user_id#recording_id`, GSI-1 for date search (`user_id` + `created_at`)

## Development Workflows

### Build & Test Commands

```bash
# macOS Swift app
cd macos && swift build            # Build
swift test                         # Run tests

# Python pipeline
cd processing
python3 -m venv venv && source venv/bin/activate
pip install -r lambdas/requirements.txt
pytest                             # Run tests (no tests exist yet - TDD approach)
ruff check .                       # Lint

# Infrastructure
cd infra/terraform
terraform init
terraform plan
terraform apply
```

### Task Execution Model

- **Phase-based**: Currently Phase 2 (Foundational) in progress. See `specs/001-meeting-recorder-ai/tasks.md` for 75 numbered tasks across 7 phases
- **Task IDs**: Reference as `MR-XX (TXXX)` in commits, e.g., `MR-13 (T006)` for Terraform scaffolding
- **TDD Required**: Write failing tests FIRST before implementation (see `processing/pytest.ini` config). In code reviews, actively call out missing or insufficient test coverage.
- **User Story Independence**: Each story (US1-US5) must be independently testable/deployable
- **AWS Region**: Use `us-east-1` as the default region for all resources unless explicitly configured otherwise

## Project-Specific Conventions

### File Organization Patterns

- **Swift**: Services in `macos/Sources/MeetingRecorder/Services/` (Config, Logger, AWSConfig singleton pattern)
- **Python**: Lambdas in `processing/lambdas/{function_name}/handler.py`, shared utilities in `processing/shared/`
- **Schemas**: JSON schemas in `specs/001-meeting-recorder-ai/contracts/schemas/` define transcript/summary structure

### Naming & Identifiers

- **Recording IDs**: ULIDs or UUIDs (e.g., `rec_01JCXYZ123`)
- **DynamoDB Keys**: Composite format `user_id#recording_id` for PK, `METADATA` for SK
- **S3 Paths**: `users/{user_id}/{category}/{recording_id}.ext` (categories: chunks, videos, audio, transcripts, summaries)

### Privacy & Security Requirements (Constitution Gates)

- **NO PII in logs**: Use structured logging with automatic filtering (`Logger.swift`, `logging.py`)
- **Encryption**: S3 SSE-S3 at rest, TLS 1.2+ in transit, deny non-TLS in IAM policies
- **Provenance**: Every artifact MUST include `pipeline_version`, `model_version`, `recording_id` (see JSON schemas)

### Configuration Management

- **Swift**: `Config.shared` singleton loads from `AWSConfig.swift` constants + environment
- **Python**: `Config` class in `processing/shared/config.py` loads from environment variables
- **Terraform**: Variables in `terraform.tfvars` (gitignored), example in `terraform.tfvars.example`

### Pipeline Versioning

All artifacts (transcripts, summaries) MUST include version metadata for observability and debugging:

- **`pipeline_version`**: Use semantic versioning (e.g., `1.0.0`). Increment for pipeline logic changes:
  - MAJOR: Breaking schema changes or fundamental processing changes
  - MINOR: New features or model changes (e.g., switching Transcribe settings)
  - PATCH: Bug fixes or parameter tuning
- **`model_version`**: Specific AI model identifier (e.g., `anthropic.claude-sonnet-4-20250514`, `amazon-transcribe-2023`)
- **Current Version**: Start with `1.0.0` for MVP. Update in `processing/shared/config.py` as `PIPELINE_VERSION` constant
- **Where to Set**: Lambda functions should read from `Config.PIPELINE_VERSION` and include in all artifact JSON outputs

## Integration Points

### AWS Service Usage Patterns

```python
# Python Lambdas: Use shared Config for consistency
from shared.config import Config
from shared.logging import get_logger

logger = get_logger(__name__)
s3_bucket = Config.S3_BUCKET_NAME  # Environment-driven
```

```swift
// Swift: Direct AWS SDK calls (no custom API layer)
let config = Config.shared
let credentials = // from Firebase → auth_exchange Lambda
// Upload directly to S3 using AWS SDK Swift
```

### Authentication Flow

1. User signs in with Google via Firebase Auth
2. macOS app sends Firebase ID token to `auth_exchange` Lambda
3. Lambda validates token, calls STS AssumeRoleWithWebIdentity
4. Returns temporary AWS credentials (AccessKeyId, SecretAccessKey, SessionToken)
5. App uses credentials for direct S3/DynamoDB SDK calls

### Processing Pipeline Orchestration

- **Trigger**: S3 event on chunk upload completion → EventBridge rule
- **State Machine**: Step Functions coordinates FFmpeg (Fargate), Transcribe (Lambda start job), Bedrock (Lambda summarize)
- **Status Updates**: Lambdas update DynamoDB `meetings` table `status` field (`pending` → `processing` → `completed`/`failed`)

## JSON Contract Requirements

**All artifacts must validate against schemas** in `specs/001-meeting-recorder-ai/contracts/schemas/`:

### Transcript (`transcript.schema.json`)

```json
{
  "recording_id": "rec_abc123",
  "segments": [
    {
      "id": "seg_001",
      "start_ms": 0,
      "end_ms": 5000,
      "speaker_label": "spk_0",
      "text": "..."
    }
  ],
  "speaker_map": { "spk_0": { "name": "Roger", "confidence": 0.9 } },
  "pipeline_version": "1.0.0",
  "model_version": "amazon-transcribe-2023"
}
```

### Summary (`summary.schema.json`)

```json
{
  "recording_id": "rec_abc123",
  "summary_text": "...",
  "actions": [
    {
      "id": "act_001",
      "description": "...",
      "owner": "Roger",
      "source_timestamp_ms": 12000
    }
  ],
  "decisions": [
    { "id": "dec_001", "decision": "...", "source_timestamp_ms": 45000 }
  ],
  "pipeline_version": "1.0.0",
  "model_version": "anthropic.claude-sonnet-4-20250514"
}
```

## Quality & Evaluation

### Testing Standards

- **Test-First Mandate**: Write failing tests BEFORE implementation. No exceptions.
- **Code Review Focus**: In reviews, prioritize test coverage feedback. Flag any PR with:
  - Missing tests for new functionality
  - Insufficient edge case coverage
  - Tests that don't fail when implementation is removed
- **Contract Tests**: Validate all JSON artifacts against schemas (use `jsonschema` library)
- **Test Structure**: Implement test tasks (T057-T059) before feature work begins
- **Pytest Markers**: `@pytest.mark.unit`, `@pytest.mark.integration`, `@pytest.mark.contract` (see `pytest.ini`)
- **Swift Tests**: Unit tests in `Tests/MeetingRecorderTests/`, UI tests in `Tests/MeetingRecorderUITests/`

### Evaluation Framework (`docs/eval.md`)

- **ASR Metrics**: WER (Word Error Rate) - target <15% for clean audio
- **Summarization Metrics**: ROUGE-L F1, BERTScore F1
- **Regression Threshold**: ≤2% relative degradation without justification
- **Provenance Requirement**: All summary elements MUST link to source timestamps

## Key Files for Context

When working on specific areas, review these foundational files first:

| Area                 | Key Files                                                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------------- |
| Architecture         | `README.md`, `specs/001-meeting-recorder-ai/spec.md`, `specs/001-meeting-recorder-ai/plan.md`           |
| Data Model           | `specs/001-meeting-recorder-ai/data-model.md`, `specs/001-meeting-recorder-ai/contracts/schemas/*.json` |
| Task Planning        | `specs/001-meeting-recorder-ai/tasks.md` (75 tasks), `docs/phase2-execution-plan.md`                    |
| Swift Configuration  | `macos/Sources/MeetingRecorder/Services/{Config,AWSConfig,Logger}.swift`                                |
| Python Configuration | `processing/shared/{config,logging}.py`                                                                 |
| Infrastructure       | `infra/README.md`, `infra/terraform/{main,s3,dynamodb,iam}.tf`                                          |

## Common Pitfalls

1. **Don't create custom API layer**: Use AWS SDK directly from macOS app (architecture decision)
2. **Never log PII**: Email/names only in structured metadata, not logs
3. **Always include provenance**: `pipeline_version`, `model_version`, `recording_id` in all artifacts
4. **Use composite keys**: DynamoDB PK format is `user_id#recording_id`, not separate fields
5. **Validate schemas**: All transcript/summary JSON must pass schema validation before storage
6. **Follow task IDs**: Reference `MR-XX (TXXX)` format from `tasks.md` in commits/PRs
