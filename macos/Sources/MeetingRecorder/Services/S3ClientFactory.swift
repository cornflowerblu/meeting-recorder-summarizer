//
//  S3ClientFactory.swift
//  MeetingRecorder
//
//  Factory for creating configured AWS S3 clients
//

import AWSS3
import AWSClientRuntime
import ClientRuntime
import Foundation

/// Factory for creating AWS S3 clients with STS credentials
actor S3ClientFactory {
    static let shared = S3ClientFactory()

    // MARK: - Properties

    private let credentialService = CredentialExchangeService.shared
    private var cachedClient: S3Client?
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
                return "Failed to create S3 client: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Initialization

    private init() {
        Task {
            await Logger.shared.debug("S3ClientFactory initialized")
        }
    }

    // MARK: - Public API

    /// Get an S3 client with valid credentials
    /// Returns cached client if credentials are still valid, otherwise creates a new one
    func getClient() async throws -> S3Client {
        // Check if we have a cached client with valid credentials
        if let client = cachedClient,
           let createdAt = clientCreatedAt,
           !shouldRefreshClient(createdAt: createdAt) {
            await Logger.shared.debug("Using cached S3 client")
            return client
        }

        await Logger.shared.info("Creating new S3 client")

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

        // Create S3 client
        let client: S3Client
        do {
            let config = try await S3Client.S3ClientConfiguration(
                awsCredentialIdentityResolver: credentialsProvider,
                region: AWSConfig.region,
                signingRegion: AWSConfig.region.rawValue
            )

            client = S3Client(config: config)
        } catch {
            await Logger.shared.error("Failed to create S3 client", metadata: [
                "error": error.localizedDescription
            ])
            throw FactoryError.clientCreationFailed(error)
        }

        // Cache the client
        cachedClient = client
        clientCreatedAt = Date()

        await Logger.shared.info("S3 client created successfully", metadata: [
            "region": AWSConfig.region.rawValue,
            "bucket": AWSConfig.s3BucketName
        ])

        return client
    }

    /// Force refresh of the S3 client (clears cache)
    func refreshClient() async throws -> S3Client {
        await Logger.shared.info("Forcing S3 client refresh")
        cachedClient = nil
        clientCreatedAt = nil
        return try await getClient()
    }

    /// Clear cached client
    func clearCache() {
        cachedClient = nil
        clientCreatedAt = nil
        Task {
            await Logger.shared.debug("S3 client cache cleared")
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

extension S3ClientFactory {
    /// Create a PutObjectInput for uploading a chunk
    static func createPutObjectInput(
        bucket: String,
        key: String,
        data: Data,
        contentType: String = "video/mp4"
    ) -> PutObjectInput {
        PutObjectInput(
            body: .data(data),
            bucket: bucket,
            contentType: contentType,
            key: key,
            serverSideEncryption: .aes256,
            storageClass: .standard
        )
    }

    /// Create a CreateMultipartUploadInput for large uploads
    static func createMultipartUploadInput(
        bucket: String,
        key: String,
        contentType: String = "video/mp4"
    ) -> CreateMultipartUploadInput {
        CreateMultipartUploadInput(
            bucket: bucket,
            contentType: contentType,
            key: key,
            serverSideEncryption: .aes256,
            storageClass: .standard
        )
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension S3ClientFactory {
    /// Get current cache status (for testing)
    func getCacheStatus() -> (hasClient: Bool, age: TimeInterval?) {
        let hasClient = cachedClient != nil
        let age = clientCreatedAt.map { Date().timeIntervalSince($0) }
        return (hasClient, age)
    }
}
#endif
