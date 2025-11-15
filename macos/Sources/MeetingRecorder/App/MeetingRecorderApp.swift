import FirebaseCore
import SwiftUI

@main
struct MeetingRecorderApp: App {

  init() {
    // Initialize Firebase
    FirebaseApp.configure()
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .frame(minWidth: 800, minHeight: 600)
    }
    .windowResizability(.contentSize)
  }
}
