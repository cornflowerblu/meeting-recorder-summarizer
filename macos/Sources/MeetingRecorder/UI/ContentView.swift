import SwiftUI

struct ContentView: View {
    @StateObject private var authService = AuthService.shared

    var body: some View {
        Group {
            if authService.isSignedIn {
                // Main app view
                MainAppView()
            } else {
                // Sign in gate
                SignInView()
            }
        }
    }
}

struct MainAppView: View {
    @StateObject private var authService = AuthService.shared

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Meeting Recorder")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    if let email = authService.currentUser?.email {
                        Text("Signed in as \(email)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Sign out button
                Button("Sign Out") {
                    Task {
                        try? await authService.signOut()
                    }
                }
                .buttonStyle(.bordered)
            }

            Divider()

            // Main content
            VStack(spacing: 16) {
                Text("Screen recording with AI intelligence")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Start Recording") {
                    // Recording start implementation pending
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 800, minHeight: 600)
    }
}

#Preview {
    ContentView()
}
