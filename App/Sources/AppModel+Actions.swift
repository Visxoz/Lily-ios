import Foundation
import YTMCore

/// A page header's buttons.
enum HeaderAction {
    case play, shuffle, radio
}

/// Starting playback and the menus' actions from pages, as ytm-native's
/// `actions.rs` and `library.rs`.
extension AppModel {
    /// A card opens its page; a song card plays, with a radio after it.
    func activate(_ card: Card, displayScale: CGFloat) {
        guard let route = card.route else { return play(card) }
        switch route {
        case .album, .playlist:
            // The header's cover is the card's, so its fetch overlaps the page's rather than following it.
            // An artist's header is a wide banner, never the card's square, so it isn't fetched ahead.
            if let url = card.thumbnail {
                let pixels = ArtworkImage.pixels(edge: Metrics.headerArt, scale: displayScale)
                Task { _ = await ImagePipeline.shared.image(for: url, pixelEdge: pixels) }
            }
        default:
            break
        }
        open(route)
    }

    func play(_ card: Card) {
        Task { await player.play(card) }
    }

    /// A card's "Start radio": a playlist's own radio, else one from its
    /// first song.
    func startRadio(from card: Card) {
        Task { await player.startRadio(from: card) }
    }

    /// The header's Play, Shuffle and Radio.
    func perform(_ action: HeaderAction, on page: Page) {
        Task {
            switch action {
            case .play: await player.play(page)
            case .shuffle: await player.play(page, shuffle: true)
            case .radio:
                if let radio = page.header?.radioId { await player.startRadio(playlistId: radio) }
            }
        }
    }

    func isPlaying(_ track: Track) -> Bool {
        player.current?.id == track.id
    }

    /// How the account rated `track`: only the playing song's is known.
    func rating(of track: Track) -> Rating {
        isPlaying(track) ? player.rating : .none
    }

    /// Likes or dislikes a song, or takes that back if it had it; `.none`
    /// removes either. The player does the toggling and says how it went,
    /// and skips a disliked song that is playing.
    func rate(_ track: Track, _ requested: Rating) {
        player.rate(requested, videoId: track.id)
    }

    func addToPlaylist(_ track: Track) {
        // From Now Playing the picker stacks on it, as ytm-native's dialog sits over its player bar and panel.
        if sheet == .nowPlaying { nowPlayingPicker = track } else { sheet = .addToPlaylist(track) }
    }

    func openArtist(of track: Track) {
        if let id = track.firstArtistId { open(.artist(id)) }
    }

    func openAlbum(of track: Track) {
        if let album = track.album { open(.album(album.id)) }
    }
}
