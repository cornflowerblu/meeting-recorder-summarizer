import AppKit
import AWSSTS
import Combine
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
import Security

/// Service for managing user authentication and AWS credentials
///
/// Flow:
/// 1. User signs in with Google via Firebase
/// 2. Exchange Firebase ID token for AWS temporary credentials via Lambda
/// 3. Store credentials securely in Keychain
/// 4. Auto-refresh before expiry
///
/// ## Configuration
///
/// Uses `AWSConfig.authExchangeEndpoint` for the Lambda API URL.
/// - Debug builds: (TBD) https://dev-auth-exchange.execute-api.us-east-1.amazonaws.com/auth/exchange
/// - Release builds: (TBD) https://auth-exchange.execute-api.us-east-1.amazonaws.com/auth/exchange
@MainActor
final class AuthService: ObservableObject {
    // MARK: - Published State

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User?
    @Published var userId: String?
    @Published var error: AuthError?

    // MARK: - Private Properties

    private let authExchangeURL: URL
    private var credentialRefreshTimer: Timer?

    // Keychain keys
    private let keychainServiceName = "com.slingshotgroup.interviewcompanion.aws"
    private let accessKeyIdKey = "aws_access_key_id"
    private let secretAccessKeyKey = "aws_secret_access_key"
    private let sessionTokenKey = "aws_session_token"
    private let expirationKey = "aws_expiration"

    // MARK: - Initialization

    init() {
        // Get auth exchange URL from AWSConfig
        guard let url = URL(string: AWSConfig.authExchangeEndpoint) else {
            fatalError("Invalid AUTH_EXCHANGE_URL in AWSConfig: \(AWSConfig.authExchangeEndpoint)")
        }
        self.authExchangeURL = url

        Logger.auth.info(
            "AuthService initialized with endpoint: \(AWSConfig.authExchangeEndpoint)",
            file: #file,
            function: #function,
            line: #line
        )

        // Check current auth state
        checkAuthState()
    }

    // MARK: - Public Methods

    /// Sign in with Google using Firebase
    func signInWithGoogle() async throws {
        Logger.auth.info(
            "Sign in with Google started",
            file: #file,
            function: #function,
            line: #line
        )

        do {
            // Configure Google Sign-In with client ID from GoogleService-Info.plist
            guard let clientID = Auth.auth().app?.options.clientID else {
                throw AuthError.configurationError("Failed to get Firebase client ID")
            }

            let config = GIDConfiguration(clientID: clientID)
            GIDSignIn.sharedInstance.configuration = config

            // Sign in with Google - this will open a browser window
            // On macOS, we need to provide the presenting window
            guard let window = NSApplication.shared.windows.first else {
                throw AuthError.configurationError("No window available for sign-in")
            }

            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
            let user = result.user

            // Get ID token and access token
            guard let idToken = user.idToken?.tokenString else {
                throw AuthError.firebaseError("Failed to get Google ID token")
            }

            let accessToken = user.accessToken.tokenString

            // Create Firebase credential with Google tokens
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: accessToken
            )

            // Sign in to Firebase with Google credential
            let authResult = try await Auth.auth().signIn(with: credential)

            Logger.auth.info(
                "Signed in with Google: \(authResult.user.email ?? "no-email")",
                file: #file,
                function: #function,
                line: #line
            )

            // Exchange Firebase token for AWS credentials
            // Lambda will emit user.signed_in event to EventBridge
            try await exchangeTokenForCredentials(user: authResult.user)

            self.currentUser = authResult.user
            self.userId = authResult.user.uid
            self.isAuthenticated = true

        } catch let error as NSError {
            Logger.auth.error(
                "Google sign-in failed: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            throw AuthError.firebaseError(error.localizedDescription)
        }
    }

    /// Sign in with email and password (for testing)
    func signInWithEmail(email: String, password: String) async throws {
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)

            Logger.auth.info(
                "Signed in with email: \(email)",
                file: #file,
                function: #function,
                line: #line
            )

            // Exchange Firebase token for AWS credentials
            // Lambda will emit user.signed_in event to EventBridge
            try await exchangeTokenForCredentials(user: result.user)

            self.currentUser = result.user
            self.userId = result.user.uid
            self.isAuthenticated = true

        } catch let error as NSError {
            Logger.auth.error(
                "Email sign-in failed: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            throw AuthError.firebaseError(error.localizedDescription)
        }
    }

    /// Create account with email and password (for testing)
    func createAccount(email: String, password: String) async throws {
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)

            Logger.auth.info(
                "Created account: \(email)",
                file: #file,
                function: #function,
                line: #line
            )

            // Exchange Firebase token for AWS credentials
            // Lambda will emit user.signed_in event to EventBridge
            try await exchangeTokenForCredentials(user: result.user)

            self.currentUser = result.user
            self.userId = result.user.uid
            self.isAuthenticated = true

        } catch let error as NSError {
            Logger.auth.error(
                "Account creation failed: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            throw AuthError.firebaseError(error.localizedDescription)
        }
    }

    /// Sign out current user
    func signOut() throws {
        do {
            try Auth.auth().signOut()

            // Clear stored credentials
            clearCredentials()

            self.currentUser = nil
            self.userId = nil
            self.isAuthenticated = false

            // Stop credential refresh timer
            credentialRefreshTimer?.invalidate()
            credentialRefreshTimer = nil

            Logger.auth.info(
                "Signed out successfully",
                file: #file,
                function: #function,
                line: #line
            )

        } catch let error as NSError {
            Logger.auth.error(
                "Sign out failed: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            throw AuthError.firebaseError(error.localizedDescription)
        }
    }

    /// Get current AWS credentials
    func getAWSCredentials() throws -> AWSCredentials {
        // Try to load from Keychain
        guard let accessKeyId = getKeychainValue(for: accessKeyIdKey),
            let secretAccessKey = getKeychainValue(for: secretAccessKeyKey),
            let sessionToken = getKeychainValue(for: sessionTokenKey),
            let expirationString = getKeychainValue(for: expirationKey),
            let expiration = ISO8601DateFormatter().date(from: expirationString)
        else {
            throw AuthError.credentialsNotFound
        }

        // Check if credentials are expired or about to expire (within 5 minutes)
        if expiration.timeIntervalSinceNow < 300 {
            throw AuthError.credentialsExpired
        }

        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiration: expiration
        )
    }

    // MARK: - Private Methods

    private func checkAuthState() {
        if let user = Auth.auth().currentUser {
            self.currentUser = user
            self.userId = user.uid

            // Try to load credentials from Keychain
            do {
                _ = try getAWSCredentials()
                self.isAuthenticated = true

                // Schedule credential refresh
                scheduleCredentialRefresh()

                Logger.auth.info(
                    "Restored auth session for user: \(user.uid)",
                    file: #file,
                    function: #function,
                    line: #line
                )
            } catch {
                // Credentials expired or not found - need to re-authenticate
                Logger.auth.warning(
                    "Stored credentials invalid: \(error.localizedDescription)",
                    file: #file,
                    function: #function,
                    line: #line
                )
                self.isAuthenticated = false
            }
        } else {
            self.isAuthenticated = false
        }
    }

    private func exchangeTokenForCredentials(user: User) async throws {
        // Get Firebase ID token
        let idToken = try await user.getIDToken()

        Logger.auth.info(
            "Exchanging Firebase token for AWS credentials",
            file: #file,
            function: #function,
            line: #line
        )

        // Call auth_exchange Lambda
        var request = URLRequest(url: authExchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body with user profile data for EventBridge event
        var requestBody: [String: String] = [
            "id_token": idToken,
            "session_name": user.uid,
        ]

        // Add optional user profile fields
        if let email = user.email {
            requestBody["email"] = email
        }
        if let displayName = user.displayName {
            requestBody["display_name"] = displayName
        }
        if let photoURL = user.photoURL?.absoluteString {
            requestBody["photo_url"] = photoURL
        }
        // Get provider from first provider data entry
        if let providerId = user.providerData.first?.providerID {
            requestBody["provider"] = providerId
        }

        request.httpBody = try JSONEncoder().encode(requestBody)

        var (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }

        // Check if response is wrapped in API Gateway structure
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bodyString = json["body"] as? String {
            // API Gateway wrapped response - extract the body
            guard let bodyData = bodyString.data(using: .utf8) else {
                throw AuthError.tokenExchangeFailed("Failed to extract body from API Gateway response")
            }
            data = bodyData
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.auth.error(
                "Token exchange failed (status \(httpResponse.statusCode)): \(errorMessage)",
                file: #file,
                function: #function,
                line: #line
            )
            throw AuthError.tokenExchangeFailed(
                "Status \(httpResponse.statusCode): \(errorMessage)")
        }

        // Parse response
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601  // Handle ISO8601 date strings
        let exchangeResponse: TokenExchangeResponse
        do {
            exchangeResponse = try decoder.decode(TokenExchangeResponse.self, from: data)
        } catch {
            Logger.auth.error(
                "Failed to parse Lambda response: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            throw AuthError.tokenExchangeFailed("Failed to parse response: \(error.localizedDescription)")
        }

        // Store credentials in Keychain
        storeCredentials(exchangeResponse.credentials)

        // Schedule credential refresh
        scheduleCredentialRefresh()

        Logger.auth.info(
            "AWS credentials obtained successfully (expires: \(exchangeResponse.credentials.expiration))",
            file: #file,
            function: #function,
            line: #line
        )
    }

    private func scheduleCredentialRefresh() {
        // Cancel existing timer
        credentialRefreshTimer?.invalidate()

        // Get credentials expiration
        guard let credentials = try? getAWSCredentials() else {
            return
        }

        // Schedule refresh 5 minutes before expiry
        let refreshTime = credentials.expiration.addingTimeInterval(-300)
        let timeInterval = refreshTime.timeIntervalSinceNow

        if timeInterval > 0 {
            credentialRefreshTimer = Timer.scheduledTimer(
                withTimeInterval: timeInterval,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshCredentials()
                }
            }

            Logger.auth.info(
                "Scheduled credential refresh in \(String(format: "%.0f", timeInterval)) seconds",
                file: #file,
                function: #function,
                line: #line
            )
        }
    }

    private func refreshCredentials() async {
        guard let user = currentUser else {
            Logger.auth.warning(
                "Cannot refresh credentials: no current user",
                file: #file,
                function: #function,
                line: #line
            )
            return
        }

        do {
            try await exchangeTokenForCredentials(user: user)
            Logger.auth.info(
                "Credentials refreshed successfully",
                file: #file,
                function: #function,
                line: #line
            )
        } catch {
            Logger.auth.error(
                "Credential refresh failed: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            self.error = error as? AuthError ?? .unknown(error.localizedDescription)
        }
    }

    // MARK: - Keychain Helpers

    private func storeCredentials(_ credentials: AWSCredentials) {
        setKeychainValue(credentials.accessKeyId, for: accessKeyIdKey)
        setKeychainValue(credentials.secretAccessKey, for: secretAccessKeyKey)
        setKeychainValue(credentials.sessionToken, for: sessionTokenKey)
        setKeychainValue(
            ISO8601DateFormatter().string(from: credentials.expiration),
            for: expirationKey
        )
    }

    private func clearCredentials() {
        deleteKeychainValue(for: accessKeyIdKey)
        deleteKeychainValue(for: secretAccessKeyKey)
        deleteKeychainValue(for: sessionTokenKey)
        deleteKeychainValue(for: expirationKey)
    }

    private func setKeychainValue(_ value: String, for key: String) {
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        // Delete existing item
        SecItemDelete(query as CFDictionary)

        // Add new item
        SecItemAdd(query as CFDictionary, nil)
    }

    private func getKeychainValue(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    private func deleteKeychainValue(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Models

/// AWS temporary credentials
struct AWSCredentials: Codable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    let expiration: Date

    enum CodingKeys: String, CodingKey {
        case accessKeyId = "AccessKeyId"
        case secretAccessKey = "SecretAccessKey"
        case sessionToken = "SessionToken"
        case expiration = "Expiration"
    }
}

/// Response from auth_exchange Lambda
private struct TokenExchangeResponse: Codable {
    let credentials: AWSCredentials
    let assumedRoleUser: AssumedRoleUser

    enum CodingKeys: String, CodingKey {
        case credentials
        case assumedRoleUser = "assumed_role_user"
    }
}

private struct AssumedRoleUser: Codable {
    let assumedRoleId: String
    let arn: String

    enum CodingKeys: String, CodingKey {
        case assumedRoleId = "AssumedRoleId"
        case arn = "Arn"
    }
}

/// Authentication errors
enum AuthError: Error, LocalizedError {
    case firebaseError(String)
    case tokenExchangeFailed(String)
    case credentialsNotFound
    case credentialsExpired
    case configurationError(String)
    case networkError(String)
    case notImplemented(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .firebaseError(let message):
            return "Firebase authentication error: \(message)"
        case .tokenExchangeFailed(let message):
            return "Failed to exchange token: \(message)"
        case .credentialsNotFound:
            return "AWS credentials not found. Please sign in again."
        case .credentialsExpired:
            return "AWS credentials expired. Please sign in again."
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .notImplemented(let message):
            return "Not implemented: \(message)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}
