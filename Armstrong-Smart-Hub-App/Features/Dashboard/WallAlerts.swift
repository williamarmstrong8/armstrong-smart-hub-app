import Foundation
import Observation
import SwiftUI

/// What the wall needs you to see, one full-screen popup at a time, most urgent first: a
/// service on the Pi that's down, then (after 10 PM, with no alarm set) tomorrow's wake-up,
/// then a birthday today (from 7 AM). Each stays until its X is tapped; then the next shows.
/// A dismissed popup stays dismissed (the Pi's comes back if a different service goes down).
enum WallAlert: Identifiable, Equatable {
    case pi([PiContainer], key: String)
    case wake(key: String)
    case birthday(title: String, calendar: String, key: String)

    var id: String {
        switch self {
        case .pi(_, let key), .wake(let key), .birthday(_, _, let key): key
        }
    }

    /// The popups due right now, in the order they show.
    @MainActor
    static func queue(now: Date, pi: PiStatus?, alarm: WakeAlarm, calendar: CalendarResponse?, dismissed: Set<String>) -> [WallAlert] {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        var out: [WallAlert] = []

        if let pi, pi.available, !pi.troubled.isEmpty {
            out.append(.pi(pi.troubled, key: "pi:" + pi.troubled.map(\.name).sorted().joined(separator: ",")))
        }

        // 10 PM to 3 AM counts as one night, keyed by the evening it started.
        if alarm.scheduled == nil, hour >= 22 || hour < 3 {
            let evening = cal.date(byAdding: .hour, value: -6, to: now) ?? now
            out.append(.wake(key: "wake:" + DayFormat.string(evening, zone: .current)))
        }

        if hour >= 7, let calendar, let today = calendar.today {
            let events = calendar.days.first { $0.day == today }?.events ?? []
            for e in events where e.title.localizedCaseInsensitiveContains("birthday") || e.calendar.localizedCaseInsensitiveContains("birthday") {
                out.append(.birthday(title: e.title, calendar: e.calendar, key: "birthday:\(today):\(e.id)"))
            }
        }
        return out.filter { !dismissed.contains($0.id) }
    }
}

/// Which popups were closed, kept across launches.
@MainActor
@Observable
final class WallAlertsStore {
    private(set) var dismissed: Set<String>
    private static let key = "wall.dismissedAlerts"

    init() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func dismiss(_ alert: WallAlert) {
        dismissed.insert(alert.id)
        // Only recent ones matter; keep the list from growing forever.
        UserDefaults.standard.set(Array(dismissed.sorted().suffix(80)), forKey: Self.key)
    }
}

/// One popup over the dimmed wall. Tapping outside does nothing: only the X closes it.
struct WallPopup: View {
    let alert: WallAlert
    let pi: PiStore
    let alarm: WakeAlarm
    let home: HomeStore
    let toast: Toast
    let onClose: () -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture {} // Stays up until the X.
            content
                .padding(36)
                .frame(maxWidth: 580)
                .background(BrickLook.card, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(BrickLook.ink)
                            .frame(width: 52, height: 52)
                            .background(BrickLook.pill, in: .circle)
                    }
                    .buttonStyle(CardPressStyle())
                    .padding(16)
                    .accessibilityLabel("Close")
                }
                .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                .padding(32)
                .foregroundStyle(BrickLook.ink)
        }
    }

    @ViewBuilder private var content: some View {
        switch alert {
        case .pi(let down, _):
            VStack(spacing: 22) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64)).foregroundStyle(.orange)
                Text(down.count == 1 ? "\(down[0].name) is down" : "\(down.count) services are down")
                    .font(.system(size: 40, weight: .light)).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.6)
                VStack(spacing: 10) {
                    ForEach(down) { c in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.system(size: 20, weight: .semibold))
                                Text(c.status).font(.system(size: 15)).foregroundStyle(BrickLook.soft).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if pi.busy == c.name {
                                ProgressView()
                            } else {
                                let action: PiStore.Action = c.running ? .restart : .start
                                Button(action == .start ? "Start" : "Restart") {
                                    Task {
                                        await pi.control(c, action, api: session.api, toast: toast)
                                    }
                                }
                                .font(.system(size: 17, weight: .semibold))
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                                .tint(BrickLook.bar)
                            }
                        }
                        .padding(16)
                        .background(BrickLook.pill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }

        case .wake:
            VStack(spacing: 18) {
                Image(systemName: "alarm.fill").font(.system(size: 56)).foregroundStyle(.orange)
                Text("Set tomorrow's wake-up").font(.system(size: 36, weight: .light)).multilineTextAlignment(.center)
                WakeEditor(alarm: alarm) {
                    Task { await alarm.set(home: home, api: session.api, toast: toast) }
                } onOff: {}
            }

        case .birthday(let title, let calendar, _):
            VStack(spacing: 16) {
                Text("🎂").font(.system(size: 110))
                Text(title).font(.system(size: 44, weight: .light)).multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.6)
                Text("Today · \(calendar)").font(.system(size: 18)).foregroundStyle(BrickLook.soft)
            }
            .padding(.vertical, 12)
        }
    }
}
