import SwiftUI

/// Sign-in view for Firebase authentication
///
/// **Primary Authentication Method:** Google Sign-In
///
/// Features:
/// - Google OAuth sign-in (primary)
/// - Email/password authentication (disabled - future feature)
/// - Loading states
/// - Error handling
/// - Auto-navigate to main app after successful sign-in
///
/// Note: Email/password authentication is not currently enabled in Firebase.
/// This will be added in a future release.
@MainActor
struct SignInView: View {
    @ObservedObject var authService: AuthService
    @State private var isLoading: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            // Header
            headerSection

            // Google Sign-In
            googleSignInSection

            // Email/Password (Coming Soon)
            comingSoonSection

            // Error display
            if showError, let error = errorMessage {
                errorBanner(error)
            }

            Spacer()

            // Footer
            footerSection
        }
        .padding(40)
        .frame(width: 500, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Interview Companion")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Sign in to get started")
                .font(.title2)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
    }

    private var googleSignInSection: some View {
        VStack(spacing: 16) {
            Button {
                Task {
                    await handleGoogleSignIn()
                }
            } label: {
                HStack(spacing: 12) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 20))
                    }
                    Text("Sign in with Google")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoading)
            .tint(.blue)
        }
        .padding(.horizontal)
    }

    private var comingSoonSection: some View {
        VStack(spacing: 12) {
            Divider()
                .padding(.horizontal)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundColor(.secondary)
                    Text("Email/Password Sign-In")
                        .font(.callout)
                        .fontWeight(.medium)
                }

                Text("Coming Soon")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }
            .opacity(0.6)
        }
        .padding(.horizontal)
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            Text("Secure authentication powered by Firebase")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Your recordings are stored in your private AWS account")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 20)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(message)
                .font(.callout)
                .foregroundColor(.red)

            Spacer()

            Button("Dismiss") {
                clearError()
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func handleGoogleSignIn() async {
        isLoading = true
        clearError()

        do {
            try await authService.signInWithGoogle()

            Logger.ui.info(
                "Google sign-in successful",
                file: #file,
                function: #function,
                line: #line
            )

        } catch {
            errorMessage = error.localizedDescription
            showError = true

            Logger.ui.error(
                "Google sign-in failed: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
        }

        isLoading = false
    }

    private func clearError() {
        showError = false
        errorMessage = nil
    }
}

// MARK: - Preview

#Preview("Sign In") {
    SignInView(authService: AuthService())
}
