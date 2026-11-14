import SwiftUI

/// ytm-native's Settings dialog (`dialogs/settings.slint`) as a sheet, in its
/// tabs: playback, appearance and the account. The Windows-only rows,
/// Discord and updates, have no place here; the audio cache, which ytm-native
/// keeps in memory, gets a row of its own.
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PillGroup(titles: ["Playback", "Appearance", "Account"], selection: $tab)
                    switch tab {
                    case 0: PlaybackSettings()
                    case 1: AppearanceSettings()
                    default: AccountSettings()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(theme.menu)
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .equaliser: EqualiserScreen()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Neutral, as ytm-native's dialog close, not the accent.
                    Button(role: .close) { dismiss() }
                        .tint(theme.text)
                }
            }
        }
    }
}

/// The pages Settings leads on to.
enum SettingsPage: Hashable {
    case equaliser
}
