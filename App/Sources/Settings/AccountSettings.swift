import SwiftUI
import YTMCore

/// Settings' Account tab: signing in and out, then, signed in, the YouTube
/// history and rating button settings, and Last.fm.
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
    }
}

/// Who is signed in, with their picture and name once YouTube has said, and
/// the button to sign out, or in, which makes way for Google's page.
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
