//
//  AuthService.swift
//  MeetingRecorder
//
//  Firebase authentication service
//

import Foundation
import FirebaseAuth

/// Service for managing Firebase authentication
@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()

    // MARK: - Published State

    @Published var isSignedIn: Bool = false
    @Published var currentUser: User?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let authSession = AuthSession.shared
    private let credentialExchange = CredentialExchangeService.shared

    // MARK: - Errors

    enum AuthError: Error, LocalizedError {
        case signInFailed(String)
        case tokenExchangeFailed(String)
        case signOutFailed(String)
        case noUser

        var errorDescription: String? {
            switch self {
            case .signInFailed(let message):
                return "Sign in failed: \(message)"
            case .tokenExchangeFailed(let message):
                return "Token exchange failed: \(message)"
            case .signOutFailed(let message):
                return "Sign out failed: \(message)"
            case .noUser:
                return "No user signed in"
            }
        }
    }

    // MARK: - Initialization

    private init() {
        // Check for existing Firebase session
        if let user = Auth.auth().currentUser {
            self.currentUser = user
            self.isSignedIn = true

            Task {
                await Logger.shared.info("Existing Firebase session found", metadata: [
                    "userId": user.uid,
                    "email": user.email ?? "no email"
                ])
            }
        }

        // Listen for auth state changes
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.currentUser = user
                self?.isSignedIn = user != nil
            }
        }
    }

    // MARK: - Sign In

    /// Sign in with email and password
    func signIn(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await Logger.shared.info("Attempting sign in", metadata: [
            "email": email
        ])

        do {
            // Sign in to Firebase
            let result = try await Auth.auth().signIn(withEmail: email, password: password)

            await Logger.shared.info("Firebase sign in successful", metadata: [
                "userId": result.user.uid,
                "email": result.user.email ?? "no email"
            ])

            // Get Firebase ID token
            let idToken = try await result.user.getIDToken()

            // Save Firebase credentials to keychain
            let firebaseCredentials = AuthSession.FirebaseCredentials(
                idToken: idToken,
                refreshToken: result.user.refreshToken ?? "",
                userId: result.user.uid
            )
            try await authSession.saveFirebaseCredentials(firebaseCredentials)

            // Exchange for AWS credentials
            await Logger.shared.info("Exchanging Firebase token for AWS credentials")
            _ = try await credentialExchange.exchangeCredentials(forceRefresh: true)

            await Logger.shared.info("Sign in completed successfully", metadata: [
                "userId": result.user.uid
            ])

        } catch let error as NSError {
            await Logger.shared.error("Sign in failed", metadata: [
                "error": error.localizedDescription,
                "code": String(error.code)
            ])
            errorMessage = error.localizedDescription
            throw AuthError.signInFailed(error.localizedDescription)
        }
    }

    /// Sign in with Google (future implementation)
    func signInWithGoogle() async throws {
        throw AuthError.signInFailed("Google sign-in not yet implemented")
    }

    /// Create account with email and password
    func createAccount(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await Logger.shared.info("Creating account", metadata: [
            "email": email
        ])

        do {
            // Create Firebase account
            let result = try await Auth.auth().createUser(withEmail: email, password: password)

            await Logger.shared.info("Account created successfully", metadata: [
                "userId": result.user.uid
            ])

            // Sign in flow (get tokens, exchange)
            let idToken = try await result.user.getIDToken()

            let firebaseCredentials = AuthSession.FirebaseCredentials(
                idToken: idToken,
                refreshToken: result.user.refreshToken ?? "",
                userId: result.user.uid
            )
            try await authSession.saveFirebaseCredentials(firebaseCredentials)

            _ = try await credentialExchange.exchangeCredentials(forceRefresh: true)

            await Logger.shared.info("Account setup completed", metadata: [
                "userId": result.user.uid
            ])

        } catch let error as NSError {
            await Logger.shared.error("Account creation failed", metadata: [
                "error": error.localizedDescription,
                "code": String(error.code)
            ])
            errorMessage = error.localizedDescription
            throw AuthError.signInFailed(error.localizedDescription)
        }
    }

    // MARK: - Sign Out

    /// Sign out of Firebase and clear all credentials
    func signOut() async throws {
        await Logger.shared.info("Signing out")

        do {
            try Auth.auth().signOut()
            try await authSession.clearAll()

            await Logger.shared.info("Sign out successful")
        } catch {
            await Logger.shared.error("Sign out failed", metadata: [
                "error": error.localizedDescription
            ])
            throw AuthError.signOutFailed(error.localizedDescription)
        }
    }

    // MARK: - Token Refresh

    /// Refresh Firebase ID token and exchange for new AWS credentials
    func refreshTokens() async throws {
        guard let user = currentUser else {
            throw AuthError.noUser
        }

        await Logger.shared.info("Refreshing tokens")

        do {
            // Force refresh Firebase ID token
            let idToken = try await user.getIDToken(forcingRefresh: true)

            // Update keychain
            let firebaseCredentials = AuthSession.FirebaseCredentials(
                idToken: idToken,
                refreshToken: user.refreshToken ?? "",
                userId: user.uid
            )
            try await authSession.saveFirebaseCredentials(firebaseCredentials)

            // Exchange for new AWS credentials
            _ = try await credentialExchange.exchangeCredentials(forceRefresh: true)

            await Logger.shared.info("Token refresh successful")
        } catch {
            await Logger.shared.error("Token refresh failed", metadata: [
                "error": error.localizedDescription
            ])
            throw AuthError.tokenExchangeFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// Check if user has valid AWS credentials
    func hasValidCredentials() async -> Bool {
        await authSession.hasValidAWSCredentials()
    }
}
