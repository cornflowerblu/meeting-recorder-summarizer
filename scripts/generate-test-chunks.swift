#!/usr/bin/env swift

import Foundation
import CryptoKit

/**
 Generate test video chunks for upload infrastructure testing.

 Creates mock MP4 files with the correct naming convention and size.
 */

func createTestChunk(
    outputDir: URL,
    recordingId: String,
    chunkIndex: Int,
    sizeMB: Int = 50
) throws -> [String: Any] {
    // Create output directory
    let chunkDir = outputDir.appendingPathComponent(recordingId, isDirectory: true)
    try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)

    // Generate filename (1-based for display, 0-based internally)
    let filename = String(format: "part-%04d.mp4", chunkIndex + 1)
    let filepath = chunkDir.appendingPathComponent(filename)

    print("Creating \(filename) (\(sizeMB)MB)...")

    // Create file with random data
    let sizeBytes = sizeMB * 1024 * 1024
    var data = Data(count: sizeBytes)
    let result = data.withUnsafeMutableBytes { bytes in
        SecRandomCopyBytes(kSecRandomDefault, sizeBytes, bytes.baseAddress!)
    }

    guard result == errSecSuccess else {
        throw NSError(domain: "TestChunkGenerator", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to generate random data"
        ])
    }

    try data.write(to: filepath, options: .atomic)

    // Calculate SHA-256 checksum
    print("Calculating checksum for \(filename)...")
    let hash = SHA256.hash(data: data)
    let checksum = hash.compactMap { String(format: "%02x", $0) }.joined()

    // Generate chunk metadata
    let chunkId = "\(recordingId)-chunk-\(String(format: "%04d", chunkIndex))"

    let metadata: [String: Any] = [
        "chunkId": chunkId,
        "filePath": filepath.path,
        "sizeBytes": sizeBytes,
        "checksum": checksum,
        "durationSeconds": 60.0,
        "index": chunkIndex,
        "recordingId": recordingId
    ]

    print("✅ Created: \(filepath.path)")
    print("   Chunk ID: \(chunkId)")
    print("   Size: \(sizeMB)MB (\(sizeBytes.formatted()) bytes)")
    print("   Checksum: \(checksum.prefix(16))...")
    print()

    return metadata
}

func main() throws {
    // Configuration
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let outputDir = homeDir
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)
        .appendingPathComponent("MeetingRecorder", isDirectory: true)
    let recordingId = "test-rec-001"

    // Parse command line arguments
    let args = CommandLine.arguments
    let numChunks = args.count > 1 ? Int(args[1]) ?? 3 : 3
    let sizeMB = args.count > 2 ? Int(args[2]) ?? 50 : 50

    print("Generating \(numChunks) test chunks of \(sizeMB)MB each...")
    print("Output directory: \(outputDir.path)/\(recordingId)")
    print("Recording ID: \(recordingId)")
    print()

    // Create chunks
    var chunks: [[String: Any]] = []
    for i in 0..<numChunks {
        let chunk = try createTestChunk(
            outputDir: outputDir,
            recordingId: recordingId,
            chunkIndex: i,
            sizeMB: sizeMB
        )
        chunks.append(chunk)
    }

    // Summary
    print(String(repeating: "=", count: 60))
    print("✅ Generated \(chunks.count) test chunks")
    print("📁 Location: \(outputDir.path)/\(recordingId)")
    print("💾 Total size: \(chunks.count * sizeMB)MB")
    print()
    print("Chunk files:")
    for chunk in chunks {
        if let path = chunk["filePath"] as? String {
            print("  - \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }
    print()
    print("To upload these chunks, use the S3Uploader in your Swift tests.")
    print()
}

// Run
print("🎬 Test Chunk Generator")
print()

do {
    try main()
} catch {
    print("\n❌ Error: \(error.localizedDescription)")
    exit(1)
}
