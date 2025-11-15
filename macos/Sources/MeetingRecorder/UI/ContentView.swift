import SwiftUI

struct ContentView: View {
  var body: some View {
    VStack(spacing: 20) {
      Text("Meeting Recorder")
        .font(.largeTitle)
        .fontWeight(.bold)

      Text("Screen recording with AI intelligence")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Button("Start Recording") {
        // Recording start implementation pending
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
  }
}

#Preview {
  ContentView()
}
