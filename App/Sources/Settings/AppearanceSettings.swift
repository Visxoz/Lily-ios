import SwiftUI
import YTMCore

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let accent = settings.value.accent
        SettingRow(label: "Theme", stacked: true) {
            ChoicePills(choices: [(Look.dark, "Dark"), (.light, "Light"), (.black, "Black")], selection: $settings.value.look)
        }
        SettingRow(
            label: "Accent colour",
            detail: accent == .artwork ? "Follows the artwork of the song playing." : accent.name,
            stacked: true
        ) {
            HStack(spacing: 6) {
                ForEach(Accent.allCases, id: \.self) { choice in
                    Swatch(accent: choice, active: choice == accent) { settings.value.accent = choice }
                }
            }
        }
        SettingRow(label: "Animated art", detail: "Art that moves: a song's Spotify Canvas once signed in below, else its album's Apple Music cover.", stacked: true) {
            ChoicePills(choices: [(AnimatedArt.on, "On"), (.wifi, "Wi-Fi only"), (.off, "Off")], selection: $settings.value.animatedArt)
        }
        SpotifyRow()
        ToggleRow(
            label: "Albums by artist",
            detail: "Orders your saved albums by artist, then title, rather than as YouTube Music lists them; Library's row too once it holds them all.",
            isOn: $settings.value.albumsByArtist
        )
    }
}

private struct SpotifyRow: View {
    @Environment(AppModel.self) private var app
    /// Nil while it is read.
    @State private var signedIn: Bool?

    var body: some View {
        SettingRow(
            label: "Spotify Canvas",
            detail: signedIn == true
                ? "Signed in: songs with a Canvas show it."
                : "Each song's moving art from Spotify, where it has one, ahead of Apple Music's album covers. Uses your Spotify account."
        ) {
            switch signedIn {
            case true?:
                PillButton(title: "Sign out", small: true) {
                    Task {
                        await MotionArtwork.shared.signOutOfSpotify()
                        app.player.refreshMotion()
                        await refresh()
                    }
                }
                .accessibilityLabel("Sign out of Spotify")
            case false?:
                PillButton(title: "Sign in", small: true) { app.sheet = .spotifySignIn }
                    .accessibilityLabel("Sign in to Spotify")
            case nil:
                EmptyView()
            }
        }
        // Settings closes for the sign-in sheet, so this reads again once it is back.
        .task { await refresh() }
    }

    private func refresh() async {
        signedIn = await MotionArtwork.shared.isSignedInToSpotify
    }
}

private struct Swatch: View {
    let accent: Accent
    let active: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    private static let size: CGFloat = 34
    private static let fill: CGFloat = 24
    private static let artwork = LinearGradient(
        colors: [Accent.red, .purple, .teal].compactMap(\.rgb).map { Color(rgb: RGB(hex: $0)) },
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(active ? theme.text : .clear, lineWidth: 2)
                Group {
                    if let rgb = accent.rgb {
                        Circle().fill(Color(rgb: RGB(hex: rgb)))
                    } else {
                        Circle().fill(Self.artwork)
                    }
                }
                .frame(width: Self.fill, height: Self.fill)
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
        }
        .buttonStyle(PressScale(scale: 0.9))
        .animation(Theme.fast, value: active)
        .accessibilityLabel(accent.name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
