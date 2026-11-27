import Foundation
import WebKit

/// Serves the bundled NexusAI web app (NexusAI/WebApp in the app bundle)
/// under the fixed origin app://localhost, so the page runs fully offline
/// with a stable origin for localStorage, while model APIs are still
/// called directly over the network by the page itself.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "app"
    static let host = "localhost"

    static var startURL: URL {
        URL(string: "\(scheme)://\(host)/index.html")!
    }

    private let fileManager = FileManager.default

    private lazy var webRoot: URL? = {
        Bundle.main.url(forResource: "WebApp", withExtension: nil)
    }()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        var path = requestURL.path
        if path.isEmpty || path == "/" { path = "/index.html" }

        guard let root = webRoot else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // Resolve inside the bundle root and refuse anything escaping it.
        let fileURL = root.appendingPathComponent(String(path.dropFirst()))
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/"),
              fileManager.fileExists(atPath: filePath) else {
            let notFound = HTTPURLResponse(url: requestURL, statusCode: 404,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(notFound)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let headers = ["Content-Type": Self.mimeType(for: fileURL.pathExtension),
                           "Content-Length": "\(data.count)"]
            let response = HTTPURLResponse(url: requestURL, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous in-memory serving; nothing to cancel.
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        default: return "application/octet-stream"
        }
    }
}
