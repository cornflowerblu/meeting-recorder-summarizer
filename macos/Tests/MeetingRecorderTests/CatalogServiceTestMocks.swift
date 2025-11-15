import Foundation
@testable import MeetingRecorder

// MARK: - Mock Dependencies for Catalog Service Tests

final class MockDynamoDBClient: DynamoDBClientProtocol {
    struct PutItemCall {
        let tableName: String
        let item: [String: DynamoDBAttributeValue]
    }
    
    struct UpdateItemCall {
        let tableName: String
        let key: [String: DynamoDBAttributeValue]
        let updateExpression: String
        let expressionAttributeValues: [String: DynamoDBAttributeValue]
    }
    
    struct GetItemCall {
        let tableName: String
        let key: [String: DynamoDBAttributeValue]
    }
    
    struct QueryCall {
        let tableName: String
        let keyConditionExpression: String
        let expressionAttributeValues: [String: DynamoDBAttributeValue]
        let scanIndexForward: Bool
        let limit: Int?
    }
    
    var putItemCalls: [PutItemCall] = []
    var updateItemCalls: [UpdateItemCall] = []
    var getItemCalls: [GetItemCall] = []
    var queryCalls: [QueryCall] = []
    
    var shouldFailPutItem = false
    var shouldFailUpdateItem = false
    var shouldFailGetItem = false
    var shouldFailQuery = false
    
    var getItemResponse: [String: DynamoDBAttributeValue]?
    var queryResponse: [[String: DynamoDBAttributeValue]] = []
    
    func putItem(tableName: String, item: [String: DynamoDBAttributeValue]) async throws {
        putItemCalls.append(PutItemCall(tableName: tableName, item: item))
        
        if shouldFailPutItem {
            throw MockDynamoDBError.putItemFailed
        }
    }
    
    func updateItem(
        tableName: String,
        key: [String: DynamoDBAttributeValue],
        updateExpression: String,
        expressionAttributeValues: [String: DynamoDBAttributeValue]
    ) async throws {
        updateItemCalls.append(UpdateItemCall(
            tableName: tableName,
            key: key,
            updateExpression: updateExpression,
            expressionAttributeValues: expressionAttributeValues
        ))
        
        if shouldFailUpdateItem {
            throw MockDynamoDBError.updateItemFailed
        }
    }
    
    func getItem(
        tableName: String,
        key: [String: DynamoDBAttributeValue]
    ) async throws -> [String: DynamoDBAttributeValue]? {
        getItemCalls.append(GetItemCall(tableName: tableName, key: key))
        
        if shouldFailGetItem {
            throw MockDynamoDBError.getItemFailed
        }
        
        return getItemResponse
    }
    
    func query(
        tableName: String,
        keyConditionExpression: String,
        expressionAttributeValues: [String: DynamoDBAttributeValue],
        scanIndexForward: Bool,
        limit: Int?
    ) async throws -> [[String: DynamoDBAttributeValue]] {
        queryCalls.append(QueryCall(
            tableName: tableName,
            keyConditionExpression: keyConditionExpression,
            expressionAttributeValues: expressionAttributeValues,
            scanIndexForward: scanIndexForward,
            limit: limit
        ))
        
        if shouldFailQuery {
            throw MockDynamoDBError.queryFailed
        }
        
        return queryResponse
    }
}

final class MockCredentialExchangeService: CredentialExchangeServiceProtocol {
    var shouldFail = false
    var mockCredentials: AWSCredentials?
    
    func getCurrentCredentials() async throws -> AWSCredentials {
        if shouldFail {
            throw CredentialExchangeError.tokenExpired
        }
        
        return mockCredentials ?? AWSCredentials(
            accessKeyId: "mock_key",
            secretAccessKey: "mock_secret",
            sessionToken: "mock_token",
            expiration: Date().addingTimeInterval(3600)
        )
    }
    
    func refreshCredentials() async throws -> AWSCredentials {
        return try await getCurrentCredentials()
    }
}

enum MockDynamoDBError: Error {
    case putItemFailed
    case updateItemFailed
    case getItemFailed
    case queryFailed
    case itemNotFound
}

enum CredentialExchangeError: Error {
    case tokenExpired
    case networkError
    case invalidToken
}

enum CatalogServiceError: Error {
    case sessionNotFound
    case invalidData
    case authenticationFailed
}

// MARK: - Supporting Types (These will be defined in implementation)

struct RecordingSession {
    let recordingId: String
    let userId: String
    let title: String
    let participants: [String]
    let tags: [String]
    let startTime: Date
    let duration: TimeInterval
    let status: SessionStatus
    let chunkCount: Int
    let s3Prefix: String
    var createdAt: Date?
    var updatedAt: Date?
}

struct ProcessingResults {
    let transcriptS3Key: String
    let summaryS3Key: String
    let videoS3Key: String
    let processingDuration: TimeInterval
    let pipelineVersion: String
    let modelVersions: [String: String]
}

enum SessionStatus: String, CaseIterable {
    case pending
    case recording
    case processing
    case completed
    case failed
}

struct AWSCredentials {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    let expiration: Date
}

enum DynamoDBAttributeValue {
    case string(String)
    case number(Double)
    case list([DynamoDBAttributeValue])
    case map([String: DynamoDBAttributeValue])
    case bool(Bool)
    case null
    
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
    
    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }
    
    var listValue: [DynamoDBAttributeValue]? {
        if case .list(let value) = self {
            return value
        }
        return nil
    }
    
    var mapValue: [String: DynamoDBAttributeValue]? {
        if case .map(let value) = self {
            return value
        }
        return nil
    }
}

protocol DynamoDBClientProtocol {
    func putItem(tableName: String, item: [String: DynamoDBAttributeValue]) async throws
    func updateItem(
        tableName: String,
        key: [String: DynamoDBAttributeValue],
        updateExpression: String,
        expressionAttributeValues: [String: DynamoDBAttributeValue]
    ) async throws
    func getItem(
        tableName: String,
        key: [String: DynamoDBAttributeValue]
    ) async throws -> [String: DynamoDBAttributeValue]?
    func query(
        tableName: String,
        keyConditionExpression: String,
        expressionAttributeValues: [String: DynamoDBAttributeValue],
        scanIndexForward: Bool,
        limit: Int?
    ) async throws -> [[String: DynamoDBAttributeValue]]
}

protocol CredentialExchangeServiceProtocol {
    func getCurrentCredentials() async throws -> AWSCredentials
    func refreshCredentials() async throws -> AWSCredentials
}
