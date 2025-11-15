//
//  CatalogListView.swift
//  MeetingRecorder
//
//  Catalog list showing recording sessions with status
//

import SwiftUI

@MainActor
struct CatalogListView: View {

    // MARK: - State

    @State private var sessions: [RecordingSession] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let catalogService: CatalogService
    private let userId: String

    // MARK: - Initialization

    init(catalogService: CatalogService, userId: String) {
        self.catalogService = catalogService
        self.userId = userId
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Session List
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if sessions.isEmpty {
                emptyView
            } else {
                sessionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadSessions()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Text("Recording Sessions")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Button {
                Task {
                    await loadSessions()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("Refresh sessions")
        }
        .padding()
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Loading sessions...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Error Loading Sessions")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Retry") {
                Task {
                    await loadSessions()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No Recordings Yet")
                .font(.headline)

            Text("Start a new recording to see it appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(sessions, id: \.recordingId) { session in
                    SessionRow(session: session)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))

                    Divider()
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadSessions() async {
        isLoading = true
        errorMessage = nil

        do {
            sessions = try await catalogService.listUserSessions(userId: userId, limit: 50)

            await Logger.shared.debug("Loaded sessions", metadata: [
                "count": String(sessions.count)
            ])
        } catch {
            await Logger.shared.error("Failed to load sessions", metadata: [
                "error": error.localizedDescription
            ])

            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: RecordingSession

    var body: some View {
        HStack(spacing: 16) {
            // Status Indicator
            statusIndicator

            // Session Info
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(formattedDate, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if session.duration > 0 {
                        Label(formattedDuration, systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !session.participants.isEmpty {
                        Label("\(session.participants.count) participants", systemImage: "person.2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Status Badge
            statusBadge
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 12, height: 12)
    }

    private var statusBadge: some View {
        Text(session.status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch session.status {
        case .pending:
            return .orange
        case .recording:
            return .red
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .gray
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: session.startTime)
    }

    private var formattedDuration: String {
        let totalSeconds = Int(session.duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

// MARK: - Preview

#Preview {
    let catalogService = CatalogService(tableName: "test-table")

    return CatalogListView(
        catalogService: catalogService,
        userId: "user_test_123"
    )
    .frame(width: 800, height: 600)
}
