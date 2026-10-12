import AlarmKit
import Foundation
import Observation
import SwiftUI

/// Tomorrow's wake-up, set from the iPad each evening. One time drives
/// everything: AlarmKit alarms on this iPad (plus an optional second one ten
/// minutes later) and a hub automation that ramps William's room lamp from
/// off to 100% over the 15 minutes before.
@MainActor
@Observable
final class WakeAlarm {
    static let lampEntity = "light.williamroomlamp"
    static let automationName = "Wake-up lamp"
    static let rampMinutes = 15
    static let followUpMinutes = 10

    /// The next alarm, or nil when none is set (or it has gone off).
    private(set) var scheduled: Date?
    private(set) var followUpScheduled = false
    private(set) var working = false

    /// The time and toggle the picker opens with: whatever was used last.
    var hour: Int
    var minute: Int
    var followUp: Bool

    private let defaults = UserDefaults.standard

    init() {
        hour = defaults.object(forKey: "wake.hour") as? Int ?? 8
        minute = defaults.object(forKey: "wake.minute") as? Int ?? 0
        followUp = defaults.object(forKey: "wake.followUp") as? Bool ?? true
        if let date = defaults.object(forKey: "wake.scheduled") as? Date, date > .now {
            scheduled = date
            followUpScheduled = defaults.bool(forKey: "wake.followUpScheduled")
        }
    }

    /// Drops an alarm that has already gone off.
    func expireIfPast() {
        if let s = scheduled, s.addingTimeInterval(Double(Self.followUpMinutes) * 60) < .now { forget() }
    }

    /// The next time the clock reads hour:minute (tomorrow if that's already passed today).
    func nextDate(hour: Int, minute: Int, after now: Date = .now) -> Date {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    func set(home: HomeStore, api: APIClient, toast: Toast) async {
        working = true
        defer { working = false }
        let date = nextDate(hour: hour, minute: minute)
        defaults.set(hour, forKey: "wake.hour")
        defaults.set(minute, forKey: "wake.minute")
        defaults.set(followUp, forKey: "wake.followUp")

        // The alarm matters most, so it goes first; a lamp problem shouldn't stop it.
        do {
            try await scheduleAlarms(at: date, followUp: followUp)
        } catch {
            toast.show(alarmMessage(error), error: true)
            return
        }
        scheduled = date
        followUpScheduled = followUp
        defaults.set(date, forKey: "wake.scheduled")
        defaults.set(followUp, forKey: "wake.followUpScheduled")

        do {
            try await saveAutomation(wake: date, home: home, api: api)
            toast.show("Alarm set for \(date.formatted(date: .omitted, time: .shortened))")
        } catch {
            toast.show("Alarm set, but the lamp couldn't be scheduled: \(error.localizedDescription)", error: true)
        }
    }

    func cancel(home: HomeStore, api: APIClient, toast: Toast) async {
        working = true
        defer { working = false }
        cancelAlarms()
        forget()
        if let automation = existingAutomation(home), automation.state == "on" {
            do {
                let _: Empty? = try await api.run("setAutomationEnabled", [.string(automation.id), .bool(false)])
                await home.refresh(api: api)
            } catch {
                toast.error(error)
                return
            }
        }
        toast.show("Wake-up turned off")
    }

    // MARK: AlarmKit

    private struct Metadata: AlarmMetadata {}

    private var alarmIDs: [UUID] {
        get { (defaults.stringArray(forKey: "wake.alarmIDs") ?? []).compactMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue.map(\.uuidString), forKey: "wake.alarmIDs") }
    }

    private func scheduleAlarms(at date: Date, followUp: Bool) async throws {
        let manager = AlarmManager.shared
        if manager.authorizationState == .notDetermined {
            _ = try await manager.requestAuthorization()
        }
        guard manager.authorizationState == .authorized else { throw AlarmDenied() }

        cancelAlarms()
        var ids: [UUID] = []
        let times = followUp ? [date, date.addingTimeInterval(Double(Self.followUpMinutes) * 60)] : [date]
        for (i, time) in times.enumerated() {
            let attributes = AlarmAttributes<Metadata>(
                presentation: AlarmPresentation(alert: .init(title: i == 0 ? "Wake up" : "Wake up, second alarm")),
                tintColor: .orange
            )
            let id = UUID()
            _ = try await manager.schedule(id: id, configuration: .alarm(schedule: .fixed(time), attributes: attributes))
            ids.append(id)
        }
        alarmIDs = ids
    }

    private func cancelAlarms() {
        for id in alarmIDs { try? AlarmManager.shared.cancel(id: id) }
        alarmIDs = []
    }

    private func forget() {
        scheduled = nil
        followUpScheduled = false
        defaults.removeObject(forKey: "wake.scheduled")
        defaults.removeObject(forKey: "wake.followUpScheduled")
    }

    private struct AlarmDenied: Error {}

    private func alarmMessage(_ error: Error) -> String {
        error is AlarmDenied
            ? "Alarms aren't allowed. Turn them on in Settings › Apps › Armstrong Hub."
            : "Couldn't set the alarm: \(error.localizedDescription)"
    }

    // MARK: Lamp automation

    private func existingAutomation(_ home: HomeStore) -> HAAutomation? {
        home.state?.automations?.automations.first { $0.hubMade && $0.name == Self.automationName }
    }

    /// Creates or moves the one-day lamp ramp that ends at the alarm.
    private func saveAutomation(wake: Date, home: HomeStore, api: APIClient) async throws {
        if home.state?.automations == nil { await home.refresh(api: api) }
        let start = wake.addingTimeInterval(-Double(Self.rampMinutes) * 60)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let at = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let rule: JSONValue = [
            "name": .string(Self.automationName),
            "trigger": ["type": "time", "at": .string(at)],
            "conditions": ["date": .string(day)],
            "actions": [["action": "on", "entity": .string(Self.lampEntity), "rampMinutes": .int(Self.rampMinutes)]],
        ]
        let existing = existingAutomation(home)
        var args: [JSONValue] = [rule]
        if let configId = existing?.configId { args.append(.string(configId)) }
        let _: Empty? = try await api.run("saveAutomation", args)
        if let existing, existing.state != "on" {
            let _: Empty? = try await api.run("setAutomationEnabled", [.string(existing.id), .bool(true)])
        }
        await home.refresh(api: api)
    }
}

/// Next to the clock: the alarm time when one is set, a quiet "Set wake-up"
/// in the evening, and nothing otherwise.
struct WakeControl: View {
    let alarm: WakeAlarm
    let home: HomeStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @State private var editing = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let hour = Calendar.current.component(.hour, from: context.date)
            // TODO: back to 21 after testing.
            let evening = hour >= 18 || hour < 3
            Group {
                if let date = alarm.scheduled {
                    Button { editing = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "alarm.fill")
                            Text(date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                            if alarm.followUpScheduled { Text("+\(WakeAlarm.followUpMinutes)").foregroundStyle(.tertiary) }
                        }
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                } else if evening {
                    Button { editing = true } label: {
                        Label("Set wake-up", systemImage: "alarm")
                            .font(.title3.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .buttonStyle(.plain)
            .onChange(of: context.date) { alarm.expireIfPast() }
        }
        .popover(isPresented: $editing, arrowEdge: .top) {
            WakeEditor(alarm: alarm) {
                editing = false
                Task { await alarm.set(home: home, api: session.api, toast: toast) }
            } onOff: {
                editing = false
                Task { await alarm.cancel(home: home, api: session.api, toast: toast) }
            }
        }
    }
}

private struct WakeEditor: View {
    @Bindable var alarm: WakeAlarm
    let onSet: () -> Void
    let onOff: () -> Void

    var body: some View {
        let time = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                alarm.hour = c.hour ?? 8
                alarm.minute = c.minute ?? 0
            }
        )
        VStack(spacing: 16) {
            DatePicker("Wake up", selection: time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
            Toggle("Second alarm \(WakeAlarm.followUpMinutes) min later", isOn: $alarm.followUp)
            Text("The lamp fades up over the \(WakeAlarm.rampMinutes) minutes before.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                if alarm.scheduled != nil {
                    Button("Turn off", role: .destructive, action: onOff).buttonStyle(.bordered)
                }
                Button(action: onSet) {
                    Text("Set").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .disabled(alarm.working)
        }
        .padding(20)
        .frame(width: 320)
    }
}
