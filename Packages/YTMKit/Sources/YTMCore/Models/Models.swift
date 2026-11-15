import Foundation

// The pages and items the UI shows, independent of InnerTube's shapes.
// Every model is a value type, Sendable and Codable, so it crosses actors
// freely and can be saved as is (session, history, the cached Home feed).

public struct ArtistRef: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AlbumRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Track: Codable, Hashable, Sendable, Identifiable {
    /// The video ID.
    public var id: String
    public var title: String
    public var artists: [ArtistRef]
    public var album: AlbumRef?
    /// Length in seconds, when YouTube said.
    public var duration: Int?
    /// Square artwork, at row size; `ImagePipeline` decodes it at any pixel edge.
    public var thumbnail: String?
    public var trackNumber: Int?
    /// A music video, which may have a song version: audio only, and the
    /// rendition YouTube Music itself plays.
    public var isVideo: Bool
    /// The entry's ID within a playlist, which removing it needs.
    public var setVideoId: String?

    public init(
        id: String, title: String, artists: [ArtistRef] = [], album: AlbumRef? = nil,
        duration: Int? = nil, thumbnail: String? = nil, trackNumber: Int? = nil,
        isVideo: Bool = false, setVideoId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.thumbnail = thumbnail
        self.trackNumber = trackNumber
        self.isVideo = isVideo
        self.setVideoId = setVideoId
    }

    public var artistNames: String { ArtistRef.joined(artists) }
    public var firstArtistId: String? { artists.lazy.compactMap(\.id).first }
    public var seconds: Double { Double(duration ?? 0) }
}

extension ArtistRef {
    /// "A, B, C", as ytm-native's `join_artists` words several artists.
    public static func joined(_ artists: [ArtistRef]) -> String {
        artists.lazy.map(\.name).joined(separator: ", ")
    }
}

public enum CardKind: String, Codable, Hashable, Sendable {
    case album, playlist, artist, genre
    /// A single song, played with a radio after it.
    case song
}

public struct Card: Codable, Hashable, Sendable, Identifiable {
    public var kind: CardKind
    /// Browse ID of an album or artist, playlist ID, genre params, or the
    /// video ID of a song.
    public var id: String
    public var title: String
    public var subtitle: String
    public var thumbnail: String?
    /// Genre chips carry YouTube's colour for them, as 0xRRGGBB.
    public var color: UInt32?
    /// The song a song card plays.
    public var track: Track?

    public init(
        kind: CardKind, id: String, title: String, subtitle: String = "",
        thumbnail: String? = nil, color: UInt32? = nil, track: Track? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
        self.color = color
        self.track = track
    }

    /// The page the card opens, if it opens one rather than playing.
    public var route: Route? {
        switch kind {
        case .album: .album(id)
        case .playlist: .playlist(id)
        case .artist: .artist(id)
        case .genre: .genre(id)
        case .song: nil
        }
    }
}

/// How tapping one track of a section fills the queue.
public enum QueueMode: String, Codable, Hashable, Sendable {
    /// Queue the whole section from the tapped track.
    case section
    /// Play the track, then a radio based on it.
    case radio
}

public enum CardLayout: String, Codable, Hashable, Sendable {
    case carousel, grid, chips
    /// One large card for the best search match.
    case top
    /// YouTube Music's Speed dial: pages of three by three tiles.
    case speedDial
}

public struct TrackSection: Codable, Hashable, Sendable {
    public var title: String
    public var tracks: [Track]
    public var mode: QueueMode
    /// Album pages show track numbers instead of artwork.
    public var numbered: Bool
    /// "More" opens this, as on artist pages' songs.
    public var more: Route?

    public init(title: String, tracks: [Track], mode: QueueMode, numbered: Bool = false, more: Route? = nil) {
        self.title = title
        self.tracks = tracks
        self.mode = mode
        self.numbered = numbered
        self.more = more
    }
}

public struct CardSection: Codable, Hashable, Sendable {
    public var title: String
    public var cards: [Card]
    public var layout: CardLayout
    public var more: Route?

    public init(title: String, cards: [Card], layout: CardLayout, more: Route? = nil) {
        self.title = title
        self.cards = cards
        self.layout = layout
        self.more = more
    }
}

public enum Section: Codable, Hashable, Sendable {
    case tracks(TrackSection)
    case cards(CardSection)

    public var title: String {
        switch self {
        case .tracks(let s): s.title
        case .cards(let s): s.title
        }
    }

    /// Where the section's "More" leads.
    public var more: Route? {
        switch self {
        case .tracks(let s): s.more
        case .cards(let s): s.more
        }
    }

    /// Empty sections are not worth a row.
    static func tracks(_ title: String, _ tracks: [Track], mode: QueueMode, numbered: Bool = false, more: Route? = nil) -> Section? {
        tracks.isEmpty ? nil : .tracks(TrackSection(title: title, tracks: tracks, mode: mode, numbered: numbered, more: more))
    }

    static func cards(_ title: String, _ cards: [Card], layout: CardLayout, more: Route? = nil) -> Section? {
        cards.isEmpty ? nil : .cards(CardSection(title: title, cards: cards, layout: layout, more: more))
    }
}

public struct PageHeader: Codable, Hashable, Sendable {
    /// "Album", "Single", "Playlist", "Artist"…, shown above the title.
    public var label: String
    public var title: String
    public var subtitle: String
    /// Counts and lengths: "12 songs • 43 min".
    public var meta: String
    public var description: String?
    public var thumbnail: String?
    /// Artists show a wide image behind the title.
    public var banner: Bool
    /// Playlist whose tracks Shuffle loads when the page's are incomplete.
    public var shufflePlaylistId: String?
    public var radioId: String?
    /// Albums and playlists that can be added to the library.
    public var playlistId: String?
    /// A playlist the signed-in user owns, so its tracks can be removed.
    public var editable: Bool

    public init(
        label: String = "", title: String, subtitle: String = "", meta: String = "",
        description: String? = nil, thumbnail: String? = nil,
        banner: Bool = false, shufflePlaylistId: String? = nil, radioId: String? = nil,
        playlistId: String? = nil, editable: Bool = false
    ) {
        self.label = label
        self.title = title
        self.subtitle = subtitle
        self.meta = meta
        self.description = description
        self.thumbnail = thumbnail
        self.banner = banner
        self.shufflePlaylistId = shufflePlaylistId
        self.radioId = radioId
        self.playlistId = playlistId
        self.editable = editable
    }
}

/// What a page still has to fetch after it shows; `YTMusic.loadMore`
/// fetches one step of it at a time.
public enum Continuation: Codable, Hashable, Sendable {
    /// The rest of a long playlist's tracks.
    case tracks(token: String, sectionIndex: Int)
    /// The Home feed's further shelves, with those read but held back
    /// until the ones above them in `HomeFeed.shelfOrder` arrive.
    case shelves(token: String, pagesLeft: Int, held: [Section])
}

public struct Page: Codable, Hashable, Sendable {
    public var header: PageHeader?
    public var sections: [Section]
    public var more: Continuation?

    public init(header: PageHeader? = nil, sections: [Section], more: Continuation? = nil) {
        self.header = header
        self.sections = sections
        self.more = more
    }

    /// What the header's Play and Shuffle buttons queue: the page's track
    /// list, which comes first.
    public var headerTracks: [Track] {
        guard header != nil, case .tracks(let s)? = sections.first else { return [] }
        return s.tracks
    }
}

public enum Route: Codable, Hashable, Sendable {
    case home, explore, library, history
    case search(String)
    case album(String)
    case playlist(String)
    case artist(String)
    /// A mood or genre, by its browse params.
    case genre(String)
    /// The signed-in library's sub-lists.
    case libraryPlaylists, libraryAlbums, libraryArtists, librarySongs
    /// "More" on an artist's discography or a Home shelf: a browse ID and
    /// its params.
    case browse(id: String, params: String?)
    /// Explore's sub-pages.
    case newReleases, charts, moodsAndGenres

    /// Liked music, an auto playlist.
    public static let likedSongs = Route.playlist(BuiltInPlaylist.likedMusic)
}

/// YouTube Music's built-in playlists, by ID.
enum BuiltInPlaylist {
    /// Liked music, an auto playlist.
    static let likedMusic = "LM"
    /// Episodes for later, a podcast page, which doesn't open as a playlist.
    static let episodesForLater = "SE"
    /// The "Shuffle all" row.
    static let shuffleAll = "MLCT"
    /// The rows list items skip, as rustypipe does.
    static let skippedInLists: Set = [likedMusic, shuffleAll, episodesForLater]
}

/// A song's thumbs, as the account rated it.
public enum Rating: String, Codable, Hashable, Sendable {
    case none = "INDIFFERENT"
    case like = "LIKE"
    case dislike = "DISLIKE"
}

/// One of the user's playlists, offered by "Save to playlist".
public struct PlaylistOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var thumbnail: String?
    /// The song is in it already.
    public var contains: Bool

    public init(id: String, title: String, thumbnail: String? = nil, contains: Bool = false) {
        self.id = id
        self.title = title
        self.thumbnail = thumbnail
        self.contains = contains
    }
}

/// Lyrics line by line, timed where YouTube has them so.
public struct Lyrics: Codable, Hashable, Sendable {
    public var lines: [String]
    /// Each line's start in seconds when synced, else empty.
    public var starts: [Double]
    /// Where they come from, such as "Source: Musixmatch".
    public var source: String

    public init(lines: [String], starts: [Double] = [], source: String = "") {
        self.lines = lines
        self.starts = starts
        self.source = source
    }

    public var isSynced: Bool { !starts.isEmpty && starts.count == lines.count }

    /// The line playing at `time`, for synced lyrics.
    public func lineIndex(at time: Double) -> Int? {
        guard isSynced else { return nil }
        // Binary search: the last start at or before `time`.
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}

/// The signed-in account, as shown in Settings.
public struct Account: Codable, Hashable, Sendable {
    public var name: String
    public var handle: String?
    public var photo: String?

    public init(name: String, handle: String? = nil, photo: String? = nil) {
        self.name = name
        self.handle = handle
        self.photo = photo
    }
}

/// How much of a stream to ask for. Low and Normal cap the bitrate, for
/// metered connections; High takes the best YouTube offers, which is 256
/// kbps Opus when signed in with Premium.
public enum AudioQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case low, normal, high

    /// The highest bitrate wanted, or nil for the best there is. YouTube's
    /// Opus streams come at about 50, 70 and 130 kbps.
    public var maxKbps: Int? {
        switch self {
        case .low: 64
        case .normal: 192
        case .high: nil
        }
    }
}

public enum AudioCodec: String, Codable, Hashable, Sendable {
    /// In WebM, 48 kHz.
    case opus
    /// AAC-LC or HE-AAC in fragmented MP4.
    case aac
}

/// A playable stream, chosen from the player endpoint's formats.
public struct ResolvedStream: Codable, Hashable, Sendable {
    public var url: URL
    /// Headers the download must send, as the client that asked.
    public var headers: [String: String]
    public var itag: Int
    public var codec: AudioCodec
    public var contentLength: Int64
    public var bitrate: Int
    public var duration: Double?
    /// YouTube's loudness measure in dB, for normalising.
    public var loudnessDb: Double?
    /// A Premium format (774 or 141). Free formats the web client gives a
    /// Premium account are not.
    public var isPremium: Bool

    public init(
        url: URL, headers: [String: String], itag: Int, codec: AudioCodec,
        contentLength: Int64, bitrate: Int, duration: Double?, loudnessDb: Double?,
        isPremium: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.itag = itag
        self.codec = codec
        self.contentLength = contentLength
        self.bitrate = bitrate
        self.duration = duration
        self.loudnessDb = loudnessDb
        self.isPremium = isPremium
    }

    /// The player's badge, as ytm-native's `quality_label`: "OPUS 165", with
    /// Premium formats at YouTube's nominal 256 kbps rather than their bitrate.
    public var badge: String {
        let kbps = PremiumResolver.premiumItags.contains(itag) ? 256 : (bitrate + 500) / 1000
        return "\(codec.rawValue.uppercased()) \(kbps)"
    }
}

/// What the app does with a failure it shows: a sentence, never a URL or
/// cookie.
public struct YTMError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        case network, http, parse, unplayable, notSignedIn, notFound, refused
    }

    public var kind: Kind
    public var message: String
    /// The HTTP status, when the failure was one.
    public var status: Int?

    public init(_ kind: Kind, _ message: String, status: Int? = nil) {
        self.kind = kind
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

/// The sentence to show for a failure: YTMCore's own words, or the system's.
public func sentence(for error: any Error) -> String {
    (error as? YTMError)?.message ?? error.localizedDescription
}
