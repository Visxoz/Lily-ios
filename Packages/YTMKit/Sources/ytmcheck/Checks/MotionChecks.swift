import AVFoundation
import Foundation
@testable import YTMCore

/// Moving art: an Apple cover found and playable, none for a made-up album by a real artist, and a Canvas given a cookie.
enum MotionChecks {
    /// In the run's own folder, and the UK's catalogue whatever this Mac's region.
    static let artwork = MotionArtwork(directory: Live.directory.appending(path: "motion", directoryHint: .isDirectory), storefront: "gb")

    static func run(_ report: Report) async {
        await report.check("motion SZA, SOS") { findings in
            let snooze = Track(id: "snooze", title: "Snooze", artists: [ArtistRef(id: nil, name: "SZA")], album: AlbumRef(id: "sos", name: "SOS"))
            // Not fetching, so Spotify isn't asked and the source is Apple's.
            guard let source = await artwork.source(.tall, for: snooze, fetching: false, cellular: true) else {
                return findings.fail("SOS: no tall source")
            }
            // Before the clip, as for an album new to the phone, so it is Apple's.
            guard let still = await artwork.still(source, fetching: true, cellular: true) else {
                return findings.fail("SOS: the tall still didn't download")
            }
            findings.expect(abs(Double(still.width) / Double(still.height) - 0.75) < 0.01, "SOS: a still of \(still.width)x\(still.height), not 3:4")
            findings.note("SOS: tall still of \(still.width)x\(still.height)")
            guard let clip = await artwork.video(source, cellular: true) else {
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
            guard let source = await artwork.source(.tall, for: track, fetching: false, cellular: true) else {
                return findings.fail("made-up album: no tall source")
            }
            let found = await artwork.video(source, cellular: true)
            findings.expect(found == nil, "a made-up album has a cover")
        }

        await report.check("motion Spotify Canvas") { findings in
            guard let cookie = ProcessInfo.processInfo.environment["LILY_SP_DC"], !cookie.isEmpty else {
                return findings.note("skipped: no LILY_SP_DC")
            }
            try await artwork.signInToSpotify(cookie: cookie)
            let snooze = Track(id: "snooze", title: "Snooze", artists: [ArtistRef(id: nil, name: "SZA")], album: AlbumRef(id: "sos", name: "SOS"), duration: 202)
            let source = await artwork.source(.tall, for: snooze, fetching: true, cellular: true)
            let clip = if let source { await artwork.video(source, cellular: true) } else { nil as URL? }
            // Not left in this Mac's keychain.
            await artwork.signOutOfSpotify()
            findings.expect(source?.name == "snooze-canvas", "Snooze: the tall source isn't its Canvas")
            guard let clip else { return findings.fail("Snooze: the Canvas didn't download") }
            let (videos, seconds) = try await inspect(clip)
            findings.expect(videos > 0, "Snooze: no video track in the Canvas")
            let size = (try? clip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            findings.note("Snooze: a Canvas of \(size >> 10) KB, \(Int(seconds)) s")
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
