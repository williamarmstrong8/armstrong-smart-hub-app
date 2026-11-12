import SwiftUI

/// Snow-mountain photo scaled to fill the screen, fully sharp, for Liquid Glass to refract.
struct AmbientBackdrop: View {
    var body: some View {
        Image("SnowMountainWallpaper")
            .resizable()
            .scaledToFill()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
