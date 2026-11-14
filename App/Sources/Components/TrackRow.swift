import SwiftUI
import YTMCore

/// ytm-native's `TrackRow` (`page/track-row.slint`): the number, or the
/// equaliser while it plays; the artwork unless the list is numbered (an
/// album's); the title, in the accent while playing, over the artists; the
/// menu button; and the length, when known. Tapping plays; holding opens the
/// same menu.
///
/// The album column ytm-native shows on wide windows has no room here, and
/// the menu button, which ytm-native shows on hover, sits tight against the
/// length, so the title keeps the room.
struct TrackRow: View {
    let track: Track
    let number: Int
    let numbered: Bool
    let play: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let playing = app.isPlaying(track)
        let length = track.duration.map(Formatting.duration)
        Button(action: play) {
            HStack(spacing: Metrics.rowSpacing) {
                Group {
                    if playing {
                        PlayingEqualizer()
                    } else {
                        Text(number, format: .number.grouping(.never))
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .frame(width: Metrics.rowNumber)

                if !numbered {
                    ArtworkView(url: track.thumbnail, size: Metrics.rowArt)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(playing ? theme.accent : theme.text)
                    Text(track.artistNames)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 0) {
                    // Room for the menu button laid over the row.
                    Color.clear.frame(width: Metrics.rowMore)
                    if let length {
                        Text(length)
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: Metrics.rowDuration, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, Metrics.rowPadding)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .overlay(alignment: .trailing) {
            Menu {
                TrackMenu(track: track)
            } label: {
                IconView(icon: .more, size: 20, colour: theme.textSecondary)
                    .frame(width: Metrics.rowMore, height: Metrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
            .padding(.trailing, Metrics.rowPadding + (length == nil ? 0 : Metrics.rowDuration))
        }
        .contextMenu { TrackMenu(track: track) }
    }
}

/// The equaliser of the playing row, apart so that play and pause redraw
/// this alone rather than every row.
struct PlayingEqualizer: View {
    var colour: Color?

    @Environment(AppModel.self) private var app

    var body: some View {
        Equalizer(active: app.player.isPlaying, colour: colour)
    }
}

/// The column labels above an album's or playlist's track list.
struct TrackColumns: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            Text("#")
                .frame(width: Metrics.rowNumber)
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            IconView(icon: .clock, size: 16, colour: theme.textSecondary)
                .frame(width: Metrics.rowDuration, alignment: .trailing)
        }
        .font(.system(size: 14))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, Metrics.rowPadding)
        .frame(height: Metrics.columnsHeight)
        .overlay(alignment: .bottom) {
            theme.divider.frame(height: 1)
        }
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }
}
