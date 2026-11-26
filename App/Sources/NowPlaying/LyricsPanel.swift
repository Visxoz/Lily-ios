import SwiftUI
import YTMCore

/// The player loads lyrics only while this shows, which Now Playing tells it.
struct LyricsPanel: View {
    /// For a pull down past the top of the lines.
    let close: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        Group {
            switch player.lyrics {
            case .loading:
                // Lines of `LyricLine`'s height and spacing.
                VStack(alignment: .leading, spacing: 19) {
                    ForEach(0..<8, id: \.self) { Bone(width: Bone.length($0) * 1.5, height: 20) }
                }
                .padding(.horizontal, NowPlayingScreen.padding)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .skeleton()
            case .loaded(let lyrics):
                LyricsLines(lyrics: lyrics, close: close)
            case .idle, .unavailable, .failed:
                LyricsLines(lyrics: Lyrics(lines: [player.lyrics.message ?? ""]), close: close)
            }
        }
        // Each song starts afresh: at the top, following the singing.
        .id(player.current?.id)
    }
}

/// Scrolling by hand stops the following until a few seconds after the list comes to rest.
private struct LyricsLines: View {
    let lyrics: Lyrics
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var current: Int?
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var phase = ScrollPhase.idle
    /// Whether the list keeps the line being sung in the middle.
    @State private var following = true
    /// Bumped each time the user lets go of the list, restarting the wait to follow again.
    @State private var released = 0

    private static let resumeAfter = Duration.seconds(3)

    var body: some View {
        let settings = app.settings.value
        let romanise = settings.lyricsRomanisation && lyrics.isRomanised
        let translate = settings.lyricsTranslation && lyrics.hasTranslations
        VStack(spacing: 0) {
            if lyrics.isRomanised || lyrics.hasTranslations {
                LyricsToggles(romanised: lyrics.isRomanised, translated: lyrics.hasTranslations)
            }
            lines(romanise: romanise, translate: translate)
        }
        // Rows change height as extras show or hide.
        .onChange(of: romanise) { glide() }
        .onChange(of: translate) { glide() }
    }

    private func lines(romanise: Bool, translate: Bool) -> some View {
        let synced = lyrics.isSynced
        let wordSynced = lyrics.isWordSynced
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lyrics.lines.indices, id: \.self) { index in
                    LyricLine(
                        text: lyrics.lines[index],
                        words: wordSynced && index == current ? lyrics.words[index] : [],
                        romanised: romanise ? lyrics.romanised[index] : "",
                        translation: translate ? lyrics.translations[index] : "",
                        lit: !synced || index == current
                    )
                        .onTapGesture { if synced { seek(to: index) } }
                        .accessibilityAddTraits(synced ? .isButton : [])
                }
                if !lyrics.source.isEmpty {
                    Text(lyrics.source)
                        .scaledFont(12)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, NowPlayingScreen.padding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position, anchor: .center)
        .onScrollPhaseChange { old, new, context in
            scrolled(new)
            if pulledPastTop(old, new, context.geometry) { close() }
        }
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

/// Outside the scroll view, so they don't scroll away.
private struct LyricsToggles: View {
    /// Which the lyrics have.
    let romanised: Bool, translated: Bool

    @Environment(AppModel.self) private var app

    var body: some View {
        let settings = app.settings
        HStack(spacing: 6) {
            if romanised {
                Pill(title: "Romanisation", active: settings.value.lyricsRomanisation, compact: true) {
                    settings.value.lyricsRomanisation.toggle()
                }
            }
            if translated {
                Pill(title: "Translation", active: settings.value.lyricsTranslation, compact: true) {
                    settings.value.lyricsTranslation.toggle()
                }
            }
        }
        .padding(.horizontal, NowPlayingScreen.padding)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The line being sung, polled while playing and on a seek, which may come while paused; reported
/// only when it changes, so the lines redraw once a line rather than every frame.
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
        // A seek lights its line whatever the pause.
        .onChange(of: player.lastSeek) { _, seek in changed(lyrics.lineIndex(at: seek.to)) }
    }
}

private struct LyricLine: View {
    let text: String
    /// Filled in as sung on the line being sung word by word; empty on the others.
    let words: [Lyrics.Word]
    /// Each shown beneath the line unless empty.
    let romanised: String, translation: String
    let lit: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if words.isEmpty {
                    Text(text)
                } else {
                    let sung = words.reduce(Text(verbatim: "")) { line, word in
                        let tagged = Text(verbatim: word.text).customAttribute(SungWord(start: word.start, end: word.end))
                        return Text("\(line)\(tagged)")
                    }
                    let end = words.reduce(0.0) { max($0, $1.start, $1.end) }
                    // 30 fps sweeps a word smoothly at half the redraws; capped at `end`, a sung line stops changing through a gap.
                    Playhead(interval: 1.0 / 30) { time in sung.textRenderer(SungFill(time: min(time, end))) }
                        .accessibilityLabel(text)
                }
            }
            // Swapped at once as a line starts or ends, so its two forms never stand together mid-fade.
            .transition(.identity)
            .scaledFont(22, weight: .bold)
            .foregroundStyle(theme.text)
            if !romanised.isEmpty { extra(romanised) }
            if !translation.isEmpty { extra(translation) }
        }
        .opacity(lit ? 1 : SungFill.dim)
        // A line filling in word by word dims its own unsung words, so it lights at once.
        .animation(words.isEmpty ? Theme.normal : nil, value: lit)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func extra(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(16, weight: .semibold)
            .foregroundStyle(theme.textSecondary)
    }
}

private nonisolated struct SungWord: TextAttribute {
    let start: Double
    let end: Double

    /// How much of the word has been sung by `time`; one without length lights once it starts.
    func fraction(at time: Double) -> Double {
        end > start ? min(max((time - start) / (end - start), 0), 1) : time >= start ? 1 : 0
    }
}

/// Draws each word dim, then lit from its start as far as it has been sung.
private nonisolated struct SungFill: TextRenderer {
    static let dim = 0.5

    let time: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                let fraction = run[SungWord.self]?.fraction(at: time) ?? 1
                guard fraction < 1 else {
                    context.draw(run)
                    continue
                }
                var unsung = context
                unsung.opacity = Self.dim
                unsung.draw(run)
                if fraction > 0 {
                    let bounds = run.typographicBounds.rect
                    let width = bounds.width * fraction
                    // From the right in right-to-left scripts; thrice the run's height, so accents are not cut.
                    let lit = CGRect(
                        x: run.layoutDirection == .rightToLeft ? bounds.maxX - width : bounds.minX, y: bounds.minY - bounds.height,
                        width: width, height: bounds.height * 3)
                    var sung = context
                    sung.clip(to: Path(lit))
                    sung.draw(run)
                }
            }
        }
    }
}
