import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Meeting Recorder")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Private screen recording with AI intelligence")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Coming soon...")
                .font(.caption)
                .padding(.top, 20)
        }
        .frame(width: 400, height: 300)
        .padding()
    }
}

#Preview {
    ContentView()
}
