import SwiftUI

#if os(iOS)
import DeviceActivity

// Must match the names in BrickReport/BrickReport.swift. iOS draws these from that extension;
// the app never sees the numbers, only places the view.
extension DeviceActivityReport.Context {
    static let brickSummary = Self("BrickScreenTimeSummary")
    static let brickFull = Self("BrickScreenTime")
}

private func screenTimeFilter(week: Bool) -> DeviceActivityFilter {
    let cal = Calendar.current
    let now = Date()
    let segment: DeviceActivityFilter.SegmentInterval = week
        ? .daily(during: cal.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: cal.startOfDay(for: now), end: now))
        : .hourly(during: DateInterval(start: cal.startOfDay(for: now), end: now))
    return DeviceActivityFilter(segment: segment, users: .all, devices: .init([.iPhone]))
}

/// A clear UIKit view that catches touches meant for a view drawn by another process.
/// A SwiftUI overlay isn't enough: it adds no UIView, so UIKit still hands the touch to the report.
/// The scroll view above still sees drags through this; taps call `onTap`.
private struct TouchShield: UIViewRepresentable {
    var onTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.onTap = onTap }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func tap() { onTap() }
    }
}

/// The Brick page's Screen Time block: today's total and top apps, then a link to the rest.
/// The report is drawn by another process and swallows touches (and scrolling), so it ignores them
/// and the card is the link to the rest.
struct BrickScreenTimeSection: View {
    let store: BrickStore
    @Binding var path: [BrickRoute]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                BrickHeading(title: "Screen Time")
                BrickCaps(text: "Today")
            }
            .padding(.bottom, 22)
            if store.authorized {
                DeviceActivityReport(.brickSummary, filter: screenTimeFilter(week: false))
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
                    .allowsHitTesting(false)
                    // A real UIView on top takes the touch before the report can, so drags scroll the page.
                    .overlay { TouchShield { path.append(.screenTime) } }
                    .padding(.horizontal, Fit.gutter)
                NavigationLink(value: BrickRoute.screenTime) {
                    HStack(spacing: 6) {
                        Text("All screen time")
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium))
                    }
                    .font(.system(size: 17, weight: .medium))
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            } else {
                Button { Task { await store.authorize() } } label: {
                    BrickCard {
                        Text("Allow Screen Time access to see where your time goes.")
                            .font(.system(size: 17)).foregroundStyle(BrickLook.soft)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Fit.gutter)
            }
        }
    }
}

/// The full breakdown, for today or this week.
struct BrickScreenTimePage: View {
    let store: BrickStore
    @State private var week = false

    var body: some View {
        VStack(spacing: 16) {
            Picker("Range", selection: $week) {
                Text("Today").tag(false)
                Text("This week").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Fit.gutter)
            DeviceActivityReport(.brickFull, filter: screenTimeFilter(week: week))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 8)
        .hubPageStyle()
        .navigationTitle("Screen Time")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
