import Observation
import SwiftUI
import YTMAudio
import YTMCore
import YTMPlayback

/// What the app presents over the tabs, as ytm-native's dialogs and its
/// player bar's expansion.
enum AppSheet: Identifiable, Hashable {
    case nowPlaying
    case settings
    case signIn
    case addToPlaylist(Track)

    var id: Self { self }
}

/// The tabs, in ytm-native's sidebar order, with its top bar's search last.
enum AppTab: Hashable {
    case home, explore, library, history, search
}

/// One tab's pushed pages.
@Observable
final class TabNavigation {
    var routes: [Route] = []
}

/// A message shown briefly over the page, as ytm-native's toast.
struct Toast: Equatable {
    let id: Int
    let message: String
}

/// The app's root state, as ytm-native's `App`: the services, the account,
/// the page cache, navigation and what is presented. Everything here runs on
/// the main actor; the services do their work off it.
@Observable
final class AppModel {
    static let toastFor: Duration = .seconds(5)

    let api: YTMusic
    let player: PlayerController
    /// The player's audio engine, for Settings' audio cache size and Clear.
    let audio: AudioPlayer
    let settings: SettingsStore
    let history: LocalHistory

    var tab: AppTab = .home
    var sheet: AppSheet? {
        // Closing Now Playing under its picker doesn't write the picker's
        // binding back, so it would reopen with the next Now Playing.
        didSet { if sheet != .nowPlaying, nowPlayingPicker != nil { nowPlayingPicker = nil } }
    }
    /// Now Playing is on screen or still zooming away, while the zoom shrinks
    /// the screen behind it and pages fill past its edges (`PastEdges`).
    var nowPlayingShown = false
    /// The playlist picker opened from Now Playing, shown over it rather than
    /// in its place, so Now Playing and its open panel stay.
    var nowPlayingPicker: Track?
    /// The search field is active, with the keyboard up, so the mini player
    /// steps aside rather than ride up above the keyboard.
    var isSearching = false

    /// Whether a sign-in cookie is stored, which counts as signed in, so
    /// pages load without waiting for YouTube to confirm it.
    private(set) var isSignedIn = false
    private(set) var account: Account?
    /// Bumped whenever the account changes, so pages load afresh and results
    /// asked for by the last account are dropped. Zero until the stored
    /// sign-in has been read, before which pages don't load.
    private(set) var accountGeneration = 0

    private(set) var theme: Theme
    /// The playing song's artwork colours, or nil without artwork.
    private(set) var artwork: ArtworkColours?
    private(set) var toast: Toast?

    @ObservationIgnored private let home = TabNavigation()
    @ObservationIgnored private let explore = TabNavigation()
    @ObservationIgnored private let library = TabNavigation()
    @ObservationIgnored private let played = TabNavigation()
    @ObservationIgnored private let search = TabNavigation()
    @ObservationIgnored var pageCache: [Route: CachedPage] = [:]
    /// The page requests in flight, shared by every screen asking for the
    /// same route, and Home's first try apart, as `refreshHome` wants the
    /// retries that joining it would lose.
    @ObservationIgnored var pageLoads: [Route: Task<Page, any Error>] = [:]
    @ObservationIgnored var homeFirstTryLoad: Task<Page, any Error>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The wait for Last.fm access, which outlives Settings, as ytm-native's.
    private var lastFMWait: Task<Void, Never>?

    init(api: YTMusic = .shared, settings: SettingsStore = .shared, history: LocalHistory = .shared) {
        self.api = api
        self.settings = settings
        self.history = history
        audio = AudioPlayer()
        player = PlayerController(api: api, settings: settings, history: history, audio: audio)
        theme = Theme(settings: settings.value, artworkAccent: nil)
        // The player's messages show as ytm-native shows them, in the toast.
        // Read here, for the app's life, not from a view whose task a scene
        // teardown would cancel, which would end the one-consumer stream.
        Task { [weak self, toasts = player.toasts] in
            for await message in toasts { self?.showToast(message) }
        }
    }

    /// Reads the stored sign-in, which is all pages wait for, then restores
    /// the last session and keeps the account's details current.
    func start() async {
        isSignedIn = await api.auth.isSignedIn
        accountGeneration += 1
        await player.start()
        await refreshAccount()
    }

    /// Keeps `theme` in step with the look, the accent and the artwork, only
    /// replacing it when it changes, so views reading it redraw only then.
    func followTheme() async {
        let changes = Observations { [settings] in
            Theme(settings: settings.value, artworkAccent: self.artwork?.vivid)
        }
        for await theme in changes where theme != self.theme {
            self.theme = theme
        }
    }

    /// Takes the colours of the playing song's artwork, for an accent that
    /// follows it and for Now Playing. They are sampled from any copy already
    /// in memory, else the small one the mini player shows, as the palette
    /// reads only 16 pixels square, so they never wait for the large one.
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

    /// The account's name and picture, signed in. Should YouTube no longer
    /// take the stored sign-in, it is dropped, as ytm-native's
    /// `sign_in_expired`.
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

    /// After signing in or out: what was loaded belongs to the last account,
    /// so it is dropped, with the saved Home feed, and every page loads
    /// afresh. As ytm-native, the app then says so and shows Library (signed
    /// in) or Home fresh, closing Settings; unless `quietly`, as for a
    /// sign-in YouTube rejected, which drops back to signed out unannounced.
    func accountChanged(quietly: Bool = false) async {
        api.clearCachedHome()
        isSignedIn = await api.auth.isSignedIn
        account = nil
        // Together with the bump, so no page asked for by the last account
        // lands in the cache once it is cleared.
        pageCache.removeAll()
        // A request the last account made must not be shared with the next.
        pageLoads.values.forEach { $0.cancel() }
        pageLoads.removeAll()
        homeFirstTryLoad?.cancel()
        homeFirstTryLoad = nil
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

    /// Opens Last.fm to allow access and waits for it, whatever Settings
    /// does, until it is allowed, refused or cancelled, as ytm-native's.
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

    /// Stops waiting for Last.fm access: the only way to, as ytm-native's.
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
        // Already on top: pushing again would only stack a copy, as ytm-native's navigate.
        guard stack.routes.last != route else { return }
        stack.routes.append(route)
    }
}
