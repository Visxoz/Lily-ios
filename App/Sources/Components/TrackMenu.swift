import SwiftUI
import YTMCore

/// The one menu every track has, wherever it shows, as ytm-native's track row
/// menu: queueing, the radio, rating and saving (signed in), and its artist
/// and album.
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

/// A track's artist and album, which the player's menu offers too.
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

/// The signed-in part of a track's menu, rating and saving it, which the
/// queue's rows offer too.
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

/// A card's menu, as ytm-native's: play it, or a radio from it.
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
