import Foundation
@testable import YTMCore

/// The YouTube Music every check talks to: signed out, with a throwaway
/// store, so the Mac's own app state is never read or changed and the
/// visitor ID and player script are fetched afresh, as on a first launch.
enum Live {
    static let directory = URL.temporaryDirectory.appending(path: "ytmcheck-\(UUID().uuidString)", directoryHint: .isDirectory)
    static let store = FileStore(directory: directory.appending(path: "store", directoryHint: .isDirectory))
    static let api = YTMusic(auth: GoogleAuth(), store: store)

    /// Songs (audio tracks, not music videos) that have been on YouTube
    /// Music for years, each with lyrics, with their lengths in seconds.
    static let songs = [
        Song(id: "4D7u5KF7SP8", title: "Get Lucky (feat. Pharrell Williams and Nile Rodgers)", artist: "Daft Punk", seconds: 370),
        Song(id: "J7p4bzqLvCw", title: "Blinding Lights", artist: "The Weeknd", seconds: 202),
        Song(id: "BSTsnWoslP4", title: "Bohemian Rhapsody", artist: "Queen", seconds: 355),
    ]
    /// A music video, and the song it is the video of.
    static let musicVideo = Song(id: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", artist: "Rick Astley", seconds: 213)
    static let songOfVideo = "lYBUbBu4W08"
    /// Random Access Memories: 13 tracks.
    static let album = "MPREb_K8qWMWVqXGi"
    static let albumTracks = 13
    /// An alias of Daft Punk's channel, which redirects to the artist's own.
    static let artistAlias = "UC_kRDKYrUlrbtrSiyu5Tflg"
    static let artist = "UCRr1xG_2WIDs18a6cIiCxeA"
    /// YouTube Music's own "Presenting Daft Punk".
    static let playlist = "RDCLAK5uy_n20FRYQXNt1p1wS55Nj2r14IouO5we"
    /// Longer than a batch (100), so it loads in several.
    static let longPlaylist = "PLMC9KNkIncKtPzgY-5rmhvj7fax8fdxoj"

    /// Checks run signed out, so they never touch an account; a Mac that
    /// somehow holds the app's Keychain session is refused rather than used.
    static func requireSignedOut() async -> Bool {
        await !api.auth.isSignedIn
    }
}

struct Song: Sendable {
    let id: String
    let title: String
    let artist: String
    let seconds: Int

    var name: String { "\(artist), \(title)" }

    /// As a list would give it, for the calls that take a track.
    var track: Track {
        Track(id: id, title: title, artists: [ArtistRef(id: nil, name: artist)], duration: seconds, isVideo: id == Live.musicVideo.id)
    }
}
