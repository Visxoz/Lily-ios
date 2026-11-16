import SwiftUI
import YTMCore
import YTMPlayback

/// Its own view, so download progress redraws the badge rather than the whole row.
struct DownloadBadge: View {
    let videoId: String

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        switch app.player.downloads.state(of: videoId) {
        case .none:
            EmptyView()
        case .waiting:
            ProgressRing(fraction: 0, size: 14)
        case .downloading(let fraction):
            ProgressRing(fraction: fraction, size: 14)
        case .downloaded:
            IconView(icon: .downloaded, size: 14, colour: theme.textSecondary)
                .accessibilityLabel("Downloaded")
        }
    }
}

struct ProgressRing: View {
    let fraction: Double
    let size: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        let line = size / 7
        ZStack {
            Circle()
                .stroke(theme.ink.opacity(0.15), lineWidth: line)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.normal, value: fraction)
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(fraction > 0 ? "Downloading, \(Int(fraction * 100)) percent" : "Waiting to download")
    }
}

struct DownloadButton: View {
    let route: Route
    let page: Page

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var confirming = false

    var body: some View {
        let downloads = app.player.downloads
        let state = downloads.state(of: route)
        Button {
            if state == .none {
                Task { await downloads.download(page, from: route) }
            } else {
                confirming = true
            }
        } label: {
            Group {
                switch state {
                case .none: IconView(icon: .download, size: 28, colour: theme.textSecondary)
                case .waiting: ProgressRing(fraction: 0, size: 26)
                case .downloading(let fraction): ProgressRing(fraction: fraction, size: 26)
                case .downloaded: IconView(icon: .downloaded, size: 28, colour: theme.accent)
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(PressScale(scale: 0.88, animation: .easeOut(duration: 0.09)))
        .accessibilityLabel(state == .none ? "Download" : "Remove download")
        .confirmationDialog("Remove this download?", isPresented: $confirming, titleVisibility: .visible) {
            Button(state == .downloaded ? "Remove download" : "Stop downloading", role: .destructive) { downloads.remove(route) }
        } message: {
            Text("Songs also downloaded on their own stay.")
        }
    }
}

/// Remove download is left out while a downloaded album or playlist still holds the song.
struct TrackDownloadItem: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        let downloads = app.player.downloads
        if downloads.state(of: track.id) == .none {
            Button("Download") { downloads.download(track) }
        } else if downloads.canRemove(track.id) {
            Button("Remove download", role: .destructive) { downloads.remove(track) }
        }
    }
}

struct CardDownloadItem: View {
    let card: Card

    @Environment(AppModel.self) private var app

    var body: some View {
        if let route = card.route, Downloads.isDownloadable(route) {
            let downloads = app.player.downloads
            if downloads.state(of: route) == .none {
                Button("Download") { Task { await downloads.download(card) } }
            } else {
                Button("Remove download", role: .destructive) { downloads.remove(route) }
            }
        }
    }
}
