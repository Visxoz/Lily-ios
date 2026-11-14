import Foundation
import Observation
import YTMCore

/// The songs played on this phone and the recent searches, as ytm-native's
/// `history.json` and `searches.json`.
///
/// The history is written two seconds after the last play, so skipping
/// through songs costs one write; the searches as soon as they change, as
/// they are tiny. Load both once at launch with `load()` (the player's
/// `start()` does).
@MainActor @Observable public final class LocalHistory {
    public static let shared = LocalHistory(store: .shared)

    /// Newest first, one entry per song.
    public private(set) var history = PlayHistory()
    /// Newest first, offered when the search field opens until the user types.
    public private(set) var searches = RecentSearches()

    @ObservationIgnored private let store: FileStore
    @ObservationIgnored private let saving = Debounce()
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(store: FileStore) {
        self.store = store
    }

    /// Reads both files off the main actor, once; later calls wait for the first.
    public func load() async {
        if loading == nil {
            let store = store
            loading = Task { [weak self] in
                let (history, searches) = await Self.read(store)
                guard let self else { return }
                // Plays recorded before the file was read come first.
                if let history { self.history = PlayHistory(tracks: self.history.tracks + history.tracks) }
                if let searches { self.searches = searches }
            }
        }
        await loading?.value
    }

    /// The history as a page, newest first, as ytm-native's `history_page`
    /// shows it when signed out or with the YouTube history off; nil when
    /// nothing has played yet.
    public var page: Page? {
        guard !history.tracks.isEmpty else { return nil }
        return Page(
            header: PageHeader(label: "Recently played", title: "History", meta: Formatting.songs(history.tracks.count)),
            sections: [.tracks(TrackSection(title: "", tracks: history.tracks, mode: .section))]
        )
    }

    public func recordSearch(_ query: String) {
        searches.record(query)
        store.save(searches, to: .searches)
    }

    public func removeSearch(_ query: String) {
        searches.remove(query)
        store.save(searches, to: .searches)
    }

    /// Writes plays still waiting, as when the app leaves the foreground.
    func saveNow() {
        guard saving.isPending else { return }
        saving.cancel()
        store.save(history, to: .history)
    }

    /// Adds a play, as its sound starts; only the player records them.
    func record(_ track: Track) {
        history.record(track)
        saving.schedule { [weak self] in
            guard let self else { return }
            store.save(history, to: .history)
        }
    }

    @concurrent
    private static func read(_ store: FileStore) async -> (PlayHistory?, RecentSearches?) {
        (store.load(PlayHistory.self, from: .history), store.load(RecentSearches.self, from: .searches))
    }
}
