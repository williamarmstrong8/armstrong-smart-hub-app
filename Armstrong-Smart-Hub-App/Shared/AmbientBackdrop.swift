import AVFoundation
import SwiftUI

/// The chosen background (the orange and teal grain wave by default) scaled to fill the screen, blurred by
/// the amount set in Home > More > Background. Live Photos and clips loop and can shift with tilt.
struct AmbientBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let store = BackgroundStore.shared

    var body: some View {
        Group {
            if let player = store.player, store.kind == .motion {
                let moves = store.parallax && !reduceMotion
                LoopingVideo(player: player)
                    .scaleEffect(moves ? 1.15 : 1)
                    .offset(moves ? store.tilt : .zero)
                    .blur(radius: store.blur, opaque: true)
            } else {
                // A still picture and its blur are drawn once into one bitmap. As a live blur,
                // the whole screen was blurred again on every frame of a scroll, under the glass.
                still
                    .blur(radius: store.blur, opaque: true)
                    .drawingGroup(opaque: true)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var still: some View {
        if let image = store.image, store.kind == .photo {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image("AmbientWallpaper").resizable().scaledToFill()
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct LoopingVideo: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
