import YTMCore

/// The playing song's lyrics, as far as they have loaded. They load while
/// `PlayerController.showsLyrics` is set, as ytm-native loads them while its
/// Lyrics tab is open.
public enum LyricsState: Equatable, Sendable {
    /// Not asked for yet, or nothing is playing.
    case idle
    case loading
    /// The song has none.
    case unavailable
    case loaded(Lyrics)
    /// The sentence to show, such as "Couldn't load lyrics: You're offline."
    case failed(String)

    /// What the lyrics panel says in place of lyrics, in ytm-native's
    /// words; nil while loading or once loaded.
    public var message: String? {
        switch self {
        case .idle: "Play something to see its lyrics."
        case .unavailable: "Lyrics aren't available for this song."
        case .failed(let message): message
        case .loading, .loaded: nil
        }
    }
}
