import SwiftUI

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
