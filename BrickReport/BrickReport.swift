import DeviceActivity
import ExtensionKit
import FamilyControls
import ManagedSettings
import SwiftUI

/// iOS only hands usage numbers to this extension; the Brick tab embeds what it draws.
/// Two views of the same numbers: a short one for the Brick page and the full breakdown.
@main
struct BrickReport: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        ScreenTimeScene(context: .summary) { SummaryView(report: $0) }
        ScreenTimeScene(context: .full) { FullView(report: $0) }
    }
}

// Must match the names the app asks for (BrickScreenTimePage.swift).
extension DeviceActivityReport.Context {
    static let summary = Self("BrickScreenTimeSummary")
    static let full = Self("BrickScreenTime")
}

// MARK: Numbers

struct AppUsage: Identifiable {
    var id: String
    var name: String
    var token: ApplicationToken?
    var seconds: TimeInterval
    var pickups: Int
    var notifications: Int
}

struct CategoryUsage: Identifiable {
    var id: String { name }
    var name: String
    var seconds: TimeInterval
}

/// One bar: an hour of a day, or a day of a week.
struct Slot: Identifiable {
    var id: Date { start }
    var start: Date
    var seconds: TimeInterval
}

struct ScreenTimeReport {
    var total: TimeInterval = 0
    var pickups = 0
    var notifications = 0
    var firstPickup: Date?
    var slots: [Slot] = []
    var apps: [AppUsage] = []
    var categories: [CategoryUsage] = []
    /// Hourly slots mean one day; daily slots mean a week.
    var hourly = false
}

struct ScreenTimeScene<Content: View>: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context
    let content: (ScreenTimeReport) -> Content

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> ScreenTimeReport {
        var r = ScreenTimeReport()
        var apps: [String: AppUsage] = [:]
        var cats: [String: TimeInterval] = [:]
        var slots: [Date: TimeInterval] = [:]
        for await d in data {
            for await seg in d.activitySegments {
                r.total += seg.totalActivityDuration
                slots[seg.dateInterval.start, default: 0] += seg.totalActivityDuration
                if seg.dateInterval.duration <= 3601 { r.hourly = true }
                if let first = seg.firstPickup { r.firstPickup = min(r.firstPickup ?? first, first) }
                r.pickups += seg.totalPickupsWithoutApplicationActivity
                for await cat in seg.categories {
                    let catName = cat.category.localizedDisplayName ?? "Other"
                    cats[catName, default: 0] += cat.totalActivityDuration
                    for await a in cat.applications {
                        let key = a.application.bundleIdentifier ?? a.application.localizedDisplayName ?? "App"
                        var u = apps[key] ?? AppUsage(id: key, name: a.application.localizedDisplayName ?? "App",
                                                      token: a.application.token, seconds: 0, pickups: 0, notifications: 0)
                        u.seconds += a.totalActivityDuration
                        u.pickups += a.numberOfPickups
                        u.notifications += a.numberOfNotifications
                        apps[key] = u
                        r.pickups += a.numberOfPickups
                        r.notifications += a.numberOfNotifications
                    }
                }
            }
        }
        // Every hour of the day, or every day of the week, even the empty ones, so bars line up with labels.
        let cal = Calendar.current
        if let first = slots.keys.min() {
            let (start, count, unit): (Date, Int, Calendar.Component) = r.hourly
                ? (cal.startOfDay(for: first), 24, .hour)
                : (cal.dateInterval(of: .weekOfYear, for: first)?.start ?? first, 7, .day)
            r.slots = (0..<count).map { i in
                let d = cal.date(byAdding: unit, value: i, to: start) ?? start
                return Slot(start: d, seconds: slots.first { cal.isDate($0.key, equalTo: d, toGranularity: unit) }?.value ?? 0)
            }
        }
        r.apps = apps.values.filter { $0.seconds >= 60 }.sorted { $0.seconds > $1.seconds }
        r.categories = cats.map { CategoryUsage(name: $0.key, seconds: $0.value) }
            .filter { $0.seconds >= 60 }.sorted { $0.seconds > $1.seconds }
        return r
    }
}

// MARK: Look (the Brick tab's colors, which this process can't import)

enum Look {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { t in
            let hex = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static let page = adaptive(0xD5D1D0, 0x161414)
    static let card = adaptive(0xE5E2E0, 0x2A2727)
    static let ink = adaptive(0x262322, 0xECE8E6)
    static let soft = adaptive(0x868180, 0x8F8A89)
    static let line = adaptive(0xC9C4C3, 0x3A3636)
    static let bar = adaptive(0x43505C, 0xA9B7C4)
    static let track = adaptive(0xD9D5D3, 0x3A3636)
    static let radius: CGFloat = 26
}

func duration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

// MARK: Views

/// The Brick page's card: today's total and the three apps that took most of it.
struct SummaryView: View {
    let report: ScreenTimeReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(duration(report.total)).font(.system(size: 34, weight: .regular).monospacedDigit())
                Spacer()
                Text("\(report.pickups) pickups").font(.system(size: 16)).foregroundStyle(Look.soft).monospacedDigit()
            }
            if report.apps.isEmpty {
                Text("No screen time yet today.").font(.system(size: 16)).foregroundStyle(Look.soft)
            } else {
                VStack(spacing: 14) {
                    ForEach(report.apps.prefix(3)) { AppRow(app: $0, top: report.apps.first?.seconds ?? 1) }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Look.card, in: RoundedRectangle(cornerRadius: Look.radius, style: .continuous))
        .background(Look.page)
        .foregroundStyle(Look.ink)
    }
}

/// The whole breakdown: total, when, by category, every app, pickups and notifications.
struct FullView: View {
    let report: ScreenTimeReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.hourly ? "Screen Time" : "Daily average").font(.system(size: 17)).foregroundStyle(Look.soft)
                        Text(duration(report.hourly ? report.total : report.total / Double(max(1, daysSoFar))))
                            .font(.system(size: 40, weight: .regular).monospacedDigit())
                        if !report.hourly {
                            Text("\(duration(report.total)) this week").font(.system(size: 16)).foregroundStyle(Look.soft)
                        }
                    }
                    SlotChart(slots: report.slots, hourly: report.hourly)
                    if !report.categories.isEmpty { CategoryStrip(categories: report.categories, total: report.total) }
                }
                .card()

                HStack(spacing: 0) {
                    stat("\(report.pickups)", "Pickups")
                    stat("\(report.notifications)", "Notifications")
                    if report.hourly {
                        stat(report.firstPickup.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–", "First pickup")
                    } else {
                        stat("\(report.pickups / max(1, daysSoFar))", "Pickups a day")
                    }
                }
                .padding(.vertical, 22)
                .background(Look.card, in: RoundedRectangle(cornerRadius: Look.radius, style: .continuous))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Most used").font(.system(size: 22))
                    if report.apps.isEmpty {
                        Text("Nothing yet.").font(.system(size: 16)).foregroundStyle(Look.soft)
                    }
                    ForEach(report.apps.prefix(25)) { AppRow(app: $0, top: report.apps.first?.seconds ?? 1, detail: true) }
                }
                .card()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Look.page)
        .foregroundStyle(Look.ink)
    }

    /// Days of the week with any use, so a Tuesday average isn't split over seven.
    private var daysSoFar: Int { report.slots.filter { $0.seconds > 0 }.count }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 22).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 13)).foregroundStyle(Look.soft)
        }
        .frame(maxWidth: .infinity)
    }
}

/// An app: icon, name, time, and a bar against the top app.
struct AppRow: View {
    let app: AppUsage
    let top: TimeInterval
    var detail = false

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let token = app.token {
                    Label(token).labelStyle(.iconOnly)
                } else {
                    Image(systemName: "app").foregroundStyle(Look.soft)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name).font(.system(size: 17)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(duration(app.seconds)).font(.system(size: 16)).foregroundStyle(Look.soft).monospacedDigit()
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Look.track)
                        Capsule().fill(Look.bar).frame(width: max(4, g.size.width * min(1, app.seconds / max(top, 1))))
                    }
                }
                .frame(height: 5)
                if detail, app.pickups + app.notifications > 0 {
                    Text("\(app.pickups) pickups · \(app.notifications) notifications")
                        .font(.system(size: 13)).foregroundStyle(Look.soft).monospacedDigit()
                }
            }
        }
    }
}

/// Hours of the day (or days of the week) as slate bars.
struct SlotChart: View {
    let slots: [Slot]
    let hourly: Bool
    private let height: CGFloat = 120

    var body: some View {
        let top = max(slots.map(\.seconds).max() ?? 0, hourly ? 1800 : 3600)
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: hourly ? 3 : 10) {
                ForEach(slots) { s in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(s.seconds > 0 ? Look.bar : Look.track)
                        .frame(height: max(2, CGFloat(s.seconds / top) * height))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 0) {
                if hourly {
                    ForEach(["12a", "6a", "12p", "6p"], id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    ForEach(slots) { s in
                        Text(s.start.formatted(.dateTime.weekday(.narrow))).frame(maxWidth: .infinity)
                    }
                }
            }
            .font(.system(size: 12)).foregroundStyle(Look.soft)
        }
    }
}

/// Categories as one stacked strip, with a legend under it.
struct CategoryStrip: View {
    let categories: [CategoryUsage]
    let total: TimeInterval
    private let shades: [Double] = [1, 0.7, 0.45, 0.28]

    var body: some View {
        let shown = Array(categories.prefix(4))
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, c in
                        Rectangle().fill(Look.bar.opacity(shades[i]))
                            .frame(width: max(2, g.size.width * c.seconds / max(total, 1)))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            ForEach(Array(shown.enumerated()), id: \.offset) { i, c in
                HStack(spacing: 8) {
                    Circle().fill(Look.bar.opacity(shades[i])).frame(width: 8, height: 8)
                    Text(c.name).font(.system(size: 15))
                    Spacer()
                    Text(duration(c.seconds)).font(.system(size: 15)).foregroundStyle(Look.soft).monospacedDigit()
                }
            }
        }
    }
}

extension View {
    func card() -> some View {
        padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Look.card, in: RoundedRectangle(cornerRadius: Look.radius, style: .continuous))
    }
}
