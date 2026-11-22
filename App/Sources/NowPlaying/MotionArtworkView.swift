import AVFoundation
import SwiftUI
import YTMCore

/// Apple Music's square moving cover, laid over the still art, which is framed as the clip's first frame and stays
/// underneath, so the clip only ever fades in and out on it. As in Apple Music, it freezes while the song is paused.
struct MotionArtworkView: View {
    static let fade = Animation.easeInOut(duration: 0.5)

    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var video: URL?
    /// The clip whose first frame is drawn, so a new one stays hidden until it has one.
    @State private var ready: URL?
    /// The last ask found no clip, as off Wi-Fi; a new song then bumps `retries`, so it is asked for again.
    @State private var missed = false
    @State private var retries = 0

    private struct Request: Hashable {
        let album: String?
        let setting: AnimatedArt
        /// The player and its buffers go in the background, made again from the file on return.
        let hidden: Bool
        let retries: Int
    }

    var body: some View {
        let request = Request(
            album: track.album?.id,
            setting: reduceMotion ? .off : app.settings.value.animatedArt,
            hidden: scenePhase == .background,
            retries: retries
        )
        let shown = video != nil && ready == video
        ZStack {
            if let video {
                LoopingVideo(url: video, playing: app.player.isPlaying && scenePhase == .active) {
                    ready = video
                }
                .id(video)
            }
        }
        .opacity(shown ? 1 : 0)
        .animation(Self.fade, value: shown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) { await load(request) }
        .onChange(of: track.id) { if missed { retries += 1 } }
    }

    /// Asked again by album, as every song of one shares its cover.
    private func load(_ request: Request) async {
        video = nil
        ready = nil
        missed = false
        guard request.album != nil, request.setting != .off, !request.hidden else { return }
        let cellular = request.setting == .on
        guard let source = await MotionArtwork.shared.source(.square, for: track, fetching: true, cellular: cellular) else { return }
        let next = await MotionArtwork.shared.video(source, cellular: cellular)
        guard !Task.isCancelled else { return }
        video = next
        missed = next == nil
    }
}

/// From a local file, so each loop is seamless and never touches the network.
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    let playing: Bool
    let ready: @MainActor () -> Void

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.start(url, ready: ready)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if playing {
            view.player.play()
        } else {
            view.player.pause()
        }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Void) {
        view.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var observation: NSKeyValueObservation?

        func start(_ url: URL, ready: @escaping @MainActor () -> Void) {
            isUserInteractionEnabled = false
            // Silent and the song's alone: no AirPlay, no hold on auto-lock, no part in the audio session.
            player.isMuted = true
            player.allowsExternalPlayback = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            if #available(iOS 27, *) { player.setDisconnectedFromSystemAudio(true) }
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            guard let layer = layer as? AVPlayerLayer else { return }
            layer.videoGravity = .resizeAspectFill
            layer.player = player
            // Sendable, as the layer reports from a decoding thread; `.initial` catches a frame drawn first.
            observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { @Sendable _, change in
                guard change.newValue == true else { return }
                Task { @MainActor in ready() }
            }
        }

        func stop() {
            observation?.invalidate()
            looper?.disableLooping()
            player.pause()
        }
    }
}
