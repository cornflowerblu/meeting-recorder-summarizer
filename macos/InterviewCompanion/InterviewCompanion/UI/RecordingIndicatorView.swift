import SwiftUI
import AppKit
import Combine

/// Persistent floating indicator that displays recording status
///
/// Features:
/// - Always-on-top window using NSPanel
/// - Pulsing red dot animation
/// - Live elapsed time display (MM:SS format)
/// - Draggable by user
/// - Position persisted across sessions
/// - Cannot be closed during recording
///
/// ## Implementation Details
///
/// Uses NSPanel with `.floating` window level to ensure visibility above all other windows.
/// SwiftUI view is wrapped in NSHostingView and added to panel's content view.
///
/// ## Position Persistence
///
/// Window position is saved to UserDefaults on drag and restored on next launch.
@MainActor
class RecordingIndicatorWindow: NSPanel {
    private static let defaultPosition = CGPoint(x: 100, y: 100)
    private static let indicatorSize = CGSize(width: 120, height: 36)

    init(viewModel: RecordingIndicatorViewModel) {
        // Load saved position or use default
        let position = Self.loadSavedPosition()

        super.init(
            contentRect: NSRect(origin: position, size: Self.indicatorSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Configure window behavior
        self.level = .floating  // Always on top
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true

        // Prevent closing during recording
        self.styleMask.remove(.closable)

        // Set accessibility identifier for UI testing
        self.identifier = NSUserInterfaceItemIdentifier("Recording Indicator")

        // Create SwiftUI view
        let indicatorView = RecordingIndicatorView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: indicatorView)
        hostingView.frame = self.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]

        self.contentView = hostingView

        // Observe position changes to save
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    @objc private func windowDidMove() {
        Self.savePosition(frame.origin)
    }

    // MARK: - Position Persistence

    private static func loadSavedPosition() -> CGPoint {
        guard let savedX = UserDefaults.standard.object(forKey: "indicatorPositionX") as? Double,
              let savedY = UserDefaults.standard.object(forKey: "indicatorPositionY") as? Double else {
            return defaultPosition
        }
        return CGPoint(x: savedX, y: savedY)
    }

    private static func savePosition(_ position: CGPoint) {
        UserDefaults.standard.set(position.x, forKey: "indicatorPositionX")
        UserDefaults.standard.set(position.y, forKey: "indicatorPositionY")
    }
}

// MARK: - View Model

@MainActor
class RecordingIndicatorViewModel: ObservableObject {
    @Published var elapsedTime: TimeInterval = 0
    @Published var isRecording: Bool = false

    private var timer: Timer?

    func startRecording() {
        isRecording = true
        elapsedTime = 0

        // Update elapsed time every second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.elapsedTime += 1
            }
        }

        Logger.recording.info(
            "Recording indicator started",
            file: #file,
            function: #function,
            line: #line
        )
    }

    func stopRecording() {
        isRecording = false
        timer?.invalidate()
        timer = nil

        Logger.recording.info(
            "Recording indicator stopped (duration: \(String(format: "%.0f", elapsedTime))s)",
            file: #file,
            function: #function,
            line: #line
        )
    }

    // Note: Timer is invalidated in stopRecording()
    // The view model should always have stopRecording() called before deallocation
}

// MARK: - SwiftUI View

struct RecordingIndicatorView: View {
    @ObservedObject var viewModel: RecordingIndicatorViewModel
    @State private var dotOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing red recording dot
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(dotOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        dotOpacity = 0.3
                    }
                }
                .accessibilityIdentifier("Recording Dot")

            // Elapsed time
            Text(formattedTime)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private var formattedTime: String {
        let minutes = Int(viewModel.elapsedTime) / 60
        let seconds = Int(viewModel.elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Window Controller

/// Controller for managing the recording indicator window lifecycle
@MainActor
class RecordingIndicatorController {
    private var window: RecordingIndicatorWindow?
    private var viewModel: RecordingIndicatorViewModel?

    /// Shows the recording indicator window
    func show() {
        guard window == nil else {
            Logger.recording.warning(
                "Recording indicator already visible",
                file: #file,
                function: #function,
                line: #line
            )
            return
        }

        let vm = RecordingIndicatorViewModel()
        vm.startRecording()

        let indicatorWindow = RecordingIndicatorWindow(viewModel: vm)
        indicatorWindow.orderFront(nil)

        self.window = indicatorWindow
        self.viewModel = vm

        Logger.recording.info(
            "Recording indicator window shown",
            file: #file,
            function: #function,
            line: #line
        )
    }

    /// Hides the recording indicator window
    func hide() {
        viewModel?.stopRecording()
        window?.close()
        window = nil
        viewModel = nil

        Logger.recording.info(
            "Recording indicator window hidden",
            file: #file,
            function: #function,
            line: #line
        )
    }

    /// Returns true if indicator is currently visible
    var isVisible: Bool {
        window != nil
    }
}

// MARK: - Preview

#Preview {
    RecordingIndicatorView(viewModel: RecordingIndicatorViewModel())
        .frame(width: 120, height: 36)
        .onAppear {
            let vm = RecordingIndicatorViewModel()
            vm.startRecording()
        }
}
