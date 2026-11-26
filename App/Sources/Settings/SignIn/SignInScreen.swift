import Network
import SwiftUI
import YTMCore

/// The site's own page signs in and its cookies sign the app in, so the
/// password goes to the site only.
struct SignInScreen<Session>: View {
    private enum Phase: Equatable {
        case browsing
        case signingIn
        case failed(String)
    }

    private let site: SignInSite<Session>
    /// Hands the session to the app; the sheet closes once it returns.
    private let signIn: (Session) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    /// Leaving `.browsing` drops the page with its private session, so
    /// Try again starts signed out on a fresh one.
    @State private var phase = Phase.browsing
    /// Read before the page loads, so it goes through the user's proxy.
    @State private var proxies: [ProxyConfiguration]?

    init(site: SignInSite<Session>, signIn: @escaping (Session) async throws -> Void) {
        self.site = site
        self.signIn = signIn
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.panel)
                .navigationTitle(site.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .browsing:
            ZStack {
                spinner
                if let proxies {
                    SignInWebView(site: site, onSession: handOver, onFailure: { phase = .failed($0) }, proxies: proxies)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .task { proxies = await Proxy.loadConfigurations() }
        case .signingIn:
            spinner
        case .failed(let message):
            VStack(spacing: 20) {
                Text(message)
                    .scaledFont(13)
                    .foregroundStyle(theme.signInError)
                    .multilineTextAlignment(.center)
                PillButton(title: "Try again", primary: true) { phase = .browsing }
            }
            .padding(24)
        }
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.large)
            .tint(theme.accent)
    }

    private func handOver(_ session: Session) {
        // Later pages of the same session hand over again.
        guard phase == .browsing else { return }
        phase = .signingIn
        Task {
            do {
                try await signIn(session)
                dismiss()
            } catch {
                phase = .failed(sentence(for: error))
            }
        }
    }
}

private extension Theme {
    var signInError: Color {
        Color(rgb: RGB(hex: isLight ? 0xc4002b : 0xff6b81))
    }
}
