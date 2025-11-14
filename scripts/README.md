# Test Chunk Generator Scripts

These scripts generate mock video chunk files for testing the upload infrastructure.

## Available Scripts

Choose the language you prefer:

- **Python**: `generate-test-chunks.py` (recommended - easiest)
- **JavaScript**: `generate-test-chunks.js` (requires Node.js)
- **Swift**: `generate-test-chunks.swift` (native, but slower for large files)

## Quick Start

### Python (Recommended)

```bash
# Generate 3 chunks of 50MB each (default)
./scripts/generate-test-chunks.py

# Generate 10 chunks of 10MB each
./scripts/generate-test-chunks.py 10 10

# Generate 5 chunks of 100MB each
./scripts/generate-test-chunks.py 5 100
```

### JavaScript

```bash
# Generate 3 chunks of 50MB each (default)
node scripts/generate-test-chunks.js

# Generate 10 chunks of 10MB each
node scripts/generate-test-chunks.js 10 10

# Generate 5 chunks of 100MB each
node scripts/generate-test-chunks.js 5 100
```

### Swift

```bash
# Generate 3 chunks of 50MB each (default)
swift scripts/generate-test-chunks.swift

# Generate 10 chunks of 10MB each
swift scripts/generate-test-chunks.swift 10 10

# Generate 5 chunks of 100MB each
swift scripts/generate-test-chunks.swift 5 100
```

## What It Creates

The scripts generate test chunks in:
```
~/Library/Caches/MeetingRecorder/test-rec-001/
├── part-0001.mp4
├── part-0002.mp4
└── part-0003.mp4
```

Each chunk:
- Contains random data (simulates video)
- Has correct naming convention (part-NNNN.mp4)
- Includes SHA-256 checksum
- Has specified size (default 50MB)

## Output Example

```
🎬 Test Chunk Generator

Generating 3 test chunks of 50MB each...
Output directory: /Users/you/Library/Caches/MeetingRecorder/test-rec-001
Recording ID: test-rec-001

Creating part-0001.mp4 (50MB)...
Calculating checksum for part-0001.mp4...
✅ Created: /Users/you/Library/Caches/MeetingRecorder/test-rec-001/part-0001.mp4
   Chunk ID: test-rec-001-chunk-0000
   Size: 50MB (52,428,800 bytes)
   Checksum: a3f2e1d9b4c5...

Creating part-0002.mp4 (50MB)...
...

============================================================
✅ Generated 3 test chunks
📁 Location: /Users/you/Library/Caches/MeetingRecorder/test-rec-001
💾 Total size: 150MB

Chunk files:
  - part-0001.mp4
  - part-0002.mp4
  - part-0003.mp4

To upload these chunks, use the S3Uploader in your Swift tests.
```

## Using Generated Chunks in Tests

### Option 1: Manual Upload Test

After generating chunks, use them in your Swift code:

```swift
import Foundation

// The chunks are already created at:
let chunkDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/MeetingRecorder/test-rec-001")

// Create uploader and queue
let s3Client = S3Client(region: "us-east-1")
let uploader = S3Uploader(s3Client: s3Client)
let queue = UploadQueue(
    uploader: uploader,
    userId: "test-user-123",
    recordingId: "test-rec-001"
)

// Enqueue chunks (they'll be loaded from the directory)
// The UploadQueue will find the manifest or create a new one
await queue.resume() // Uploads all chunks
```

### Option 2: Integration with Recording

The recording infrastructure will automatically generate real chunks:

```swift
let recorder = ScreenRecorder()
await recorder.startRecording(recordingId: "my-recording")
// Records for 3 minutes → creates 3 chunks automatically
await recorder.stopRecording()
```

### Option 3: Unit Tests

Use the generated chunks in your tests:

```swift
let chunkMetadata = ChunkMetadata(
    chunkId: "test-rec-001-chunk-0000",
    filePath: URL(fileURLWithPath:
        "\(NSHomeDirectory())/Library/Caches/MeetingRecorder/test-rec-001/part-0001.mp4"),
    sizeBytes: 52_428_800,
    checksum: "...", // Read from file or use placeholder
    durationSeconds: 60.0,
    index: 0,
    recordingId: "test-rec-001"
)

await uploadQueue.enqueue(chunkMetadata)
await uploadQueue.start()
```

## Cleanup

```bash
# Remove all test chunks
rm -rf ~/Library/Caches/MeetingRecorder/test-rec-*

# Remove manifests
rm ~/Library/Caches/MeetingRecorder/test-rec-*-manifest.json
```

## Parameters

### Number of Chunks (argument 1)
- How many chunk files to create
- Default: 3
- Example: `10` creates 10 files

### Chunk Size in MB (argument 2)
- Size of each chunk in megabytes
- Default: 50MB
- Example: `100` creates 100MB chunks

## Common Use Cases

### Test Basic Upload (3 small chunks)
```bash
./scripts/generate-test-chunks.py 3 10
```
Creates 3 × 10MB = 30MB total

### Test Concurrent Uploads (10 medium chunks)
```bash
./scripts/generate-test-chunks.py 10 50
```
Creates 10 × 50MB = 500MB total

### Test Large File Multipart Upload (1 huge chunk)
```bash
./scripts/generate-test-chunks.py 1 200
```
Creates 1 × 200MB = 200MB (tests multipart upload with ~40 parts)

### Test Resume Capability (Many small chunks)
```bash
./scripts/generate-test-chunks.py 20 5
```
Creates 20 × 5MB = 100MB total (good for testing pause/resume)

## Requirements

### Python
- Python 3.6+ (built-in on macOS)
- No additional packages needed

### JavaScript
- Node.js 14+ (install via `brew install node`)
- No additional packages needed

### Swift
- Swift 5.5+ (built-in on macOS with Xcode)
- No additional packages needed

## Performance

| Language | 3 × 50MB | 10 × 50MB | Notes |
|----------|----------|-----------|-------|
| Python   | ~2s      | ~6s       | Fast, recommended |
| JavaScript | ~3s    | ~8s       | Slightly slower |
| Swift    | ~5s      | ~15s      | Slower but native |

## Troubleshooting

### Permission Denied
```bash
chmod +x scripts/generate-test-chunks.py
```

### Python Not Found
```bash
python3 scripts/generate-test-chunks.py
```

### Node Not Found
```bash
brew install node
```

### Out of Disk Space
Reduce chunk size or count:
```bash
./scripts/generate-test-chunks.py 3 10  # Only 30MB total
```

## See Also

- **Test Plan**: `docs/upload-infrastructure-test-plan.md`
- **Checkpoint**: `docs/checkpoint-2025-11-12-phase3-pr2.md`
- **PR #16**: Upload Infrastructure
