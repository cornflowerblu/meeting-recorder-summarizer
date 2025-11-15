//
//  RecordingIndicatorOverlay.swift
//  MeetingRecorder
//
//  Persistent recording indicator overlay with timer and controls
//

import SwiftUI

@MainActor
struct RecordingIndicatorOverlay: View {

    // MARK: - State

    @ObservedObject var recorder: ScreenRecorder
    @State private var showStopConfirmation = false

    var onStop: () async -> Void

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            // Recording status dot
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .fill(Color.red.opacity(0.3))
                        .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: pulseAnimation
                        )
                )
                .accessibilityIdentifier("recording_status_dot")
                .onAppear {
                    pulseAnimation = true
                }

            // Status label
            Text("Recording")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .accessibilityIdentifier("recording_status_label")

            // Elapsed time
            Text(formattedElapsedTime)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("recording_time_label")
                .accessibilityValue(formattedElapsedTime)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            // Stop button
            Button {
                showStopConfirmation = true
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Stop Recording")
            .accessibilityIdentifier("stop_recording_button")
            .accessibilityLabel("Stop Recording")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(8)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording_indicator")
        .accessibilityLabel("Recording in progress")
        .alert("Stop Recording", isPresented: $showStopConfirmation) {
            Button("Stop", role: .destructive) {
                Task {
                    await onStop()
                }
            }
            .accessibilityIdentifier("confirm_stop_button")

            Button("Continue Recording", role: .cancel) {
                showStopConfirmation = false
            }
        } message: {
            Text("Are you sure you want to stop the recording? This will finalize the current session.")
        }
        .accessibilityIdentifier("stop_recording_confirmation")
    }

    // MARK: - Animation State

    @State private var pulseAnimation = false

    // MARK: - Computed Properties

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
}

// MARK: - Visual Effect View (NSVisualEffectView wrapper)

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Indicator Window

/// Window controller for the recording indicator overlay
@MainActor
final class RecordingIndicatorWindow: NSWindow {

    init(recorder: ScreenRecorder, onStop: @escaping () async -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configure window behavior
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hasShadow = false

        // Set content view
        contentView = NSHostingView(
            rootView: RecordingIndicatorOverlay(recorder: recorder, onStop: onStop)
        )

        // Position in top-right corner
        positionInTopRight()
    }

    func positionInTopRight() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = frame.size

        let x = screenFrame.maxX - windowSize.width - 20
        let y = screenFrame.maxY - windowSize.height - 20

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Show the indicator window
    func show() {
        orderFrontRegardless()
        positionInTopRight()

        Task {
            await Logger.shared.debug("Recording indicator shown")
        }
    }

    /// Hide the indicator window
    func hide() {
        orderOut(nil)

        Task {
            await Logger.shared.debug("Recording indicator hidden")
        }
    }
}

// MARK: - Preview

#Preview {
    // Create mock recorder for preview
    @MainActor class MockRecorder: ScreenRecorder {
        override var elapsedTime: TimeInterval {
            125.0 // 2:05
        }

        override var recordingState: RecordingState {
            .recording
        }
    }

    return RecordingIndicatorOverlay(
        recorder: MockRecorder(
            chunkWriter: ChunkWriter.testing(),
            chunkDuration: 60.0,
            outputDirectory: FileManager.default.temporaryDirectory
        ),
        onStop: {
            print("Stop recording")
        }
    )
    .padding()
    .frame(width: 300, height: 100)
}
