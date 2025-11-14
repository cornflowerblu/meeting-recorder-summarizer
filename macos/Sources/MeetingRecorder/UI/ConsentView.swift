import SwiftUI

/// View for obtaining user consent before screen recording
///
/// Implements two-tier consent system:
/// 1. First-run: Initial acknowledgment and permission setup
/// 2. Per-session: Explicit consent before each recording
///
/// ## Privacy Considerations
///
/// - Clear warning about what will be recorded
/// - Explanation of data storage and access
/// - Link to privacy policy
/// - Checkbox required before enabling recording
///
/// ## UserDefaults Keys
///
/// - `hasCompletedFirstRun`: Bool - Tracks first-run acknowledgment
/// - `lastConsentDate`: Date - Timestamp of most recent consent
@MainActor
struct ConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hasAgreed: Bool = false
    @AppStorage("hasCompletedFirstRun") private var hasCompletedFirstRun: Bool = false

    /// Callback invoked when user accepts or rejects consent
    /// - Parameter consented: true if user accepted, false if rejected
    var onConsent: (Bool) -> Void

    /// Determines if this is the first time the app is being used
    private var isFirstRun: Bool {
        !hasCompletedFirstRun
    }

    var body: some View {
        VStack(spacing: 24) {
            // Warning Icon
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
                .padding(.top, 20)

            // Title
            Text(isFirstRun ? "Screen Recording Consent" : "Confirm Recording")
                .font(.title)
                .fontWeight(.bold)
                .accessibilityIdentifier("Screen Recording Consent")

            // Description
            VStack(alignment: .leading, spacing: 16) {
                if isFirstRun {
                    firstRunMessage
                } else {
                    perSessionMessage
                }

                privacyStatement
            }
            .padding(.horizontal, 20)

            // Consent Checkbox
            Toggle(isOn: $hasAgreed) {
                Text("I understand and consent")
                    .font(.headline)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("I understand and consent")

            // Privacy Policy Link
            Link("Read our Privacy Policy", destination: URL(string: "https://example.com/privacy")!)
                .font(.caption)
                .foregroundColor(.blue)

            Spacer()

            // Action Buttons
            HStack(spacing: 16) {
                Button("Cancel") {
                    dismiss()
                    onConsent(false)
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Cancel")

                Button("Start Recording") {
                    saveConsentAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasAgreed)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("Start Recording")
            }
            .padding(.bottom, 20)
        }
        .frame(width: 450, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Subviews

    private var firstRunMessage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to Meeting Recorder")
                .font(.headline)

            Text("This app requires permission to record your screen.")
                .font(.body)

            Text("Before you begin:")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                bulletPoint("You'll be prompted to grant Screen Recording permission")
                bulletPoint("Your screen will be recorded during meetings")
                bulletPoint("Recordings are stored securely in your private AWS account")
                bulletPoint("Only you can access your recordings")
            }
        }
    }

    private var perSessionMessage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your screen will be recorded")
                .font(.headline)
                .foregroundColor(.orange)

            Text("This recording will capture everything visible on your screen, including:")
                .font(.body)

            VStack(alignment: .leading, spacing: 8) {
                bulletPoint("All open windows and applications")
                bulletPoint("Desktop notifications")
                bulletPoint("System UI elements")
                bulletPoint("Any sensitive information currently displayed")
            }

            Text("Please close any windows containing private information before proceeding.")
                .font(.callout)
                .foregroundColor(.secondary)
                .italic()
                .padding(.top, 8)
        }
    }

    private var privacyStatement: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 8)

            Label {
                Text("Only you can access your recordings")
                    .font(.callout)
            } icon: {
                Image(systemName: "lock.fill")
                    .foregroundColor(.green)
            }
            .accessibilityIdentifier("Only you can access your recordings")

            Label {
                Text("Recordings stored in your private AWS account")
                    .font(.callout)
            } icon: {
                Image(systemName: "cloud.fill")
                    .foregroundColor(.blue)
            }
            .accessibilityIdentifier("Recordings stored in your private AWS account")

            Label {
                Text("No data shared with third parties")
                    .font(.callout)
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(.orange)
            }
        }
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.body)
            Text(text)
                .font(.callout)
        }
    }

    // MARK: - Actions

    private func saveConsentAndDismiss() {
        // Mark first run as complete
        if isFirstRun {
            hasCompletedFirstRun = true
        }

        // Save consent timestamp
        UserDefaults.standard.set(Date(), forKey: "lastConsentDate")

        Logger.app.info(
            "User consented to screen recording (first run: \(isFirstRun))",
            file: #file,
            function: #function,
            line: #line
        )

        dismiss()
        onConsent(true)
    }
}

// MARK: - Preview

#Preview("First Run") {
    ConsentView { consented in
        print("Consent: \(consented)")
    }
}

#Preview("Per-Session") {
    ConsentView { consented in
        print("Consent: \(consented)")
    }
    .onAppear {
        UserDefaults.standard.set(true, forKey: "hasCompletedFirstRun")
    }
}
