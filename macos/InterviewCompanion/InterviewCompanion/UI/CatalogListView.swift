import SwiftUI
import AWSDynamoDB

/// View for displaying list of recorded sessions
///
/// Features:
/// - Displays recordings sorted by date (most recent first)
/// - Shows status badge (pending/uploading/completed/failed)
/// - Displays duration and creation date
/// - Empty state when no recordings
/// - Pull-to-refresh and manual refresh
/// - Error handling with retry
@MainActor
struct CatalogListView: View {
    @ObservedObject var catalogService: CatalogService

    @State private var recordings: [CatalogItem] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                if recordings.isEmpty && !isLoading {
                    emptyState
                } else {
                    recordingsList
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await refresh()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .onAppear {
                Task {
                    await loadRecordings()
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("Retry") {
                    Task {
                        await refresh()
                    }
                }
                Button("Dismiss", role: .cancel) {
                    showError = false
                }
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
        }
    }

    // MARK: - Subviews

    private var recordingsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if isLoading && recordings.isEmpty {
                    ProgressView("Loading recordings...")
                        .padding()
                } else {
                    ForEach(recordings) { recording in
                        CatalogRowView(recording: recording)
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            await refresh()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No recordings yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start recording to see your sessions here")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let error = errorMessage {
                VStack(spacing: 8) {
                    Text("Last error:")
                        .font(.caption)
                        .foregroundColor(.red)

                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Button("Retry") {
                        Task {
                            await refresh()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadRecordings() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            recordings = try await catalogService.listSessions()

            Logger.catalog.info(
                "Loaded \(recordings.count) recordings",
                file: #file,
                function: #function,
                line: #line
            )

        } catch {
            errorMessage = error.localizedDescription
            showError = true

            Logger.catalog.error(
                "Failed to load recordings: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
        }

        isLoading = false
    }

    private func refresh() async {
        await loadRecordings()
    }
}

// MARK: - Catalog Row View

struct CatalogRowView: View {
    let recording: CatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Status Badge
                statusBadge
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.2))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)

                Spacer()

                // Date
                Text(formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Title or default
            Text(recording.title ?? "Recording \(recording.recordingId.prefix(8))")
                .font(.headline)

            // Duration
            HStack(spacing: 16) {
                Label(formattedDuration, systemImage: "clock")
                    .font(.callout)
                    .foregroundColor(.secondary)

                if let participants = recording.participants, !participants.isEmpty {
                    Label("\(participants.count) participants", systemImage: "person.2")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            // Tags
            if let tags = recording.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Computed Properties

    private var statusBadge: some View {
        Text(recording.status.rawValue.capitalized)
    }

    private var statusColor: Color {
        switch recording.status {
        case .pending:
            return .gray
        case .uploading:
            return .blue
        case .processing:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: recording.createdAt)
    }

    private var formattedDuration: String {
        let duration = recording.duration
        if duration == 0 {
            return "0:00"
        }

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60

        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return String(format: "%d:%02d:%02d", hours, remainingMinutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Preview

#Preview("With Recordings") {
    CatalogListView(
        catalogService: PreviewCatalogService(recordings: [
            CatalogItem(
                recordingId: "rec-001",
                userId: "user-123",
                createdAt: Date().addingTimeInterval(-3600),
                durationMs: 180000,
                status: .completed,
                s3Paths: S3Paths(chunksPrefix: "test/"),
                title: "Team Standup",
                participants: ["alice@example.com", "bob@example.com"],
                tags: ["standup", "team-alpha"]
            ),
            CatalogItem(
                recordingId: "rec-002",
                userId: "user-123",
                createdAt: Date().addingTimeInterval(-7200),
                durationMs: 3600000,
                status: .uploading,
                s3Paths: S3Paths(chunksPrefix: "test/"),
                title: "Product Review",
                participants: ["charlie@example.com"],
                tags: ["review"]
            ),
            CatalogItem(
                recordingId: "rec-003",
                userId: "user-123",
                createdAt: Date().addingTimeInterval(-86400),
                durationMs: 0,
                status: .failed,
                s3Paths: S3Paths(chunksPrefix: "test/"),
                title: nil,
                participants: nil,
                tags: nil
            )
        ])
    )
}

#Preview("Empty State") {
    CatalogListView(
        catalogService: PreviewCatalogService(recordings: [])
    )
}

// MARK: - Preview Helper

// Simple function to create a mock service for previews
private func PreviewCatalogService(recordings: [CatalogItem]) -> CatalogService {
    let mock = MockDynamoDBForPreview(recordings: recordings)
    return CatalogService(
        dynamoDBClient: mock,
        userId: "preview-user"
    )
}

private final class MockDynamoDBForPreview: DynamoDBClientProtocol, @unchecked Sendable {
    let mockRecordings: [CatalogItem]

    init(recordings: [CatalogItem]) {
        self.mockRecordings = recordings
    }

    func putItem(input: AWSDynamoDB.PutItemInput) async throws -> AWSDynamoDB.PutItemOutput {
        AWSDynamoDB.PutItemOutput()
    }

    func updateItem(input: AWSDynamoDB.UpdateItemInput) async throws -> AWSDynamoDB.UpdateItemOutput {
        AWSDynamoDB.UpdateItemOutput()
    }

    func query(input: AWSDynamoDB.QueryInput) async throws -> AWSDynamoDB.QueryOutput {
        // Convert mock recordings to DynamoDB format
        let items = mockRecordings.map { recording -> [String: AWSDynamoDB.DynamoDBClientTypes.AttributeValue] in
            [
                "pk": .s("\(recording.userId)#\(recording.recordingId)"),
                "sk": .s("METADATA"),
                "recording_id": .s(recording.recordingId),
                "user_id": .s(recording.userId),
                "created_at": .s(ISO8601DateFormatter().string(from: recording.createdAt)),
                "status": .s(recording.status.rawValue),
                "duration_ms": .n(String(recording.durationMs)),
                "s3_paths": .m([
                    "chunks_prefix": .s(recording.s3Paths.chunksPrefix)
                ])
            ]
        }

        return AWSDynamoDB.QueryOutput(items: items)
    }
}
