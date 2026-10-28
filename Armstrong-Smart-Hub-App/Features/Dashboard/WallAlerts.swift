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

    /// Bump to show the sample round again; each sample goes for good once its X is tapped.
    static let testRound = 2

    /// One of each popup with sample content, to see them all once.
    @MainActor
    private static func samples() -> [WallAlert] {
        let r = testRound
        let stopped = try? JSONDecoder().decode(PiContainer.self, from: Data("""
            {"name":"test-service","state":"exited","status":"Exited (1) 2 minutes ago · a sample","health":null,"image":"sample"}
            """.utf8))
        return [
            .pi(stopped.map { [$0] } ?? [], key: "test\(r):pi"),
            .wake(key: "test\(r):wake"),
            .birthday(title: "Sample's birthday", calendar: "Birthdays (sample)", key: "test\(r):birthday"),
        ]
    }

    /// The popups due right now, in the order they show.
    @MainActor
    static func queue(now: Date, pi: PiStatus?, alarm: WakeAlarm, calendar: CalendarResponse?,
                      dismissed: Set<String>, kept: Set<String> = []) -> [WallAlert] {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        var out: [WallAlert] = samples()

        if let pi, pi.available, !pi.troubled.isEmpty {
            out.append(.pi(pi.troubled, key: "pi:" + pi.troubled.map(\.name).sorted().joined(separator: ",")))
        }

        // 10 PM to 3 AM counts as one night, keyed by the evening it started. It shows while no
        // alarm is set, and stays (now showing the time) once one is set from it, until its X.
        if hour >= 22 || hour < 3 {
            let evening = cal.date(byAdding: .hour, value: -6, to: now) ?? now
            let key = "wake:" + DayFormat.string(evening, zone: .current)
            if alarm.scheduled == nil || kept.contains(key) { out.append(.wake(key: key)) }
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

/// Which popups were closed, kept across launches, newest last.
@MainActor
@Observable
final class WallAlertsStore {
    private var order: [String]
    private(set) var dismissed: Set<String>
    private static let key = "wall.dismissedAlerts"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        order = saved
        dismissed = Set(saved)
    }

    /// Popups that stay up after what would end them (an alarm set from the wake-up popup), until
    /// their X. Just for this launch.
    private(set) var kept: Set<String> = []

    func keep(_ alert: WallAlert) { kept.insert(alert.id) }

    func dismiss(_ alert: WallAlert) {
        order.removeAll { $0 == alert.id }
        order.append(alert.id)
        // Only recent ones matter; keep the newest so the list doesn't grow forever.
        order = Array(order.suffix(80))
        dismissed = Set(order)
        UserDefaults.standard.set(order, forKey: Self.key)
    }
}

/// A popup is the whole screen, in the cards' quiet style: a caps label, one big light line, a
/// short note, and the X in the corner. Nothing else closes it.
struct WallPopup: View {
    let alert: WallAlert
    let pi: PiStore
    let alarm: WakeAlarm
    let home: HomeStore
    let toast: Toast
    /// Keeps the popup up after its alarm is set, so it closes only with the X.
    var onKeep: () -> Void = {}
    let onClose: () -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        ZStack(alignment: .topTrailing) {
            BrickLook.page.ignoresSafeArea()
            content
                .frame(maxWidth: 640)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .light))
                    .frame(width: 60, height: 60)
                    .background(BrickLook.card, in: .circle)
            }
            .buttonStyle(CardPressStyle())
            .padding(28)
            .accessibilityLabel("Close")
        }
        .foregroundStyle(BrickLook.ink)
        // The wall tints with its ink, which is near white in dark mode; the hub's blue reads in both.
        .tint(Fit.action)
    }

    private func headline(_ caps: String, _ title: String, _ note: String?) -> some View {
        VStack(spacing: 14) {
            BrickCaps(text: caps).foregroundStyle(BrickLook.soft)
            Text(title)
                .font(.system(size: 64, weight: .light))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            if let note {
                Text(note).font(.system(size: 20)).foregroundStyle(BrickLook.soft).multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch alert {
        case .pi(let down, _):
            VStack(spacing: 40) {
                headline("Raspberry Pi",
                         down.count == 1 ? "\(down[0].name) is down" : "\(down.count) services down",
                         down.count == 1 ? down[0].status : down.map(\.name).joined(separator: ", "))
                VStack(spacing: 12) {
                    ForEach(down) { c in
                        HStack(spacing: 16) {
                            Circle().fill(.orange).frame(width: 10, height: 10)
                            Text(c.name).font(.system(size: 22, weight: .regular))
                            Spacer(minLength: 8)
                            if pi.busy == c.name {
                                ProgressView()
                            } else {
                                let action: PiStore.Action = c.running ? .restart : .start
                                Button(action == .start ? "Start" : "Restart") {
                                    Task { await pi.control(c, action, api: session.api, toast: toast) }
                                }
                                .font(.system(size: 18, weight: .medium))
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .background(BrickLook.card, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
                    }
                }
            }

        case .wake:
            VStack(spacing: 32) {
                headline("Wake-up",
                         alarm.scheduled.map { "Alarm set for \($0.formatted(date: .omitted, time: .shortened))" } ?? "Set tomorrow's alarm",
                         nil)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: alarm.scheduled)
                WakeEditor(alarm: alarm) {
                    onKeep()
                    Task { await alarm.set(home: home, api: session.api, toast: toast) }
                } onOff: {
                    onKeep()
                    Task { await alarm.cancel(home: home, api: session.api, toast: toast) }
                }
                .background(BrickLook.card, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
            }

        case .birthday(let title, let calendar, _):
            VStack(spacing: 28) {
                Text("🎂").font(.system(size: 120))
                headline("Birthday", title, "Today · \(calendar)")
            }
        }
    }
}
