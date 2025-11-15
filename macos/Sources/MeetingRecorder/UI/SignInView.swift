//
//  SignInView.swift
//  MeetingRecorder
//
//  Firebase authentication UI
//

import SwiftUI

struct SignInView: View {
    @StateObject private var authService = AuthService.shared

    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Meeting Recorder")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text(isCreatingAccount ? "Create Account" : "Sign In")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            // Form
            VStack(spacing: 16) {
                // Email field
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                // Password field
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(isCreatingAccount ? .newPassword : .password)

                // Error message
                if let errorMessage = authService.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 400)

            // Action buttons
            VStack(spacing: 12) {
                Button {
                    Task {
                        if isCreatingAccount {
                            try? await authService.createAccount(email: email, password: password)
                        } else {
                            try? await authService.signIn(email: email, password: password)
                        }
                    }
                } label: {
                    if authService.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(isCreatingAccount ? "Create Account" : "Sign In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty || authService.isLoading)
                .controlSize(.large)

                // Toggle between sign in / create account
                Button {
                    isCreatingAccount.toggle()
                    authService.errorMessage = nil
                } label: {
                    Text(isCreatingAccount ? "Already have an account? Sign in" : "Don't have an account? Create one")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 400)
    }
}

#Preview {
    SignInView()
}
