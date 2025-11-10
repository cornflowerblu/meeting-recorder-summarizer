# Evaluation Guide

This document defines the baseline evaluation suite and acceptance thresholds for
speech recognition and meeting summarization quality. All changes MUST maintain or
improve these metrics unless an approved exception is documented.

## Metrics

- ASR (Transcription)
  - WER (Word Error Rate) — lower is better
  - CER (Character Error Rate) — optional for short utterances
- Summarization
  - ROUGE-L F1 — higher is better
  - BERTScore F1 — higher is better
  - Faithfulness (manual spot-checks with provenance links) — no critical hallucinations

## Thresholds and Regression Policy

- Relative regression permit: up to 2% on any single metric without compounding across
  metrics. Anything beyond requires an explicit justification, mitigation plan, and
  approval in the PR description.
- If a metric improves while another regresses, provide analysis to confirm overall
  utility is maintained for the target scenarios.

## Datasets

- Internal Eval Set
  - Domain: personal meeting recordings (screen + mic)
  - Size: target 5–10 meetings (30–60 mins each)
  - Storage: `s3://<your-bucket>/eval/` with transcripts and references
  - Access: restricted; do not include PII in file names or logs
- References
  - Transcripts: human-edited references stored as JSON (`{ts, speaker, text}`)
  - Summaries: human-written reference summaries capturing key decisions, action items,
    and timelines with timestamps

> Note: For public reproducibility, you MAY add a secondary public dataset (e.g., AMI)
> to sanity-check generalization. Keep privacy-sensitive sets separate.

## How To Run

- Local/CI invocation should produce a JSON report:
  - asr: { wer, cer }
  - summarization: { rougeL_f1, bertscore_f1 }
  - metadata: { model_version, data_hash, date }
- Store reports in `artifacts/eval/<date>/report.json` and attach as a CI artifact.
- CI must fail if any metric exceeds the allowed regression threshold without an opt-in
  bypass flag set by reviewers.

## Provenance & Traceability

- Every summary produced MUST include source references (timestamps and speakers) to
  enable spot-checking faithfulness.
- Include a model/pipeline version string in the report.

## Change Control

- When changing models, prompts, or pre/post-processing, update this document if
  thresholds or datasets change. Document rationale in the PR.
