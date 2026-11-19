import Observation
import SwiftUI
import YTMAudio
import YTMCore
import YTMPlayback

enum AppSheet: Identifiable, Hashable {
    case nowPlaying
    case settings
    case signIn
    case addToPlaylist(Track)

    var id: Self { self }
}

enum AppTab: Hashable {
    case home, explore, library, history, search
}

@Observable
final class TabNavigation {
    var routes: [Route] = []
}

struct Toast: Equatable {
    let id: Int
    let message: String
}

/// Everything here runs on the main actor; the services do their work off it.
@Observable
final class AppModel {
    static let toastFor: Duration = .seconds(5)

    let api: YTMusic
    let player: PlayerController
    let audio: AudioPlayer
    let settings: SettingsStore
    let history: LocalHistory

    var tab: AppTab = .home
    var sheet: AppSheet? {
        // Closing Now Playing under its picker doesn't write the picker's
        // binding back, so it would reopen with the next Now Playing.
        didSet { if sheet != .nowPlaying, nowPlayingPicker != nil { nowPlayingPicker = nil } }
    }
    /// Now Playing is on screen or still zooming away, while pages fill past their edges (`PastEdges`).
    var nowPlayingShown = false
    /// iPhone Duo, which Settings offers fold to scrub on.
    var hasHinge = false
    /// The playlist picker opened from Now Playing, shown over it so its open panel stays.
    var nowPlayingPicker: Track?
    /// The keyboard is up, so the mini player steps aside rather than ride above it.
    var isSearching = false

    /// A stored sign-in cookie counts, so pages load without waiting for YouTube to confirm it.
    private(set) var isSignedIn = false
    private(set) var account: Account?
    /// Bumped whenever the account changes, so results asked for by the last account are
    /// dropped. Zero until the stored sign-in has been read, before which pages don't load.
    private(set) var accountGeneration = 0

    private(set) var theme: Theme
    private(set) var artwork: ArtworkColours?
    private(set) var toast: Toast?

    @ObservationIgnored private let home = TabNavigation()
    @ObservationIgnored private let explore = TabNavigation()
    @ObservationIgnored private let library = TabNavigation()
    @ObservationIgnored private let played = TabNavigation()
    @ObservationIgnored private let search = TabNavigation()
    @ObservationIgnored var pageCache: [Route: CachedPage] = [:]
    /// Shared by every screen asking for the same route.
    @ObservationIgnored var pageLoads: [Route: Task<Page, any Error>] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The wait for Last.fm access, which outlives Settings.
    private var lastFMWait: Task<Void, Never>?
    @ObservationIgnored private var downloadTime = UIBackgroundTaskIdentifier.invalid

    init(api: YTMusic = .shared, settings: SettingsStore = .shared, history: LocalHistory = .shared) {
        self.api = api
        self.settings = settings
        self.history = history
        audio = AudioPlayer()
        player = PlayerController(api: api, settings: settings, history: history, audio: audio)
        theme = Theme(settings: settings.value, artworkAccent: nil)
        // Read here, for the app's life: a view's task would be cancelled by a scene teardown,
        // ending the one-consumer stream.
        Task { [weak self, toasts = player.toasts] in
            for await message in toasts { self?.showToast(message) }
        }
    }

    /// Signed in, Home's feed is asked for at once and the launch's other requests wait for it
    /// (two seconds at most), so they don't slow it.
    func start() async {
        isSignedIn = await api.auth.isSignedIn
        // Before the request, which belongs to the generation it starts in.
        accountGeneration += 1
        let home = isSignedIn ? Task { try await fetchPage(.home) } : nil
        let homeSettled = Task { await Self.settled(home, within: .seconds(2)) }
        await player.start { await homeSettled.value }
        await homeSettled.value
        await refreshAccount()
    }

    /// Not a task group, which would wait out `load` all the same.
    private nonisolated static func settled(_ load: Task<Page, any Error>?, within limit: Duration) async {
        guard let load else { return }
        let (done, finish) = AsyncStream.makeStream(of: Void.self)
        Task { _ = try? await load.value; finish.finish() }
        Task { try? await Task.sleep(for: limit); finish.finish() }
        for await _ in done {}
    }

    /// Replaces `theme` only when it changes, so views reading it redraw only then.
    func followTheme() async {
        let changes = Observations { [settings] in
            Theme(settings: settings.value, artworkAccent: self.artwork?.vivid)
        }
        for await theme in changes where theme != self.theme {
            self.theme = theme
        }
    }

    /// The colours are sampled from any copy in memory, else the small one, as the palette reads
    /// only 16 pixels square, so they never wait for the large one.
    func followArtwork(of url: String?) async {
        // Without artwork, the last song's colour would linger.
        guard let url else {
            artwork = nil
            return
        }
        let colours: ArtworkColours?
        // At 3x, the scale the shared pixel sizes are set for, so the card a song started from is found.
        if let image = ArtworkImage.cachedAnySize(url, scale: 3) {
            colours = await ArtworkColours.of(image)
        } else {
            colours = await ArtworkColours.of(url: url, pixelEdge: ImagePipeline.smallEdge)
        }
        guard let colours, !Task.isCancelled else { return }
        artwork = colours
    }

    /// Should YouTube no longer take the stored sign-in, it is dropped.
    func refreshAccount() async {
        guard isSignedIn else {
            account = nil
            return
        }
        let generation = accountGeneration
        let found: Account?
        do {
            found = try await api.account()
        } catch {
            // YouTube couldn't be asked, which says nothing of the sign-in.
            return
        }
        guard generation == accountGeneration else { return }
        guard let found else {
            // The menu came back signed out.
            await signOut(quietly: true)
            return
        }
        account = found
    }

    /// Drops everything the last account loaded. `quietly`, as for a sign-in YouTube rejected,
    /// skips announcing it and switching to Library or Home.
    func accountChanged(quietly: Bool = false) async {
        await api.forgetAccount()
        isSignedIn = await api.auth.isSignedIn
        account = nil
        // Together with the bump, so no page asked for by the last account
        // lands in the cache once it is cleared.
        pageCache.removeAll()
        // A request the last account made must not be shared with the next.
        pageLoads.values.forEach { $0.cancel() }
        pageLoads.removeAll()
        accountGeneration += 1
        if !quietly {
            sheet = nil
            showToast(isSignedIn ? "Signed in" : "Signed out")
            tab = isSignedIn ? .library : .home
            navigation(for: tab).routes.removeAll()
        }
        await player.accountDidChange()
        await refreshAccount()
    }

    func signOut(quietly: Bool = false) async {
        await api.auth.signOut()
        await accountChanged(quietly: quietly)
    }

    var isConnectingLastFM: Bool { lastFMWait != nil }

    /// Waits, whatever Settings does, until access is allowed, refused or cancelled.
    func connectLastFM(open: OpenURLAction) {
        lastFMWait = Task { [weak self] in
            let message: String?
            do {
                try await LastFM.shared.signIn { url in await open(url) }
                message = await LastFM.shared.username.map { "Scrobbling to Last.fm as \($0)" }
            } catch {
                // Cancelled, the user stopped waiting, which needs no word.
                message = Task.isCancelled ? nil : sentence(for: error)
            }
            guard let self, !Task.isCancelled else { return }
            lastFMWait = nil
            if let message { showToast(message) }
        }
    }

    func cancelLastFMConnect() {
        lastFMWait?.cancel()
        lastFMWait = nil
    }

    func showToast(_ message: String) {
        toast = Toast(id: (toast?.id ?? 0) + 1, message: message)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastFor)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// iOS gives downloads only a short while in the background; while music plays they carry on anyway.
    func keepDownloading(_ active: Bool) {
        if active, downloadTime == .invalid {
            downloadTime = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
                self?.keepDownloading(false)
            }
        } else if !active, downloadTime != .invalid {
            UIApplication.shared.endBackgroundTask(downloadTime)
            downloadTime = .invalid
        }
    }

    /// Each tab's own stack of pages, observed apart so a push redraws one.
    func navigation(for tab: AppTab) -> TabNavigation {
        switch tab {
        case .home: home
        case .explore: explore
        case .library: library
        case .history: played
        case .search: search
        }
    }

    /// Pushes `route` on the tab in view, closing whatever is presented.
    func open(_ route: Route) {
        sheet = nil
        let stack = navigation(for: tab)
        // Already on top: pushing again would only stack a copy.
        guard stack.routes.last != route else { return }
        stack.routes.append(route)
    }
}
