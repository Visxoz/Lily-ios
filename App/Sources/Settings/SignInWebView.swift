import SwiftUI
import WebKit
import os

/// Google's own sign-in page, as ytm-native's WebView2 window: private, kept
/// to the sign-in chain, with no new windows or downloads. Once it reaches
/// YouTube Music signed in, it hands over the cookies that go there.
struct SignInWebView: UIViewRepresentable {
    /// The cookies sent to YouTube Music, HttpOnly ones included, once a session is among them.
    let onSession: ([HTTPCookie]) -> Void
    /// A sentence for the user when the page can't go on.
    let onFailure: (String) -> Void

    private static let startURL = URL(
        string: "https://accounts.google.com/ServiceLogin?service=youtube&passive=true"
            + "&continue=https%3A%2F%2Fmusic.youtube.com%2F"
    )

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Private mode, as ytm-native's: the page's cookies stay in memory
        // and go with the view, so each attempt starts signed out.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // See-through until Google's page paints, so the spinner behind shows.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        if let url = Self.startURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.openURL = context.environment.openURL
    }

    /// Safari on a Mac. ytm-native's WebView2 reads to Google as desktop Edge,
    /// so Google runs the desktop sign-in, which hands over to YouTube Music
    /// directly; a phone's is routed through YouTube's mobile site. A bare
    /// WKWebView reads as an embedded page, which Google may refuse.
    private static var userAgent: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(os.majorVersion).\(os.minorVersion) Safari/605.1.15"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private static let log = Logger(subsystem: "YTMusic", category: "sign-in")
        /// A signed-in session has one of these.
        private static let sessionCookies: Set<String> = ["SAPISID", "__Secure-3PAPISID"]

        var parent: SignInWebView
        var openURL: OpenURLAction?
        /// Set once the session is handed over, so later pages don't hand it over again.
        private var signedIn = false

        init(_ parent: SignInWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.shouldPerformDownload { return .cancel }
            // Only the page itself is kept to the chain, as WebView2 reports
            // only top-level navigations: frames inside Google's pages load
            // freely, and links for a new window go on to `createWebViewWith`.
            guard let frame = action.targetFrame, frame.isMainFrame, let url = action.request.url else { return .allow }
            guard SignInHosts.allows(url) else {
                leave(for: url)
                return .cancel
            }
            // Signed in by the time Google sends the page to YouTube: hand
            // over without loading it, which also keeps iOS from opening the
            // YouTube Music app for the link.
            if let host = url.host(), SignInHosts.isYouTube(host), await handOver(from: webView) {
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            // What the page can't show would be a download.
            response.canShowMIMEType ? .allow : .cancel
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Sign-in's own pages asked for in a new window stay in this one.
            if let url = action.request.url {
                if SignInHosts.allows(url) {
                    webView.load(action.request)
                } else {
                    leave(for: url)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard let url = webView.url, url.scheme == "https", let host = url.host(), SignInHosts.isYouTube(host) else { return }
            Task { await handOver(from: webView) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
            failed(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.onFailure("Couldn't sign in with Google: the sign-in page stopped.")
        }

        /// Hands over the cookies YouTube Music is sent, as ytm-native's
        /// `cookies_for_url`, once Google has set a session among them, and
        /// says whether it did; until then the page is still signing in.
        @discardableResult
        private func handOver(from webView: WKWebView) async -> Bool {
            guard !signedIn else { return true }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter(Self.goesToMusic)
            guard !signedIn, cookies.contains(where: { Self.sessionCookies.contains($0.name) }) else { return signedIn }
            signedIn = true
            parent.onSession(cookies)
            return true
        }

        /// Network failures end the attempt. Cancellations don't: a new
        /// navigation or a refused response stops the last one on purpose.
        private func failed(_ error: any Error) {
            guard let error = error as? URLError, error.code != .cancelled else { return }
            parent.onFailure("Couldn't sign in with Google: \(error.localizedDescription)")
        }

        /// Opens a link the sign-in page refused in the browser, when it may go there.
        private func leave(for url: URL) {
            Self.log.info("sign-in page: refused \(url.host() ?? "", privacy: .public)\(url.path(), privacy: .private)")
            if SignInHosts.opensInBrowser(url) {
                openURL?(url)
            }
        }

        private static func goesToMusic(_ cookie: HTTPCookie) -> Bool {
            let domain = cookie.domain.trimmingPrefix(".")
            return SignInHosts.musicHost == domain || SignInHosts.musicHost.hasSuffix("." + domain)
        }
    }
}
