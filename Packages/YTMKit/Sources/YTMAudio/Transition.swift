/// How the next item follows the current one.
public enum Transition: Equatable, Sendable {
    case gapless
    /// A fade of this many seconds.
    case crossfade(Double)
    /// A blend planned from both items' sound.
    case automix

    /// How long before the current item's end the move can begin, in song time, silence cut included, so the next
    /// item must be queued at least this early.
    public var reach: Double {
        switch self {
        case .gapless: 0
        case .crossfade(let seconds): seconds + AudioPlayer.silenceTrimSeconds
        // Room for the longest blend and the varispeed before it.
        case .automix: Automix.tailSeconds + AudioPlayer.silenceTrimSeconds
        }
    }
}

/// Where the two songs of a blend are sung, in song seconds, by their timed lyrics; nil where unknown. Only Automix
/// reads it, to keep two voices apart.
public struct Sung: Equatable, Sendable {
    public let current: [Range<Double>]?
    public let next: [Range<Double>]?

    public init(current: [Range<Double>]? = nil, next: [Range<Double>]? = nil) {
        self.current = current
        self.next = next
    }
}
