import SwiftUI

@main
struct NexusAIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadToken = 0

    var body: some View {
        ZStack {
            Color(red: 0.949, green: 0.949, blue: 0.969)
                .ignoresSafeArea()

            WebView(isLoading: $isLoading, loadError: $loadError, reloadToken: reloadToken)
                .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color(red: 0.0, green: 0.443, blue: 0.890))
                    .scaleEffect(1.5)
            }

            if let message = loadError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("载入失败")
                        .font(.headline)
                        .foregroundColor(Color(red: 0.114, green: 0.114, blue: 0.122))
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("重新载入") {
                        loadError = nil
                        reloadToken += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .preferredColorScheme(.light)
    }
}
