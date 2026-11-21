import Foundation
@testable import YTMAudio
@testable import YTMCore

/// Real songs streamed through the engine and rendered offline.
enum AudioChecks {
    /// Seconds YouTube's stated length may be from the decoded one.
    static let statedTolerance = 0.25
    /// The most a run may take, downloads and all.
    static let timeLimit: Duration = .seconds(240)

    static func run(_ report: Report) async {
        await report.check("audio Opus, gapless") { findings in
            let first = Live.songs[1], second = Live.songs[2]
            let items = [
                item(first, stream: try await Live.api.stream(videoId: first.id, quality: .high)),
                item(second, stream: try await Live.api.stream(videoId: second.id, quality: .high)),
            ]
            try await play(items, &findings)
        }

        await report.check("audio AAC") { findings in
            let song = Live.songs[0]
            let resolver = StreamResolver(innerTube: Live.api.innerTube)
            let response = try PlayerResponse(json: await resolver.player(videoId: song.id, as: .visionOS))
            guard let format = bestAudio(response.formats.filter { $0.codec == .aac && $0.url != nil }, maxKbps: nil),
                  let url = format.url.flatMap(URL.init(string:)), HTTP.isAllowed(url)
            else { return findings.fail("no plain AAC format among itags \(response.formats.map(\.itag))") }
            let stream = makeStream(format, url: url, userAgent: ClientProfile.visionOS.userAgent, response: response, isPremium: false)
            try await play([item(song, stream: stream)], &findings)
        }
    }

    /// Built as the player controller builds one, so the check covers the same path.
    private static func item(_ song: Song, stream: ResolvedStream) -> Entry {
        let itag = stream.itag
        let item = AudioItem(
            id: song.id, url: stream.url, headers: stream.headers, contentLength: stream.contentLength,
            cacheKey: "\(song.id)-\(itag)", loudnessDB: -Float(max(stream.loudnessDb ?? 0, 0))
        ) { _ in
            let fresh = try await Live.api.stream(videoId: song.id, quality: .high, itag: itag)
            guard fresh.itag == itag, HTTP.isAllowed(fresh.url) else { throw YTMError(.unplayable, "The refreshed stream isn't the same file.") }
            return (url: fresh.url, headers: fresh.headers)
        }
        return Entry(song: song, stream: stream, item: item)
    }

    /// Each item's buffers must cover it exactly, frame for frame, and follow
    /// the one before on the same player timeline, with no gap.
    private static func play(_ entries: [Entry], _ findings: inout Findings) async throws {
        let playback = OfflineEngine(cache: Live.directory.appending(path: "audio", directoryHint: .isDirectory))
        let items = entries.map(\.item)
        playback.engine.send { engine in
            engine.play(items[0], from: 0, paused: false, session: 1)
            if items.count > 1 { engine.setNext(items[1], fade: 0, session: 1) }
        }
        var buffers = Set<OfflineEngine.Buffer>()
        var lengths: [String: (frames: Int64, rate: Double)] = [:]
        var rendered = 0
        let clock = ContinuousClock()
        let started = clock.now
        while clock.now - started < timeLimit {
            try Task.checkCancellation()
            let step = await playback.step()
            buffers.formUnion(step.scheduled)
            rendered += step.frames
            if let id = step.heard {
                lengths[id] = step.length ?? lengths[id]
            } else if !step.gap, playback.events.contains(where: \.ends) {
                break
            }
        }
        let elapsed = clock.now - started

        let events = playback.events.filter { if case .buffering = $0 { false } else { true } }
        let expected: [AudioEvent] = [.started(id: items[0].id)] + items.dropFirst().map { .advanced(id: $0.id) } + [.finished]
        findings.expect(events == expected, "events \(events), wanted \(expected)")
        var previous: OfflineEngine.Buffer?
        for entry in entries {
            let name = entry.song.title
            let own = buffers.filter { $0.item == entry.item.id }.sorted { $0.first < $1.first }
            guard let (length, rate) = lengths[entry.item.id], let first = own.first
            else {
                findings.fail("\(name): never played to its end")
                continue
            }
            let covered = zip(own, own.dropFirst()).allSatisfy { $0.first + Int64($0.frames) == $1.first }
            let end = own.last.map { $0.first + Int64($0.frames) } ?? 0
            findings.expect(first.first == 0 && covered && end == length, "\(name): buffers cover \(first.first)..<\(end) with gaps or repeats, of \(length) frames")
            if let previous {
                findings.expect(first.timeline == previous.timeline && first.start == previous.start + Int64(previous.frames),
                                "\(name): doesn't follow the item before it without a gap")
            }
            previous = own.max { $0.first < $1.first }
            let decoded = Double(length) / rate
            let stated = entry.stream.duration ?? 0
            findings.expect(abs(decoded - stated) < statedTolerance, "\(name): decoded \(decoded) s, YouTube says \(stated) s")
            findings.note(String(format: "%@ %@: decoded %.3f s (%lld frames in %d buffers), stated %.3f s, gain %+.1f dB",
                                 name, entry.stream.badge, decoded, length, own.count, stated, entry.item.loudnessDB))
        }
        let timelines = Set(buffers.map(\.timeline)).count
        findings.note("rendered \(String(format: "%.1f", Double(rendered) / OfflineEngine.rate)) s in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))), \(timelines) player timelines")
    }
}

private struct Entry {
    let song: Song
    let stream: ResolvedStream
    let item: AudioItem
}

private extension AudioEvent {
    var ends: Bool {
        switch self {
        case .finished, .failed, .dropped: true
        case .started, .advanced, .buffering, .nextDropped: false
        }
    }
}
