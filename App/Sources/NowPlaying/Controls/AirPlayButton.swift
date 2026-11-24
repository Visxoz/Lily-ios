import AVKit
import SwiftUI

/// The app's icon under an invisible system route picker, as iOS offers no other way to open it.
struct AirPlayButton: View {
    var body: some View {
        IconLabel(icon: .airplay, size: 44, iconSize: 22)
            .accessibilityHidden(true)
            .overlay { RoutePicker() }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}

    /// Fills the button, not just the picker's glyph.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AVRoutePickerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
