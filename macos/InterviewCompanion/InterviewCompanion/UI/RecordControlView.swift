import SwiftUI

/// Main control view for recording screen and monitoring upload progress
///
/// Features:
/// - Recording state display (Idle/Recording/Paused/Stopped)
/// - Start/Pause/Resume/Stop controls
/// - Live recording duration
/// - Chunk generation count
/// - Upload progress per chunk
/// - Error messages with retry actions
/// - Disk space monitoring
///
/// ## State Management
///
/// Observes ScreenRecorder and UploadQueue for state updates.
/// Shows ConsentView before starting recording.
@MainActor
struct RecordControlView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var uploadQueue: UploadQueue

    @State private var showConsent: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isPermissionError: Bool = false
    @State private var diskSpaceGB: Double = 0.0

    /// Recording indicator controller (managed by this view)
    private let indicatorController = RecordingIndicatorController()

    var body: some View {
        VStack(spacing: 24) {
            // Header
            headerSection

            Divider()

            // Status Display
            statusSection

            Divider()

            // Control Buttons
            controlsSection

            Divider()

            // Upload Progress
            uploadSection

            Spacer()

            // Error Banner
            if showError, let error = errorMessage {
                errorBanner(error)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 600)
        .sheet(isPresented: $showConsent) {
            ConsentView { consented in
                if consented {
                    Task {
                        await startRecording()
                    }
                }
            }
            .frame(width: 450, height: 550)
        }
        .onAppear {
            updateDiskSpace()
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            if isRecording {
                indicatorController.show()
            } else {
                indicatorController.hide()
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(recorder.isRecording ? .red : .gray)
                .symbolEffect(.pulse, isActive: recorder.isRecording)

            Text("Screen Recording")
                .font(.title)
                .fontWeight(.bold)

            Text(recorder.isRecording ? "Recording in progress" : "Ready to record")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Recording State
            statusRow(
                icon: "circle.fill",
                iconColor: stateColor,
                title: "Status",
                value: stateText
            )

            // Recording Duration
            if recorder.isRecording || recorder.recordingDuration > 0 {
                statusRow(
                    icon: "clock.fill",
                    iconColor: .blue,
                    title: "Duration",
                    value: formattedDuration
                )
            }

            // Chunks Generated
            if recorder.currentChunkIndex > 0 {
                statusRow(
                    icon: "film.fill",
                    iconColor: .purple,
                    title: "Chunks",
                    value: "\(recorder.currentChunkIndex) generated"
                )
            }

            // Disk Space
            statusRow(
                icon: "internaldrive.fill",
                iconColor: diskSpaceColor,
                title: "Available Space",
                value: String(format: "%.1f GB", diskSpaceGB)
            )
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var controlsSection: some View {
        VStack(spacing: 16) {
            if !recorder.isRecording {
                // Start Recording Button
                Button {
                    requestConsent()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(diskSpaceGB < 1.0)  // Require at least 1GB free
                .accessibilityIdentifier("Start Recording")

                if diskSpaceGB < 1.0 {
                    Text("Insufficient disk space (need at least 1 GB)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else {
                HStack(spacing: 12) {
                    // Pause/Resume Button
                    Button {
                        Task {
                            await togglePause()
                        }
                    } label: {
                        Label(
                            recorder.isPaused ? "Resume" : "Pause",
                            systemImage: recorder.isPaused ? "play.circle" : "pause.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    // Stop Button
                    Button {
                        Task {
                            await stopRecording()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .accessibilityIdentifier("Stop Recording")
                }
            }
        }
    }

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.blue)
                Text("Upload Progress")
                    .font(.headline)

                Spacer()

                if uploadQueue.status == .uploading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if uploadQueue.uploadProgress.isEmpty && uploadQueue.failedChunks.isEmpty {
                Text("No uploads in progress")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                // Upload Summary
                Text(String(format: "%.0f%% complete", uploadQueue.overallProgress * 100))
                    .font(.callout)

                // Overall Progress Bar
                ProgressView(value: uploadQueue.overallProgress, total: 1.0)
                    .progressViewStyle(.linear)

                // Failed Chunks
                if !uploadQueue.failedChunks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(uploadQueue.failedChunks.count) chunks failed")
                            .font(.callout)
                            .foregroundColor(.red)

                        Button {
                            Task {
                                await uploadQueue.retryFailed()
                            }
                        } label: {
                            Label("Retry Failed Uploads", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func statusRow(icon: String, iconColor: Color, title: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 20)

            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.callout)
                .fontWeight(.medium)
                .accessibilityIdentifier(value)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(message)
                .font(.callout)

            Spacer()

            // Show "Open Settings" button for permission errors
            if isPermissionError {
                Button("Open Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Dismiss") {
                showError = false
                errorMessage = nil
                isPermissionError = false
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    private func openSystemSettings() {
        // Open System Settings to Screen Recording permissions
        // On macOS 13+, use Settings app; on older versions, use System Preferences
        if #available(macOS 13.0, *) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: - Computed Properties

    private var stateText: String {
        if recorder.isRecording {
            return recorder.isPaused ? "Paused" : "Recording"
        } else if recorder.recordingDuration > 0 {
            return "Stopped"
        } else {
            return "Idle"
        }
    }

    private var stateColor: Color {
        if recorder.isRecording {
            return recorder.isPaused ? .yellow : .red
        } else if recorder.recordingDuration > 0 {
            return .gray
        } else {
            return .green
        }
    }

    private var formattedDuration: String {
        let minutes = Int(recorder.recordingDuration) / 60
        let seconds = Int(recorder.recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var diskSpaceColor: Color {
        if diskSpaceGB < 1.0 {
            return .red
        } else if diskSpaceGB < 5.0 {
            return .orange
        } else {
            return .green
        }
    }

    // MARK: - Actions

    private func requestConsent() {
        showConsent = true
    }

    private func startRecording() async {
        do {
            // Generate a unique recording ID
            let recordingId = "rec-\(UUID().uuidString)"

            try await recorder.startRecording(recordingId: recordingId)

            Logger.recording.info(
                "Recording started from UI (ID: \(recordingId))",
                file: #file,
                function: #function,
                line: #line
            )
        } catch {
            handleError(error)
        }
    }

    private func togglePause() async {
        do {
            if recorder.isPaused {
                try await recorder.resumeRecording()
            } else {
                try await recorder.pauseRecording()
            }
        } catch {
            handleError(error)
        }
    }

    private func stopRecording() async {
        do {
            try await recorder.stopRecording()

            Logger.recording.info(
                "Recording stopped from UI (duration: \(formattedDuration))",
                file: #file,
                function: #function,
                line: #line
            )
        } catch {
            handleError(error)
        }
    }

    private func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true

        // Check if this is a permission error
        if let captureError = error as? CaptureError, case .permissionDenied = captureError {
            isPermissionError = true
        } else {
            isPermissionError = false
        }

        Logger.recording.error(
            "Recording error: \(error.localizedDescription)",
            file: #file,
            function: #function,
            line: #line
        )
    }

    private func updateDiskSpace() {
        if let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ),
           let freeSpace = attributes[.systemFreeSize] as? Int64 {
            diskSpaceGB = Double(freeSpace) / 1_000_000_000.0
        }
    }
}

// MARK: - Preview

#Preview {
    RecordControlView(
        recorder: ScreenRecorder(
            captureService: MockCaptureService(),
            storageService: MockStorageService()
        ),
        uploadQueue: UploadQueue(
            uploader: MockS3Uploader(),
            userId: "preview-user",
            recordingId: "preview-rec-001"
        )
    )
}

// MARK: - Mocks for Preview

private final class MockS3Uploader: S3UploaderProtocol, @unchecked Sendable {
    func uploadChunk(
        recordingId: String,
        chunkMetadata: ChunkMetadata,
        userId: String
    ) async throws -> S3UploadResult {
        S3UploadResult(
            s3Key: "test-key",
            etag: "test-etag",
            uploadDuration: 1.0
        )
    }
}

private final class MockCaptureService: ScreenCaptureService, @unchecked Sendable {
    nonisolated func hasPermission() -> Bool { true }
    func startCapture() async throws {}
    func stopCapture() async throws {}
    func pauseCapture() async throws {}
    func resumeCapture() async throws {}
    func requestPermission() async throws {}
}

private final class MockStorageService: ChunkStorageService, @unchecked Sendable {
    nonisolated func calculateChecksum(fileURL: URL) throws -> String { "mock-checksum" }
    nonisolated func hasSufficientDiskSpace(requiredBytes: Int64) -> Bool { true }
    nonisolated func getChunkDirectory(for recordingId: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(recordingId)")
    }
    func saveChunk(fileURL: URL, index: Int, recordingId: String) async throws -> ChunkMetadata {
        ChunkMetadata(
            chunkId: "mock-\(index)",
            filePath: fileURL,
            sizeBytes: 1000,
            checksum: "mock",
            durationSeconds: 60,
            index: index,
            recordingId: recordingId
        )
    }
    func cleanup(recordingId: String) async throws {}
}
