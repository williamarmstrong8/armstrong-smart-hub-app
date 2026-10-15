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

/// The watch, cut out and floating on the page, fading at the edges.
struct WatchHero: View {
    /// 0...1 while the watch syncs; nil shows the watch's own face.
    var progress: Double?

    var body: some View {
        ZStack {
            Image("GarminHero")
                .resizable()
                .scaledToFit()
                .frame(height: 190)
                .overlay { syncFace }
                .rotationEffect(.degrees(-6))
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
                Ellipse().trim(from: 0, to: max(0.02, min(progress ?? 0, 1)))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                    .frame(width: screenHeight - 2 * inset, height: screenWidth - 2 * inset)
                    .rotationEffect(.degrees(-90))
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
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(.primary)
                .symbolEffect(.pulse, isActive: live)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A recent activity as a floating tile: sport icon, big number.
struct ActivityTile: View {
    var activity: FitnessActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: activity.symbol)
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.primary)
                .frame(height: 48, alignment: .leading)
            Text(activity.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(activity.hasDistance ? FitnessFormat.distance(activity.distanceMeters) : FitnessFormat.duration(activity.duration))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            HStack(spacing: 8) {
                if activity.hasDistance { Text(FitnessFormat.duration(activity.duration)) }
                if let hr = activity.avgHr { Label("\(hr)", systemImage: "heart").font(.caption.weight(.light)) }
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
