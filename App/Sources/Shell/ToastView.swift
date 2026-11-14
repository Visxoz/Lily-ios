import SwiftUI

/// ytm-native's toast (`app.slint`): a short message in the text colour,
/// rising into view above the player and fading after a few seconds.
struct ToastView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if let toast = app.toast {
                Text(toast.message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textInverse)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.text))
                    .shadow(color: theme.shadow, radius: 8)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
                    .id(toast.id)
                    .transition(.opacity.combined(with: .offset(y: 20)))
            }
        }
        .animation(Theme.normal, value: app.toast)
        .allowsHitTesting(false)
    }
}
