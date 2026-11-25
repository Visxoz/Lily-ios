import SwiftUI

struct SettingRow<Control: View>: View {
    let label: String
    var detail = ""
    /// A detail whose height this one keeps, so a shorter one put in its place, as an error, doesn't move the
    /// rows below.
    var detailRoom = ""
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
                    // One cell for both, so it is as tall as the taller.
                    ZStack(alignment: .topLeading) {
                        if !detailRoom.isEmpty { Text(detailRoom).hidden() }
                        Text(detail)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

extension View {
    /// A text field's look in Settings.
    func settingField() -> some View {
        modifier(SettingField())
    }
}

private struct SettingField: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(theme.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().strokeBorder(theme.ink.opacity(0.44), lineWidth: 1))
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
