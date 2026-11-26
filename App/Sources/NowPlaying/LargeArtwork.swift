import SwiftUI
import YTMCore

/// Decoded at the player's shared size, which is fetched ahead with the song.
struct LargeArtwork: View {
    static let radius: CGFloat = 8
    /// How far a drag, or a flick's predicted end, must carry the artwork to skip.
    private static let skipDistance: CGFloat = 100

    let track: Track
    /// With the square clip over it, beside the panel or stood, where the pager's tall one isn't.
    let moves: Bool
    /// The pager's tall clip stands in for it; only the image goes, so the page keeps its place and its action.
    var stillHidden = false

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var shift: CGFloat = 0
    @State private var skips = 0

    var body: some View {
        GeometryReader { space in
            let edge = min(space.size.width, space.size.height)
            ArtworkView(url: track.thumbnail, size: edge, radius: Self.radius, pixelEdge: ImagePipeline.playerEdge, shadow: (theme.shadowSoft, 16, 8))
                // Shown while dragged, so the swipe has something to follow over the tall clip.
                .opacity(stillHidden && shift == 0 ? 0 : 1)
                .animation(MotionArtworkView.fade, value: stillHidden)
                .overlay {
                    if moves {
                        MotionArtworkView(track: track)
                            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
                    }
                }
                .frame(width: space.size.width, height: space.size.height)
        }
        .offset(x: shift)
        // Hit-tested as a whole, as the still takes no touches while hidden under the tall clip.
        .contentShape(Rectangle())
        .gesture(SidewaysPan(moved: { shift = $0 }, ended: ended))
        .sensoryFeedback(.skip, trigger: skips)
    }

    private func ended(_ x: CGFloat, velocity: CGFloat) {
        // A flick's resting point at normal deceleration; skips only the way it was dragged.
        let travel = x + velocity / 2
        if abs(travel) > Self.skipDistance, travel.sign == x.sign {
            if travel < 0 { app.player.next() } else { app.player.previous() }
            skips += 1
        }
        withAnimation(Theme.normal) { shift = 0 }
    }
}

/// Begins only on a mostly sideways move, and never shared, so it can't scroll the pager or close the sheet.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let moved: (CGFloat) -> Void
    /// The distance across and the speed, in points per second.
    let ended: (CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let x = pan.translation(in: nil).x
        switch pan.state {
        case .began, .changed: moved(x)
        case .ended: ended(x, pan.velocity(in: nil).x)
        default: ended(0, 0)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
