#!/usr/bin/env node
/**
 * Generate test video chunks for upload infrastructure testing.
 *
 * Creates mock MP4 files with the correct naming convention and size.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');

/**
 * Create a test chunk file
 */
function createTestChunk(outputDir, recordingId, chunkIndex, sizeMB = 50) {
    // Create output directory
    const chunkDir = path.join(outputDir, recordingId);
    fs.mkdirSync(chunkDir, { recursive: true });

    // Generate filename (1-based for display, 0-based internally)
    const filename = `part-${String(chunkIndex + 1).padStart(4, '0')}.mp4`;
    const filepath = path.join(chunkDir, filename);

    console.log(`Creating ${filename} (${sizeMB}MB)...`);

    // Create file with random data
    const sizeBytes = sizeMB * 1024 * 1024;
    const buffer = crypto.randomBytes(sizeBytes);
    fs.writeFileSync(filepath, buffer);

    // Calculate SHA-256 checksum
    console.log(`Calculating checksum for ${filename}...`);
    const hash = crypto.createHash('sha256');
    hash.update(buffer);
    const checksum = hash.digest('hex');

    // Generate chunk metadata
    const chunkId = `${recordingId}-chunk-${String(chunkIndex).padStart(4, '0')}`;

    const metadata = {
        chunkId: chunkId,
        filePath: filepath,
        sizeBytes: sizeBytes,
        checksum: checksum,
        durationSeconds: 60.0,
        index: chunkIndex,
        recordingId: recordingId
    };

    console.log(`✅ Created: ${filepath}`);
    console.log(`   Chunk ID: ${chunkId}`);
    console.log(`   Size: ${sizeMB}MB (${sizeBytes.toLocaleString()} bytes)`);
    console.log(`   Checksum: ${checksum.substring(0, 16)}...`);
    console.log();

    return metadata;
}

function main() {
    // Configuration
    const outputDir = path.join(os.homedir(), 'Library', 'Caches', 'MeetingRecorder');
    const recordingId = 'test-rec-001';

    // Parse command line arguments
    const numChunks = parseInt(process.argv[2]) || 3;
    const sizeMB = parseInt(process.argv[3]) || 50;

    console.log(`Generating ${numChunks} test chunks of ${sizeMB}MB each...`);
    console.log(`Output directory: ${outputDir}/${recordingId}`);
    console.log(`Recording ID: ${recordingId}`);
    console.log();

    // Create chunks
    const chunks = [];
    for (let i = 0; i < numChunks; i++) {
        const chunk = createTestChunk(outputDir, recordingId, i, sizeMB);
        chunks.push(chunk);
    }

    // Summary
    console.log('='.repeat(60));
    console.log(`✅ Generated ${chunks.length} test chunks`);
    console.log(`📁 Location: ${outputDir}/${recordingId}`);
    console.log(`💾 Total size: ${chunks.length * sizeMB}MB`);
    console.log();
    console.log('Chunk files:');
    chunks.forEach(chunk => {
        console.log(`  - ${path.basename(chunk.filePath)}`);
    });
    console.log();
    console.log('To upload these chunks, use the S3Uploader in your Swift tests.');
    console.log();
}

// Run
console.log('🎬 Test Chunk Generator');
console.log();

try {
    main();
} catch (error) {
    console.error(`\n❌ Error: ${error.message}`);
    process.exit(1);
}
