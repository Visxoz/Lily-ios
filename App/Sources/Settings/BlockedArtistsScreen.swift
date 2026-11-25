import SwiftUI
import YTMCore

struct BlockedArtistsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if app.blocked.isEmpty {
                    Text("No artists blocked.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(app.blocked, id: \.self) { artist in
                    SettingRow(label: artist.name) {
                        // No toast, which would show behind Settings; the row going says as much.
                        PillButton(title: "Unblock", small: true) { _ = app.settings.value.toggleBlock(artist) }
                            .accessibilityLabel("Unblock \(artist.name)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.menu)
        .navigationTitle("Blocked artists")
    }
}
