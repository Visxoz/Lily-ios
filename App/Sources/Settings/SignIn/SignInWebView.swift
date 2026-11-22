import Network
import SwiftUI
import WebKit
import YTMCore
import os

private let log = Logger(subsystem: "Lily", category: "sign-in")

/// A site's sign-in page: private, kept to the sign-in chain, with no new
/// windows or downloads.
struct SignInWebView<Session>: UIViewRepresentable {
    let site: SignInSite<Session>
    let onSession: (Session) -> Void
    /// A sentence for the user when the page can't go on.
    let onFailure: (String) -> Void
    /// The user's own proxy, which the page would otherwise go around for iOS's.
    let proxies: [ProxyConfiguration]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The page's cookies stay in memory and go with the view, so each
        // attempt starts signed out.
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = proxies
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Browser.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // See-through until the site's page paints, so the spinner behind shows.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        if let url = site.startURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.openURL = context.environment.openURL
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: SignInWebView
        var openURL: OpenURLAction?
        /// Set once the session is handed over, so later pages don't hand it over again.
        private var signedIn = false

        init(_ parent: SignInWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.shouldPerformDownload { return .cancel }
            // Only the main frame is kept to the chain; new-window links go on to `createWebViewWith`.
            guard let frame = action.targetFrame, frame.isMainFrame, let url = action.request.url else { return .allow }
            guard parent.site.allows(url) else {
                leave(for: url)
                return .cancel
            }
            // Hand over without loading the signed-in page, which also keeps iOS
            // from opening the site's app for the link.
            if let host = url.host(), parent.site.isSignedInHost(host), await handOver(from: webView) {
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
                if parent.site.allows(url) {
                    webView.load(action.request)
                } else {
                    leave(for: url)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard let url = webView.url, url.scheme == "https", let host = url.host(), parent.site.isSignedInHost(host) else { return }
            Task { await handOver(from: webView) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
            failed(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.onFailure("\(parent.site.failure) the sign-in page stopped.")
        }

        /// Hands over the session once the site sets it; false while the page is still signing in.
        @discardableResult
        private func handOver(from webView: WKWebView) async -> Bool {
            guard !signedIn else { return true }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard !signedIn, let session = parent.site.session(cookies) else { return signedIn }
            signedIn = true
            parent.onSession(session)
            return true
        }

        /// Network failures end the attempt. Cancellations don't: a new
        /// navigation or a refused response stops the last one on purpose.
        private func failed(_ error: any Error) {
            guard let error = error as? URLError, error.code != .cancelled else { return }
            parent.onFailure("\(parent.site.failure) \(error.localizedDescription)")
        }

        private func leave(for url: URL) {
            log.info("sign-in page: refused \(url.host() ?? "", privacy: .public)\(url.path(), privacy: .private)")
            if parent.site.opensInBrowser(url) {
                openURL?(url)
            }
        }
    }
}
