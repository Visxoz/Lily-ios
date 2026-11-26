import SwiftUI
import YTMCore

struct AccountSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        AccountRow()
        if app.isSignedIn {
            ToggleRow(
                label: "YouTube history",
                detail: "Adds songs played here to your YouTube Music history, so your recommendations and Listen again reflect them.",
                isOn: $settings.value.youtubeHistory
            )
            ToggleRow(
                label: "Like and dislike buttons",
                detail: "Shows them beside the song playing. Liking adds a song to your Liked music; disliking steers your recommendations away from it.",
                isOn: $settings.value.ratingButtons
            )
        }
        LastFMRow()
        ListenBrainzRow()
        ProxyRow()
        if let version = AppRelease.version {
            VersionRow(version: version)
        }
    }
}

/// Its own view, so the update check's answer redraws only this row.
private struct VersionRow: View {
    let version: String

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingRow(label: "Lily \(version)") {
            if app.hasUpdate {
                update
                    .buttonStyle(PressScale(scale: 0.95))
            }
        }
    }

    /// iOS can't say which installer Lily came from, so it offers each one on the phone, or GitHub without any.
    @ViewBuilder private var update: some View {
        let installers = Installer.onPhone
        if installers.isEmpty {
            Button(action: openReleasePage) { label }
        } else {
            Menu {
                ForEach(installers, id: \.name) { installer in
                    Button("Update with \(installer.name)") { openURL(installer.link) }
                }
                Button("Download from GitHub", action: openReleasePage)
            } label: {
                label
            }
        }
    }

    /// Inside the button, so the whole 44 pt is tappable.
    private var label: some View {
        Text("Update available")
            .scaledFont(13, weight: .semibold)
            .foregroundStyle(theme.accent)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }

    private func openReleasePage() {
        if let page = AppRelease.page { openURL(page) }
    }
}

/// Sideloading apps whose links install an IPA from its address.
private struct Installer {
    let name: String
    let link: URL

    /// Checked once, on first use, as each check asks the system; only schemes listed in Info.plist's
    /// LSApplicationQueriesSchemes can be checked.
    static let onPhone = [
        ("SideStore", "sidestore://install?url="),
        ("AltStore", "altstore://install?url="),
        // Feather takes the address as its path.
        ("Feather", "feather://install/"),
    ]
    .compactMap { name, prefix in URL(string: prefix + AppRelease.ipa).map { Installer(name: name, link: $0) } }
    .filter { UIApplication.shared.canOpenURL($0.link) }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            if app.isSignedIn {
                AccountPhoto(size: 40)
                    .accessibilityHidden(true)
            }
            SettingRow(
                label: app.isSignedIn ? app.account?.name ?? "Signed in" : "Not signed in",
                detail: app.isSignedIn
                    ? "Your library and history come from your YouTube account."
                    : "Sign in to see your library and history."
            ) {
                if app.isSignedIn {
                    PillButton(title: "Sign out", small: true) { Task { await app.signOut() } }
                } else {
                    PillButton(title: "Sign in", small: true) { app.sheet = .signIn }
                }
            }
        }
    }
}
