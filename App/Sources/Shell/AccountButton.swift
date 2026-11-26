import SwiftUI

struct AccountButton: View {
    /// Its tap area outside a toolbar; a toolbar sizes its own.
    var edge: CGFloat?

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Button { app.sheet = .settings } label: {
            AccountPhoto(size: 26)
                .overlay(alignment: .topTrailing) {
                    if app.hasUpdate {
                        // Ringed, so it shows against the accent fill of a photo still loading.
                        Circle()
                            .fill(theme.accent)
                            .stroke(theme.panel, lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                            .offset(x: 2, y: -2)
                    }
                }
                .frame(width: edge, height: edge)
                .contentShape(Circle())
        }
        .accessibilityLabel("Settings")
        .accessibilityValue(app.hasUpdate ? "Update available" : "")
    }
}

struct AccountPhoto: View {
    let size: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().fill(app.isSignedIn ? theme.accent : theme.ink.opacity(0.3))
            IconView(icon: .account, size: size * 0.69, colour: app.isSignedIn ? theme.onColour : theme.text)
            if app.isSignedIn, let photo = app.account?.photo {
                ArtworkImage(url: photo, edge: size, placeholder: false)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }
}
