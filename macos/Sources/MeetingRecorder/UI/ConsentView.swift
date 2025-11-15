//
//  ConsentView.swift
//  MeetingRecorder
//
//  User consent and permission request for screen recording
//

import SwiftUI
import ScreenCaptureKit

@MainActor
struct ConsentView: View {

    // MARK: - State

    @State private var isRequestingPermission = false
    @State private var showCancellationAlert = false

    var onConsentGranted: () -> Void
    var onConsentDenied: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "video.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)
                .padding(.bottom, 8)

            // Title
            Text("Screen Recording Permission")
                .font(.title)
                .fontWeight(.semibold)
                .accessibilityIdentifier("consent_title")

            // Description
            VStack(alignment: .leading, spacing: 12) {
                Text("Meeting Recorder needs permission to record your screen and audio to create meeting recordings.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("consent_description")

                VStack(alignment: .leading, spacing: 8) {
                    PermissionRow(
                        icon: "record.circle",
                        title: "Screen Recording",
                        description: "Capture your screen during meetings"
                    )

                    PermissionRow(
                        icon: "mic.fill",
                        title: "Microphone Access",
                        description: "Record audio during meetings"
                    )

                    PermissionRow(
                        icon: "lock.fill",
                        title: "Privacy First",
                        description: "All recordings are stored locally and encrypted"
                    )
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }

            // Privacy Policy Link
            Link("Privacy Policy", destination: URL(string: "https://your-company.com/privacy")!)
                .font(.footnote)
                .accessibilityIdentifier("privacy_policy_link")

            Spacer()

            // Action Buttons
            VStack(spacing: 12) {
                if isRequestingPermission {
                    ProgressView("Requesting permission...")
                        .progressViewStyle(.linear)
                        .frame(width: 300)
                        .accessibilityIdentifier("permission_loading")
                } else {
                    Button {
                        Task {
                            await requestPermission()
                        }
                    } label: {
                        Text("Allow Screen Recording")
                            .frame(maxWidth: 300)
                            .frame(height: 44)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("allow_recording_button")

                    Button {
                        showCancellationAlert = true
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: 300)
                            .frame(height: 44)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cancel_recording_button")
                }
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("consent_view")
        .alert("Cancel Permission Request", isPresented: $showCancellationAlert) {
            Button("Exit App", role: .destructive) {
                onConsentDenied()
            }
            .accessibilityIdentifier("exit_app_button")

            Button("Go Back", role: .cancel) {
                showCancellationAlert = false
            }
        } message: {
            Text("Screen recording permission is required to use Meeting Recorder. Without it, the app cannot function.")
        }
        .accessibilityIdentifier("consent_cancellation_alert")
    }

    // MARK: - Permission Request

    private func requestPermission() async {
        isRequestingPermission = true

        await Logger.shared.info("Requesting screen recording permission")

        do {
            // Trigger permission dialog by attempting to get shareable content
            if #available(macOS 13.0, *) {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            } else {
                // For macOS 12.3-12.x, use older API
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            }

            await Logger.shared.info("Screen recording permission granted")

            isRequestingPermission = false
            onConsentGranted()
        } catch {
            await Logger.shared.warning("Screen recording permission denied", metadata: [
                "error": error.localizedDescription
            ])

            isRequestingPermission = false

            // Show error state
            await MainActor.run {
                showPermissionDeniedAlert()
            }
        }
    }

    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Permission Denied"
        alert.informativeText = "Screen recording permission is required. Please enable it in System Settings > Privacy & Security > Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open System Settings to Screen Recording
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }

            onConsentDenied()
        } else {
            onConsentDenied()
        }
    }
}

// MARK: - Permission Row Component

private struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Preview

#Preview {
    ConsentView(
        onConsentGranted: {
            print("Consent granted")
        },
        onConsentDenied: {
            print("Consent denied")
        }
    )
    .frame(width: 600, height: 700)
}
