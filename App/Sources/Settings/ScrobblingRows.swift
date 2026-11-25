import SwiftUI
import YTMCore

/// Last.fm connects on its page in the browser; a build without its API keys has no button.
struct LastFMRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrobblingRow(
            service: .lastFM, about: "Logs what you play to your Last.fm profile.",
            waiting: "Allow access on the Last.fm page in your browser."
        ) {
            PillButton(title: "Connect", small: true) {
                let open = openURL
                app.connect(.lastFM) { service in try await service.signIn { url in await open(url) } }
            }
        }
    }
}

/// ListenBrainz connects with the user token from its settings, sent on Done.
struct ListenBrainzRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var token = ""

    var body: some View {
        ScrobblingRow(
            service: .listenBrainz,
            about: "Logs what you play to ListenBrainz. Paste the user token from your ListenBrainz settings.",
            waiting: "Checking the token.", stacked: true
        ) {
            SecureField("ListenBrainz user token", text: $token, prompt: Text("User token").foregroundStyle(theme.textDim))
                .settingField()
                .onSubmit {
                    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    self.token = ""
                    app.connect(.listenBrainz) { try await $0.signIn(token: token) }
                }
        }
    }
}

/// The app, not this row, waits while an account connects, so leaving Settings doesn't stop it.
private struct ScrobblingRow<Connect: View>: View {
    private enum Phase: Equatable {
        case signedOut
        case connected(String)
    }

    let service: ScrobbleService
    /// The detail while signed out.
    let about: String
    /// The detail while connecting.
    let waiting: String
    /// Whether `connect` goes beneath the label.
    var stacked = false
    @ViewBuilder let connect: Connect

    @Environment(AppModel.self) private var app
    /// Nil while the Keychain is read.
    @State private var phase: Phase?

    var body: some View {
        let connecting = app.isConnecting(service)
        SettingRow(label: service.name, detail: detail(connecting), stacked: stacked && !connecting && phase == .signedOut) {
            if connecting {
                PillButton(title: "Cancel", small: true) { app.cancelConnect(service) }
            } else if case .connected = phase {
                PillButton(title: "Disconnect", small: true) {
                    Task {
                        await service.signOut()
                        phase = .signedOut
                    }
                }
            } else if phase == .signedOut, service.isAvailable {
                connect
            }
        }
        // Read again as a wait starts or ends, which it may do while the row is gone.
        .task(id: connecting) { phase = await service.username.map(Phase.connected) ?? .signedOut }
    }

    private func detail(_ connecting: Bool) -> String {
        if !service.isAvailable { return "Not available in this build." }
        if connecting { return waiting }
        if case .connected(let name) = phase { return "Scrobbling what you play as \(name)." }
        return about
    }
}
