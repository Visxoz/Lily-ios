import SwiftUI
import YTMCore

/// The lyrics under "Lyrics", as `panel/lyrics.slint` and `now_playing.rs`:
/// the spinner while they load, then the lines, or what stands in for them,
/// in the same words. The player loads them only while this shows.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        Group {
            switch player.lyrics {
            case .loading:
                Spinner(size: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let lyrics):
                LyricsLines(lyrics: lyrics)
            case .idle, .unavailable, .failed:
                // ytm-native shows the reason as a lyric of its own.
                LyricsLines(lyrics: Lyrics(lines: [player.lyrics.message ?? ""]))
            }
        }
        // Each song starts afresh: at the top, following the singing.
        .id(player.current?.id)
        .onAppear { player.showsLyrics = true }
        .onDisappear { player.showsLyrics = false }
    }
}

/// The lines, and for synced lyrics the one being sung lit and glided to
/// the middle, the rest dimmed; tapping a line seeks to it. Scrolling by
/// hand stops the following until a few seconds after the list comes to
/// rest.
private struct LyricsLines: View {
    let lyrics: Lyrics

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var current: Int?
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var phase = ScrollPhase.idle
    /// Whether the list keeps the line being sung in the middle.
    @State private var following = true
    /// Counts the times the user let go of the list, restarting the wait to
    /// follow again.
    @State private var released = 0

    private static let resumeAfter = Duration.seconds(3)

    var body: some View {
        let synced = lyrics.isSynced
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lyrics.lines.indices, id: \.self) { index in
                    LyricLine(text: lyrics.lines[index], lit: !synced || index == current)
                        .onTapGesture { if synced { seek(to: index) } }
                        .accessibilityAddTraits(synced ? .isButton : [])
                }
                if !lyrics.source.isEmpty {
                    Text(lyrics.source)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, NowPlayingScreen.padding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position, anchor: .center)
        .onScrollPhaseChange { _, new in scrolled(new) }
        .task(id: released) {
            guard released > 0 else { return }
            try? await Task.sleep(for: Self.resumeAfter)
            guard !Task.isCancelled, phase == .idle else { return }
            following = true
            glide()
        }
        .background {
            if synced {
                LyricClock(lyrics: lyrics) { line in
                    current = line
                    glide()
                }
            }
        }
    }

    private func scrolled(_ new: ScrollPhase) {
        let byHand = phase == .interacting || phase == .decelerating
        phase = new
        switch new {
        case .interacting:
            following = false
        case .idle where byHand:
            released += 1
        default:
            break
        }
    }

    private func seek(to index: Int) {
        app.player.seek(to: lyrics.starts[index])
        current = index
        following = true
        glide()
    }

    /// Glides the lit line to the middle, unless the user has the list.
    private func glide() {
        guard following, let current else { return }
        withAnimation(.easeOut(duration: 0.5)) { position.scrollTo(id: current, anchor: .center) }
    }
}

/// Finds the line being sung, pulled from the player twenty times a second
/// while it plays, and again on a seek, which may come while paused, and
/// reports it only when it changes, so the lines redraw once a line rather
/// than every frame.
private struct LyricClock: View {
    let lyrics: Lyrics
    let changed: (Int?) -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        TimelineView(.animation(minimumInterval: 0.05, paused: !player.isPlaying)) { _ in
            Color.clear
                .onChange(of: lyrics.lineIndex(at: player.currentTime), initial: true) { _, line in changed(line) }
        }
        // As ytm-native's `seek_to` lights the line whatever the pause.
        .onChange(of: player.lastSeek) { _, seek in changed(lyrics.lineIndex(at: seek.to)) }
    }
}

/// One line, as the slint `Text`: large and bold, dimmed unless lit.
private struct LyricLine: View {
    let text: String
    let lit: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(theme.text)
            .opacity(lit ? 1 : 0.5)
            .animation(Theme.normal, value: lit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
