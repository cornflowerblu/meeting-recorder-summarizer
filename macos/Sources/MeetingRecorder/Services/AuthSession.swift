//
//  AuthSession.swift
//  MeetingRecorder
//
//  Secure storage of authentication tokens in macOS Keychain
//

import Foundation
import Security

/// Manages secure storage of authentication credentials in macOS Keychain
actor AuthSession {
    static let shared = AuthSession()

    // MARK: - Keychain Keys

    private enum KeychainKey: String {
        case firebaseIdToken = "com.meetingrecorder.firebase.idToken"
        case firebaseRefreshToken = "com.meetingrecorder.firebase.refreshToken"
        case firebaseUserId = "com.meetingrecorder.firebase.userId"
        case awsAccessKeyId = "com.meetingrecorder.aws.accessKeyId"
        case awsSecretAccessKey = "com.meetingrecorder.aws.secretAccessKey"
        case awsSessionToken = "com.meetingrecorder.aws.sessionToken"
        case awsCredentialsExpiration = "com.meetingrecorder.aws.expiration"
    }

    // MARK: - Service Identifier

    private let serviceName = "com.meetingrecorder.app"

    // MARK: - Errors

    enum AuthSessionError: Error, LocalizedError {
        case keychainWriteFailed(OSStatus)
        case keychainReadFailed(OSStatus)
        case keychainDeleteFailed(OSStatus)
        case invalidData
        case credentialsExpired
        case noCredentialsFound

        var errorDescription: String? {
            switch self {
            case .keychainWriteFailed(let status):
                return "Failed to write to keychain: \(status)"
            case .keychainReadFailed(let status):
                return "Failed to read from keychain: \(status)"
            case .keychainDeleteFailed(let status):
                return "Failed to delete from keychain: \(status)"
            case .invalidData:
                return "Invalid credential data"
            case .credentialsExpired:
                return "AWS credentials have expired"
            case .noCredentialsFound:
                return "No credentials found in keychain"
            }
        }
    }

    // MARK: - Firebase Credentials

    struct FirebaseCredentials {
        let idToken: String
        let refreshToken: String
        let userId: String
    }

    /// Save Firebase credentials to keychain
    func saveFirebaseCredentials(_ credentials: FirebaseCredentials) throws {
        try saveToKeychain(key: .firebaseIdToken, value: credentials.idToken)
        try saveToKeychain(key: .firebaseRefreshToken, value: credentials.refreshToken)
        try saveToKeychain(key: .firebaseUserId, value: credentials.userId)

        Task { await Logger.shared.info("Firebase credentials saved to keychain", metadata: [
            "userId": credentials.userId
        ]) }
    }

    /// Load Firebase credentials from keychain
    func loadFirebaseCredentials() throws -> FirebaseCredentials {
        let idToken = try loadFromKeychain(key: .firebaseIdToken)
        let refreshToken = try loadFromKeychain(key: .firebaseRefreshToken)
        let userId = try loadFromKeychain(key: .firebaseUserId)

        Task { await Logger.shared.debug("Firebase credentials loaded from keychain") }

        return FirebaseCredentials(
            idToken: idToken,
            refreshToken: refreshToken,
            userId: userId
        )
    }

    /// Check if Firebase credentials exist
    func hasFirebaseCredentials() -> Bool {
        do {
            _ = try loadFromKeychain(key: .firebaseIdToken)
            return true
        } catch {
            return false
        }
    }

    /// Clear Firebase credentials from keychain
    func clearFirebaseCredentials() throws {
        try deleteFromKeychain(key: .firebaseIdToken)
        try deleteFromKeychain(key: .firebaseRefreshToken)
        try deleteFromKeychain(key: .firebaseUserId)

        Task { await Logger.shared.info("Firebase credentials cleared from keychain") }
    }

    // MARK: - AWS Credentials

    struct AWSCredentials {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String
        let expiration: Date

        /// Check if credentials are expired or will expire soon
        func isExpired(bufferMinutes: Int = 10) -> Bool {
            let bufferDate = Date().addingTimeInterval(TimeInterval(bufferMinutes * 60))
            return expiration <= bufferDate
        }

        /// Time until expiration in seconds
        var secondsUntilExpiration: TimeInterval {
            expiration.timeIntervalSinceNow
        }
    }

    /// Save AWS STS credentials to keychain
    func saveAWSCredentials(_ credentials: AWSCredentials) throws {
        try saveToKeychain(key: .awsAccessKeyId, value: credentials.accessKeyId)
        try saveToKeychain(key: .awsSecretAccessKey, value: credentials.secretAccessKey)
        try saveToKeychain(key: .awsSessionToken, value: credentials.sessionToken)

        // Store expiration as ISO8601 string
        let expirationString = ISO8601DateFormatter().string(from: credentials.expiration)
        try saveToKeychain(key: .awsCredentialsExpiration, value: expirationString)

        Task { await Logger.shared.info("AWS credentials saved to keychain", metadata: [
            "expiration": expirationString,
            "secondsUntilExpiration": String(Int(credentials.secondsUntilExpiration))
        ]) }
    }

    /// Load AWS STS credentials from keychain
    /// Throws if credentials are expired
    func loadAWSCredentials() throws -> AWSCredentials {
        let accessKeyId = try loadFromKeychain(key: .awsAccessKeyId)
        let secretAccessKey = try loadFromKeychain(key: .awsSecretAccessKey)
        let sessionToken = try loadFromKeychain(key: .awsSessionToken)
        let expirationString = try loadFromKeychain(key: .awsCredentialsExpiration)

        guard let expiration = ISO8601DateFormatter().date(from: expirationString) else {
            throw AuthSessionError.invalidData
        }

        let credentials = AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiration: expiration
        )

        // Check if expired
        if credentials.isExpired(bufferMinutes: AWSConfig.Security.tokenExpirationBufferMinutes) {
            Task { await Logger.shared.warning("AWS credentials expired", metadata: [
                "expiration": expirationString
            ]) }
            throw AuthSessionError.credentialsExpired
        }

        Task { await Logger.shared.debug("AWS credentials loaded from keychain", metadata: [
            "secondsUntilExpiration": String(Int(credentials.secondsUntilExpiration))
        ]) }

        return credentials
    }

    /// Check if valid AWS credentials exist (not expired)
    func hasValidAWSCredentials() -> Bool {
        do {
            let credentials = try loadAWSCredentials()
            return !credentials.isExpired(bufferMinutes: AWSConfig.Security.tokenExpirationBufferMinutes)
        } catch {
            return false
        }
    }

    /// Clear AWS credentials from keychain
    func clearAWSCredentials() throws {
        try deleteFromKeychain(key: .awsAccessKeyId)
        try deleteFromKeychain(key: .awsSecretAccessKey)
        try deleteFromKeychain(key: .awsSessionToken)
        try deleteFromKeychain(key: .awsCredentialsExpiration)

        Task { await Logger.shared.info("AWS credentials cleared from keychain") }
    }

    // MARK: - Clear All

    /// Clear all stored credentials (sign out)
    func clearAll() throws {
        do {
            try clearFirebaseCredentials()
        } catch {
            Task { await Logger.shared.warning("Failed to clear Firebase credentials", metadata: [
                "error": error.localizedDescription
            ]) }
        }

        do {
            try clearAWSCredentials()
        } catch {
            Task { await Logger.shared.warning("Failed to clear AWS credentials", metadata: [
                "error": error.localizedDescription
            ]) }
        }

        Task { await Logger.shared.info("All credentials cleared") }
    }

    // MARK: - Keychain Operations

    /// Save a string value to keychain
    private func saveToKeychain(key: KeychainKey, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw AuthSessionError.invalidData
        }

        // Delete existing item first (if any)
        try? deleteFromKeychain(key: key)

        // Add new item
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw AuthSessionError.keychainWriteFailed(status)
        }
    }

    /// Load a string value from keychain
    private func loadFromKeychain(key: KeychainKey) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? AuthSessionError.noCredentialsFound
                : AuthSessionError.keychainReadFailed(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AuthSessionError.invalidData
        }

        return value
    }

    /// Delete a value from keychain
    private func deleteFromKeychain(key: KeychainKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)

        // Don't throw if item doesn't exist (already deleted)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthSessionError.keychainDeleteFailed(status)
        }
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension AuthSession {
    /// Create sample Firebase credentials for testing
    static func sampleFirebaseCredentials() -> FirebaseCredentials {
        FirebaseCredentials(
            idToken: "sample-firebase-id-token-abc123",
            refreshToken: "sample-firebase-refresh-token-def456",
            userId: "test-user-123"
        )
    }

    /// Create sample AWS credentials for testing
    static func sampleAWSCredentials(expiresIn: TimeInterval = 3600) -> AWSCredentials {
        AWSCredentials(
            accessKeyId: "ASIASAMPLEACCESSKEY",
            secretAccessKey: "sampleSecretAccessKey123",
            sessionToken: "sampleSessionToken456",
            expiration: Date().addingTimeInterval(expiresIn)
        )
    }
}
#endif
