import SwiftUI
import WebKit

/// Full-screen WKWebView shell for the NexusAI web app.
/// - The web app ships inside the bundle (WebApp/) and is served locally
///   via BundleSchemeHandler at app://localhost: no web hosting needed.
/// - Persistent data store: localStorage (squads, API key) survives relaunches.
/// - Blob downloads (config export) are bridged to native and offered via share sheet.
/// - Non-displayable navigation responses become WKDownloads, also share-sheeted.
/// - JS alert/confirm/prompt panels are presented natively.
struct WebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    var reloadToken: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, loadError: $loadError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.userContentController.add(context.coordinator, name: "blobDownload")
        let script = WKUserScript(source: Coordinator.blobBridgeJS,
                                  injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: false)
        config.userContentController.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        context.coordinator.webView = webView
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: BundleSchemeHandler.startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
        @Binding var isLoading: Bool
        @Binding var loadError: String?
        weak var webView: WKWebView?
        var lastReloadToken = 0
        private var pendingDownloadURL: URL?

        init(isLoading: Binding<Bool>, loadError: Binding<String?>) {
            _isLoading = isLoading
            _loadError = loadError
        }

        static let blobBridgeJS = """
        (function () {
          document.addEventListener('click', function (e) {
            var t = e.target;
            var a = t && t.closest ? t.closest('a[download]') : null;
            if (!a) return;
            var href = a.getAttribute('href') || '';
            if (href.indexOf('blob:') !== 0) return;
            e.preventDefault();
            fetch(href).then(function (r) { return r.blob(); }).then(function (b) {
              var reader = new FileReader();
              reader.onload = function () {
                var result = reader.result || '';
                var comma = result.indexOf(',');
                var base64 = comma >= 0 ? result.substring(comma + 1) : '';
                window.webkit.messageHandlers.blobDownload.postMessage({
                  filename: a.getAttribute('download') || 'download.json',
                  base64: base64,
                  mime: b.type || ''
                });
              };
              reader.readAsDataURL(b);
            }).catch(function () {});
          }, true);
        })();
        """

        // MARK: - Loading state

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            loadError = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            loadError = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            loadError = error.localizedDescription
        }

        // MARK: - Navigation policy

        /// target=_blank links load in the same web view instead of vanishing.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame == nil, let target = navigationAction.request.url {
                webView.load(URLRequest(url: target))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        // MARK: - WKDownloadDelegate

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let dest = Self.uniqueFileURL(for: suggestedFilename)
            pendingDownloadURL = dest
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            if let url = pendingDownloadURL {
                presentShareSheet(for: url)
            }
            pendingDownloadURL = nil
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            pendingDownloadURL = nil
        }

        // MARK: - Blob download bridge

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "blobDownload",
                  let body = message.body as? [String: Any],
                  let filename = body["filename"] as? String,
                  let base64 = body["base64"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            let dest = Self.uniqueFileURL(for: filename)
            do {
                try data.write(to: dest)
                presentShareSheet(for: dest)
            } catch {
                // Saving failed; nothing sensible to surface in the shell.
            }
        }

        // MARK: - JS panels (WKUIDelegate)

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            present(alert)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
            present(alert)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { field in field.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            present(alert)
        }

        // MARK: - Helpers

        private func present(_ alert: UIAlertController) {
            DispatchQueue.main.async {
                guard let top = Self.topViewController() else { return }
                top.present(alert, animated: true)
            }
        }

        private func presentShareSheet(for fileURL: URL) {
            DispatchQueue.main.async {
                guard let top = Self.topViewController() else { return }
                let vc = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                if let pop = vc.popoverPresentationController {
                    pop.sourceView = top.view
                    pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                }
                top.present(vc, animated: true)
            }
        }

        private static func topViewController() -> UIViewController? {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            return top
        }

        private static func uniqueFileURL(for filename: String) -> URL {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var dest = dir.appendingPathComponent(filename)
            var counter = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                let name = (filename as NSString).deletingPathExtension
                let ext = (filename as NSString).pathExtension
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(name)-\(counter)" : "\(name)-\(counter).\(ext)")
                counter += 1
            }
            return dest
        }
    }
}
