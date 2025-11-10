<!--
Sync Impact Report
Version change: 1.0.0 → 1.1.0
Modified principles:
  - I. Privacy & Consent First: clarified explicit consent and visible indicator requirements
Added sections: —
Removed sections: —
Templates requiring updates:
  ✅ .specify/templates/plan-template.md (remains aligned)
  ✅ .specify/templates/spec-template.md (no changes required)
  ✅ .specify/templates/tasks-template.md (no changes required)
  ⚠ .github/prompts/speckit.plan.prompt.md (review for consistency; no change applied)
Follow-up TODOs:
  - Define and store baseline evaluation datasets and metrics in docs/eval.md (ROUGE-L, BERTScore, WER)
  - Add a PR checklist that maps to the Constitution Gates in /.github/PULL_REQUEST_TEMPLATE.md
-->

# Meeting Recorder Summarizer Constitution

## Core Principles

### I. Privacy & Consent First (NON-NEGOTIABLE)

Users MUST be able to pause, exclude parts of a meeting, or request redaction of specific
segments. Data collection MUST follow data minimization: collect only what is strictly
necessary for transcription and summarization.

Rationale: Trust and regulatory compliance depend on transparent consent and control.

### II. Data Security & Retention

All content (audio, transcripts, summaries, metadata) MUST be encrypted in transit
(TLS 1.2+) and at rest (AES‑256 or platform equivalent). Access MUST follow least
privilege with role-based controls and audit trails. Retention MUST be configurable; the
default retention is 30 days. Upon user deletion request, data MUST be hard‑deleted
within 30 days. Logs and exports MUST redact PII by default.

Rationale: Sensitive meeting data requires strong protection and predictable lifecycle.

### III. Test‑First & Quality Evaluation

All changes MUST follow test‑first discipline (unit + integration where applicable).
The system MUST maintain an evaluation suite for speech recognition and summarization
quality. Changes MUST not degrade baseline metrics (e.g., ROUGE‑L, BERTScore, WER)
beyond a 2% relative drop without approved justification and documented mitigation.

Rationale: Quality must be measurable and protected against regressions.

### IV. Transparent Summaries & Provenance

Summaries MUST link back to source segments with timestamps and speaker attribution.
Each generated artifact MUST record the model/pipeline version used. Where supported,
surface confidence or uncertainty cues and provide an in‑product feedback loop to
correct errors.

Rationale: Users need traceability to trust and correct the system.

### V. Observability & Versioning Discipline

Operational logs MUST be structured and PII‑redacted, supporting trace IDs and stable
error codes. No raw audio or full transcripts are permitted in logs. Public contracts
(APIs/CLIs/exports) and the ML pipeline MUST use semantic versioning. Releases MUST
include change logs, rollout plans (e.g., A/B or staged), and rollback procedures.

Rationale: Safe evolution requires visibility and controlled change.

## Additional Constraints

- Interface modality MAY be CLI, API, or UI, but contracts MUST be documented and
  testable end‑to‑end.
- Data residency requirements MUST be supported where demanded by customers or law.
- Third‑party vendors (storage, transcription, LLMs) MUST pass a security and privacy
  review prior to use; DPA/SCCs MUST be in place where applicable.
- An offline/edge mode MAY be provided; when enabled, data MUST remain local unless
  users explicitly opt‑in to cloud processing.

## Development Workflow & Quality Gates

Every PR MUST pass the Constitution Gates:

1. Privacy & Consent: No collection without consent; redaction controls present; no
   PII in logs.
2. Security & Retention: Encryption configurations intact; retention honored; deletion
   paths tested.
3. Quality Evaluation: Tests added/updated; evaluation suite run; no >2% relative
   regression without approval.
4. Transparency: Summaries link to source timestamps/speakers; version metadata
   present.
5. Observability & Versioning: Structured, redacted logs; appropriate SemVer bump and
   changelog entry.

Release Process:

- Use feature branches and PR reviews with at least one reviewer.
- Require green CI for tests and evaluation checks before merge.
- Record release notes and affected versions for contracts and ML pipeline.

## Governance

- This constitution supersedes other practice guides where conflicts exist.
- Amendments require a PR that includes: redlined changes, migration/impact analysis,
  version bump proposal, and owner approval.
- Versioning Policy: MAJOR for breaking governance changes; MINOR for new principles
  or materially expanded guidance; PATCH for clarifications or non‑semantic edits.
- Compliance: Each PR reviewer MUST verify gates. A quarterly review MUST reaffirm
  compliance and update gates/metrics as needed.

**Version**: 1.1.0 | **Ratified**: 2025-11-10 | **Last Amended**: 2025-11-10
