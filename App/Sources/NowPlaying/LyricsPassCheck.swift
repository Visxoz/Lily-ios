import UIKit
import WebKit
import YTMCore

/// Better Lyrics' Cloudflare check, which passes only a real browser in a window: run in a web view on the screen
/// but all but transparent, about once a day. It passes by itself or fails; one wanting a tap isn't shown.
@MainActor
final class LyricsPassCheck: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static func run() async -> LyricsHub.Check {
        let proxies = await Proxy.loadConfigurations()
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?.keyWindow
        else { return .skipped }
        if let token = await LyricsPassCheck().run(in: window, proxies: proxies) { return .passed(token: token) }
        // Left part way through, the page stalls, which is no failure of the check.
        return UIApplication.shared.applicationState == .active ? .failed : .skipped
    }

    private static let page = URL(string: "https://\(LyricsHub.host)/challenge")
    private static let handler = "lily"
    /// Time for the widget to retry an error of its own once or twice.
    private static let limit = Duration.seconds(20)

    private var answer: CheckedContinuation<String?, Never>?

    private func run(in window: UIWindow, proxies: [ProxyConfiguration]) async -> String? {
        guard let page = Self.page else { return nil }
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = proxies
        configuration.websiteDataStore = store
        // The page posts its answer to its parent, which for a page alone is itself.
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
                addEventListener('message', e => {
                  if (typeof e.data?.type === 'string' && e.data.type.startsWith('turnstile-')) webkit.messageHandlers.\(Self.handler).postMessage(e.data)
                })
                """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController.add(self, name: Self.handler)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 65), configuration: configuration)
        view.navigationDelegate = self
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.addSubview(view)
        view.load(URLRequest(url: page))
        let timeout = Task {
            try? await Task.sleep(for: Self.limit)
            finish(nil)
        }
        let token = await withCheckedContinuation { answer = $0 }
        timeout.cancel()
        view.stopLoading()
        view.removeFromSuperview()
        // The controller holds its handler, which would otherwise keep this alive.
        configuration.userContentController.removeScriptMessageHandler(forName: Self.handler)
        return token
    }

    private func finish(_ token: String?) {
        answer?.resume(returning: token)
        answer = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        // The widget renews an expired token and retries an error itself; the time limit ends one that keeps failing.
        switch type {
        case "turnstile-token": finish(body["token"] as? String)
        case "turnstile-timeout": finish(nil)
        default: return
        }
    }

    /// The hub's page only, with Cloudflare's frames inside it, and nothing downloaded.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !action.shouldPerformDownload else { return .cancel }
        if action.targetFrame?.isMainFrame ?? true { return action.request.url?.host() == LyricsHub.host ? .allow : .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        finish(nil)
    }
}
