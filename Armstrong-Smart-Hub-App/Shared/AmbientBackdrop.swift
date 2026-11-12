import SwiftUI

/// Snow-mountain photo scaled to fill the screen, softly blurred (light-to-medium) so it stays
/// recognizable while still giving Liquid Glass something moody to refract.
struct AmbientBackdrop: View {
    var body: some View {
        Image("SnowMountainWallpaper")
            .resizable()
            .scaledToFill()
            .blur(radius: 10, opaque: true)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
