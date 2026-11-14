import Foundation

extension YTMusic {
    /// The free path: plain-URL clients, best_audio within the quality's cap (Opus first, AAC after).
    @concurrent
    public func stream(videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        try await StreamResolver(innerTube: innerTube).resolve(videoId: videoId, maxKbps: quality.maxKbps)
    }
}
