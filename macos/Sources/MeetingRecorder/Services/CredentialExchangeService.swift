//
//  CredentialExchangeService.swift
//  MeetingRecorder
//
//  Exchanges Firebase ID tokens for temporary AWS STS credentials
//

import Foundation

/// Service for exchanging Firebase authentication tokens for AWS STS credentials
actor CredentialExchangeService {
    static let shared = CredentialExchangeService()

    // MARK: - Configuration

    private let authSession = AuthSession.shared
    private let lambdaEndpoint: URL

    // MARK: - Errors

    enum ExchangeError: Error, LocalizedError {
        case noFirebaseToken
        case invalidEndpoint
        case requestFailed(Error)
        case invalidResponse(statusCode: Int, body: String?)
        case invalidResponseData
        case missingCredentials
        case sessionStorageFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noFirebaseToken:
                return "No Firebase ID token found"
            case .invalidEndpoint:
                return "Invalid Lambda endpoint URL"
            case .requestFailed(let error):
                return "Request failed: \(error.localizedDescription)"
            case .invalidResponse(let statusCode, let body):
                return "Invalid response (status \(statusCode)): \(body ?? "no body")"
            case .invalidResponseData:
                return "Invalid response data format"
            case .missingCredentials:
                return "Response missing AWS credentials"
            case .sessionStorageFailed(let error):
                return "Failed to store credentials: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Response Models

    private struct ExchangeRequest: Codable {
        let idToken: String
    }

    private struct ExchangeResponse: Codable {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String
        let expiration: String  // ISO8601 format
        let userId: String

        enum CodingKeys: String, CodingKey {
            case accessKeyId = "AccessKeyId"
            case secretAccessKey = "SecretAccessKey"
            case sessionToken = "SessionToken"
            case expiration = "Expiration"
            case userId
        }
    }

    // MARK: - Initialization

    private init() {
        // Get Lambda endpoint from config
        let baseURL = Config.shared.authExchangeLambdaURL
        self.lambdaEndpoint = URL(string: baseURL)!

        Task {
            await Logger.shared.debug("CredentialExchangeService initialized", metadata: [
                "endpoint": baseURL
            ])
        }
    }

    // MARK: - Public API

    /// Exchange Firebase ID token for AWS STS credentials
    /// - Parameter forceRefresh: If true, ignore cached credentials and force exchange
    /// - Returns: AWS credentials with expiration
    func exchangeCredentials(forceRefresh: Bool = false) async throws -> AuthSession.AWSCredentials {
        // Check for valid cached credentials first (unless forcing refresh)
        if !forceRefresh, await authSession.hasValidAWSCredentials() {
            await Logger.shared.debug("Using cached AWS credentials")
            return try await authSession.loadAWSCredentials()
        }

        await Logger.shared.info("Exchanging Firebase token for AWS credentials")

        // Load Firebase credentials
        let firebaseCredentials: AuthSession.FirebaseCredentials
        do {
            firebaseCredentials = try await authSession.loadFirebaseCredentials()
        } catch {
            await Logger.shared.error("Failed to load Firebase credentials", metadata: [
                "error": error.localizedDescription
            ])
            throw ExchangeError.noFirebaseToken
        }

        // Call Lambda to exchange token
        let awsCredentials = try await performExchange(idToken: firebaseCredentials.idToken)

        // Store in keychain
        do {
            try await authSession.saveAWSCredentials(awsCredentials)
        } catch {
            await Logger.shared.error("Failed to save AWS credentials", metadata: [
                "error": error.localizedDescription
            ])
            throw ExchangeError.sessionStorageFailed(error)
        }

        await Logger.shared.info("AWS credentials exchanged successfully", metadata: [
            "userId": firebaseCredentials.userId,
            "expiresIn": String(Int(awsCredentials.secondsUntilExpiration))
        ])

        return awsCredentials
    }

    /// Get current AWS credentials, refreshing if needed
    func getCredentials() async throws -> AuthSession.AWSCredentials {
        // Try to load existing credentials
        do {
            let credentials = try await authSession.loadAWSCredentials()

            // If not expired, return them
            if !credentials.isExpired(bufferMinutes: AWSConfig.Security.tokenExpirationBufferMinutes) {
                return credentials
            }

            // Expired - fall through to refresh
            await Logger.shared.info("AWS credentials expired, refreshing")
        } catch AuthSession.AuthSessionError.credentialsExpired {
            await Logger.shared.info("AWS credentials expired, refreshing")
        } catch AuthSession.AuthSessionError.noCredentialsFound {
            await Logger.shared.info("No AWS credentials found, performing initial exchange")
        }

        // Refresh by exchanging again
        return try await exchangeCredentials(forceRefresh: true)
    }

    // MARK: - Private Methods

    /// Perform the actual HTTP exchange with the Lambda
    private func performExchange(idToken: String) async throws -> AuthSession.AWSCredentials {
        // Prepare request body
        let requestBody = ExchangeRequest(idToken: idToken)
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(requestBody)
        } catch {
            await Logger.shared.error("Failed to encode request", metadata: [
                "error": error.localizedDescription
            ])
            throw ExchangeError.requestFailed(error)
        }

        // Create URLRequest
        var request = URLRequest(url: lambdaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData
        request.timeoutInterval = 30

        // Send request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            await Logger.shared.error("HTTP request failed", metadata: [
                "error": error.localizedDescription,
                "endpoint": lambdaEndpoint.absoluteString
            ])
            throw ExchangeError.requestFailed(error)
        }

        // Check HTTP status
        guard let httpResponse = response as? HTTPURLResponse else {
            await Logger.shared.error("Invalid HTTP response")
            throw ExchangeError.invalidResponseData
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            await Logger.shared.error("Lambda returned error", metadata: [
                "statusCode": String(httpResponse.statusCode),
                "body": bodyString ?? "no body"
            ])
            throw ExchangeError.invalidResponse(statusCode: httpResponse.statusCode, body: bodyString)
        }

        // Parse response
        let exchangeResponse: ExchangeResponse
        do {
            exchangeResponse = try JSONDecoder().decode(ExchangeResponse.self, from: data)
        } catch {
            await Logger.shared.error("Failed to decode response", metadata: [
                "error": error.localizedDescription,
                "body": String(data: data, encoding: .utf8) ?? "no body"
            ])
            throw ExchangeError.invalidResponseData
        }

        // Parse expiration date
        guard let expiration = ISO8601DateFormatter().date(from: exchangeResponse.expiration) else {
            await Logger.shared.error("Invalid expiration date format", metadata: [
                "expiration": exchangeResponse.expiration
            ])
            throw ExchangeError.invalidResponseData
        }

        // Create credentials object
        let credentials = AuthSession.AWSCredentials(
            accessKeyId: exchangeResponse.accessKeyId,
            secretAccessKey: exchangeResponse.secretAccessKey,
            sessionToken: exchangeResponse.sessionToken,
            expiration: expiration
        )

        await Logger.shared.debug("Successfully parsed exchange response", metadata: [
            "userId": exchangeResponse.userId,
            "expiresIn": String(Int(credentials.secondsUntilExpiration))
        ])

        return credentials
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension CredentialExchangeService {
    /// Mock exchange for testing (bypasses Lambda call)
    func mockExchange(expiresIn: TimeInterval = 3600) async throws -> AuthSession.AWSCredentials {
        await Logger.shared.warning("Using mock credential exchange (DEBUG only)")

        let credentials = AuthSession.sampleAWSCredentials(expiresIn: expiresIn)
        try await authSession.saveAWSCredentials(credentials)

        return credentials
    }
}
#endif
