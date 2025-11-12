# Meeting Recorder with AI Intelligence

A macOS app for recording screen during calls with AI-powered transcription, summaries, action items, and key decisions. Designed for private, personal meeting records with explicit consent and persistent visual indicators.

## Overview

Meeting Recorder enables you to capture your own screen during calls for personal reference, then automatically generate:
- **Transcripts** with speaker labels
- **Meeting summaries** with timestamp links
- **Action items** with owners and due dates
- **Key decisions** with participant attribution

All processing happens in your AWS account with full data privacy and control.

## Key Features

### 🎥 Private Screen Recording
- Explicit per-session consent with first-run acknowledgment
- Persistent on-screen recording indicator (always visible)
- Pause/resume capability
- 60-second chunk segmentation for reliable uploads
- Automatic background sync to S3

### 🤖 AI-Powered Analysis
- **Amazon Transcribe** for accurate speech-to-text with speaker labels
- **Amazon Bedrock (Claude Sonnet 4.5)** for intelligent summarization
- Timestamp-linked summary elements for quick navigation
- Custom vocabulary support for domain-specific terms

### 🔍 Searchable Catalog
- Browse sessions by date, participants, or tags
- Quick filter and search across all meetings
- Metadata editing (title, participants, tags)
- Cost estimation before processing

### 🔐 Privacy & Security
- Single-user, your AWS account only
- Data encrypted at rest (S3 SSE)
- Data encrypted in transit (TLS 1.2+)
- No PII in logs
- Firebase Auth with Google Sign-In for cross-device sync

### 🛡️ Error Recovery
- Automatic retry with exponential backoff
- Resume uploads after app restart
- Processing status monitoring
- Failure notifications with retry options

## Architecture

### macOS App (Swift)
- **Native Swift + AVFoundation** for high-quality screen capture
- **SwiftUI** for modern, responsive UI
- **Firebase Auth** for authentication
- **AWS SDK Swift** for direct S3/DynamoDB access (no custom API layer)

### AWS Processing Pipeline
- **S3**: Durable storage for recordings and artifacts
- **DynamoDB**: Metadata catalog with GSI indexes for search
- **EventBridge → Step Functions**: Event-driven orchestration
- **Fargate**: FFmpeg video processing (concat, audio extraction)
- **Lambda (Python 3.13)**: Glue code for Transcribe and Bedrock
- **Amazon Transcribe**: Speech-to-text with speaker diarization
- **Amazon Bedrock**: Claude Sonnet 4.5 for summarization

### Data Flow
```
macOS App → S3 (chunks) → EventBridge → Step Functions
    ↓                                         ↓
DynamoDB (metadata)                     Fargate (FFmpeg)
                                              ↓
                                        Transcribe Job
                                              ↓
                                        Bedrock Summary
                                              ↓
                                        S3 (artifacts) + DynamoDB (status)
```

## Project Structure

```
meeting-recorder-summarizer/
├── macos/                    # Native macOS Swift app
│   ├── Sources/
│   │   └── MeetingRecorder/
│   │       ├── App/          # Main app entry and views
│   │       ├── Services/     # AWS, logging, config
│   │       ├── Models/       # Data models
│   │       ├── UI/           # SwiftUI views
│   │       └── Recording/    # Screen capture logic
│   ├── Tests/                # Unit and UI tests
│   └── Package.swift         # Swift package manifest
│
├── processing/               # Python Lambda functions
│   ├── lambdas/
│   │   ├── auth_exchange/    # Firebase → AWS STS
│   │   ├── start_processing/ # S3 event handler
│   │   ├── start_transcribe/ # Transcribe job starter
│   │   └── bedrock_summarize/# Bedrock invocation
│   ├── shared/               # Shared utilities
│   ├── fargate/              # FFmpeg Dockerfile
│   └── tests/                # Pytest tests
│
├── infra/                    # Terraform IaC
│   └── terraform/
│       ├── main.tf
│       ├── s3.tf
│       ├── dynamodb.tf
│       ├── iam.tf
│       └── stepfunctions.tf
│
├── specs/                    # Design documents
│   └── 001-meeting-recorder-ai/
│       ├── spec.md           # Feature specification
│       ├── plan.md           # Implementation plan
│       ├── tasks.md          # Task breakdown (75 tasks)
│       └── contracts/        # JSON schemas
│
└── docs/                     # Documentation
    └── eval.md               # Evaluation framework
```

## Getting Started

### Prerequisites

- macOS 14.0+ (Sonoma or later)
- Swift 6.0+
- Xcode 15.0+ (for development)
- Python 3.13+ (for Lambda development)
- AWS Account
- Firebase project with Google Sign-In enabled

### Development Setup

**1. Clone the repository**
```bash
git clone https://github.com/cornflowerblu/meeting-recorder-summarizer.git
cd meeting-recorder-summarizer
```

**2. Build the macOS app**
```bash
cd macos
swift build
```

**3. Set up Python environment**
```bash
cd ../processing
python3 -m venv venv
source venv/bin/activate
pip install -r lambdas/requirements.txt
pip install pytest pytest-cov ruff
```

**4. Run tests**
```bash
# Swift tests
cd macos
swift test

# Python tests
cd ../processing
pytest
```

**5. Deploy infrastructure (Phase 2+)**
```bash
cd infra/terraform
terraform init
terraform plan
terraform apply
```

## Implementation Status

### ✅ Phase 1: Setup (Complete)
- [x] Repository structure
- [x] Swift package with macOS app
- [x] Python Lambda scaffolding
- [x] Test infrastructure
- [x] Linting configuration

### ✅ Phase 2: Foundational (Complete)
- [x] Terraform infrastructure
- [x] S3 buckets and DynamoDB tables
- [x] IAM roles and policies
- [x] Firebase auth integration
- [x] AWS SDK configuration

### 📋 Upcoming Phases
- **Phase 3**: User Story 1 - Recording with consent and indicator (P1 - MVP)
- **Phase 4**: User Story 2 - AI transcription and summarization (P1)
- **Phase 5**: User Story 3 - Metadata capture and cost estimation (P2)
- **Phase 6**: User Story 4 - Catalog and search (P2)
- **Phase 7**: User Story 5 - Error recovery and monitoring (P2)

See [`specs/001-meeting-recorder-ai/tasks.md`](specs/001-meeting-recorder-ai/tasks.md) for the full 75-task breakdown.

## Cost Estimation

Approximate AWS costs for typical usage:
- **Amazon Transcribe**: ~$0.72/hour of audio
- **Amazon Bedrock (Claude Sonnet 4.5)**: ~$0.003/summary
- **S3 Storage**: ~$0.023/GB/month
- **DynamoDB**: Free tier covers typical usage
- **Other services**: Minimal (Lambda, EventBridge, Step Functions)

**Example**: 10 hours of meetings/month ≈ $10-15/month

## Development Workflow

This project follows a structured development approach:

1. **Specification-first**: All features documented in `specs/`
2. **TDD approach**: Tests written before implementation
3. **Phase-based execution**: 7 phases with clear checkpoints
4. **Independent user stories**: Each story is independently testable

See the [Constitution](docs/constitution.md) and [Evaluation Guide](docs/eval.md) for quality standards.

## Contributing

This is currently a personal project. Contributions are not being accepted at this time.

## License

Copyright © 2025. All rights reserved.

## Acknowledgments

- Built with [Claude Code](https://claude.com/claude-code)
- Powered by AWS services (S3, Transcribe, Bedrock, DynamoDB)
- Firebase Auth for authentication

---

**Status**: Phase 1 Complete | **Next**: Phase 2 - Foundational Infrastructure
