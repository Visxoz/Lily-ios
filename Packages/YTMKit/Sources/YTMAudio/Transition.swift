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
        case .automix: Automix.maxSeconds + AudioPlayer.silenceTrimSeconds
        }
    }
}
