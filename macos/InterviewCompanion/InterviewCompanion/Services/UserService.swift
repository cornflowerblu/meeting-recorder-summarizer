import Foundation
import AWSDynamoDB
import AWSClientRuntime
import FirebaseAuth

/// Service for managing user profiles in DynamoDB
///
/// Stores and updates user authentication and profile information:
/// - Firebase User ID (primary key)
/// - Email address
/// - Display name
/// - Photo URL
/// - Authentication provider
/// - Created and last login timestamps
@MainActor
final class UserService {
    private let dynamoDBClient: DynamoDBClient
    private let userId: String

    init(dynamoDBClient: DynamoDBClient, userId: String) {
        self.dynamoDBClient = dynamoDBClient
        self.userId = userId
    }

    // MARK: - User Profile Management

    /// Create or update user profile on sign-in
    /// Updates lastLoginDate and creates the user if they don't exist
    func recordUserSignIn(firebaseUser: User) async throws {
        let tableName = AWSConfig.dynamoDBUsersTableName
        let now = ISO8601DateFormatter().string(from: Date())

        // Get existing user to preserve createdAt if they exist
        let existingUser = try? await getUser()
        let createdAt = existingUser?["createdAt"]?.s ?? now

        var item: [String: DynamoDBClientTypes.AttributeValue] = [
            "userId": .s(firebaseUser.uid),
            "email": .s(firebaseUser.email ?? ""),
            "lastLoginDate": .s(now),
            "createdAt": .s(createdAt)
        ]

        // Add optional fields if available
        if let displayName = firebaseUser.displayName {
            item["displayName"] = .s(displayName)
        }

        if let photoURL = firebaseUser.photoURL?.absoluteString {
            item["photoURL"] = .s(photoURL)
        }

        // Get provider info (Google, Apple, etc.)
        if let providerId = firebaseUser.providerData.first?.providerID {
            item["provider"] = .s(providerId)
        }

        let input = PutItemInput(
            item: item,
            tableName: tableName
        )

        _ = try await dynamoDBClient.putItem(input: input)

        Logger.app.info(
            "User profile updated: \(firebaseUser.uid) (\(firebaseUser.email ?? "no email"))",
            file: #file,
            function: #function,
            line: #line
        )
    }

    /// Get user profile from DynamoDB
    func getUser() async throws -> [String: DynamoDBClientTypes.AttributeValue]? {
        let tableName = AWSConfig.dynamoDBUsersTableName

        let input = GetItemInput(
            key: ["userId": .s(userId)],
            tableName: tableName
        )

        let output = try await dynamoDBClient.getItem(input: input)
        return output.item
    }

    /// Update user's last login date
    func updateLastLogin() async throws {
        let tableName = AWSConfig.dynamoDBUsersTableName
        let now = ISO8601DateFormatter().string(from: Date())

        let input = UpdateItemInput(
            key: ["userId": .s(userId)],
            tableName: tableName,
            updateExpression: "SET lastLoginDate = :now",
            expressionAttributeValues: [
                ":now": .s(now)
            ]
        )

        _ = try await dynamoDBClient.updateItem(input: input)

        Logger.app.debug(
            "Updated last login for user: \(userId)",
            file: #file,
            function: #function,
            line: #line
        )
    }
}

// MARK: - User Profile Model

/// User profile data model matching DynamoDB schema
struct UserProfile: Codable {
    let userId: String
    let email: String
    let displayName: String?
    let photoURL: String?
    let provider: String?
    let createdAt: String
    let lastLoginDate: String

    /// Initialize from DynamoDB item
    init?(dynamoDBItem: [String: DynamoDBClientTypes.AttributeValue]) {
        guard let userId = dynamoDBItem["userId"]?.s,
              let email = dynamoDBItem["email"]?.s,
              let createdAt = dynamoDBItem["createdAt"]?.s,
              let lastLoginDate = dynamoDBItem["lastLoginDate"]?.s else {
            return nil
        }

        self.userId = userId
        self.email = email
        self.displayName = dynamoDBItem["displayName"]?.s
        self.photoURL = dynamoDBItem["photoURL"]?.s
        self.provider = dynamoDBItem["provider"]?.s
        self.createdAt = createdAt
        self.lastLoginDate = lastLoginDate
    }
}
