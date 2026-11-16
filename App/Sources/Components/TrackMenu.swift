import SwiftUI
import YTMCore

struct TrackMenu: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        // The player says what it queued.
        Button("Play next") { app.player.playNext([track]) }
        Button("Add to queue") { app.player.addToQueue([track]) }
        Button("Start radio") { app.player.startRadio(from: track) }

        TrackLibraryMenu(track: track)

        Divider()
        TrackLinks(track: track)
    }
}

struct TrackLinks: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Go to artist") { app.openArtist(of: track) }
            .disabled(track.firstArtistId == nil)
        Button("Go to album") { app.openAlbum(of: track) }
            .disabled(track.album == nil)
    }
}

struct TrackLibraryMenu: View {
    let track: Track

    @Environment(AppModel.self) private var app

    var body: some View {
        if app.isSignedIn {
            Divider()
            let rating = app.rating(of: track)
            Button(rating == .like ? "Remove from liked songs" : "Like") { app.rate(track, .like) }
            Button(rating == .dislike ? "Remove dislike" : "Dislike") { app.rate(track, .dislike) }
            // Unknown for any but the playing song, so offered to clear.
            if !app.isPlaying(track) {
                Button("Remove rating") { app.rate(track, .none) }
            }
            Button("Save to playlist") { app.addToPlaylist(track) }
        }
    }
}

struct CardMenu: View {
    let card: Card

    @Environment(AppModel.self) private var app

    var body: some View {
        if card.kind != .genre {
            Button("Play") { app.play(card) }
            Button("Start radio") { app.startRadio(from: card) }
        }
    }
}
