import SwiftUI

/// Snow-mountain photo scaled to fill the screen, heavily blurred so it reads as an atmospheric
/// backdrop rather than a literal image — gives Liquid Glass something moody to refract.
struct AmbientBackdrop: View {
    var body: some View {
        Image("SnowMountainWallpaper")
            .resizable()
            .scaledToFill()
            .blur(radius: 40, opaque: true)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
