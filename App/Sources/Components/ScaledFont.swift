import SwiftUI

extension View {
    /// The system font at `size` points at the default text size, scaled with the reader's choice.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size: size, weight: weight))
    }

    /// Stops short of the accessibility sizes, which would overflow the fixed-height pills, badges and rows. Needed on
    /// each modal too, as each takes the system's size afresh.
    func cappedTypeSize() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Self.style(for: size))
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }

    /// The system style of about `size`, so titles grow more gently than body text, as Apple's do.
    private static func style(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12: .caption2
        case ..<13: .caption
        case ..<15: .footnote
        case ..<16: .subheadline
        case ..<17: .callout
        case ..<20: .body
        case ..<22: .title3
        case ..<28: .title2
        case ..<34: .title
        default: .largeTitle
        }
    }
}
