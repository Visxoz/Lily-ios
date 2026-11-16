import SwiftUI
import YTMCore

struct PageStatus: View {
    enum Phase {
        case loading
        case failed(message: String, retry: () -> Void)
        case empty(String)
    }

    let phase: Phase
    /// The route's tint, as `Theme.routeTint` gives it.
    let tint: RGB?

    @Environment(AppModel.self) private var app

    @Environment(\.theme) private var theme
    @State private var spinnerDue = false

    var body: some View {
        Group {
            switch phase {
            case .loading:
                // Held back a moment, so a page from the cache or a quick reply never flashes it.
                Spinner(size: 40)
                    .opacity(spinnerDue ? 1 : 0)
                    .task {
                        do {
                            try await Task.sleep(for: .milliseconds(250))
                        } catch {
                            return
                        }
                        withAnimation(Theme.normal) { spinnerDue = true }
                    }
            case .failed(let message, let retry):
                VStack(spacing: 20) {
                    Message(text: message)
                    PillButton(title: "Try again", primary: true, action: retry)
                    // Offline, as in YouTube Music, it points to the downloads.
                    if app.player.downloads.online == false, !app.player.downloads.isEmpty {
                        PillButton(title: "Go to downloads") { app.open(.downloads) }
                    }
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
