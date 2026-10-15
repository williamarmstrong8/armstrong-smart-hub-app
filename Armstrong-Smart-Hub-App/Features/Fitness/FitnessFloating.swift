import Charts
import SwiftUI

/// Building blocks for the floating Fitness page: no card backgrounds, just
/// data and color sitting on the page.

/// A titled section with no surface behind it.
struct FloatingSection<Content: View>: View {
    var title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The watch, cut out and floating over a soft glow, fading into the page.
struct WatchHero: View {
    /// 0...1 while the watch syncs; nil shows the watch's own face.
    var progress: Double?

    var body: some View {
        ZStack {
            Circle().fill(Color.green.opacity(0.35)).frame(width: 150).blur(radius: 50).offset(x: -70, y: -20)
            Circle().fill(Color.blue.opacity(0.30)).frame(width: 160).blur(radius: 55).offset(x: 80, y: 20)
            Circle().fill(Color.red.opacity(0.22)).frame(width: 110).blur(radius: 45).offset(x: 50, y: -70)
            Image("GarminHero")
                .resizable()
                .scaledToFit()
                .frame(height: 190)
                .overlay { syncFace }
                .rotationEffect(.degrees(-6))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 18)
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.12),
                                           .init(color: .black, location: 0.82),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .accessibilityHidden(true)
    }

    /// The watch's screen as it sits in the cutout (835x992 px): an ellipse
    /// centered at (0.640, 0.4175) with semi-axes 279 and 303 px, tilted 14.4 degrees.
    /// A progress ring is drawn on it while syncing.
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
                Ellipse().trim(from: 0, to: max(0.02, min(progress ?? 0, 1)))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
                    .shadow(color: .green.opacity(0.7), radius: 4)
                VStack(spacing: 1) {
                    Text("\(Int(((progress ?? 0) * 100).rounded()))%")
                        .font(.system(size: screenWidth * 0.27, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("SYNCING")
                        .font(.system(size: screenWidth * 0.085, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.green)
                }
            }
            .frame(width: screenWidth, height: screenHeight)
            .rotationEffect(.degrees(-14.43))
            .position(x: 0.640 * geo.size.width, y: 0.4175 * geo.size.height)
            .opacity(progress == nil ? 0 : 1)
            .animation(.smooth, value: progress == nil)
        }
        .allowsHitTesting(false)
    }
}

/// One ring of the Today view.
struct RingArc: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.012, min(progress, 1)))
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, min(progress, 1)))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.55), radius: 6)
        }
    }
}

/// A big number with a glowing icon, no container.
struct BigMetric: View {
    var symbol: String
    var color: Color
    var title: String
    var value: String
    var unit: String
    var live = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color.gradient)
                .shadow(color: color.opacity(0.6), radius: 8)
                .symbolEffect(.pulse, isActive: live)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(title).font(.caption).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A recent activity as a floating tile: glowing sport icon, big number.
struct ActivityTile: View {
    var activity: FitnessActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(activity.color.opacity(0.35)).frame(width: 64, height: 64).blur(radius: 14)
                Circle().fill(activity.color.gradient).frame(width: 56, height: 56)
                Image(systemName: activity.symbol).font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
            Text(activity.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(activity.hasDistance ? FitnessFormat.distance(activity.distanceMeters) : FitnessFormat.duration(activity.duration))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            HStack(spacing: 8) {
                if activity.hasDistance { Text(FitnessFormat.duration(activity.duration)) }
                if let hr = activity.avgHr { Label("\(hr)", systemImage: "heart.fill").labelStyle(TintedDot(color: .red)) }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let start = activity.start {
                Text(start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 140, alignment: .leading)
    }
}
