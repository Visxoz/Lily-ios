import SwiftUI

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsTabs(selection: $tab)
                    switch tab {
                    case 0: PlaybackSettings()
                    case 1: SoundSettings()
                    case 2: DownloadSettings()
                    case 3: AppearanceSettings()
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
                    Button(role: .close) { dismiss() }
                        .tint(theme.text)
                }
            }
        }
    }
}

/// One row where the titles fit, else rows of three; never a scroll.
private struct SettingsTabs: View {
    @Binding var selection: Int
    @Environment(\.theme) private var theme
    @Namespace private var underline

    private static let titles = ["Playback", "Sound", "Downloads", "Appearance", "Account"]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Self.titles.indices, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 12) }
                    tab(index, group: "row")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)) {
                ForEach(Self.titles.indices, id: \.self) { tab($0, group: "grid") }
            }
        }
        .background(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
        .animation(Theme.fast, value: selection)
    }

    /// `group` gives each layout its own underline, as ViewThatFits builds both.
    private func tab(_ index: Int, group: String) -> some View {
        let active = selection == index
        return Button {
            selection = index
        } label: {
            // One weight for both states, so the row never shifts.
            Text(Self.titles[index])
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? theme.text : theme.textSecondary)
                .fixedSize()
                .frame(height: 44)
                .overlay(alignment: .bottom) {
                    if active {
                        Capsule().fill(theme.accent).frame(height: 3)
                            .matchedGeometryEffect(id: group, in: underline)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

enum SettingsPage: Hashable {
    case equaliser
}
