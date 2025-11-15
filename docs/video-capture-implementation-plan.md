# Screen Recording Video Capture Implementation Plan

**Date**: 2025-11-15
**Author**: Claude Code
**Status**: In Progress
**Jira Tickets**: MR-25 (T018), MR-30 (T023), MR-24 (T017)

---

## Executive Summary

The Meeting Recorder macOS app has excellent architecture and UI but lacks the critical video capture implementation in `AVFoundationCaptureService.swift`. This plan outlines a **test-driven development (TDD)** approach to implement the missing functionality, enabling actual screen recording with 60-second chunk rotation.

**Estimated Effort**: 6-8 hours
**Approach**: Write tests first, then implement to pass tests
**Risk Level**: Medium (AVFoundation concurrency requires careful handling)

---

## Current State Analysis

### What Exists ✅

1. **Complete Architecture**
   - `ScreenCaptureProtocol` with start/stop/pause/resume
   - `ScreenRecorder` coordinator with state management
   - `ChunkWriter` for file storage
   - Upload queue and catalog integration

2. **Fully Functional UI**
   - `RecordControlView` with start/pause/resume/stop buttons
   - Live duration display and chunk counter
   - `RecordingIndicatorView` overlay
   - Consent flow and permission handling

3. **Partial AVFoundation Setup**
   - `AVCaptureSession` created and started
   - `AVCaptureScreenInput` configured for screen capture
   - `AVAssetWriter` initialized with correct settings
   - File management and cleanup logic

### What's Missing ❌

**Critical Gap**: No connection between screen input and file writer!

The implementation has this warning:
```swift
⚠️ WARNING: Partial Implementation
Critical functionality NOT yet implemented:
- Actual sample buffer processing and video data capture
- Chunk rotation logic based on time intervals
DO NOT USE for production recording.
```

**Specific TODOs in Code**:

1. **Line 214-219**: Connect capture output to writer input
   ```swift
   // TODO: Connect capture output to writer input
   // This is a simplified implementation. In reality, you'd need to:
   // 1. Add AVCaptureVideoDataOutput to the session
   // 2. Implement AVCaptureVideoDataOutputSampleBufferDelegate
   // 3. Write samples to the asset writer
   // 4. Monitor time and rotate chunks
   ```

2. **Line 284-294**: Implement sample buffer processing
   ```swift
   // NOTE: Full sample buffer processing will be implemented in the next phase
   nonisolated func captureOutput(...) {
       // TODO: Implement sample buffer processing with proper concurrency handling
   }
   ```

---

## Implementation Plan: Test-Driven Development

### Principle: Red → Green → Refactor

We'll follow strict TDD:
1. **Red**: Write failing tests that specify behavior
2. **Green**: Write minimal code to make tests pass
3. **Refactor**: Clean up while keeping tests green

---

## Phase 1: Write Comprehensive Tests (2-3 hours)

### Test File Structure

**File**: `macos/InterviewCompanion/InterviewCompanionTests/Recording/AVFoundationCaptureServiceTests.swift`

### Test Suite 1: Video Output Setup Tests

**Objective**: Verify `AVCaptureVideoDataOutput` is properly configured

```swift
class AVFoundationCaptureServiceTests: XCTestCase {

    // MARK: - Video Output Configuration Tests

    func testVideoOutputIsCreatedWhenSessionStarts() {
        // Given: A capture service
        // When: Recording starts
        // Then: AVCaptureVideoDataOutput exists and is added to session
    }

    func testVideoOutputSettingsMatchAssetWriter() {
        // Given: A capture service with recording started
        // When: Inspecting video output settings
        // Then: Format is H.264, resolution is 1920x1080, frame rate is 30fps
    }

    func testVideoOutputDelegateIsSet() {
        // Given: A capture service
        // When: Recording starts
        // Then: Delegate is set and dispatch queue is serial
    }

    func testVideoOutputIsRemovedWhenRecordingStops() {
        // Given: A capture service with active recording
        // When: Recording stops
        // Then: Video output is removed from session
    }
}
```

### Test Suite 2: Sample Buffer Processing Tests

**Objective**: Verify video frames are captured and written correctly

```swift
// MARK: - Sample Buffer Processing Tests

func testSampleBufferIsWrittenToAssetWriter() {
    // Given: A capture service with recording started
    // When: Sample buffer delegate receives a frame
    // Then: Frame is written to asset writer input
}

func testSampleBuffersAreProcessedInOrder() {
    // Given: Multiple sample buffers with sequential timestamps
    // When: Buffers are received
    // Then: Buffers are written in presentation time order
}

func testDroppedFramesAreHandled() {
    // Given: Asset writer input is not ready
    // When: Sample buffer arrives
    // Then: Frame is dropped gracefully without crash
}

func testSampleBufferProcessingUsesSerialQueue() {
    // Given: A capture service
    // When: Multiple frames arrive simultaneously
    // Then: Frames are processed serially (not concurrently)
}

func testErrorDuringWriteIsHandled() {
    // Given: Asset writer encounters error
    // When: Writing sample buffer
    // Then: Error is captured and delegate is notified
}
```

### Test Suite 3: Chunk Rotation Tests

**Objective**: Verify chunks rotate at exactly 60 seconds

```swift
// MARK: - Chunk Rotation Tests

func testChunkRotatesAtSixtySeconds() {
    // Given: Recording started at T=0
    // When: Sample buffer arrives at T=60s
    // Then: shouldRotateChunk() returns true
}

func testChunkDoesNotRotateBeforeSixtySeconds() {
    // Given: Recording started at T=0
    // When: Sample buffer arrives at T=59s
    // Then: shouldRotateChunk() returns false
}

func testChunkRotationFinalizesCurrentWriter() {
    // Given: Recording in progress
    // When: Chunk rotation triggers
    // Then: Current asset writer is finalized
}

func testChunkRotationCreatesNewWriter() {
    // Given: Recording in progress
    // When: Chunk rotation completes
    // Then: New asset writer is created and ready
}

func testChunkCounterIncrementsOnRotation() {
    // Given: Recording with 1 chunk completed
    // When: Second chunk starts
    // Then: Current chunk index is 2
}

func testChunkFileNamingIsSequential() {
    // Given: Recording with multiple rotations
    // When: Checking output files
    // Then: Files are named chunk_0.mov, chunk_1.mov, chunk_2.mov...
}
```

### Test Suite 4: Pause/Resume Timing Tests

**Objective**: Verify pause doesn't affect chunk duration calculations

```swift
// MARK: - Pause/Resume Timing Tests

func testPausedTimeIsExcludedFromDuration() {
    // Given: Recording paused for 30 seconds
    // When: Recording resumed and continued to T=90s total
    // Then: Recorded duration is 60 seconds (excluding pause)
}

func testChunkRotationDuringPause() {
    // Given: Recording at T=55s then paused
    // When: Resumed at T=65s (but only 55s recorded)
    // Then: Chunk does NOT rotate (only 55s of actual video)
}

func testResumeAfterPauseContinuesWriting() {
    // Given: Recording paused
    // When: Recording resumed
    // Then: Sample buffers continue writing to same chunk
}
```

### Test Suite 5: Error Handling Tests

```swift
// MARK: - Error Handling Tests

func testInsufficientDiskSpaceIsDetected() {
    // Given: Less than 1GB disk space
    // When: Attempting to start recording
    // Then: Error is thrown and recording doesn't start
}

func testAssetWriterFailureIsReported() {
    // Given: Recording in progress
    // When: Asset writer fails (disk full, etc.)
    // Then: Delegate receives error callback
}

func testSessionInterruptionIsHandled() {
    // Given: Recording in progress
    // When: Capture session is interrupted
    // Then: Recording stops gracefully
}
```

---

## Phase 2: Implement to Pass Tests (3-4 hours)

### Implementation Task 1: AVCaptureVideoDataOutput Setup

**File**: `AVFoundationCaptureService.swift`
**Location**: `setupCaptureSession()` method (~line 120)

**Changes**:
```swift
private func setupCaptureSession() throws {
    // ... existing code ...

    // Create video data output
    let videoOutput = AVCaptureVideoDataOutput()

    // Configure video settings to match asset writer
    videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    // Set up delegate on serial queue
    let videoQueue = DispatchQueue(label: "com.interviewcompanion.videoProcessing", qos: .userInitiated)
    videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

    // Add to session
    guard captureSession.canAddOutput(videoOutput) else {
        throw CaptureError.setupFailed("Cannot add video output to session")
    }
    captureSession.addOutput(videoOutput)

    // Store reference
    self.videoOutput = videoOutput
    self.videoProcessingQueue = videoQueue
}
```

**New Properties to Add**:
```swift
private var videoOutput: AVCaptureVideoDataOutput?
private var videoProcessingQueue: DispatchQueue?
```

### Implementation Task 2: Sample Buffer Delegate

**File**: `AVFoundationCaptureService.swift`
**Location**: Extension implementing `AVCaptureVideoDataOutputSampleBufferDelegate`

**Changes**:
```swift
// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension AVFoundationCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Get presentation timestamp
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Check if we should rotate chunks based on elapsed time
        Task { @MainActor in
            if shouldRotateChunk() {
                await rotateChunk()
            }
        }

        // Write sample to asset writer input
        guard let writerInput = assetWriterInput,
              writerInput.isReadyForMoreMediaData else {
            // Drop frame if not ready (prevents blocking)
            return
        }

        // Append sample buffer
        if !writerInput.append(sampleBuffer) {
            // Handle write failure
            Task { @MainActor in
                handleWriteError()
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Log dropped frames for debugging
        print("⚠️ Dropped frame")
    }
}
```

### Implementation Task 3: Chunk Rotation Logic

**File**: `AVFoundationCaptureService.swift`
**Location**: Timing tracking properties and rotation method

**New Properties**:
```swift
private var chunkStartTime: CMTime?
private var pauseStartTime: CMTime?
private var totalPausedDuration: CMTime = .zero
```

**Update `shouldRotateChunk()` Method**:
```swift
@MainActor
private func shouldRotateChunk() -> Bool {
    guard let startTime = chunkStartTime else { return false }

    // Calculate elapsed time excluding paused duration
    let now = CMClockGetTime(CMClockGetHostTimeClock())
    let elapsed = CMTimeSubtract(now, startTime)
    let effectiveElapsed = CMTimeSubtract(elapsed, totalPausedDuration)

    // Rotate at 60 seconds
    let sixtySeconds = CMTime(seconds: 60, preferredTimescale: 600)
    return CMTimeCompare(effectiveElapsed, sixtySeconds) >= 0
}
```

**Update `rotateChunk()` Method**:
```swift
@MainActor
private func rotateChunk() async {
    // Finalize current chunk
    guard let writer = assetWriter else { return }

    await writer.finishWriting()

    // Notify delegate of completed chunk
    if writer.status == .completed {
        delegate?.captureService(self, didCompleteChunk: currentChunkIndex)
    }

    // Start new chunk
    currentChunkIndex += 1

    do {
        try setupAssetWriter()
        chunkStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        totalPausedDuration = .zero
    } catch {
        await handleError(error)
    }
}
```

### Implementation Task 4: Pause/Resume Timing

**Update `pause()` Method**:
```swift
@MainActor
func pause() async throws {
    guard state == .recording else {
        throw CaptureError.invalidState("Cannot pause when not recording")
    }

    // Mark pause start time
    pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())

    state = .paused
}
```

**Update `resume()` Method**:
```swift
@MainActor
func resume() async throws {
    guard state == .paused else {
        throw CaptureError.invalidState("Cannot resume when not paused")
    }

    // Calculate paused duration and add to total
    if let pauseStart = pauseStartTime {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let pauseDuration = CMTimeSubtract(now, pauseStart)
        totalPausedDuration = CMTimeAdd(totalPausedDuration, pauseDuration)
    }

    pauseStartTime = nil
    state = .recording
}
```

---

## Phase 3: Integration Testing (1-2 hours)

### Manual Test Checklist

- [ ] **Start Recording**
  - Press record button
  - Verify screen recording permission granted
  - Check temp directory for chunk_0.mov created

- [ ] **60-Second Chunk Rotation**
  - Record for 2+ minutes
  - Verify chunk_0.mov, chunk_1.mov, chunk_2.mov created
  - Check each file is approximately 60 seconds long
  - Verify files are playable in QuickTime

- [ ] **Pause/Resume**
  - Start recording
  - Pause at 30 seconds
  - Wait 30 seconds (paused)
  - Resume and record to 60 seconds total recorded time
  - Verify chunk rotates at correct time (excluding pause)

- [ ] **Stop Recording**
  - Record for 90 seconds (1.5 chunks)
  - Press stop
  - Verify final chunk is finalized and playable
  - Verify chunk count is correct (2 chunks)

- [ ] **Disk Space Validation**
  - Attempt to record with <1GB free space
  - Verify error is shown and recording doesn't start

- [ ] **File Size Validation**
  - Record 60-second chunk
  - Check file size is reasonable (~37MB at 5Mbps)
  - Verify resolution is 1920x1080
  - Verify frame rate is 30fps

### Performance Testing

- [ ] **CPU Usage**
  - Monitor CPU during 5-minute recording
  - Should stay under 30% on modern Mac
  - No UI lag during recording

- [ ] **Memory Usage**
  - Monitor memory during recording
  - Should stay under 500MB
  - No memory leaks after stopping

- [ ] **Frame Drops**
  - Check console for dropped frame warnings
  - Should be minimal (<1% of frames)

---

## Success Criteria

### Functional Requirements ✅
1. Pressing "Start Recording" captures actual screen video
2. Video files (.mov) are created in temp directory
3. Chunks rotate at exactly 60 seconds of recorded time
4. Pause/resume works without affecting chunk timing
5. Stop finalizes the last chunk properly
6. All unit tests pass

### Quality Requirements ✅
1. No memory leaks during 10-minute recording
2. CPU usage stays reasonable (<30%)
3. Video files are playable in QuickTime Player
4. Resolution matches config (1920x1080)
5. Frame rate matches config (30fps)
6. Code passes SwiftLint validation

### Documentation Requirements ✅
1. All public methods have doc comments
2. Complex logic has inline comments explaining why
3. Tests have clear Given/When/Then structure
4. This plan document is complete and accurate

---

## Risk Mitigation

### Medium Risks

**Risk**: AVFoundation concurrency issues (sample buffer delegate on background queue)
**Mitigation**: Use dedicated serial queue, proper `@MainActor` isolation, test thoroughly

**Risk**: Chunk rotation timing accuracy
**Mitigation**: Use `CMTime` for precision, account for paused time, unit test edge cases

**Risk**: Memory leaks from sample buffers
**Mitigation**: Don't retain sample buffers, use Instruments to profile

### Low Risks

**Risk**: Disk space runs out during recording
**Mitigation**: Already implemented - check before start, monitor during recording

**Risk**: Screen recording permission denied
**Mitigation**: Already implemented - consent flow in UI

---

## Timeline

### Session 1 (2-3 hours): Write Tests
- Set up test file structure
- Write all test suites
- Verify tests fail (red)

### Session 2 (3-4 hours): Implement Features
- Implement video output setup
- Implement sample buffer delegate
- Implement chunk rotation
- Run tests until all pass (green)

### Session 3 (1-2 hours): Integration & Polish
- Manual integration testing
- Performance profiling
- Bug fixes and refinements
- Update Jira tickets

**Total Estimated Time**: 6-9 hours

---

## Related Jira Tickets

- **MR-25** (T018): Screen capture controller
  - Status: Testing → In Progress (needs implementation)

- **MR-30** (T023): Record controls UI
  - Status: Testing (UI complete, waiting on capture)

- **MR-24** (T017): Recording indicator overlay
  - Status: Testing (complete, can be tested once capture works)

- **MR-2** (US1): Recording & Consent Epic
  - Status: In Progress (14 tasks total)

---

## References

### Apple Documentation
- [AVFoundation Programming Guide](https://developer.apple.com/av-foundation/)
- [AVCaptureVideoDataOutput](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput)
- [AVAssetWriter](https://developer.apple.com/documentation/avfoundation/avassetwriter)
- [CMSampleBuffer](https://developer.apple.com/documentation/coremedia/cmsamplebuffer)
- [CMTime](https://developer.apple.com/documentation/coremedia/cmtime-u58)

### Internal Documentation
- `docs/technical-architecture.md` - System architecture
- `macos/InterviewCompanion/InterviewCompanion/Recording/README.md` - Recording module docs

### Code Files
- `AVFoundationCaptureService.swift` - Implementation file
- `ScreenRecorder.swift` - Coordinator using capture service
- `RecordControlView.swift` - UI that triggers recording
- `Config.swift` - Video quality configuration

---

## Notes

- This implementation focuses on video only (no audio yet)
- Mouse click capture is configured but not yet utilized
- Multi-display support can be added later
- Consider adding audio capture in a follow-up task
- Consider adaptive bitrate based on performance in future

---

**Last Updated**: 2025-11-15
**Status**: Ready to begin implementation
