import Foundation

/// The parts of a `player` response the stream paths use: whether YouTube
/// will play the video, its audio formats and the loudness to normalise by.
/// Both the free path and the Premium path read their answers with it.
struct PlayerResponse: Sendable {
    /// The adaptive audio formats; video formats are left out.
    let formats: [Format]
    /// The player-wide loudness, for formats that carry none of their own.
    let loudnessDb: Double?

    /// Fails with YouTube's own reason when it won't play the video, such
    /// as "Sign in to confirm your age".
    init(json: JSON) throws {
        let playability = json["playabilityStatus"]
        guard let status = playability["status"].string else {
            throw YTMError(.parse, "YouTube's player sent an answer the app couldn't read.")
        }
        guard status == "OK" else {
            throw YTMError(.unplayable, playability["reason"].string ?? "YouTube won't play this (\(status)).")
        }
        formats = json["streamingData", "adaptiveFormats"].array.compactMap(Format.init(json:))
        loudnessDb = json["playerConfig", "audioConfig", "loudnessDb"].double
    }
}

/// One audio format of a player response.
struct Format: Sendable, Hashable {
    let itag: Int
    /// A plain URL, ready to download.
    let url: String?
    /// `s`, `sp` and `url`, when the URL is scrambled and needs the player
    /// script to unlock.
    let signatureCipher: String?
    /// In bits per second.
    let bitrate: Int
    /// Nil for audio the engine doesn't decode, such as HE-AAC.
    let codec: AudioCodec?
    let contentLength: Int64?
    let durationSeconds: Double?
    let loudnessDb: Double?
    /// A dynamic-range compressed variant, which sounds flattened.
    let isDrc: Bool
    let channels: Int?
    /// False for a dubbed or described track beside the original.
    let isDefaultAudio: Bool

    /// Nil for video formats and formats without an itag.
    init?(json: JSON) {
        guard let itag = json["itag"].int, let mime = json["mimeType"].string, mime.hasPrefix("audio/") else {
            return nil
        }
        self.itag = itag
        url = json["url"].string
        signatureCipher = json["signatureCipher"].string
        bitrate = json["bitrate"].int ?? 0
        codec = Self.codec(mime: mime)
        contentLength = json["contentLength"].string.flatMap { Int64($0) }
        durationSeconds = json["approxDurationMs"].double.map { $0 / 1000 }
        loudnessDb = json["loudnessDb"].double
        isDrc = json["isDrc"].bool ?? false
        channels = json["audioChannels"].int
        let track = json["audioTrack"]
        isDefaultAudio = track.exists ? track["audioIsDefault"].bool ?? false : true
    }

    /// Opus in WebM, or AAC-LC in MP4. The quotes keep out `mp4a.40.29`;
    /// HE-AAC (`mp4a.40.5`, itag 139) is left out as ytm-native leaves it,
    /// so every quality plays the same files on both.
    private static func codec(mime: String) -> AudioCodec? {
        if mime.hasPrefix("audio/webm"), mime.contains("opus") { return .opus }
        if mime.hasPrefix("audio/mp4"), mime.contains("\"mp4a.40.2\"") { return .aac }
        return nil
    }
}

/// The highest-bitrate Opus format, else the best AAC, as ytm-native's
/// `best_audio`. Skips dynamic-range compressed variants, dubbed tracks and
/// surround mixes. With `maxKbps`, the best within it, or the lowest there
/// is when none fits. Scrambled formats count, so the Premium path can pick
/// 774 and 141; the free path then takes only a plain URL.
func bestAudio(_ formats: [Format], maxKbps: Int?) -> Format? {
    func pick(_ codec: AudioCodec) -> Format? {
        let candidates = formats.filter { format in
            format.codec == codec
                && (format.url != nil || format.signatureCipher != nil)
                && !format.isDrc
                && format.channels.map { $0 <= 2 } ?? true
                && format.isDefaultAudio
        }
        let within = maxKbps.map { kbps in candidates.filter { $0.bitrate <= kbps * 1000 } } ?? candidates
        return within.max { ($0.bitrate, $0.itag) < ($1.bitrate, $1.itag) }
            ?? candidates.min { $0.bitrate < $1.bitrate }
    }
    return pick(.opus) ?? pick(.aac)
}

/// The stream to play from one of `response`'s formats, downloaded as the
/// client that asked, whose User-Agent googlevideo checks.
func makeStream(_ format: Format, url: URL, userAgent: String, response: PlayerResponse, isPremium: Bool) -> ResolvedStream {
    ResolvedStream(
        url: url,
        headers: ["User-Agent": userAgent],
        itag: format.itag,
        codec: format.codec ?? .aac,
        contentLength: format.contentLength ?? 0,
        bitrate: format.bitrate,
        duration: format.durationSeconds,
        loudnessDb: format.loudnessDb ?? response.loudnessDb,
        isPremium: isPremium
    )
}
