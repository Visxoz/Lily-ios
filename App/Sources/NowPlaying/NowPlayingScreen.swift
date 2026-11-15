import SwiftUI
import YTMCore

/// ytm-native's player bar and right-hand panel as one screen, grown out of
/// the mini player: the artwork, which a swipe up turns to Up next, or with
/// the panel open the Up next and Lyrics chips over the queue or the
/// lyrics; then the seek bar, the transport, and the volume, quality badge
/// and panel buttons, all over the artwork's colour.
struct NowPlayingScreen: View {
    static let padding: CGFloat = 24

    @Environment(AppModel.self) private var app
    @State private var panel: PanelTab?
    @Namespace private var artwork

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if let track = app.player.current {
                NowPlayingTopBar(track: track)
                if let tab = panel {
                    HStack(spacing: 14) {
                        ArtworkView(url: track.thumbnail, size: 56)
                            .matchedGeometryEffect(id: track.id, in: artwork)
                        TrackTitle(track: track, compact: true)
                    }
                    .padding(.horizontal, Self.padding)
                    .padding(.vertical, 8)
                    SidePanel(tab: tab) { panel = $0 }
                } else {
                    LargeArtwork(url: track.thumbnail)
                        .matchedGeometryEffect(id: track.id, in: artwork)
                        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { drag in
                            let up = -drag.translation.height
                            if up > 60, up > abs(drag.translation.width) { panel = .upNext }
                        })
                        .accessibilityAction(named: "Up next") { panel = .upNext }
                        .padding(.horizontal, Self.padding)
                        .padding(.vertical, 12)
                    TrackTitle(track: track, compact: false)
                        .padding(.horizontal, Self.padding)
                }
                Group {
                    Scrubber()
                        .padding(.top, 12)
                    TransportControls()
                    PlayerOptions(panel: $panel)
                }
                .padding(.horizontal, Self.padding)
            }
        }
        .padding(.bottom, 8)
        .background { NowPlayingBackground() }
        .animation(Theme.normal, value: panel)
        .sheet(item: $app.nowPlayingPicker) { PlaylistPickerSheet(track: $0) }
    }
}

/// The close button, and the song's menu as the player bar's: saving it
/// (signed in), its artist and its album. Rating is beside the title, and
/// queueing the song playing has no use.
private struct NowPlayingTopBar: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            IconButton(icon: .close, size: 40, iconSize: 22, colour: theme.text) { dismiss() }
                .accessibilityLabel("Close")
            Spacer()
            Menu {
                if app.isSignedIn {
                    Button("Save to playlist") { app.addToPlaylist(track) }
                }
                TrackLinks(track: track)
            } label: {
                IconView(icon: .more, size: 22, colour: theme.text)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, NowPlayingScreen.padding - 8)
        .padding(.top, 12)
    }
}

/// The artwork as large as the room left for it, square, decoded at the
/// player's shared size, which is fetched ahead with the song.
private struct LargeArtwork: View {
    let url: String?

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { space in
            let edge = min(space.size.width, space.size.height)
            ArtworkView(url: url, size: edge, radius: 8, pixelEdge: ImagePipeline.playerEdge, shadow: (theme.shadowSoft, 16, 8))
                .frame(width: space.size.width, height: space.size.height)
        }
    }
}

/// Behind the screen, the artwork's colour darkening downwards, as the
/// side panel's lyrics, fading as the song changes; the panel's own colour
/// without artwork.
private struct NowPlayingBackground: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let colour = app.artwork?.background {
                LinearGradient(colors: [theme.tint(colour), theme.tint(colour.darker(0.5))], startPoint: .top, endPoint: .bottom)
            } else {
                theme.panel
            }
        }
        .animation(.easeInOut(duration: 0.5), value: app.artwork)
        .ignoresSafeArea()
    }
}
