import SwiftUI

/// `dialog.slint`'s `SettingRow`: a label over a line of detail, with the
/// row's control beside them, or under them where a phone is too narrow
/// for both.
struct SettingRow<Control: View>: View {
    let label: String
    var detail = ""
    var stacked = false
    @ViewBuilder let control: Control

    @Environment(\.theme) private var theme

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 24))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

/// `dialog.slint`'s `ToggleRow`: a setting row with a switch in the accent.
struct ToggleRow: View {
    let label: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(label: label, detail: detail) {
            Toggle(label, isOn: $isOn)
                .labelsHidden()
        }
    }
}

/// A `PillGroup` picking one of a few values, such as the audio quality.
struct ChoicePills<Value: Hashable>: View {
    let choices: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        PillGroup(
            titles: choices.map(\.title),
            selection: Binding {
                choices.firstIndex { $0.value == selection } ?? 0
            } set: {
                selection = choices[$0].value
            }
        )
    }
}
