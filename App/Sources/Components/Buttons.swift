import SwiftUI

// The controls of ytm-native's `widgets/buttons.slint`. Hover states have no
// place on a touch screen; the press feedback stays.

/// `Icon`: a Material Symbol filled in one colour.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 24
    let colour: Color

    var body: some View {
        IconShape(icon: icon)
            .fill(colour)
            .frame(width: size, height: size)
    }
}

/// `IconButton`: a round icon button that shrinks slightly while pressed,
/// in the accent with a dot beneath when `active`.
struct IconButton: View {
    let icon: Icon
    var size: CGFloat = 32
    var iconSize: CGFloat = 18
    var active = false
    /// The icon's colour; the theme's secondary text when nil.
    var colour: Color?
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                IconView(icon: icon, size: iconSize, colour: iconColour)
                if active {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 4, height: 4)
                        .offset(y: iconSize / 2 + 4)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressScale(scale: 0.88, animation: .easeOut(duration: 0.09)))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var iconColour: Color {
        if !isEnabled { return theme.ink.opacity(0.25) }
        return active ? theme.accent : colour ?? theme.textSecondary
    }
}

/// `PlayButton`: the circular play button, in the accent unless told.
struct PlayButton: View {
    var size: CGFloat = 56
    var playing = false
    var colour: Color?
    var iconColour: Color?
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(colour ?? theme.accent)
                .shadow(color: theme.shadow, radius: 6, y: 4)
                .overlay {
                    IconView(icon: playing ? .pause : .play, size: size * 0.48, colour: iconColour ?? theme.onColour)
                }
                .frame(width: size, height: size)
        }
        .buttonStyle(PressScale(scale: 0.95))
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

/// `PillButton`: a rounded text button, filled with the text colour when
/// primary, outlined otherwise.
struct PillButton: View {
    let title: String
    var primary = false
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PillLabel(title: title, primary: primary, small: small)
        }
        .buttonStyle(PressScale(scale: 0.96))
    }
}

/// A `PillButton`'s look, for the labels of links and menus that open
/// something rather than act.
struct PillLabel: View {
    let title: String
    var primary = false
    var small = false

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .font(.system(size: small ? 13 : 14, weight: .bold))
            .foregroundStyle(primary ? theme.textInverse : theme.text)
            // A pill is one line, as ytm-native's: a row squeezes its
            // description instead.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, small ? 16 : 24)
            .frame(height: small ? 32 : 40)
            .background {
                if primary {
                    Capsule().fill(theme.text)
                } else {
                    Capsule().strokeBorder(theme.ink.opacity(0.44), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// `Pill`: one choice of a `PillGroup`.
struct Pill: View {
    let title: String
    let active: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? theme.textInverse : theme.text)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(active ? theme.text : theme.hover))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale(scale: 0.96))
        .accessibilityAddTraits(active ? .isSelected : [])
        .animation(Theme.fast, value: active)
    }
}

/// `PillGroup`: a row of pills, one of them picked.
struct PillGroup: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(titles.indices, id: \.self) { index in
                Pill(title: titles[index], active: selection == index) { selection = index }
            }
        }
    }
}

/// Shrinks a control while it is pressed, as ytm-native's buttons do.
struct PressScale: ButtonStyle {
    var scale: CGFloat
    var animation = Theme.fast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(animation, value: configuration.isPressed)
    }
}

/// A list row's press: the row washes over, as it does under the pointer in
/// ytm-native.
struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowPressBody(configuration: configuration)
    }

    private struct RowPressBody: View {
        let configuration: Configuration
        @Environment(\.theme) private var theme

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? theme.hover : .clear)
                )
                .animation(Theme.fast, value: configuration.isPressed)
        }
    }
}
