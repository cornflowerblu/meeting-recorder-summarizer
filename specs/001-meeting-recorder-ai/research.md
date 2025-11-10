# Phase 0 Research - DECISIONS

Goal: Resolve unknowns to de-risk MVP implementation.

## RESOLVED DECISIONS

### R-001: Auth Provider ✅ RESOLVED

**Question**: How to authenticate users for cross-device access?

**Decision**: **Firebase Authentication with Google Sign-In**

- Lambda exchanges Firebase ID token for temporary AWS credentials (STS AssumeRole)
- User identity: Firebase UID
- Cross-device sync: Automatic via shared Firebase account
- Implementation time: ~4-6 hours including testing

**Rationale**: Better UX than Cognito, simpler than managing IAM directly, enables Google Workspace integration.

---

### R-003: Encryption ✅ RESOLVED

**Question**: Client-side vs server-side encryption?

**Decision**: **S3 default encryption (SSE-S3) + TLS in transit**

- Bucket-level encryption enabled
- IAM policies enforce HTTPS-only access
- Local temp files: macOS sandbox with secure deletion post-upload

**Rationale**: Zero key management overhead, sufficient security for MVP, can upgrade to SSE-KMS later if needed.

---

### R-006: GSI Design ✅ RESOLVED

**Question**: DynamoDB index structure for search?

**Decision**:

- **Primary Key**: `user_id#recording_id` (ensures user isolation)
- **GSI-1 (DateSearch)**: PK=`user_id`, SK=`recorded_at`
- **GSI-2 (ParticipantSearch)**: PK=`user_id#participant`, SK=`recorded_at` (denormalized)
- **GSI-3 (TagSearch)**: PK=`user_id#tag`, SK=`recorded_at` (denormalized)

**Rationale**: User isolation via partition key, efficient date-range queries, participant/tag filtering with acceptable denormalization cost.

---

## ACTIVE RESEARCH (Phase 0)

### R-002: Chunk Upload Retry Strategy 🔬 IN PROGRESS

**Question**: How to handle chunk upload failures without blocking recording?

**Approach**:

- Local queue: `manifest.jsonl` with entries `{chunk_id, path, size, checksum, attempts, last_error}`
- Background worker: Exponential backoff (max 24h retry window)
- Validation: Verify S3 ETag matches local checksum post-upload
- Resume: Scan manifest on app restart, resume incomplete uploads

**Next Steps**:

1. Implement manifest format
2. Test offline→online transitions
3. Validate no memory leaks during long recordings

---

### R-005: Cost Estimation Formula 🔬 IN PROGRESS

**Question**: Accurate cost preview (±25% tolerance)?

**Approach**:

```
Transcribe: duration_minutes * $0.012 (batch pricing)
Bedrock: (duration_minutes * 130 wpm * 4 chars/word / 1000) * $3/M input
         + (estimated_summary_tokens / 1000) * $15/M output
S3: file_size_gb * $0.023/month
Total: Sum + 10% buffer
```

**Validation**: Track `cost_estimate` vs `cost_actual` for first 10 recordings, tune heuristic if error >25%.

**Next Steps**: Implement formula, add to metadata form UI

---

## DEFERRED (Post-MVP)

### R-004: Redaction UX ⏸️ DEFERRED

**Question**: How to mark transcript segments for exclusion?

**Post-MVP Approach**: Transcript viewer with time-range selection → create `RedactionRule{start_ms, end_ms, reason}` → re-render summaries excluding redacted content.

**Why Deferred**: Not critical for dogfooding phase, adds UI complexity.

---

### R-007: Baseline Evaluation Dataset ⏸️ DEFERRED

**Question**: How to measure transcription/summarization quality?

**Post-MVP Approach**: Manual spot-checking during dogfooding is sufficient for MVP. Formal evaluation framework when scaling to team.

**Why Deferred**: Not gating for single-user MVP.

---

### R-008: Speaker Correction Flow ⏸️ DEFERRED

**Question**: UI for correcting speaker attribution?

**Post-MVP Approach**: Bedrock AI mapping sufficient for MVP. Manual correction UI added when users report mapping errors.

**Why Deferred**: AI mapping likely accurate enough for 2-3 person meetings.

---

### R-009: Pipeline Versioning ⏸️ DEFERRED

**Question**: How to track artifact schema versions?

**Post-MVP Approach**: CloudTrail provides audit trail for now. Add explicit `pipeline_version` field when introducing breaking changes.

**Why Deferred**: Single developer, no schema migrations needed yet.

---

## Decision Log

| ID    | Topic              | Status      | Date       | Owner                |
| ----- | ------------------ | ----------- | ---------- | -------------------- |
| R-001 | Auth Provider      | ✅ RESOLVED | 2025-11-10 | Firebase Auth        |
| R-002 | Chunk Retry        | 🔬 ACTIVE   | -          | Needs validation     |
| R-003 | Encryption         | ✅ RESOLVED | 2025-11-10 | SSE-S3               |
| R-004 | Redaction UX       | ⏸️ DEFERRED | -          | Post-MVP             |
| R-005 | Cost Formula       | 🔬 ACTIVE   | -          | Needs implementation |
| R-006 | GSI Design         | ✅ RESOLVED | 2025-11-10 | user_id scoping      |
| R-007 | Eval Dataset       | ⏸️ DEFERRED | -          | Post-MVP             |
| R-008 | Speaker Correction | ⏸️ DEFERRED | -          | Post-MVP             |
| R-009 | Versioning         | ⏸️ DEFERRED | -          | Post-MVP             |
