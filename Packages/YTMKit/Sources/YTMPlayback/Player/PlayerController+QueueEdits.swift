import Foundation
import YTMCore

/// Offsets are the queue's entry indices, as SwiftUI's `onMove` and `onDelete` give them.
extension PlayerController {
    /// As `onMove` reports a drag; the song playing may move too.
    public func moveQueue(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        if queue.move(fromOffsets: offsets, toOffset: destination) { queueEdited() }
    }

    /// Removes the entries at `offsets`, all but the song playing.
    public func removeFromQueue(atOffsets offsets: IndexSet) {
        if !queue.removeMany(offsets).isEmpty { queueEdited() }
    }

    /// Moves the entries to right after the song playing, in their queue order.
    public func playNext(queueOffsets offsets: IndexSet) {
        if queue.playNextMany(offsets) { queueEdited() }
    }

    /// Also drops the rest of a playlist, or a radio, still on its way.
    public func clearUpcoming() {
        continuing?.cancel()
        cancelExtending()
        let before = queue.revision
        queue.clearUpcoming()
        if queue.revision != before { queueEdited() }
    }

    /// Saves the queue as a private playlist, such as "Queue 14 November 2026", answering its card for Library to
    /// show at once, as YouTube's list of playlists takes a while to hold one just made. Signed in only.
    public func saveQueueAsPlaylist() async -> Card? {
        let ids = Array(queue.items.map(\.id))
        guard !ids.isEmpty else { return nil }
        let thumbnail = queue.items.lazy.compactMap(\.thumbnail).first
        let title = Date.now.formatted(Self.playlistTitle)
        say("Saving \(Formatting.songs(ids.count)) as a playlist…")
        do {
            let id = try await music.createPlaylist(title: title, videoIds: ids)
            say("Saved as “\(title)”")
            return Card(
                kind: .playlist, id: id, title: title, subtitle: "Playlist • \(Formatting.songs(ids.count))", thumbnail: thumbnail
            )
        } catch {
            say("Couldn't save the playlist: \(sentence(for: error))")
            return nil
        }
    }

    private static let playlistTitle = Date.VerbatimFormatStyle(
        format: "Queue \(day: .defaultDigits) \(month: .wide) \(year: .defaultDigits)",
        locale: Locale(identifier: "en_GB"), timeZone: .current, calendar: Calendar(identifier: .gregorian)
    )

    func queueEdited() {
        dropStaleNext()
        persistSoon()
        prefetchNext()
    }

    /// Takes the artists' songs out of the queue and skips the one playing; one paused stays, as skipping would play.
    func leaveOutBlocked(_ blocked: Blocked) {
        // First, so the skip lands on a song kept.
        removeEntries { blocked.has($0.item) }
        guard let at = queue.currentIndex, blocked.has(queue.entries[at].item) else { return }
        let playing = queue.entries[at]
        // Paused too, so Play doesn't end in its radio.
        dropAutoplayRadio(of: playing.item.id)
        guard isPlaying else { return }
        skip(past: playing.item.id)
        // Its entry, spared while it played.
        removeEntries { $0.id == playing.id }
    }

    /// Drops the radio autoplay queued or is fetching from a song rejected, with Smart Shuffle's picks put in since.
    func dropAutoplayRadio(of id: String) {
        guard let radio = autoplayed, radio.seed == id else { return }
        autoplayed = nil
        // Still on its way, it would join behind the song skipped to.
        cancelExtending()
        removeEntries { radio.entries.contains($0.id) || ($0.isRecommended && $0.id >= radio.entries.lowerBound) }
    }

    /// All but the current entry; the queue is left untouched when none match, so its observers aren't woken.
    func removeEntries(where drop: (Queue<Track>.Entry) -> Bool) {
        let (entries, current) = (queue.entries, queue.currentIndex)
        let matching = entries.indices.filter { $0 != current && drop(entries[$0]) }
        guard !matching.isEmpty else { return }
        queue.removeMany(matching)
        queueEdited()
    }

    /// Drops the song queued in the player should it no longer be next.
    func dropStaleNext() {
        if let queued = gapless.queued, queued.trackID != queue.peekNext(repeat: repeatMode)?.id {
            dropQueuedNext()
        }
    }
}
