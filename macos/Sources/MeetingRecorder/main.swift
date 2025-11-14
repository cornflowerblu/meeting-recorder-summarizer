import SwiftUI
import AWSS3
import AWSDynamoDB

@main
struct MeetingRecorderApp: App {
    // Placeholder for future authentication
    @State private var isAuthenticated: Bool = true  // TODO: Replace with real auth
    @State private var currentUserId: String = "demo-user"  // TODO: Replace with real user ID

    var body: some Scene {
        WindowGroup {
            if isAuthenticated {
                MainView(userId: currentUserId)
            } else {
                LoginPlaceholderView()
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

    @StateObject private var screenRecorder: ScreenRecorder
    @StateObject private var uploadQueue: UploadQueue
    @StateObject private var catalogService: CatalogService

    init(userId: String) {
        self.userId = userId

        // Initialize services
        let captureService = AVFoundationCaptureService()
        let storageService = ChunkWriter()
        let screenRecorder = ScreenRecorder(
            captureService: captureService,
            storageService: storageService
        )

        // Create AWS clients (will use credentials from environment or IAM role)
        // TODO: Replace with STS credentials from Firebase auth exchange
        let s3Client = try! S3Client(region: ProcessInfo.processInfo.environment["AWS_REGION"] ?? "us-east-1")
        let dynamoDBClient = try! DynamoDBClient(region: ProcessInfo.processInfo.environment["AWS_REGION"] ?? "us-east-1")

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
    }
}

// MARK: - Login Placeholder

struct LoginPlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Meeting Recorder")
                .font(.title)
                .fontWeight(.bold)

            Text("Sign in to continue")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("Sign In with Google") {
                // TODO: Implement Firebase Google Sign-In
                print("Sign in tapped")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Firebase authentication coming soon")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 20)
        }
        .frame(width: 400, height: 300)
        .padding()
    }
}

// MARK: - Preview

#Preview {
    MainView(userId: "preview-user")
}
