import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
}

/// Smart shuffle mixes recommended songs in; it is a kind of shuffle, so it
/// goes off with it.
public enum ShuffleMode: String, Codable, CaseIterable, Sendable {
    case off, on, smart
}

/// The app's colours: dark, light, or pure black for OLED screens.
public enum Look: String, Codable, CaseIterable, Sendable {
    case dark, light, black
}

/// The colour of active controls: one of a few, or one taken from the
/// playing song's artwork. In the order Settings offers them.
public enum Accent: String, Codable, CaseIterable, Sendable {
    case red, orange, green, teal, blue, purple, pink, artwork

    /// As `0xRRGGBB`, or nil for the artwork's, which changes with the song.
    public var rgb: UInt32? {
        switch self {
        case .red: 0xff0033  // YouTube Music's red
        case .orange: 0xff6a13
        case .green: 0x1db954
        case .teal: 0x00a89d
        case .blue: 0x3d7bff
        case .purple: 0x9b5cff
        case .pink: 0xf0458f
        case .artwork: nil
        }
    }

    public var name: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .green: "Green"
        case .teal: "Teal"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .artwork: "From the artwork"
        }
    }
}

/// The user's preferences, saved as settings.json.
public struct Settings: Codable, Equatable, Sendable {
    /// YTMCore cannot see YTMAudio's EqualiserBands, so its band count is repeated here and checked by a test.
    static let equaliserBands = 6

    public var muted = false
    public var quality: AudioQuality = .high
    public var normalise = true
    /// Fade each track into the next, rather than playing them gaplessly.
    public var crossfade = false
    public var autoplay = true
    public var shuffle: ShuffleMode = .off
    public var repeatMode: RepeatMode = .off
    public var equaliserEnabled = false
    /// Each band's gain in dB, kept while the equaliser is off.
    public var equaliserGains: [Float] = Array(repeating: 0, count: Settings.equaliserBands)
    /// Report songs played to the signed-in account's YouTube history.
    public var youtubeHistory = true
    /// Show like and dislike buttons beside the song playing.
    public var ratingButtons = true
    public var look: Look = .dark
    public var accent: Accent = .red
    /// The account has been served Premium formats, so songs without them (music videos) never mark it as not Premium.
    public var premiumAccount = false
    /// The account was taken as without Premium: songs start on the free stream while a background check confirms it.
    public var noPremium = false

    public init() {}

    /// Reads each setting on its own, so one that can't be read (a value
    /// from a newer version, say) goes back to its default alone rather than
    /// taking an opt-out such as `youtubeHistory` with it.
    public init(from decoder: any Decoder) throws {
        self.init()
        let file = try decoder.container(keyedBy: CodingKeys.self)
        file.read(&muted, .muted)
        file.read(&quality, .quality)
        file.read(&normalise, .normalise)
        file.read(&crossfade, .crossfade)
        file.read(&autoplay, .autoplay)
        file.read(&shuffle, .shuffle)
        file.read(&repeatMode, .repeatMode)
        file.read(&equaliserEnabled, .equaliserEnabled)
        file.read(&equaliserGains, .equaliserGains) { $0.count == Self.equaliserBands }
        file.read(&youtubeHistory, .youtubeHistory)
        file.read(&ratingButtons, .ratingButtons)
        file.read(&look, .look)
        file.read(&accent, .accent)
        file.read(&premiumAccount, .premiumAccount)
        file.read(&noPremium, .noPremium)
    }
}

extension KeyedDecodingContainer {
    /// Overwrites `value` with the key's, when present, readable and `valid`;
    /// otherwise leaves it, which is the default.
    func read<T: Decodable>(_ value: inout T, _ key: Key, valid: (T) -> Bool = { _ in true }) {
        if let decoded = try? decodeIfPresent(T.self, forKey: key), valid(decoded) {
            value = decoded
        }
    }
}
