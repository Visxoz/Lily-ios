import SwiftUI
import YTMCore

/// Settings' Last.fm row, as `settings.slint` and `scrobble.rs`: Connect opens
/// Last.fm's page to allow access, and the app waits while it is allowed,
/// whatever Settings does, with Cancel here; connected, it names the account,
/// with Disconnect. ytm-native builds its API key in; here the user enters
/// their own once, kept in the Keychain.
struct LastFMRow: View {
    private enum Phase: Equatable {
        /// Reading the Keychain.
        case reading
        case needsKeys
        case ready
        case connected(String)
    }

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var phase = Phase.reading
    @State private var changingKeys = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow(label: "Last.fm", detail: detail) { control }
            if phase == .needsKeys || changingKeys {
                LastFMKeys { apiKey, apiSecret in
                    Task {
                        await LastFM.shared.setKeys(apiKey: apiKey, apiSecret: apiSecret)
                        changingKeys = false
                        await refresh()
                    }
                }
            } else if phase == .ready, !app.isConnectingLastFM {
                Button("Change API key") { changingKeys = true }
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        // Read again as a wait starts or ends, which it may do while the
        // row is gone.
        .task(id: app.isConnectingLastFM) { await refresh() }
    }

    private var detail: String {
        if app.isConnectingLastFM { return "Allow access on the Last.fm page in your browser." }
        return switch phase {
        case .reading, .ready: "Logs what you play to your Last.fm profile."
        case .needsKeys: "Logs what you play to your Last.fm profile. Enter the API key and shared secret of an API account from last.fm/api first."
        case .connected(let name): "Scrobbling what you play as \(name)."
        }
    }

    @ViewBuilder
    private var control: some View {
        if app.isConnectingLastFM {
            PillButton(title: "Cancel", small: true) { app.cancelLastFMConnect() }
        } else {
            switch phase {
            case .reading, .needsKeys:
                EmptyView()
            case .ready:
                PillButton(title: "Connect", small: true) { app.connectLastFM(open: openURL) }
            case .connected:
                PillButton(title: "Disconnect", small: true) {
                    Task {
                        await LastFM.shared.signOut()
                        await refresh()
                    }
                }
            }
        }
    }

    private func refresh() async {
        let lastFM = LastFM.shared
        if let name = await lastFM.username {
            phase = .connected(name)
        } else {
            phase = await lastFM.hasKeys ? .ready : .needsKeys
        }
    }
}

/// The API key and shared secret, entered once.
private struct LastFMKeys: View {
    let save: (String, String) -> Void

    @Environment(\.theme) private var theme
    @State private var apiKey = ""
    @State private var apiSecret = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Group {
                TextField("API key", text: $apiKey)
                SecureField("Shared secret", text: $apiSecret)
            }
            .font(.system(size: 14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.hover))
            PillButton(title: "Save", primary: true, small: true) { save(apiKey, apiSecret) }
                .disabled(apiKey.isEmpty || apiSecret.isEmpty)
        }
    }
}
