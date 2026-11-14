import Foundation

/// A stream for the engine to play: where its bytes are, and how to ask for
/// them again should the server refuse the URL part way through.
public struct AudioItem: Sendable {
    /// Stable for one entry of the queue, so events name the entry they concern.
    public let id: String
    public let url: URL
    /// Headers every request for the file must carry.
    public let headers: [String: String]
    /// The file's length in bytes, or 0 when the server did not say.
    public let contentLength: Int64
    /// Names the file in the disk cache, so the same encode plays from there next time.
    public let cacheKey: String
    /// The correction for the file's loudness in dB, applied while the
    /// player normalises.
    public let loudnessDB: Float
    /// A fresh URL for the same file, asked for when the old one is refused.
    public let refresh: @Sendable () async throws -> URL

    public init(
        id: String,
        url: URL,
        headers: [String: String],
        contentLength: Int64,
        cacheKey: String,
        loudnessDB: Float,
        refresh: @escaping @Sendable () async throws -> URL
    ) {
        self.id = id
        self.url = url
        self.headers = headers
        self.contentLength = contentLength
        self.cacheKey = cacheKey
        self.loudnessDB = loudnessDB
        self.refresh = refresh
    }

    /// The loudness correction as a factor on the samples.
    var loudnessGain: Float { pow(10, loudnessDB / 20) }
}

public enum AudioEvent: Sendable, Equatable {
    /// The first sound of an item started by `play`.
    case started(id: String)
    /// The next item became the one heard, with no gap or as a crossfade began.
    case advanced(id: String)
    /// The last item ended with nothing queued after it.
    case finished
    /// The item could not play. For the item queued by `setNext`, it was dropped
    /// and the current one ends with `finished`, so the next loads afresh.
    case failed(id: String, message: String)
    /// Whether the sound is waiting on the network.
    case buffering(Bool)
    /// A seek in the current item dropped the next one, which had already
    /// started following it; queue it again with `setNext`.
    case nextDropped
}
