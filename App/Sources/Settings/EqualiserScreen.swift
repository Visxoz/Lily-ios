import SwiftUI
import YTMAudio
import YTMCore

/// ytm-native's equaliser (`dialogs/equaliser.slint`): the preset menu and
/// the on/off switch, then a slider for each of the six bands, ±12 dB in
/// whole steps, heard as they move since the player follows the settings.
struct EqualiserScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    /// Settings' line about the equaliser: off, its preset, or custom.
    static func summary(_ settings: Settings) -> String {
        settings.equaliserEnabled ? preset(matching: settings.equaliserGains) ?? "Custom" : "Off"
    }

    private static func preset(matching gains: [Float]) -> String? {
        EqualiserBands.presets.first { $0.gains == gains }?.name
    }

    var body: some View {
        @Bindable var settings = app.settings
        let gains = settings.value.equaliserGains
        VStack(alignment: .leading, spacing: 18) {
            SettingRow(label: "Preset", detail: "A starting point; the bands below fine-tune it.") {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(EqualiserBands.presets.indices, id: \.self) { index in
                            Button(EqualiserBands.presets[index].name) { choose(index) }
                        }
                    } label: {
                        PillLabel(title: Self.preset(matching: gains) ?? "Custom", small: true)
                    }
                    Toggle("Equaliser", isOn: $settings.value.equaliserEnabled)
                        .labelsHidden()
                }
            }
            ForEach(EqualiserBands.frequencies.indices, id: \.self) { band in
                BandRow(
                    label: Self.label(EqualiserBands.frequencies[band]),
                    gain: gains.indices.contains(band) ? gains[band] : 0,
                    enabled: settings.value.equaliserEnabled
                ) { set(band, to: $0) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.menu)
        .navigationTitle("Equaliser")
    }

    /// A preset turns the equaliser on too, in one change.
    private func choose(_ index: Int) {
        var value = app.settings.value
        value.equaliserEnabled = true
        value.equaliserGains = EqualiserBands.presets[index].gains
        app.settings.value = value
    }

    /// A slider position from 0 to 1 as a whole number of dB. A drag reports
    /// every move, most within the same dB, which change nothing.
    private func set(_ band: Int, to fraction: Double) {
        // Adding 0 turns the -0 just left of centre into 0.
        let gain = ((Float(fraction) * 2 - 1) * EqualiserBands.maxGain).rounded() + 0
        guard app.settings.value.equaliserGains.indices.contains(band),
              app.settings.value.equaliserGains[band] != gain else { return }
        app.settings.value.equaliserGains[band] = gain
    }

    /// "60 Hz", "2.4 kHz".
    private static func label(_ hz: Float) -> String {
        hz >= 1_000 ? "\((hz / 1_000).formatted()) kHz" : "\(hz.formatted()) Hz"
    }
}

/// One band: its frequency, its slider and its gain.
private struct BandRow: View {
    let label: String
    let gain: Float
    let enabled: Bool
    let set: (Double) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 64, alignment: .leading)
            BarSlider(value: Double(gain / EqualiserBands.maxGain + 1) / 2, changed: set, committed: set)
                .disabled(!enabled)
                .accessibilityLabel(label)
            Text("\(gain > 0 ? "+" : "")\(Int(gain.rounded())) dB")
                .monospacedDigit()
                .foregroundStyle(enabled ? theme.text : theme.textDim)
                .frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 13))
    }
}
