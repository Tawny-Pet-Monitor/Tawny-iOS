import UIKit
import WebKit

/// The live session's engine: the shared web app (WebRTC, Nostr, the
/// rendezvous) running in a WKWebView, the same code the Android app runs.
///
/// What the shell adds is what a web view cannot do alone: grant camera and
/// microphone to the bundled page only, keep every other origin out, hand
/// ordinary links to Safari, and turn the page's snapshot downloads into a
/// share sheet.
@MainActor
final class WebEngine: NSObject {
    let webView: WKWebView

    /// Events the page posts with `webkit.messageHandlers.tawny.postMessage`.
    var onEvent: ((String, [String: Any]) -> Void)?
    /// A snapshot or clip the page saved, ready to share.
    var onFile: ((URL) -> Void)?

    private var port = 0
    private var startScript = ""
    private var started = false
    private var downloads: [ObjectIdentifier: URL] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()   // channel keys live in the page's localStorage
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        config.userContentController.add(WeakScriptHandler(self), name: "tawny")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // The page lays itself out under the bars with env(safe-area-inset-*).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.delegate = self
        webView.allowsLinkPreview = false
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func load(port: Int, startScript: String) {
        self.port = port
        self.startScript = startScript
        started = false
        guard let url = URL(string: "http://127.0.0.1:\(port)/#native") else { return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    /// Run a line of the page's own API (`window.tawnyPairCode(…)` and friends).
    func run(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Release the camera and microphone and stop everything, at once.
    func shutDown() {
        webView.setCameraCaptureState(.none, completionHandler: nil)
        webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tawny")
        webView.loadHTMLString("", baseURL: nil)
    }

    private func isOurs(_ origin: WKSecurityOrigin) -> Bool {
        origin.protocol == "http" && origin.host == "127.0.0.1" && origin.port == port
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, isOurs(message.frameInfo.securityOrigin),
              let body = message.body as? [String: Any],
              let event = body["event"] as? String
        else { return }
        onEvent?(event, body)
    }
}

// MARK: - navigation

extension WebEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url else { return .cancel }
        if url.scheme == "http" && url.host == "127.0.0.1" && url.port == port { return .allow }
        if url.scheme == "about" { return .allow }
        // Ordinary web links leave for Safari; any other scheme is refused, so
        // the page cannot open arbitrary apps.
        if url.scheme == "https" || url.scheme == "http" {
            _ = await UIApplication.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !started, webView.url?.host == "127.0.0.1" else { return }
        started = true
        run(startScript)
        onEvent?("shell-started", [:])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onEvent?("shell-load-failed", ["message": error.localizedDescription])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onEvent?("shell-crashed", [:])
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - camera and microphone

extension WebEngine: WKUIDelegate {
    /// Granted to the bundled page alone. iOS still asks the person the first
    /// time, with the usage strings in Info.plist.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        frame.isMainFrame && isOurs(origin) ? .grant : .deny
    }

    /// The page never opens windows; a stray target=_blank goes to Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme == "https" {
            UIApplication.shared.open(url)
        }
        return nil
    }
}

// MARK: - snapshots and clips

extension WebEngine: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (suggestedFilename as NSString).lastPathComponent
        let url = dir.appendingPathComponent(name.isEmpty ? "tawny-snapshot.png" : name)
        try? FileManager.default.removeItem(at: url)
        downloads[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloads.removeValue(forKey: ObjectIdentifier(download)) { onFile?(url) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        Diag.shared.log("shell", "capture save failed: \(error.localizedDescription)")
    }
}

// MARK: - no page zoom

extension WebEngine: UIScrollViewDelegate {
    /// The page has its own pinch-to-zoom on the video; the web view's page
    /// zoom would fight it.
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }
}

/// WKUserContentController holds its handlers strongly; this breaks the loop.
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var engine: WebEngine?
    init(_ engine: WebEngine) { self.engine = engine }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        engine?.received(message)
    }
}
