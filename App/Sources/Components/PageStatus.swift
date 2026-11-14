import SwiftUI
import YTMCore

/// What `page-view.slint` shows in place of a page: the spinner while it
/// loads, or a message, such as why it failed, with a button to act on it,
/// under the page's tint as the page itself would be.
struct PageStatus: View {
    enum Phase {
        case loading
        case failed(message: String, action: String, perform: () -> Void)
        /// Nothing to show yet, and nothing to do about it.
        case empty(String)
    }

    let phase: Phase
    /// The route's tint, as `Theme.routeTint` gives it.
    let tint: RGB?

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch phase {
            case .loading:
                Spinner(size: 40)
            case .failed(let message, let action, let perform):
                VStack(spacing: 20) {
                    Message(text: message)
                    PillButton(title: action, primary: true, action: perform)
                }
                .padding(48)
            case .empty(let message):
                Message(text: message)
                    .padding(48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            PageTint(colour: tint, top: 0)
                .ignoresSafeArea(edges: .top)
        }
        .background(theme.panel)
    }

    private struct Message: View {
        let text: String

        @Environment(\.theme) private var theme

        var body: some View {
            Text(text)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
        }
    }
}
