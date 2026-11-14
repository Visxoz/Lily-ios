import SwiftUI
import YTMCore

/// ytm-native's window on a phone: the sidebar's pages and the top bar's
/// search become tabs, the player bar a mini player above them that opens
/// Now Playing, and the dialogs sheets.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var transition

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab(value: AppTab.home) {
                TabRoot(tab: .home) { PageScreen(route: .home) }
            } label: {
                TabLabel(title: "Home", icon: app.tab == .home ? .home : .homeOutline)
            }
            Tab(value: AppTab.explore) {
                TabRoot(tab: .explore) { PageScreen(route: .explore) }
            } label: {
                TabLabel(title: "Explore", icon: .explore)
            }
            Tab(value: AppTab.library) {
                TabRoot(tab: .library) { LibraryScreen() }
            } label: {
                TabLabel(title: "Library", icon: .library)
            }
            Tab(value: AppTab.history) {
                TabRoot(tab: .history) { HistoryScreen() }
            } label: {
                TabLabel(title: "History", icon: .history)
            }
            Tab(value: AppTab.search, role: .search) {
                TabRoot(tab: .search) { SearchScreen() }
            }
        }
        .tabViewBottomAccessory(isEnabled: app.player.current != nil) {
            MiniPlayer()
                .matchedTransitionSource(id: AppSheet.nowPlaying, in: transition)
        }
        .sheet(item: $app.sheet) { sheet in
            SheetContent(sheet: sheet, transition: transition)
        }
        .environment(\.theme, app.theme)
        .preferredColorScheme(app.theme.colorScheme)
        .tint(app.theme.accent)
        .task { await app.start() }
        .task { await app.followTheme() }
        .task(id: app.player.current?.thumbnail) { await app.followArtwork(of: app.player.current?.thumbnail) }
        .onChange(of: app.player.libraryRevision) { app.libraryChanged() }
    }
}

/// A tab's label in ytm-native's own icons rather than SF Symbols.
private struct TabLabel: View {
    let title: String
    let icon: Icon

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(icon: icon)
        }
    }
}

/// What `AppSheet` presents, each with the toast over it, as ytm-native's
/// toast shows above its dialogs and panel. Now Playing grows out of the
/// mini player.
private struct SheetContent: View {
    let sheet: AppSheet
    let transition: Namespace.ID

    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch sheet {
            case .nowPlaying:
                NowPlayingScreen()
                    .navigationTransition(.zoom(sourceID: AppSheet.nowPlaying, in: transition))
            case .settings:
                SettingsScreen()
            case .signIn:
                SignInScreen { Task { await app.accountChanged() } }
            case .addToPlaylist(let track):
                PlaylistPickerSheet(track: track)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
    }
}
