import SwiftUI

/// The watch, cut out and floating on the page, fading at the edges.
struct WatchHero: View {
    /// 0...1 while the watch syncs; nil shows the watch's own face.
    var progress: Double?
    /// Shown as the face's time: when the data was last refreshed. The PNG's own time is erased.
    var time: Date?

    var body: some View {
        ZStack {
            Image("GarminHero")
                .resizable()
                .scaledToFit()
                .frame(height: 150)
                .overlay { timeFace }
                .overlay { syncFace }
                .rotationEffect(.degrees(-6))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.1),
                                   .init(color: .black, location: 0.9),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
        .accessibilityHidden(true)
    }

    /// The face's time, where the PNG's "4:37:33" was (x 335-715, y 302-394 of
    /// 835x992 px, level with the image): white, about 90 px tall digits.
    private var timeFace: some View {
        GeometryReader { geo in
            let k = geo.size.height / 992
            Text(time.map { $0.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()) } ?? "--:--")
                .font(.system(size: 128 * k, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 400 * k, height: 110 * k)
                .position(x: 525 * k, y: 348 * k)
                .contentTransition(.numericText())
                .hubAnimation(value: time)
        }
        .allowsHitTesting(false)
    }

    /// The watch's screen as it sits in the cutout (835x992 px): an ellipse
    /// centered at (0.640, 0.4175) with semi-axes 279 and 303 px, tilted 14.4 degrees.
    /// A progress ring (no text) is drawn on it while syncing.
    private var syncFace: some View {
        GeometryReader { geo in
            let k = geo.size.height / 992
            let screenWidth = 2 * 279 * k * 0.97
            let screenHeight = 2 * 303 * k * 0.97
            let ring = screenWidth * 0.075
            let inset = screenWidth * 0.07
            ZStack {
                Ellipse().fill(.black)
                Ellipse().stroke(Color.green.opacity(0.18), lineWidth: ring)
                    .padding(inset)
                Ellipse().trim(from: 0, to: max(0.02, min(progress ?? 1, 1)))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                    .frame(width: screenHeight - 2 * inset, height: screenWidth - 2 * inset)
                    .rotationEffect(.degrees(-90))
                    .hubAnimation(value: progress)
            }
            .frame(width: screenWidth, height: screenHeight)
            .rotationEffect(.degrees(-14.43))
            .position(x: 0.640 * geo.size.width, y: 0.4175 * geo.size.height)
            .opacity(progress == nil ? 0 : 1)
            .hubAnimation(value: progress == nil)
        }
        .allowsHitTesting(false)
    }
}

/// Tabler line icon (tabler.io/icons, MIT license), bundled as a template vector asset
/// named "tabler-<name>" so it tints with the foreground style.
struct TablerIcon: View {
    var name: String
    var size: CGFloat = 24

    var body: some View {
        Image("tabler-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
