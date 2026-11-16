import SwiftUI
import YTMCore

struct TrackTitle: View {
    let track: Track
    /// Small and without the rating buttons, so the title has room beside play
    /// and next; large under the artwork.
    let compact: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Button { app.openAlbum(of: track) } label: {
                    // Under the artwork there is room for a long title to wrap.
                    Text(track.title)
                        .font(.system(size: compact ? 16 : 22, weight: .bold))
                        .foregroundStyle(theme.text)
                        .lineLimit(compact ? 1 : 2)
                }
                .disabled(track.album == nil)
                Button { app.openArtist(of: track) } label: {
                    Text(track.artistNames)
                        .font(.system(size: compact ? 13 : 16))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                .disabled(track.firstArtistId == nil)
            }
            .buttonStyle(PressScale(scale: 0.98))
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                RatingButtons(track: track)
            }
        }
    }
}

private struct RatingButtons: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if app.isSignedIn, app.settings.value.ratingButtons {
            let rating = app.player.rating
            button(rating == .dislike ? .thumbDownFilled : .thumbDown, on: rating == .dislike, label: "Dislike") {
                app.rate(track, .dislike)
            }
            button(rating == .like ? .thumbUpFilled : .thumbUp, on: rating == .like, label: "Like") {
                app.rate(track, .like)
            }
        }
    }

    private func button(_ icon: Icon, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        IconButton(icon: icon, size: 40, iconSize: 22, colour: on ? theme.text : theme.textSecondary, action: action)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}
