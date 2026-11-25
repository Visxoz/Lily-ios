import Foundation
import os
import YTMCore

/// Mixes recommendations from a queued song's radio in after every few of the user's own songs, marked so turning
/// Smart Shuffle off takes them out again.
struct SmartShuffle {
    /// The user's own songs between two recommendations.
    static let gaps = 3...4
    /// Own songs ahead that get recommendations, so a long playlist never asks for all.
    static let lookahead = 8
    /// Recently played songs that are not recommended again.
    static let recent = 100

    /// Bumped when the queue is replaced or Smart Shuffle turned off, so a batch asked for an earlier queue is
    /// dropped as it arrives.
    private(set) var generation: UInt64 = 0
    private(set) var fetching = false
    private var pool: [Track] = []
    /// Own songs to pass before the next recommendation; zero picks anew.
    private var gap = 0
    /// IDs in the queue or recently played; rebuilt only when the queue's revision changes.
    private var known: Set<String> = []
    private var knownRevision: Int?

    mutating func reset() {
        generation += 1
        fetching = false
        pool.removeAll()
        gap = 0
    }

    /// Returns the seed of a batch to ask for when the pool ran dry, and marks it as being fetched. `blocked` is
    /// checked as each is placed, so one blocked after its batch arrived is left out too.
    mutating func topUp(_ queue: inout Queue<Track>, recent: some Sequence<String>, blocked: [ArtistRef]) -> String? {
        guard let current = queue.currentIndex, !fetching else { return nil }
        if knownRevision != queue.revision {
            known = Set(queue.items.map(\.id)).union(recent)
        }
        var run = queue.isRecommended(at: current) ? 0 : 1
        var ahead = 0
        var index = current + 1
        var dry = false
        // Only before one of the user's own songs, never after the last: a cleared queue stays clear, and autoplay
        // takes over at the end.
        while index < queue.count, ahead < Self.lookahead {
            if queue.isRecommended(at: index) {
                run = 0
                index += 1
                continue
            }
            if gap == 0 {
                gap = Int.random(in: Self.gaps)
            }
            if run >= gap {
                guard let track = fresh(blocked) else {
                    dry = true
                    break
                }
                known.insert(track.id)
                queue.insertRecommended(track, at: index)
                gap = 0
                run = 0
                index += 1
                continue
            }
            run += 1
            ahead += 1
            index += 1
        }
        knownRevision = queue.revision
        guard dry, let seed = Self.seed(queue) else { return nil }
        fetching = true
        return seed
    }

    /// Returns whether the batch brought anything new to place; one for an earlier queue is dropped.
    /// `blocked` too, so a batch of only blocked songs doesn't count as new and ask again at once.
    mutating func receive(_ tracks: [Track]?, generation: UInt64, blocked: [ArtistRef]) -> Bool {
        guard generation == self.generation else { return false }
        fetching = false
        pool += (tracks ?? []).filter { !known.contains($0.id) && !$0.isBy(anyOf: blocked) }
        return !pool.isEmpty
    }

    private mutating func fresh(_ blocked: [ArtistRef]) -> Track? {
        while !pool.isEmpty {
            let track = pool.removeFirst()
            if !known.contains(track.id), !track.isBy(anyOf: blocked) { return track }
        }
        return nil
    }

    private static func seed(_ queue: Queue<Track>) -> String? {
        queue.entries.filter { !$0.isRecommended }.randomElement()?.item.id
    }
}

extension PlayerController {
    /// Runs from `prefetchNext`, so at each song start.
    func topUpSmartShuffle() {
        guard settings.value.shuffle == .smart else { return }
        let recent = history.history.tracks.prefix(SmartShuffle.recent).lazy.map(\.id)
        // On a copy, written back only when something was placed: the queue is observed, and most calls place nothing.
        var upcoming = queue
        let seed = smart.topUp(&upcoming, recent: recent, blocked: settings.value.blockedArtists)
        if upcoming.revision != queue.revision { queue = upcoming }
        guard let seed else { return }
        let generation = smart.generation
        let music = music
        Task { [weak self] in
            let result = await Result { try await music.radio(videoId: seed) }
            guard let self else { return }
            if case .failure(let error) = result {
                Logger.playback.debug("smart shuffle could not fetch recommendations: \(sentence(for: error), privacy: .public)")
            }
            // Nothing new: the next song start asks again from another seed.
            if smart.receive(try? result.get(), generation: generation, blocked: settings.value.blockedArtists) {
                prefetchNext()
            }
        }
    }
}
