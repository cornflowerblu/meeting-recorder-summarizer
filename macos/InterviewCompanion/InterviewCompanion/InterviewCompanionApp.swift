import SwiftUI
import AWSS3
import AWSDynamoDB
import AWSSDKIdentity
import SmithyIdentity
import FirebaseCore
import GoogleSignIn
import FirebaseAuth
import AppKit

@main
struct InterviewCompanionApp: App {
    @StateObject private var authService = AuthService()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // UI Testing bypass - use static property so it's evaluated once
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init() {
        // Configure Firebase on app launch
        // In Xcode app projects, resources are in Bundle.main
        configureFirebase()

        if Self.isUITesting {
            print("🧪 UI Testing mode enabled - bypassing authentication")
        }
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
                if Self.isUITesting {
                    // Bypass authentication for UI tests
                    MainView(userId: "ui-test-user", authService: authService)
                } else if authService.isAuthenticated, let userId = authService.userId {
                    MainViewLoader(userId: userId, authService: authService)
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

// MARK: - Main View Loader

/// Loads runtime configuration before showing MainView to avoid blocking the main thread
@MainActor
struct MainViewLoader: View {
    let userId: String
    let authService: AuthService

    @State private var isConfigLoaded = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.red)
                    Text("Configuration Error")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else if isConfigLoaded {
                MainView(userId: userId, authService: authService)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading configuration...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Initialize credentials first
            do {
                guard let credentials = try? authService.getAWSCredentials() else {
                    loadError = "AWS credentials not available. Please sign in again."
                    return
                }

                // Set credentials on RuntimeConfig for SSM access
                RuntimeConfig.shared.setCredentials(credentials)

                // Now prefetch parameters in the background
                await RuntimeConfig.shared.prefetchParameters()

                isConfigLoaded = true
            } catch {
                loadError = "Failed to load configuration: \(error.localizedDescription)"
            }
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

        // Get credentials from AuthService (Firebase token exchange)
        // These are temporary AWS credentials obtained from the auth_exchange Lambda
        // Note: RuntimeConfig.shared.setCredentials() is called by MainViewLoader
        guard let credentials = try? authService.getAWSCredentials() else {
            Logger.app.error(
                "Failed to get AWS credentials from AuthService",
                file: #file,
                function: #function,
                line: #line
            )
            fatalError("AWS credentials not available. Please sign in again.")
        }

        // Create credential resolver for AWS service clients
        let credentialResolver: StaticAWSCredentialIdentityResolver
        do {
            credentialResolver = try AWSConfig.createCredentialResolver(from: credentials)
        } catch {
            Logger.app.error(
                "Failed to create credential resolver: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            fatalError("Failed to initialize AWS credential resolver")
        }

        // Create AWS service clients with credentials from Firebase token exchange
        let s3Client: S3Client
        let dynamoDBClient: DynamoDBClient

        do {
            let s3Config = try S3Client.S3ClientConfiguration(
                awsCredentialIdentityResolver: credentialResolver,
                region: AWSConfig.region
            )
            s3Client = S3Client(config: s3Config)

            let dynamoDBConfig = try DynamoDBClient.DynamoDBClientConfiguration(
                awsCredentialIdentityResolver: credentialResolver,
                region: AWSConfig.region
            )
            dynamoDBClient = DynamoDBClient(config: dynamoDBConfig)
        } catch {
            Logger.app.error(
                "Failed to create AWS clients: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            fatalError("Failed to initialize AWS service clients")
        }

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

// MARK: - App Delegate

/// AppDelegate to handle app activation and window management
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to ensure we're a regular app (not accessory)
        NSApp.setActivationPolicy(.regular)

        // Activate the app and bring it to the front
        NSApp.activate(ignoringOtherApps: true)

        // Give the window a moment to appear, then bring it forward
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApp.windows.first {
                // Set window level to float above normal windows
                window.level = .floating
                window.makeKeyAndOrderFront(nil)

                // Reset to normal level after a moment so it doesn't stay on top forever
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    window.level = .normal
                    window.makeKeyAndOrderFront(nil)
                }
            }

            // Activate again to be sure
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
