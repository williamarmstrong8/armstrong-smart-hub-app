import SwiftUI

/// Snow-mountain photo scaled to fill the screen with a slight blur, still clearly recognizable.
struct AmbientBackdrop: View {
    var body: some View {
        Image("SnowMountainWallpaper")
            .resizable()
            .scaledToFill()
            .blur(radius: 4, opaque: true)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
