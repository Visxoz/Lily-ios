import Foundation
import YTMCore

/// Editing the queue from Up next, as ytm-native's `queue_panel.rs`:
/// dragging entries into a new order, removing or playing several next, and
/// saving it all as a playlist. Offsets are the queue's entry indices, as
/// SwiftUI's `onMove` and `onDelete` give them.
extension PlayerController {
    /// Moves the entries at `offsets` to before the entry at `destination`,
    /// as `onMove` reports a drag. The song playing may move too.
    public func moveQueue(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        if queue.move(fromOffsets: offsets, toOffset: destination) { queueEdited() }
    }

    /// Removes the entries at `offsets`, all but the song playing.
    public func removeFromQueue(atOffsets offsets: IndexSet) {
        if !queue.removeMany(offsets).isEmpty { queueEdited() }
    }

    /// Moves the entries at `offsets` to right after the song playing, in
    /// their queue order.
    public func playNext(queueOffsets offsets: IndexSet) {
        if queue.playNextMany(offsets) { queueEdited() }
    }

    /// Drops everything after the song playing, and the rest of a playlist
    /// still on its way.
    public func clearUpcoming() {
        continuing?.cancel()
        let before = queue.revision
        queue.clearUpcoming()
        if queue.revision != before { queueEdited() }
    }

    /// Saves the whole queue as a private playlist named after today, such as
    /// "Queue 14 November 2026", saying how it went. Signed in only.
    public func saveQueueAsPlaylist() {
        let ids = Array(queue.items.map(\.id))
        guard !ids.isEmpty else { return }
        let title = Date.now.formatted(Self.playlistTitle)
        say("Saving \(Formatting.songs(ids.count)) as a playlist…")
        let music = music
        Task { [weak self] in
            let result = await Result { try await music.createPlaylist(title: title, videoIds: ids) }
            guard let self else { return }
            switch result {
            case .success:
                libraryRevision += 1
                say("Saved as “\(title)”")
            case .failure(let error):
                say("Couldn't save the playlist: \(sentence(for: error))")
            }
        }
    }

    /// As ytm-native words it: the day, the month's name and the year.
    private static let playlistTitle = Date.VerbatimFormatStyle(
        format: "Queue \(day: .defaultDigits) \(month: .wide) \(year: .defaultDigits)",
        locale: Locale(identifier: "en_GB"), timeZone: .current, calendar: Calendar(identifier: .gregorian)
    )

    /// After an edit: a song queued in the engine that is no longer next is
    /// dropped, the new next one is got ready, and the session is saved.
    func queueEdited() {
        if let queued = gapless.queued, queued.trackID != queue.peekNext(repeat: repeatMode)?.id {
            dropQueuedNext()
        }
        persistSoon()
        prefetchNext()
    }
}
