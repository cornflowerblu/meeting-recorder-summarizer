import SwiftUI
import AWSS3
import AWSDynamoDB
import FirebaseCore

@main
struct MeetingRecorderApp: App {
    @StateObject private var authService = AuthService()

    init() {
        // Configure Firebase on app launch
        // Requires GoogleService-Info.plist in Resources directory
        // See: macos/Sources/MeetingRecorder/Resources/README.md
        do {
            FirebaseApp.configure()
            Logger.app.info(
                "Firebase configured successfully",
                file: #file,
                function: #function,
                line: #line
            )
        } catch {
            Logger.app.error(
                "Firebase configuration failed. Did you add GoogleService-Info.plist? See Resources/README.md for setup instructions.",
                error: error,
                file: #file,
                function: #function,
                line: #line
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            if authService.isAuthenticated, let userId = authService.userId {
                MainView(userId: userId, authService: authService)
            } else {
                SignInView(authService: authService)
            }
        }
        .windowResizability(.contentSize)
        .commands {
            // TODO: Add menu commands (Preferences, About, etc.)
        }
    }
}

// MARK: - Main View

@MainActor
struct MainView: View {
    let userId: String
    @ObservedObject var authService: AuthService

    @StateObject private var screenRecorder: ScreenRecorder
    @StateObject private var uploadQueue: UploadQueue
    @StateObject private var catalogService: CatalogService

    init(userId: String, authService: AuthService) {
        self.userId = userId
        self.authService = authService

        // Initialize services
        let captureService = AVFoundationCaptureService()
        let storageService = ChunkWriter()
        let screenRecorder = ScreenRecorder(
            captureService: captureService,
            storageService: storageService
        )

        // TODO: Implement STS credential provider after Lambda deployment
        // For now, AWS SDK will use credentials from:
        // 1. Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN)
        // 2. AWS credentials file (~/.aws/credentials)
        // 3. IAM role (if running on EC2/ECS)
        //
        // After Lambda deployment, we need to:
        // 1. Get credentials from AuthService.getAWSCredentials()
        // 2. Set them as environment variables before AWS client initialization
        // 3. Refresh environment variables before credential expiry
        //
        // AWS SDK for Swift doesn't have a public CredentialsProvider protocol,
        // so we'll need to use environment variables or implement a custom solution

        // Create AWS clients using default credential provider chain
        let s3Client = try! S3Client(region: AWSConfig.region)
        let dynamoDBClient = try! DynamoDBClient(region: AWSConfig.region)

        let uploader = S3Uploader(s3Client: s3Client)
        let uploadQueue = UploadQueue(
            uploader: uploader,
            userId: userId,
            recordingId: "temp-rec-\(UUID().uuidString)"  // TODO: Set properly when recording starts
        )

        let catalogService = CatalogService(
            dynamoDBClient: dynamoDBClient,
            userId: userId
        )

        _screenRecorder = StateObject(wrappedValue: screenRecorder)
        _uploadQueue = StateObject(wrappedValue: uploadQueue)
        _catalogService = StateObject(wrappedValue: catalogService)

        Logger.app.info(
            "AWS clients initialized for user: \(userId)",
            file: #file,
            function: #function,
            line: #line
        )
    }

    var body: some View {
        TabView {
            RecordControlView(
                recorder: screenRecorder,
                uploadQueue: uploadQueue
            )
            .tabItem {
                Label("Record", systemImage: "record.circle")
            }

            CatalogListView(catalogService: catalogService)
                .tabItem {
                    Label("Recordings", systemImage: "list.bullet")
                }
        }
        .frame(minWidth: 600, minHeight: 700)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Text("Signed in as: \(authService.currentUser?.email ?? userId)")
                    Divider()
                    Button("Sign Out") {
                        do {
                            try authService.signOut()
                        } catch {
                            Logger.app.error(
                                "Sign out failed: \(error.localizedDescription)",
                                file: #file,
                                function: #function,
                                line: #line
                            )
                        }
                    }
                } label: {
                    Image(systemName: "person.circle")
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Main View") {
    MainView(userId: "preview-user", authService: AuthService())
}

#Preview("Sign In") {
    SignInView(authService: AuthService())
}
