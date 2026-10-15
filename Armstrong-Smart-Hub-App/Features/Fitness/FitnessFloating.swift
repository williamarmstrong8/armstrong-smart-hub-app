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
    var body: some View {
        ZStack {
            Circle().fill(Color.green.opacity(0.35)).frame(width: 220).blur(radius: 70).offset(x: -90, y: -40)
            Circle().fill(Color.blue.opacity(0.30)).frame(width: 240).blur(radius: 80).offset(x: 100, y: 30)
            Circle().fill(Color.red.opacity(0.22)).frame(width: 160).blur(radius: 60).offset(x: 60, y: -100)
            Image("GarminHero")
                .resizable()
                .scaledToFit()
                .frame(height: 300)
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
        .frame(height: 320)
        .accessibilityHidden(true)
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
