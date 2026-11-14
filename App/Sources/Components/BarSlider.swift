import SwiftUI

/// ytm-native's `Slider` (`widgets/slider.slint`): a thin rounded bar filled
/// to `value` over any `buffered` fill, turning the accent with a knob while dragged. It is driven
/// from outside: `changed` follows the finger and `committed` takes where it
/// was let go, and the owner passes the value back. The touch area is taller
/// than the bar, for a finger.
struct BarSlider: View {
    /// From 0 to 1.
    let value: Double
    /// How much is ready, from 0 to 1, drawn lighter behind `value`, as the
    /// seek bar's buffered fill. Zero for none.
    var buffered = 0.0
    var changed: ((Double) -> Void)?
    let committed: (Double) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var width: CGFloat = 0
    @State private var dragging = false

    private static let touchHeight: CGFloat = 32
    private static let barHeight: CGFloat = 4
    private static let knob: CGFloat = 12
    /// How far one swipe of VoiceOver's adjust moves it, as the slint
    /// slider's scroll wheel step.
    private static let step = 0.05

    var body: some View {
        let shown = min(max(value, 0), 1)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(theme.ink.opacity(0.19))
            Capsule()
                .fill(theme.ink.opacity(0.16))
                .scaleEffect(x: min(max(buffered, 0), 1), anchor: .leading)
            Capsule()
                .fill(dragging ? theme.accent : isEnabled ? theme.text : theme.textDim)
                // Scaled rather than resized, so a moving bar never lays out.
                .scaleEffect(x: shown, anchor: .leading)
        }
        .frame(height: Self.barHeight)
        .overlay(alignment: .leading) {
            Circle()
                .fill(theme.text)
                .shadow(color: theme.shadow, radius: 2)
                .frame(width: Self.knob, height: Self.knob)
                .offset(x: width * shown - Self.knob / 2)
                .opacity(dragging ? 1 : 0)
        }
        .animation(Theme.fast, value: dragging)
        .frame(maxWidth: .infinity, minHeight: Self.touchHeight)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .gesture(drag, isEnabled: isEnabled)
        .accessibilityElement()
        .accessibilityValue(Text(shown, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: committed(min(shown + Self.step, 1))
            case .decrement: committed(max(shown - Self.step, 0))
            @unknown default: break
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                dragging = true
                changed?(fraction(at: gesture.location.x))
            }
            .onEnded { gesture in
                dragging = false
                committed(fraction(at: gesture.location.x))
            }
    }

    private func fraction(at x: CGFloat) -> Double {
        width > 0 ? min(max(x / width, 0), 1) : 0
    }
}
