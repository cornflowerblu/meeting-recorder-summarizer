//
//  RecordControlView.swift
//  MeetingRecorder
//
//  Recording controls with start/stop buttons and status display
//

import SwiftUI

@MainActor
struct RecordControlView: View {

    // MARK: - Dependencies

    @ObservedObject var recorder: ScreenRecorder
    @State private var recordingId: String?
    @State private var showErrorAlert = false
    @State private var errorMessage: String?

    var onRecordingStarted: (String) -> Void
    var onRecordingStopped: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {
            // Status Display
            statusSection

            Spacer()

            // Controls
            controlsSection

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main_app_view")
        .alert("Recording Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {
                showErrorAlert = false
            }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        VStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 64))
                .foregroundColor(statusColor)
                .symbolEffect(.pulse, isActive: recorder.recordingState == .recording)

            Text(statusText)
                .font(.title2)
                .fontWeight(.semibold)

            if recorder.recordingState == .recording {
                Text(formattedElapsedTime)
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 16) {
            if recorder.recordingState == .stopped {
                Button {
                    Task {
                        await startRecording()
                    }
                } label: {
                    HStack {
                        Image(systemName: "record.circle.fill")
                            .font(.title3)
                        Text("Start Recording")
                            .font(.title3)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: 300)
                    .frame(height: 50)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("start_recording_button")
                .help("Start a new recording session")
            } else if recorder.recordingState == .recording {
                Button {
                    Task {
                        await stopRecording()
                    }
                } label: {
                    HStack {
                        Image(systemName: "stop.circle.fill")
                            .font(.title3)
                        Text("Stop Recording")
                            .font(.title3)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: 300)
                    .frame(height: 50)
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .help("Stop the current recording")
            }
        }
    }

    // MARK: - Computed Properties

    private var statusIcon: String {
        switch recorder.recordingState {
        case .stopped:
            return "circle.fill"
        case .recording:
            return "record.circle.fill"
        case .paused:
            return "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        switch recorder.recordingState {
        case .stopped:
            return .gray
        case .recording:
            return .red
        case .paused:
            return .orange
        }
    }

    private var statusText: String {
        switch recorder.recordingState {
        case .stopped:
            return "Ready to Record"
        case .recording:
            return "Recording in Progress"
        case .paused:
            return "Recording Paused"
        }
    }

    private var formattedElapsedTime: String {
        let totalSeconds = Int(recorder.elapsedTime)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    // MARK: - Actions

    private func startRecording() async {
        let newRecordingId = "rec_\(UUID().uuidString)"
        recordingId = newRecordingId

        do {
            try await recorder.startRecording(recordingId: newRecordingId)
            onRecordingStarted(newRecordingId)

            await Logger.shared.info("Recording started from UI", metadata: [
                "recordingId": newRecordingId
            ])
        } catch {
            await Logger.shared.error("Failed to start recording", metadata: [
                "error": error.localizedDescription
            ])

            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func stopRecording() async {
        do {
            try await recorder.stopRecording()
            onRecordingStopped()

            await Logger.shared.info("Recording stopped from UI", metadata: [
                "recordingId": recordingId ?? "unknown"
            ])

            recordingId = nil
        } catch {
            await Logger.shared.error("Failed to stop recording", metadata: [
                "error": error.localizedDescription
            ])

            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
}

// MARK: - Preview

#Preview {
    @MainActor class MockRecorder: ScreenRecorder {
        override var recordingState: RecordingState {
            .stopped
        }

        override var elapsedTime: TimeInterval {
            0
        }
    }

    return RecordControlView(
        recorder: MockRecorder(
            chunkWriter: ChunkWriter.testing(),
            chunkDuration: 60.0,
            outputDirectory: FileManager.default.temporaryDirectory
        ),
        onRecordingStarted: { _ in },
        onRecordingStopped: { }
    )
    .frame(width: 600, height: 500)
}
