# Feature Specification: Meeting Recorder with AI Intelligence

**Feature Branch**: `001-meeting-recorder-ai`  
**Created**: 2025-11-10  
**Status**: Draft  
**Input**: User description: "Record your own screen during calls for personal reference with visible recording indicator, capture simple meeting metadata, and automatically generate transcript, summary, action items, and key decisions. Provide a searchable catalog by date/participants/topics. Primary user: Roger (AWS PM)."

## User Scenarios & Testing _(mandatory)_

<!--
  IMPORTANT: User stories should be PRIORITIZED as user journeys ordered by importance.
  Each user story/journey must be INDEPENDENTLY TESTABLE - meaning if you implement just ONE of them,
  you should still have a viable MVP (Minimum Viable Product) that delivers value.

  Assign priorities (P1, P2, P3, etc.) to each story, where P1 is the most critical.
  Think of each story as a standalone slice of functionality that can be:
  - Developed independently
  - Tested independently
  - Deployed independently
  - Demonstrated to users independently
-->

### User Story 1 - Private screen recording with consent and indicator (Priority: P1)

Roger starts a private meeting recording of his own screen during a call without inviting a bot.
Before any capture, he confirms consent and sees a clear on-screen recording indicator. He can
pause/resume at any time and stop when finished.

**Why this priority**: Recording is the foundation for all other value (transcripts, summaries).

**Independent Test**: User can complete a short recording session (2–5 minutes) and obtain a
playable recording with visible indicator present the entire time.

**Acceptance Scenarios**:

1. **Given** no active recording, **When** Roger initiates recording and confirms consent,
   **Then** recording starts and a persistent visible indicator is shown until stopped.
2. **Given** an active recording, **When** Roger pauses and resumes, **Then** the indicator
   reflects state and the final recording contains only unpaused segments.
3. **Given** recording has ended, **When** Roger checks the app, **Then** the session appears
   in his catalog with basic details (date/time/duration) and is available for processing.

---

### User Story 2 - Automated transcript, summary, actions, decisions (Priority: P1)

After recording, Roger requests processing. The system produces a transcript with speaker
attribution, a concise meeting summary, a list of action items (owner, due date if stated), and
highlighted key decisions. Each summary element references source timestamps.

**Why this priority**: The AI outputs are the main user value beyond raw recording.

**Independent Test**: Feed an existing recording; verify that transcript, summary, actions, and
decisions are generated and stored, each with source references.

**Acceptance Scenarios**:

1. **Given** a finished recording, **When** processing completes, **Then** a transcript with speaker labels
   (mapped to participant names using AI inference) is available for the whole session.
2. **Given** a finished recording, **When** processing completes, **Then** a summary with
   links to source timestamps is available.
3. **Given** a finished recording, **When** processing completes, **Then** action items and key
   decisions are extracted with references to the transcript.

---

### User Story 3 - Post-recording metadata capture (Priority: P2)

Immediately after stopping, Roger can review and edit meeting metadata: participants, meeting
title, and tags. He can preview a processing cost estimate before choosing to process.

**Why this priority**: Metadata improves search quality and relevance; cost preview helps control
spend.

**Independent Test**: User completes the metadata form, sees an estimated cost, and saves without
starting processing.

**Acceptance Scenarios**:

1. **Given** a new session, **When** Roger opens the metadata form, **Then** he can add/edit
   participants (names), a title, and tags.
2. **Given** estimated processing cost is available, **When** Roger reviews the estimate,
   **Then** he can confirm or cancel processing based on cost.

---

### User Story 4 - Catalog and Search (Priority: P2)

Roger can browse all sessions, filter by date range, participants, or topics, and open any
session to view the summary and full transcript with timestamp navigation.

**Why this priority**: Retrieval completes the workflow; without search the value of the archive
is limited.

**Independent Test**: With at least 10 sessions present, user finds a target session by participant
name or time range and opens the summary within a few seconds.

**Acceptance Scenarios**:

1. **Given** multiple sessions, **When** Roger filters by participant name, **Then** matching
   sessions appear ordered by date.
2. **Given** a session is open, **When** Roger clicks a summary item, **Then** the transcript
   scrolls to the corresponding timestamp.

### User Story 5 - Error Recovery and Monitoring (Priority: P2)

Roger can view processing status for each recording and retry failed
processing. He receives notifications when processing completes or fails.
He can view cost breakdown for completed sessions.

**Why this priority**: Visibility into async processing builds trust;
retry capability ensures reliability.

**Independent Test**: Simulate a Transcribe API failure; verify user sees
failure status and can retry successfully.

**Acceptance Scenarios**:

1. **Given** processing failed for a session, **When** Roger views session
   details, **Then** he sees error reason and can retry processing.
2. **Given** processing is in progress, **When** Roger checks status,
   **Then** he sees current step (FFmpeg/Transcribe/Bedrock) and progress.
3. **Given** processing completed, **When** Roger views session, **Then**
   he sees actual cost breakdown by service.

### Edge Cases

<!--
  ACTION REQUIRED: The content in this section represents placeholders.
  Fill them out with the right edge cases.
-->

- Recording attempted without required consents → block start with clear rationale and guidance
- Low storage or battery during recording → warn and provide safe stop; never corrupt saved data
- No network connectivity post-session → allow deferred processing; queue until available
- Very long sessions (>3 hours) → segment handling and UI performance remain usable
- Sensitive segments → user can mark for redaction; summaries avoid exposing redacted content
- Speaker mapping confidence low → system flags uncertain attributions; user can manually correct in UI
- Network loss during recording → chunks queue locally; recording continues
  uninterrupted; uploads resume when connectivity restored; user sees upload
  status indicator

## Requirements _(mandatory)_

<!--
  ACTION REQUIRED: The content in this section represents placeholders.
  Fill them out with the right functional requirements.
-->

### Functional Requirements

- **FR-001**: User MUST explicitly start each recording session (via "Start
  Recording" button). A visible recording indicator MUST be shown on-screen
  for the entire recording duration. On first launch, user MUST acknowledge
  responsibility for recording usage.
- **FR-002**: Recording MUST upload video segments to cloud storage in
  60-second chunks during capture. If upload fails, chunks MUST be queued for retry without blocking recording.
- **FR-003**: Users MUST be able to review and edit meeting metadata (participants, title, tags)
  before processing.
- **FR-004**: Users MUST see processing cost estimate (based on recording
  duration) when reviewing metadata. Estimate MUST break down costs by
  service (Transcribe, Bedrock, Storage). User can proceed with or defer
  processing.
- **FR-005**: System MUST generate a transcript with speaker attribution for each processed
  session.
- **FR-006**: System MUST generate a concise summary with links to source timestamps and speakers.
- **FR-007**: System MUST extract action items (owner, due date if stated) and highlight key
  decisions from the session.
- **FR-008**: Users MUST be able to browse and search sessions by date, participants, and topics,
  and open summaries and transcripts.
- **FR-009**: Deletion requests MUST remove associated content within the defined retention window
  and update the catalog accordingly.
- **FR-010**: System MUST avoid including personally identifiable information in logs and expose
  only redacted operational events to users or diagnostics.
- **FR-011**: Users can delete individual sessions. Deletion MUST remove:
  - All video chunks and processed video from S3
  - Audio file from S3
  - Transcript and summary from S3
  - DynamoDB metadata entry
  - Deletion MUST complete within 24 hours of request.
- **FR-012**: System MUST provide bulk retention management. User can
  set auto-delete policies (e.g., "delete recordings older than 1 year"
  or "keep only summaries/transcripts, delete video after 90 days").
- **FR-013**: Users MUST be able to play back recordings with synchronized
  transcript display. Clicking transcript timestamps jumps video playback
  to that moment.

### Assumptions & Decisions

- **Consent model**: Explicit per-session start action (user clicks "Start Recording" button). One-time responsibility acknowledgment on first launch.
- **Data residency**: Cloud storage (MVP scope). Local-only processing deferred to future.
- **Cross-device access**: In scope for MVP to maximize utility.
- **Speaker attribution**: Probabilistic AI mapping with manual correction capability for low-confidence cases.

### Key Entities _(include if feature involves data)_

- **Recording**: Captured session artifact with start/end times, duration, and storage location.
- **Transcript**: Text with speaker attribution and timestamps; links back to Recording segments.
- **Summary**: Concise narrative of the meeting with references to Transcript timestamps.
- **ActionItem**: Task extracted with owner (if stated), description, due date (if stated), and
  source reference.
- **Meeting**: Logical container tying Recording, Transcript, Summary, participants, tags, and
  dates.
- **Participant**: Person involved in the meeting; minimally name/label used for attribution.
- **User**: Individual with authenticated access to the application; identified by email address.

### Authentication (High-Level Requirement)

- **FR-014**: System MUST uniquely authenticate users via their email address to isolate their
  catalog privately across devices. Multiple devices using the same user identity MUST share the
  same catalog.

Rationale: Cross-device access is in scope for MVP to support users accessing their meeting
archive from MacBook, iMac, or future iOS devices.

Implementation Details: Deferred to technical plan.

### Non-Functional Requirements

- **NFR-001**: All data MUST remain within user's AWS account. No third-party services except AWS APIs and authentication provider.
- **NFR-002**: Recordings, transcripts, and summaries MUST be encrypted at rest and in transit.
- **NFR-003**: AWS credentials MUST never be logged or exposed in error messages.
- **NFR-004**: Local temporary files MUST be securely deleted after successful upload.
- **NFR-005**: System MUST maintain reliability: recording continuation MUST NOT be interrupted by transient network loss.
- **NFR-006**: Catalog search MUST return initial results within 2 seconds for libraries up to 1000 sessions.

## Success Criteria _(mandatory)_

<!--
  ACTION REQUIRED: Define measurable success criteria.
  These must be technology-agnostic and measurable.
-->

### Measurable Outcomes

- **SC-001**: Users can start recording and see a visible indicator within 1 second of initiation
  and stop within 1 second of request.
- **SC-002**: 95% of processed sessions produce transcript, summary, actions, and decisions without
  requiring manual retries.
- **SC-003**: Users can locate a target session in the catalog by participant
  or date in under 5 seconds for libraries up to 1000 sessions.
- **SC-004**: 100% of recordings enforce a consent checkpoint before capture and display the
  visible indicator continuously while recording.
