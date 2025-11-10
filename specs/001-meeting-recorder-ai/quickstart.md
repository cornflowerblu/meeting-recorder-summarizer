# Quickstart (MVP)

This guide outlines the minimal steps to run the MVP locally and in AWS.

## Prerequisites

- macOS with Xcode 16 (Swift 6.1)
- AWS account with S3, DynamoDB, Step Functions, ECS Fargate, Lambda, KMS access
- AWS CLI configured

## High-level Steps

1. Create S3 bucket (private) and KMS key (if using SSE-KMS). Enable bucket policy to require TLS.
2. Create DynamoDB table `meetings` with GSIs (by_participant, by_tag, by_date).
3. Build and run the macOS app; configure bucket/table names and AWS profile.
4. Configure processing pipeline:
   - Fargate task with FFmpeg container (Dockerfile + process_video.py)
   - Lambda: StartProcessing (S3 event → Step Functions), StartTranscribe, BedrockSummarize
   - Step Functions state machine wiring the above; grant IAM permissions
5. Record a short session (2–5 mins). Verify chunks upload and appear in the app catalog.
6. Trigger processing and observe status. Inspect transcript and summary artifacts in S3.
7. Run evaluation script (once available) to record baseline metrics.

## Versioning & Observability

- Include `pipeline_version` and `model_version` fields in artifacts.
- Emit structured JSON logs without PII.

## Retention & Deletion

- Default retention: 30 days. Configure auto-delete policies per your preference.
- Deletion of a session removes video/audio/transcript/summary and the DynamoDB item within 24 hours.

Refer to `research.md` for decisions and to `data-model.md` for detailed schemas and object keys.
