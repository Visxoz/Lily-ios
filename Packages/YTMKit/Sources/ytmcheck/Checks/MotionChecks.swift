import AVFoundation
import Foundation
@testable import YTMCore

/// Apple Music's moving covers: one found, downloaded and playable, and none for a made-up album by a real artist.
enum MotionChecks {
    /// In the run's own folder, and the UK's catalogue whatever this Mac's region.
    static let artwork = MotionArtwork(directory: Live.directory.appending(path: "motion", directoryHint: .isDirectory), storefront: "gb")

    static func run(_ report: Report) async {
        await report.check("motion SZA, SOS") { findings in
            let snooze = Track(id: "snooze", title: "Snooze", artists: [ArtistRef(id: nil, name: "SZA")], album: AlbumRef(id: "sos", name: "SOS"))
            // Before the clip, as for an album new to the phone, so it is Apple's.
            guard let still = await artwork.still(.tall, for: snooze, fetching: true, cellular: true) else {
                return findings.fail("SOS: the tall still didn't download")
            }
            findings.expect(abs(Double(still.width) / Double(still.height) - 0.75) < 0.01, "SOS: a still of \(still.width)x\(still.height), not 3:4")
            findings.note("SOS: tall still of \(still.width)x\(still.height)")
            guard let clip = await artwork.video(.tall, for: snooze, cellular: true) else {
                return findings.fail("SOS: the tall clip didn't download")
            }
            let (videos, seconds) = try await inspect(clip)
            findings.expect(videos > 0, "SOS: no video track")
            findings.expect(seconds > 5, "SOS: \(seconds) s long")
            let size = (try? clip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            findings.note("SOS: tall clip of \(size >> 10) KB, \(Int(seconds)) s")
        }

        await report.check("motion made-up album") { findings in
            let track = Track(id: "made-up", title: "Snooze", artists: [ArtistRef(id: nil, name: "SZA")], album: AlbumRef(id: "made-up", name: "Quiet Marmalade Afternoons"))
            let found = await artwork.video(.tall, for: track, cellular: true)
            findings.expect(found == nil, "a made-up album has a cover")
        }
    }

    /// Off the main actor, as an asset isn't Sendable and its loads aren't isolated to it.
    @concurrent
    private static func inspect(_ clip: URL) async throws -> (videos: Int, seconds: Double) {
        let asset = AVURLAsset(url: clip)
        let videos = try await asset.loadTracks(withMediaType: .video).count
        return (videos, try await asset.load(.duration).seconds)
    }
}
