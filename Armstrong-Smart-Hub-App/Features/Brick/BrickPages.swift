import SwiftUI

#if os(iOS)
import FamilyControls
import DeviceActivity

// MARK: Modes

/// Every mode in one list. Tap one to make it the mode the next Brick uses; the arrow edits it.
struct BrickModesPage: View {
    let store: BrickStore
    @Binding var path: [BrickRoute]

    var body: some View {
        BrickPage(title: "Modes") {
            BrickList {
                ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Divider().padding(.leading, 60) }
                    let chosen = store.selectedID == p.id
                    HStack(spacing: 12) {
                        Button { if !store.isBlocking { store.selectedID = p.id } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(chosen ? Color.accentColor : Color(.tertiaryLabel))
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.subheadline.weight(.medium))
                                    Text(modeSummary(p)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        NavigationLink(value: BrickRoute.mode(p.id)) {
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary).frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            if store.isBlocking {
                BrickNote(text: "Modes can't change while bricked.")
            } else {
                Button { path.append(.mode(store.addProfile())) } label: {
                    Label("New mode", systemImage: "plus").font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func modeSummary(_ p: BrickProfile) -> String {
        var parts = [p.blockedCount == 1 ? "Blocks 1 app" : "Blocks \(p.blockedCount) apps"]
        if p.strict { parts.append("Strict") }
        if let m = p.timerMinutes { parts.append("\(m) min") }
        return parts.joined(separator: " · ")
    }
}

/// One mode's controls: name, what it blocks, strict, and the auto-unlock timer.
struct BrickModePage: View {
    let store: BrickStore
    var id: UUID
    @State private var picking = false
    @Environment(\.dismiss) private var dismiss

    private var profile: BrickProfile? { store.profiles.first { $0.id == id } }
    private var locked: Bool { store.blockingProfileID == id }

    var body: some View {
        BrickPage(title: profile?.name ?? "Mode") {
            if let p = profile {
                BrickList {
                    TextField("Name", text: Binding(get: { p.name }, set: { var q = p; q.name = $0; store.update(q) }))
                        .font(.subheadline.weight(.medium)).padding(16)
                    Divider().padding(.leading, 16)
                    Button { picking = true } label: {
                        BrickRow(icon: "apps.iphone", title: "Apps and sites",
                                 value: p.blockedCount == 0 ? "Choose" : "\(p.blockedCount)")
                    }
                    .buttonStyle(.plain)
                }
                Card {
                    Toggle(isOn: Binding(get: { p.strict }, set: { var q = p; q.strict = $0; store.update(q) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Strict").font(.subheadline.weight(.medium))
                            Text("Only your Brick, or an emergency unbrick, ends it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Stepper(value: Binding(get: { p.timerMinutes ?? 0 },
                                           set: { var q = p; q.timerMinutes = $0 > 0 ? $0 : nil; store.update(q) }),
                            in: 0...480, step: 15) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-unbrick").font(.subheadline.weight(.medium))
                            Text(p.timerMinutes.map { "After \(brickDuration(Double($0) * 60))" } ?? "Off, until you tap")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if store.profiles.count > 1 {
                    Button("Delete mode", role: .destructive) { store.delete(p); dismiss() }
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.top, 8)
                }
            }
        }
        .disabled(locked)
        .familyActivityPicker(isPresented: $picking, selection: Binding(
            get: { profile?.selection ?? FamilyActivitySelection() },
            set: { new in
                guard var p = profile else { return }
                p.selection = new
                store.update(p)
            }))
    }
}

// MARK: Schedules

/// A schedule's time, days and mode.
struct BrickSchedulePage: View {
    let store: BrickStore
    var id: UUID
    @Environment(\.dismiss) private var dismiss

    private var schedule: BrickSchedule? { store.schedules.first { $0.id == id } }

    var body: some View {
        BrickPage(title: "Schedule") {
            if let s = schedule {
                Card {
                    TextField("Name", text: bind(s, \.name)).font(.subheadline.weight(.medium))
                    Divider()
                    Toggle("On", isOn: bind(s, \.enabled)).font(.subheadline.weight(.medium))
                }
                Card {
                    DatePicker("Bricks at", selection: timeBinding(s), displayedComponents: .hourAndMinute)
                        .font(.subheadline.weight(.medium))
                    Divider()
                    Text("Days").font(.subheadline.weight(.medium))
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { d in
                            let on = s.weekdays.contains(d)
                            Button {
                                var q = s
                                if on { q.weekdays.remove(d) } else { q.weekdays.insert(d) }
                                store.update(q)
                            } label: {
                                Text(Calendar.current.veryShortWeekdaySymbols[d - 1])
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity).frame(height: 38)
                                    .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: .circle)
                                    .foregroundStyle(on ? Color.white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider()
                    Picker("Mode", selection: bind(s, \.profileID)) {
                        ForEach(store.profiles) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    .font(.subheadline.weight(.medium))
                }
                BrickNote(text: "Bricks within an hour of the start time while the app is open or next opened. Your Brick ends it.")
                Button("Delete schedule", role: .destructive) { store.delete(s); dismiss() }
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.top, 8)
            }
        }
    }

    private func bind<T>(_ fallback: BrickSchedule, _ key: WritableKeyPath<BrickSchedule, T>) -> Binding<T> {
        Binding(get: { (schedule ?? fallback)[keyPath: key] }, set: { v in
            guard var s = schedule else { return }
            s[keyPath: key] = v
            store.update(s)
        })
    }

    private func timeBinding(_ s: BrickSchedule) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                var q = s
                q.hour = Calendar.current.component(.hour, from: d)
                q.minute = Calendar.current.component(.minute, from: d)
                store.update(q)
            })
    }
}

// MARK: Activity

/// The week in full: average, chart, totals, each day, and iOS's own Screen Time.
struct BrickActivityPage: View {
    let store: BrickStore
    @State private var weeksBack = 0

    var body: some View {
        let week = store.week(weeksBack)
        let shown = week.filter { $0.date <= Date() }.reversed()
        let total = week.reduce(0) { $0 + $1.value }
        let count = week.reduce(0) { $0 + store.sessions(on: $1.date).count }
        BrickPage(title: "Activity") {
            Picker("Week", selection: $weeksBack) {
                Text("This week").tag(0)
                Text("Last week").tag(1)
                Text("2 wks ago").tag(2)
                Text("3 wks ago").tag(3)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text("Average a day · \(weekLabel(week))").font(.subheadline).foregroundStyle(.secondary)
                if let avg = store.average(week) {
                    Text(brickDuration(avg))
                        .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                } else {
                    Text("Your first day is underway. Check back for your average.")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.vertical, 4)

            Card {
                BrickWeekChart(days: week)
                Divider()
                HStack(spacing: 0) {
                    stat(brickDuration(total), "Total")
                    stat("\(count)", count == 1 ? "Session" : "Sessions")
                    stat("\(store.streak)", "Day streak")
                }
            }

            SectionHeader(title: "Days").padding(.top, 8)
            BrickList {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Divider().padding(.leading, 16) }
                    BrickDayRow(day: d.date, seconds: d.value, sessions: store.sessions(on: d.date)).padding(16)
                }
            }

            SectionHeader(title: "Screen Time today").padding(.top, 8)
            let cal = Calendar.current
            DeviceActivityReport(DeviceActivityReport.Context("BrickScreenTime"),
                                 filter: DeviceActivityFilter(segment: .daily(during: DateInterval(start: cal.startOfDay(for: Date()), end: Date())),
                                                              users: .all, devices: .init([.iPhone])))
                .frame(minHeight: 360)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
    }

    private func weekLabel(_ week: [DayValue]) -> String {
        if weeksBack == 0 { return "This week" }
        if weeksBack == 1 { return "Last week" }
        guard let a = week.first?.date, let b = week.last?.date else { return "" }
        return "\(a.formatted(.dateTime.month(.abbreviated).day())) – \(b.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Settings pages

/// The tag that locks and unlocks: register or replace it.
struct BrickTagPage: View {
    let store: BrickStore

    var body: some View {
        BrickPage(title: "My Brick") {
            Image("BrickDevice").resizable().scaledToFit().frame(width: 120, height: 120)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            BrickList {
                BrickRow(icon: "wave.3.right", title: "Tag",
                         value: store.tagID.map { String($0.prefix(8)).uppercased() } ?? "Not set", chevron: false)
                Divider().padding(.leading, 60)
                Button { store.registerTag() } label: {
                    BrickRow(icon: "plus.viewfinder", title: store.tagID == nil ? "Register tag" : "Replace tag", value: nil)
                }
                .buttonStyle(.plain)
                .disabled(store.isBlocking)
            }
            BrickNote(text: "Any NFC sticker works (NTAG213 and up). Its ID becomes the key: tap it to Brick, tap it again to unbrick. Replacing it makes the old one stop working.")
        }
    }
}

/// A small allowance of unlocks without the tag.
struct BrickEmergencyPage: View {
    let store: BrickStore
    @State private var confirming = false

    var body: some View {
        BrickPage(title: "Emergency Unbrick") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Left").font(.subheadline).foregroundStyle(.secondary)
                Text("\(store.emergencyLeft) of \(BrickStore.emergencyAllowance)")
                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .padding(.vertical, 4)
            Button(role: .destructive) { confirming = true } label: {
                Text("Emergency Unbrick").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.isBlocking || store.emergencyLeft == 0)
            .confirmationDialog("Use one of your \(store.emergencyLeft) emergency unbricks?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Unbrick", role: .destructive) { store.emergencyUnbrick() }
            }
            BrickNote(text: store.isBlocking
                      ? "Ends this Brick without the tag. They don't come back, so save them for when you really need your phone."
                      : "For when you're bricked and away from your Brick. Ends the session without the tag. They don't come back.")
        }
    }
}
#endif
