import SwiftUI
import AWSS3
import AWSDynamoDB
import FirebaseCore
import GoogleSignIn
import FirebaseAuth

@main
struct InterviewCompanionApp: App {
    @StateObject private var authService = AuthService()

    init() {
        // Configure Firebase on app launch
        // In Xcode app projects, resources are in Bundle.main
        configureFirebase()
    }

    private func configureFirebase() {
        // Try to load GoogleService-Info.plist from Bundle.main
        guard let plistURL = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") else {
            Logger.app.error(
                "GoogleService-Info.plist not found in Resources directory. See Resources/README.md for setup instructions.",
                file: #file,
                function: #function,
                line: #line
            )
            return
        }

        guard let plistData = try? Data(contentsOf: plistURL),
              let plistDict = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            Logger.app.error(
                "Failed to read GoogleService-Info.plist",
                file: #file,
                function: #function,
                line: #line
            )
            return
        }

        // Extract required Firebase configuration values
        guard let apiKey = plistDict["API_KEY"] as? String,
              let gcmSenderID = plistDict["GCM_SENDER_ID"] as? String,
              let googleAppID = plistDict["GOOGLE_APP_ID"] as? String,
              let projectID = plistDict["PROJECT_ID"] as? String else {
            Logger.app.error(
                "GoogleService-Info.plist is missing required keys",
                file: #file,
                function: #function,
                line: #line
            )
            return
        }

        // Create FirebaseOptions manually
        let options = FirebaseOptions(googleAppID: googleAppID, gcmSenderID: gcmSenderID)
        options.apiKey = apiKey
        options.projectID = projectID

        // Optional fields
        if let bundleID = plistDict["BUNDLE_ID"] as? String {
            options.bundleID = bundleID
        }
        if let clientID = plistDict["CLIENT_ID"] as? String {
            options.clientID = clientID
        }
        if let databaseURL = plistDict["DATABASE_URL"] as? String {
            options.databaseURL = databaseURL
        }
        if let storageBucket = plistDict["STORAGE_BUCKET"] as? String {
            options.storageBucket = storageBucket
        }

        // Configure Firebase with our custom options
        FirebaseApp.configure(options: options)

        Logger.app.info(
            "Firebase configured successfully for project: \(projectID)",
            file: #file,
            function: #function,
            line: #line
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authService.isAuthenticated, let userId = authService.userId {
                    MainView(userId: userId, authService: authService)
                } else {
                    SignInView(authService: authService)
                }
            }
            .onOpenURL { url in
                // Handle Google Sign-In OAuth redirect
                GIDSignIn.sharedInstance.handle(url)

                Logger.app.info(
                    "Received OAuth redirect URL: \(url.absoluteString)",
                    file: #file,
                    function: #function,
                    line: #line
                )
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
