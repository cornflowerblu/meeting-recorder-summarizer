#!/usr/bin/env python3
"""
Generate test video chunks for upload infrastructure testing.

Creates mock MP4 files with the correct naming convention and size.
"""

import os
import sys
import hashlib
from pathlib import Path


def create_test_chunk(output_dir, recording_id, chunk_index, size_mb=50):
    """
    Create a test chunk file.

    Args:
        output_dir: Directory to create chunk in
        recording_id: Recording identifier (e.g., "test-rec-001")
        chunk_index: Zero-based chunk index (0, 1, 2, etc.)
        size_mb: Size of chunk in megabytes (default 50MB)

    Returns:
        dict with chunk metadata
    """
    # Create output directory
    chunk_dir = Path(output_dir) / recording_id
    chunk_dir.mkdir(parents=True, exist_ok=True)

    # Generate filename (1-based for display, 0-based internally)
    filename = f"part-{chunk_index + 1:04d}.mp4"
    filepath = chunk_dir / filename

    # Create file with random data (simulates video chunk)
    size_bytes = size_mb * 1024 * 1024
    print(f"Creating {filename} ({size_mb}MB)...")

    # Write random data in chunks to avoid memory issues
    chunk_size = 1024 * 1024  # 1MB at a time
    with open(filepath, 'wb') as f:
        remaining = size_bytes
        while remaining > 0:
            write_size = min(chunk_size, remaining)
            f.write(os.urandom(write_size))
            remaining -= write_size

    # Calculate SHA-256 checksum
    print(f"Calculating checksum for {filename}...")
    sha256 = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(8192):
            sha256.update(chunk)
    checksum = sha256.hexdigest()

    # Generate chunk metadata
    chunk_id = f"{recording_id}-chunk-{chunk_index:04d}"

    metadata = {
        "chunkId": chunk_id,
        "filePath": str(filepath.absolute()),
        "sizeBytes": size_bytes,
        "checksum": checksum,
        "durationSeconds": 60.0,
        "index": chunk_index,
        "recordingId": recording_id
    }

    print(f"✅ Created: {filepath}")
    print(f"   Chunk ID: {chunk_id}")
    print(f"   Size: {size_mb}MB ({size_bytes:,} bytes)")
    print(f"   Checksum: {checksum[:16]}...")
    print()

    return metadata


def main():
    # Configuration
    output_dir = Path.home() / "Library" / "Caches" / "MeetingRecorder"
    recording_id = "test-rec-001"

    # Parse command line arguments
    if len(sys.argv) > 1:
        num_chunks = int(sys.argv[1])
    else:
        num_chunks = 3

    if len(sys.argv) > 2:
        size_mb = int(sys.argv[2])
    else:
        size_mb = 50

    print(f"Generating {num_chunks} test chunks of {size_mb}MB each...")
    print(f"Output directory: {output_dir}/{recording_id}")
    print(f"Recording ID: {recording_id}")
    print()

    # Create chunks
    chunks = []
    for i in range(num_chunks):
        chunk = create_test_chunk(output_dir, recording_id, i, size_mb)
        chunks.append(chunk)

    # Summary
    print("=" * 60)
    print(f"✅ Generated {len(chunks)} test chunks")
    print(f"📁 Location: {output_dir}/{recording_id}")
    print(f"💾 Total size: {len(chunks) * size_mb}MB")
    print()
    print("Chunk files:")
    for chunk in chunks:
        print(f"  - {Path(chunk['filePath']).name}")
    print()
    print("To upload these chunks, use the S3Uploader in your Swift tests.")
    print()


if __name__ == "__main__":
    print("🎬 Test Chunk Generator")
    print()

    try:
        main()
    except KeyboardInterrupt:
        print("\n\n❌ Cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)
