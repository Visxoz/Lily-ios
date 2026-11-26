import SwiftUI

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

extension SensoryFeedback {
    /// Play, pause and shuffle-play; firmer than a skip.
    static let play = SensoryFeedback.impact(weight: .medium)
    static let skip = SensoryFeedback.impact(weight: .light)
}

/// A button that plays `feedback` with each tap, or none when nil.
struct FeedbackButton<Label: View>: View {
    let feedback: SensoryFeedback?
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var taps = 0

    var body: some View {
        Button {
            if feedback != nil { taps += 1 }
            action()
        } label: {
            label
        }
        .sensoryFeedback(trigger: taps) { _, _ in feedback }
    }
}

struct IconButton: View {
    let icon: Icon
    var size: CGFloat = 32
    var iconSize: CGFloat = 18
    var active = false
    var colour: Color?
    var feedback: SensoryFeedback?
    let action: () -> Void

    var body: some View {
        FeedbackButton(feedback: feedback, action: action) {
            IconLabel(icon: icon, size: size, iconSize: iconSize, active: active, colour: colour)
        }
        .buttonStyle(PressScale(scale: 0.88, animation: .easeOut(duration: 0.09)))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// `IconButton`'s look, for menus and system controls that take the tap.
struct IconLabel: View {
    let icon: Icon
    var size: CGFloat = 32
    var iconSize: CGFloat = 18
    var active = false
    /// The theme's secondary text when nil.
    var colour: Color?

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
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

    private var iconColour: Color {
        if !isEnabled { return theme.ink.opacity(0.25) }
        return active ? theme.accent : colour ?? theme.textSecondary
    }
}

struct PlayButton: View {
    var size: CGFloat = 56
    var playing = false
    var colour: Color?
    var iconColour: Color?
    var feedback: SensoryFeedback? = .play
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        FeedbackButton(feedback: feedback, action: action) {
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

/// A page header's labelled button: the accent for the main action, a tonal wash for the rest.
struct ActionPill: View {
    let icon: Icon
    let title: String
    var primary = false
    /// The icon alone, in a circle, where the row is too narrow for the words.
    var compact = false
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        // The accent stays readable as text in every look, so it stands out without a solid fill.
        let foreground = primary ? theme.accent : theme.text
        FeedbackButton(feedback: .play, action: action) {
            HStack(spacing: 8) {
                IconView(icon: icon, size: 22, colour: foreground)
                if !compact {
                    Text(title)
                        .scaledFont(15, weight: .bold)
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, compact ? 0 : 16)
            .padding(.trailing, compact ? 0 : 20)
            .frame(width: compact ? 48 : nil, height: 48)
            .background {
                Capsule().fill(primary ? theme.accent.opacity(0.18) : theme.hover)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale(scale: 0.96))
        .accessibilityLabel(title)
    }
}

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

/// A `PillButton`'s look, for links and menus that open something rather than act.
struct PillLabel: View {
    let title: String
    var primary = false
    var small = false

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .scaledFont(small ? 13 : 14, weight: .bold)
            .foregroundStyle(primary ? theme.textInverse : theme.text)
            // A pill is one line: a row squeezes its description instead.
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

struct Pill: View {
    let title: String
    let active: Bool
    var compact = false
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .scaledFont(compact ? 13 : 14, weight: .semibold)
                .foregroundStyle(active ? theme.textInverse : theme.text)
                .lineLimit(1)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(height: 32)
                .background(Capsule().fill(active ? theme.text : theme.hover))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale(scale: 0.96))
        .accessibilityAddTraits(active ? .isSelected : [])
        .animation(Theme.fast, value: active)
    }
}

struct PillGroup: View {
    let titles: [String]
    @Binding var selection: Int

    /// Tighter pills only when the row won't fit, and scrolling only when even those won't, so no title is cut
    /// short.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            pills(compact: false)
            pills(compact: true)
            // Unclipped, so the row runs on to the screen's edge, and kept on the pill chosen.
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    pills(compact: true)
                }
                .scrollClipDisabled()
                .onAppear { scroller.scrollTo(selection) }
                .onChange(of: selection) { withAnimation(Theme.fast) { scroller.scrollTo(selection) } }
            }
        }
    }

    private func pills(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(titles.indices, id: \.self) { index in
                Pill(title: titles[index], active: selection == index, compact: compact) { selection = index }
            }
        }
    }
}

struct PressScale: ButtonStyle {
    var scale: CGFloat
    var animation = Theme.fast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(animation, value: configuration.isPressed)
    }
}

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
