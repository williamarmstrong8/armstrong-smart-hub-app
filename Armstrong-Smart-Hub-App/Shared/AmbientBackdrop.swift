import AVFoundation
import SwiftUI

/// The chosen background (the snow-mountain photo by default) scaled to fill the screen, blurred by
/// the amount set in Home > More > Background. Live Photos and clips loop and can shift with tilt.
struct AmbientBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let store = BackgroundStore.shared

    var body: some View {
        let moves = store.kind == .motion && store.parallax && !reduceMotion
        media
            .scaleEffect(moves ? 1.15 : 1)
            .offset(moves ? store.tilt : .zero)
            .blur(radius: store.blur, opaque: true)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var media: some View {
        if let player = store.player, store.kind == .motion {
            LoopingVideo(player: player)
        } else if let image = store.image, store.kind == .photo {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image("SnowMountainWallpaper").resizable().scaledToFill()
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
