//
//  DynamoDBClientFactory.swift
//  MeetingRecorder
//
//  Factory for creating configured AWS DynamoDB clients
//

import AWSDynamoDB
import AWSClientRuntime
import ClientRuntime
import Foundation

/// Factory for creating AWS DynamoDB clients with STS credentials
actor DynamoDBClientFactory {
    static let shared = DynamoDBClientFactory()

    // MARK: - Properties

    private let credentialService = CredentialExchangeService.shared
    private var cachedClient: DynamoDBClient?
    private var clientCreatedAt: Date?

    // MARK: - Errors

    enum FactoryError: Error, LocalizedError {
        case credentialsFailed(Error)
        case clientCreationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .credentialsFailed(let error):
                return "Failed to get AWS credentials: \(error.localizedDescription)"
            case .clientCreationFailed(let error):
                return "Failed to create DynamoDB client: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Initialization

    private init() {
        Task {
            await Logger.shared.debug("DynamoDBClientFactory initialized")
        }
    }

    // MARK: - Public API

    /// Get a DynamoDB client with valid credentials
    /// Returns cached client if credentials are still valid, otherwise creates a new one
    func getClient() async throws -> DynamoDBClient {
        // Check if we have a cached client with valid credentials
        if let client = cachedClient,
           let createdAt = clientCreatedAt,
           !shouldRefreshClient(createdAt: createdAt) {
            await Logger.shared.debug("Using cached DynamoDB client")
            return client
        }

        await Logger.shared.info("Creating new DynamoDB client")

        // Get fresh credentials
        let credentials: AuthSession.AWSCredentials
        do {
            credentials = try await credentialService.getCredentials()
        } catch {
            await Logger.shared.error("Failed to get AWS credentials", metadata: [
                "error": error.localizedDescription
            ])
            throw FactoryError.credentialsFailed(error)
        }

        // Create credentials provider
        let credentialsProvider = try createCredentialsProvider(from: credentials)

        // Create DynamoDB client
        let client: DynamoDBClient
        do {
            let config = try await DynamoDBClient.DynamoDBClientConfiguration(
                awsCredentialIdentityResolver: credentialsProvider,
                region: AWSConfig.region,
                signingRegion: AWSConfig.region.rawValue
            )

            client = DynamoDBClient(config: config)
        } catch {
            await Logger.shared.error("Failed to create DynamoDB client", metadata: [
                "error": error.localizedDescription
            ])
            throw FactoryError.clientCreationFailed(error)
        }

        // Cache the client
        cachedClient = client
        clientCreatedAt = Date()

        await Logger.shared.info("DynamoDB client created successfully", metadata: [
            "region": AWSConfig.region.rawValue,
            "table": AWSConfig.dynamoDBTableName
        ])

        return client
    }

    /// Force refresh of the DynamoDB client (clears cache)
    func refreshClient() async throws -> DynamoDBClient {
        await Logger.shared.info("Forcing DynamoDB client refresh")
        cachedClient = nil
        clientCreatedAt = nil
        return try await getClient()
    }

    /// Clear cached client
    func clearCache() {
        cachedClient = nil
        clientCreatedAt = nil
        Task {
            await Logger.shared.debug("DynamoDB client cache cleared")
        }
    }

    // MARK: - Private Methods

    /// Check if client should be refreshed based on age
    private func shouldRefreshClient(createdAt: Date) -> Bool {
        let age = Date().timeIntervalSince(createdAt)
        let maxAge = TimeInterval(AWSConfig.Security.credentialCacheMinutes * 60)
        return age >= maxAge
    }

    /// Create a credentials provider from STS credentials
    private func createCredentialsProvider(
        from credentials: AuthSession.AWSCredentials
    ) throws -> AWSCredentialIdentity {
        AWSCredentialIdentity(
            accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken,
            expiration: credentials.expiration
        )
    }
}

// MARK: - Convenience Extensions

extension DynamoDBClientFactory {
    /// Create attribute value from string
    static func stringAttribute(_ value: String) -> AWSDynamoDB.AttributeValue {
        .s(value)
    }

    /// Create attribute value from number
    static func numberAttribute(_ value: Int) -> AWSDynamoDB.AttributeValue {
        .n(String(value))
    }

    /// Create attribute value from number
    static func numberAttribute(_ value: Double) -> AWSDynamoDB.AttributeValue {
        .n(String(value))
    }

    /// Create attribute value from boolean
    static func boolAttribute(_ value: Bool) -> AWSDynamoDB.AttributeValue {
        .bool(value)
    }

    /// Create attribute value from string list
    static func stringListAttribute(_ values: [String]) -> AWSDynamoDB.AttributeValue {
        .ss(values)
    }

    /// Create attribute value from map
    static func mapAttribute(_ map: [String: AWSDynamoDB.AttributeValue]) -> AWSDynamoDB.AttributeValue {
        .m(map)
    }

    /// Extract string from attribute value
    static func extractString(from attribute: AWSDynamoDB.AttributeValue?) -> String? {
        guard case .s(let value) = attribute else { return nil }
        return value
    }

    /// Extract number as Int from attribute value
    static func extractInt(from attribute: AWSDynamoDB.AttributeValue?) -> Int? {
        guard case .n(let value) = attribute else { return nil }
        return Int(value)
    }

    /// Extract number as Double from attribute value
    static func extractDouble(from attribute: AWSDynamoDB.AttributeValue?) -> Double? {
        guard case .n(let value) = attribute else { return nil }
        return Double(value)
    }

    /// Extract boolean from attribute value
    static func extractBool(from attribute: AWSDynamoDB.AttributeValue?) -> Bool? {
        guard case .bool(let value) = attribute else { return nil }
        return value
    }

    /// Extract string list from attribute value
    static func extractStringList(from attribute: AWSDynamoDB.AttributeValue?) -> [String]? {
        guard case .ss(let value) = attribute else { return nil }
        return value
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension DynamoDBClientFactory {
    /// Get current cache status (for testing)
    func getCacheStatus() -> (hasClient: Bool, age: TimeInterval?) {
        let hasClient = cachedClient != nil
        let age = clientCreatedAt.map { Date().timeIntervalSince($0) }
        return (hasClient, age)
    }
}
#endif
