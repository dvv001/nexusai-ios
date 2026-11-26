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

    private let homeURL = URL(string: "https://dvv001.github.io/hghub1/nexus/")!

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08)
                .ignoresSafeArea()

            WebView(url: homeURL, isLoading: $isLoading, loadError: $loadError, reloadToken: reloadToken)
                .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.5)
            }

            if let message = loadError {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("载入失败")
                        .font(.headline)
                        .foregroundColor(.white)
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
        .preferredColorScheme(.dark)
    }
}
