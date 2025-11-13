import XCTest
@testable import MeetingRecorder

final class ChunkWriterTests: XCTestCase {
    var chunkWriter: ChunkWriter!
    var testRecordingId: String!
    var tempFileURL: URL!

    override func setUp() async throws {
        chunkWriter = ChunkWriter()
        testRecordingId = "test-recording-\(UUID().uuidString)"

        // Create a temporary test file
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-chunk-\(UUID().uuidString).mp4")

        // Write some test data
        let testData = Data(repeating: 0xFF, count: 1024 * 1024) // 1MB
        try testData.write(to: tempFileURL)
    }

    override func tearDown() async throws {
        // Cleanup test files
        try? await chunkWriter.cleanup(recordingId: testRecordingId)
        try? FileManager.default.removeItem(at: tempFileURL)

        chunkWriter = nil
        testRecordingId = nil
        tempFileURL = nil
    }

    // MARK: - Save Chunk Tests

    func testSaveChunkSuccess() async throws {
        // When
        let metadata = try await chunkWriter.saveChunk(
            fileURL: tempFileURL,
            index: 0,
            recordingId: testRecordingId
        )

        // Then
        XCTAssertEqual(metadata.index, 0, "Chunk index should be 0")
        XCTAssertEqual(metadata.recordingId, testRecordingId, "Recording ID should match")
        XCTAssertFalse(metadata.checksum.isEmpty, "Checksum should not be empty")
        XCTAssertGreaterThan(metadata.sizeBytes, 0, "File size should be greater than 0")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: metadata.filePath.path),
            "Chunk file should exist at destination"
        )

        // Verify filename format
        XCTAssertTrue(
            metadata.filePath.lastPathComponent == "part-0001.mp4",
            "Chunk filename should be part-0001.mp4"
        )
    }

    func testSaveMultipleChunks() async throws {
        // When - Save 3 chunks
        var savedMetadata: [ChunkMetadata] = []

        for index in 0..<3 {
            // Create unique temp file for each chunk
            let chunkTempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk-\(index)-\(UUID().uuidString).mp4")
            let data = Data(repeating: UInt8(index), count: 1024 * 1024)
            try data.write(to: chunkTempURL)

            let metadata = try await chunkWriter.saveChunk(
                fileURL: chunkTempURL,
                index: index,
                recordingId: testRecordingId
            )
            savedMetadata.append(metadata)
        }

        // Then
        XCTAssertEqual(savedMetadata.count, 3, "Should have saved 3 chunks")

        // Verify filenames are sequential
        XCTAssertEqual(savedMetadata[0].filePath.lastPathComponent, "part-0001.mp4")
        XCTAssertEqual(savedMetadata[1].filePath.lastPathComponent, "part-0002.mp4")
        XCTAssertEqual(savedMetadata[2].filePath.lastPathComponent, "part-0003.mp4")

        // Verify all files exist
        for metadata in savedMetadata {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: metadata.filePath.path),
                "Chunk file should exist: \(metadata.filePath.lastPathComponent)"
            )
        }
    }

    func testAtomicWrite() async throws {
        // Given - A chunk that already exists
        let firstMetadata = try await chunkWriter.saveChunk(
            fileURL: tempFileURL,
            index: 0,
            recordingId: testRecordingId
        )

        // When - Overwrite with new data
        let newTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-chunk-\(UUID().uuidString).mp4")
        let newData = Data(repeating: 0xAA, count: 2 * 1024 * 1024) // 2MB
        try newData.write(to: newTempURL)

        let secondMetadata = try await chunkWriter.saveChunk(
            fileURL: newTempURL,
            index: 0,
            recordingId: testRecordingId
        )

        // Then - Second metadata should have different size and checksum
        XCTAssertEqual(firstMetadata.filePath, secondMetadata.filePath, "Should overwrite same file")
        XCTAssertNotEqual(firstMetadata.sizeBytes, secondMetadata.sizeBytes, "File sizes should differ")
        XCTAssertNotEqual(firstMetadata.checksum, secondMetadata.checksum, "Checksums should differ")

        // File should exist and have the new size
        let attributes = try FileManager.default.attributesOfItem(atPath: secondMetadata.filePath.path)
        let fileSize = attributes[.size] as? Int64
        XCTAssertEqual(fileSize, secondMetadata.sizeBytes, "File should have new size")
    }

    // MARK: - Checksum Tests

    func testCalculateChecksum() throws {
        // When
        let checksum = try chunkWriter.calculateChecksum(fileURL: tempFileURL)

        // Then
        XCTAssertFalse(checksum.isEmpty, "Checksum should not be empty")
        XCTAssertEqual(checksum.count, 64, "SHA-256 checksum should be 64 hex characters")

        // Verify it's a valid hex string
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        let checksumSet = CharacterSet(charactersIn: checksum)
        XCTAssertTrue(hexCharacterSet.isSuperset(of: checksumSet), "Checksum should be valid hex")
    }

    func testChecksumDeterministic() throws {
        // When - Calculate checksum twice
        let checksum1 = try chunkWriter.calculateChecksum(fileURL: tempFileURL)
        let checksum2 = try chunkWriter.calculateChecksum(fileURL: tempFileURL)

        // Then - Should be identical
        XCTAssertEqual(checksum1, checksum2, "Checksum should be deterministic")
    }

    func testChecksumDifferentFiles() throws {
        // Given - Two different files
        let tempFile2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-chunk-2-\(UUID().uuidString).mp4")
        let data2 = Data(repeating: 0xAA, count: 1024 * 1024)
        try data2.write(to: tempFile2)
        defer { try? FileManager.default.removeItem(at: tempFile2) }

        // When
        let checksum1 = try chunkWriter.calculateChecksum(fileURL: tempFileURL)
        let checksum2 = try chunkWriter.calculateChecksum(fileURL: tempFile2)

        // Then
        XCTAssertNotEqual(checksum1, checksum2, "Different files should have different checksums")
    }

    // MARK: - Disk Space Tests

    func testHasSufficientDiskSpace() {
        // When - Check for reasonable amount (1MB)
        let hasSpace = chunkWriter.hasSufficientDiskSpace(requiredBytes: 1_000_000)

        // Then - Should have space (assuming test machine has > 1MB free)
        XCTAssertTrue(hasSpace, "Should have at least 1MB free space")
    }

    // MARK: - Cleanup Tests

    func testCleanup() async throws {
        // Given - Save a chunk
        let metadata = try await chunkWriter.saveChunk(
            fileURL: tempFileURL,
            index: 0,
            recordingId: testRecordingId
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: metadata.filePath.path),
            "File should exist before cleanup"
        )

        // When
        try await chunkWriter.cleanup(recordingId: testRecordingId)

        // Then
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: metadata.filePath.path),
            "File should not exist after cleanup"
        )

        let chunkDir = chunkWriter.getChunkDirectory(for: testRecordingId)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: chunkDir.path),
            "Chunk directory should be removed"
        )
    }

    func testCleanupMultipleChunks() async throws {
        // Given - Save multiple chunks
        for index in 0..<3 {
            let chunkTempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk-\(index)-\(UUID().uuidString).mp4")
            let data = Data(repeating: UInt8(index), count: 1024 * 1024)
            try data.write(to: chunkTempURL)

            _ = try await chunkWriter.saveChunk(
                fileURL: chunkTempURL,
                index: index,
                recordingId: testRecordingId
            )
        }

        let chunkDir = chunkWriter.getChunkDirectory(for: testRecordingId)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: chunkDir.path)
        XCTAssertEqual(filesBefore.count, 3, "Should have 3 chunk files")

        // When
        try await chunkWriter.cleanup(recordingId: testRecordingId)

        // Then
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: chunkDir.path),
            "Chunk directory should be removed"
        )
    }

    func testCleanupNonexistentRecording() async throws {
        // When - Cleanup a recording that doesn't exist
        let nonexistentId = "nonexistent-recording-id"

        // Then - Should not throw
        try await chunkWriter.cleanup(recordingId: nonexistentId)

        // Test passes if no error thrown
    }

    // MARK: - Directory Management Tests

    func testGetChunkDirectory() {
        // When
        let chunkDir = chunkWriter.getChunkDirectory(for: testRecordingId)

        // Then
        XCTAssertTrue(chunkDir.path.contains("MeetingRecorder"), "Should be in MeetingRecorder directory")
        XCTAssertTrue(chunkDir.path.contains(testRecordingId), "Should contain recording ID")
    }

    func testChunkDirectoryCreation() async throws {
        // When
        _ = try await chunkWriter.saveChunk(
            fileURL: tempFileURL,
            index: 0,
            recordingId: testRecordingId
        )

        // Then
        let chunkDir = chunkWriter.getChunkDirectory(for: testRecordingId)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: chunkDir.path, isDirectory: &isDirectory)

        XCTAssertTrue(exists, "Chunk directory should exist")
        XCTAssertTrue(isDirectory.boolValue, "Path should be a directory")
    }

    // MARK: - Error Handling Tests

    func testSaveChunkWithInvalidFile() async {
        // Given - A non-existent file
        let invalidURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).mp4")

        // When/Then
        do {
            _ = try await chunkWriter.saveChunk(
                fileURL: invalidURL,
                index: 0,
                recordingId: testRecordingId
            )
            XCTFail("Should throw error for non-existent file")
        } catch {
            // Expected error
            XCTAssertTrue(error is ChunkStorageError, "Should throw ChunkStorageError")
        }
    }

    func testCalculateChecksumWithInvalidFile() {
        // Given - A non-existent file
        let invalidURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).mp4")

        // When/Then
        XCTAssertThrowsError(try chunkWriter.calculateChecksum(fileURL: invalidURL)) { error in
            XCTAssertTrue(error is ChunkStorageError, "Should throw ChunkStorageError")
            if case .checksumCalculationFailed = error as? ChunkStorageError {
                // Expected
            } else {
                XCTFail("Wrong error type")
            }
        }
    }

    // MARK: - Metadata Tests

    func testChunkMetadataGeneration() async throws {
        // When
        let metadata = try await chunkWriter.saveChunk(
            fileURL: tempFileURL,
            index: 5,
            recordingId: testRecordingId
        )

        // Then
        XCTAssertEqual(metadata.index, 5, "Index should match")
        XCTAssertEqual(metadata.recordingId, testRecordingId, "Recording ID should match")
        XCTAssertEqual(
            metadata.chunkId,
            "\(testRecordingId!)-chunk-0005",
            "Chunk ID should be formatted correctly"
        )
        XCTAssertTrue(metadata.createdAt <= Date(), "Created date should be in the past or now")
    }

    // MARK: - Helper Method Tests

    func testGetChunkFilesEmpty() throws {
        // Given - Recording ID with no chunks
        let emptyRecordingId = "empty-recording-\(UUID().uuidString)"

        // When
        let chunkFiles = try chunkWriter.getChunkFiles(for: emptyRecordingId)

        // Then
        XCTAssertTrue(chunkFiles.isEmpty, "Should return empty array for recording with no chunks")
    }

    func testGetChunkFilesSortedByIndex() async throws {
        // Given - Save chunks in non-sequential order (2, 0, 1)
        let indices = [2, 0, 1]
        for index in indices {
            let chunkTempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk-\(index)-\(UUID().uuidString).mp4")
            let data = Data(repeating: UInt8(index), count: 1024)
            try data.write(to: chunkTempURL)

            _ = try await chunkWriter.saveChunk(
                fileURL: chunkTempURL,
                index: index,
                recordingId: testRecordingId
            )
        }

        // When
        let chunkFiles = try chunkWriter.getChunkFiles(for: testRecordingId)

        // Then
        XCTAssertEqual(chunkFiles.count, 3, "Should have 3 chunks")

        // Verify sorting by filename (part-0001.mp4, part-0002.mp4, part-0003.mp4)
        XCTAssertEqual(
            chunkFiles[0].lastPathComponent,
            "part-0001.mp4",
            "First chunk should be part-0001.mp4"
        )
        XCTAssertEqual(
            chunkFiles[1].lastPathComponent,
            "part-0002.mp4",
            "Second chunk should be part-0002.mp4"
        )
        XCTAssertEqual(
            chunkFiles[2].lastPathComponent,
            "part-0003.mp4",
            "Third chunk should be part-0003.mp4"
        )
    }

    func testGetChunkFilesFiltersNonMp4Files() async throws {
        // Given - Create chunk directory with mixed file types
        _ = try await chunkWriter.saveChunk(
            fileURL: tempFileURL,
            index: 0,
            recordingId: testRecordingId
        )

        let chunkDir = chunkWriter.getChunkDirectory(for: testRecordingId)

        // Add non-mp4 files to the directory
        let txtFile = chunkDir.appendingPathComponent("notes.txt")
        try "Some notes".write(to: txtFile, atomically: true, encoding: .utf8)

        let jsonFile = chunkDir.appendingPathComponent("metadata.json")
        try "{}".write(to: jsonFile, atomically: true, encoding: .utf8)

        // When
        let chunkFiles = try chunkWriter.getChunkFiles(for: testRecordingId)

        // Then
        XCTAssertEqual(chunkFiles.count, 1, "Should only return .mp4 files")
        XCTAssertEqual(
            chunkFiles[0].lastPathComponent,
            "part-0001.mp4",
            "Should only return mp4 chunk"
        )
    }

    func testGetTotalSizeEmpty() throws {
        // Given - Recording ID with no chunks
        let emptyRecordingId = "empty-recording-\(UUID().uuidString)"

        // When
        let totalSize = try chunkWriter.getTotalSize(for: emptyRecordingId)

        // Then
        XCTAssertEqual(totalSize, 0, "Should return 0 for recording with no chunks")
    }

    func testGetTotalSizeSingleChunk() async throws {
        // Given - Save one chunk with known size
        let data = Data(repeating: 0xFF, count: 2_000_000) // 2MB
        let chunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-single-\(UUID().uuidString).mp4")
        try data.write(to: chunkURL)

        let metadata = try await chunkWriter.saveChunk(
            fileURL: chunkURL,
            index: 0,
            recordingId: testRecordingId
        )

        // When
        let totalSize = try chunkWriter.getTotalSize(for: testRecordingId)

        // Then
        XCTAssertEqual(
            totalSize,
            metadata.sizeBytes,
            "Total size should match single chunk size"
        )
        XCTAssertEqual(totalSize, 2_000_000, "Total size should be 2MB")
    }

    func testGetTotalSizeMultipleChunks() async throws {
        // Given - Save multiple chunks with different sizes
        let sizes = [1_000_000, 2_000_000, 3_000_000] // 1MB, 2MB, 3MB
        var expectedTotal: Int64 = 0

        for (index, size) in sizes.enumerated() {
            let data = Data(repeating: UInt8(index), count: size)
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk-\(index)-\(UUID().uuidString).mp4")
            try data.write(to: chunkURL)

            let metadata = try await chunkWriter.saveChunk(
                fileURL: chunkURL,
                index: index,
                recordingId: testRecordingId
            )
            expectedTotal += metadata.sizeBytes
        }

        // When
        let totalSize = try chunkWriter.getTotalSize(for: testRecordingId)

        // Then
        XCTAssertEqual(totalSize, expectedTotal, "Total size should be sum of all chunks")
        XCTAssertEqual(totalSize, 6_000_000, "Total size should be 6MB")
    }

    func testGetTotalSizeAfterChunkDeletion() async throws {
        // Given - Save 2 chunks
        for index in 0..<2 {
            let data = Data(repeating: UInt8(index), count: 1_000_000)
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk-\(index)-\(UUID().uuidString).mp4")
            try data.write(to: chunkURL)

            _ = try await chunkWriter.saveChunk(
                fileURL: chunkURL,
                index: index,
                recordingId: testRecordingId
            )
        }

        // Verify initial size
        let initialSize = try chunkWriter.getTotalSize(for: testRecordingId)
        XCTAssertEqual(initialSize, 2_000_000, "Initial total should be 2MB")

        // Manually delete one chunk
        let chunkDir = chunkWriter.getChunkDirectory(for: testRecordingId)
        let chunkToDelete = chunkDir.appendingPathComponent("part-0001.mp4")
        try FileManager.default.removeItem(at: chunkToDelete)

        // When
        let updatedSize = try chunkWriter.getTotalSize(for: testRecordingId)

        // Then
        XCTAssertEqual(updatedSize, 1_000_000, "Updated total should be 1MB after deletion")
    }
}
