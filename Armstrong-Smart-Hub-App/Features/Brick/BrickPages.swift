import SwiftUI

#if os(iOS)
import FamilyControls

// MARK: Modes

/// Every mode as a card. Tap a card to edit it; the circle makes it the mode the next Brick uses.
struct BrickModesPage: View {
    let store: BrickStore
    @Binding var path: [BrickRoute]

    var body: some View {
        BrickPage(title: "Modes") {
            ForEach(store.profiles) { p in
                let chosen = store.selectedID == p.id
                ZStack(alignment: .leading) {
                    NavigationLink(value: BrickRoute.mode(p.id)) {
                        HStack(spacing: 14) {
                            // Room for the circle, which sits on top as its own button.
                            Color.clear.frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.system(size: 19, weight: .medium))
                                Text(modeSummary(p)).font(.system(size: 15)).foregroundStyle(BrickLook.soft)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium))
                                .foregroundStyle(BrickLook.soft)
                        }
                        .padding(20)
                        .background(BrickLook.card, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button { if !store.isBlocking { store.selectedID = p.id } } label: {
                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(chosen ? BrickLook.bar : BrickLook.soft)
                            .frame(width: 26, height: 26)
                            .padding(10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                    .accessibilityLabel(chosen ? "\(p.name), selected" : "Use \(p.name)")
                }
            }
            if store.isBlocking {
                Text("Modes can't change while bricked.").font(.footnote).foregroundStyle(BrickLook.soft)
            } else {
                Button { path.append(.mode(store.addProfile())) } label: {
                    VStack(spacing: 16) {
                        Text("New mode").font(.system(size: 18)).foregroundStyle(BrickLook.soft)
                        BrickPlus()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 24)
            }
        }
    }

    private func modeSummary(_ p: BrickProfile) -> String {
        var parts = [p.blockedCount == 1 ? "Blocks 1 app" : "Blocks \(p.blockedCount) apps"]
        if p.strict { parts.append("Strict") }
        if let m = p.timerMinutes { parts.append("\(m) min") }
        let tags = store.tags.filter { $0.profileID == p.id }.map(\.name)
        if !tags.isEmpty { parts.append(tags.joined(separator: ", ")) }
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
                BrickCard(padding: 0) {
                    VStack(spacing: 0) {
                        TextField("Name", text: Binding(get: { p.name }, set: { var q = p; q.name = $0; store.update(q) }))
                            .font(.system(size: 18)).padding(.vertical, 20)
                        BrickDivider()
                        Button { picking = true } label: {
                            BrickRow(icon: "apps.iphone", title: "Apps and sites",
                                     value: p.blockedCount == 0 ? "Choose" : "\(p.blockedCount)")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
                BrickCard {
                    Toggle(isOn: Binding(get: { p.strict }, set: { var q = p; q.strict = $0; store.update(q) })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Strict").font(.system(size: 18))
                            Text("Only your Brick, or an emergency unbrick, ends it.")
                                .font(.system(size: 15)).foregroundStyle(BrickLook.soft)
                        }
                    }
                    .tint(BrickLook.bar)
                    BrickDivider().padding(.vertical, 18)
                    Stepper(value: Binding(get: { p.timerMinutes ?? 0 },
                                           set: { var q = p; q.timerMinutes = $0 > 0 ? $0 : nil; store.update(q) }),
                            in: 0...480, step: 15) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-unbrick").font(.system(size: 18))
                            Text(p.timerMinutes.map { "After \(brickDuration(Double($0) * 60))" } ?? "Off, until you tap")
                                .font(.system(size: 15)).foregroundStyle(BrickLook.soft)
                        }
                    }
                }
                if store.profiles.count > 1 {
                    Button("Delete mode", role: .destructive) { store.delete(p); dismiss() }
                        .font(.system(size: 17)).padding(.top, 12)
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
                BrickCard(padding: 0) {
                    VStack(spacing: 0) {
                        TextField("Name", text: bind(s, \.name)).font(.system(size: 18)).padding(.vertical, 20)
                        BrickDivider()
                        Toggle("On", isOn: bind(s, \.enabled)).font(.system(size: 18)).tint(BrickLook.bar).padding(.vertical, 14)
                    }
                    .padding(.horizontal, 24)
                }
                BrickCard {
                    DatePicker("Bricks at", selection: timeBinding(s), displayedComponents: .hourAndMinute)
                        .font(.system(size: 18))
                    BrickDivider().padding(.vertical, 18)
                    Text("Days").font(.system(size: 18))
                    HStack(spacing: 8) {
                        ForEach(1...7, id: \.self) { d in
                            let on = s.weekdays.contains(d)
                            Button {
                                var q = s
                                if on { q.weekdays.remove(d) } else { q.weekdays.insert(d) }
                                store.update(q)
                            } label: {
                                Text(Calendar.current.veryShortWeekdaySymbols[d - 1])
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity).frame(height: 40)
                                    .background(on ? BrickLook.bar : BrickLook.track, in: Circle())
                                    .foregroundStyle(on ? Color.white : BrickLook.ink)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 14)
                    BrickDivider().padding(.vertical, 18)
                    Picker("Mode", selection: bind(s, \.profileID)) {
                        ForEach(store.profiles) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    .font(.system(size: 18))
                }
                Takeaway(text: "Bricks within an hour of the start time while the app is open or next opened. Your Brick ends it.")
                    .padding(.horizontal, 4)
                Button("Delete schedule", role: .destructive) { store.delete(s); dismiss() }
                    .font(.system(size: 17)).padding(.top, 12)
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

/// The week in full: average, chart, a card per day, totals, and iOS's own Screen Time.
struct BrickActivityPage: View {
    let store: BrickStore
    @State private var weeksBack = 0

    var body: some View {
        let week = store.week(weeksBack)
        let shown = week.filter { $0.date <= Date() }.reversed()
        let total = week.reduce(0) { $0 + $1.value }
        let count = week.reduce(0) { $0 + store.sessions(on: $1.date).count }
        ScrollView {
            VStack(spacing: 0) {
                Menu {
                    Picker("Week", selection: $weeksBack) {
                        Text("This week").tag(0)
                        Text("Last week").tag(1)
                        Text("2 weeks ago").tag(2)
                        Text("3 weeks ago").tag(3)
                    }
                } label: {
                    VStack(spacing: 18) {
                        BrickHeading(title: "Weekly Activity", chevron: true)
                        BrickCaps(text: weekLabel(week))
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 8).padding(.bottom, 22)
                BrickAverage(value: store.average(week)).padding(.horizontal, Fit.gutter).padding(.vertical, 20)
                BrickWeekChart(days: week).padding(.top, 8)
                HStack(spacing: 0) {
                    stat(brickDuration(total), "Total")
                    stat("\(count)", count == 1 ? "Session" : "Sessions")
                    stat("\(store.streak)", "Day streak")
                }
                .padding(.vertical, 22)
                .background(BrickLook.card, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
                .padding(.horizontal, Fit.gutter).padding(.top, 28)
                VStack(spacing: 16) {
                    ForEach(Array(shown)) { d in
                        BrickDayCard(day: d.date, seconds: d.value, sessions: store.sessions(on: d.date))
                    }
                }
                .padding(.horizontal, Fit.gutter).padding(.top, 16)
                NavigationLink(value: BrickRoute.screenTime) {
                    BrickCard(padding: 0) {
                        BrickRow(icon: "hourglass", title: "Screen Time", value: nil).padding(.horizontal, 24)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Fit.gutter).padding(.top, 40)
            }
            .padding(.bottom, 48)
        }
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrickLook.page, for: .navigationBar)
    }

    private func weekLabel(_ week: [DayValue]) -> String {
        if weeksBack == 0 { return "This week" }
        if weeksBack == 1 { return "Last week" }
        guard let a = week.first?.date, let b = week.last?.date else { return "" }
        return "\(a.formatted(.dateTime.month(.abbreviated).day())) – \(b.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 24).monospacedDigit())
            Text(label).font(.system(size: 14)).foregroundStyle(BrickLook.soft)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Settings pages

/// Every tag that locks and unlocks. Each can start its own mode, so a tag by the bed and one on the desk block different things.
struct BrickTagPage: View {
    let store: BrickStore

    var body: some View {
        BrickPage(title: "My Bricks") {
            Image("BrickDevice").resizable().scaledToFit().frame(width: 140, height: 140)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 12)
                .padding(.vertical, 28)
            ForEach(store.tags) { tag in
                BrickTagCard(store: store, tag: tag)
            }
            BrickCard(padding: 0) {
                Button { store.registerTag() } label: {
                    BrickRow(icon: "plus.viewfinder", title: store.hasTag ? "Add another tag" : "Register tag", value: nil)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
            if store.isBlocking {
                Text("Tags can't change while bricked.").font(.footnote).foregroundStyle(BrickLook.soft)
            }
            Takeaway(text: "Any NFC sticker works (NTAG213 and up). Its ID becomes a key. A tag with a mode starts that mode and only it can end it; a tag set to Any starts the selected mode and ends any Brick.")
                .padding(.horizontal, 4)
            Takeaway(text: "To use a tag without opening the app: in Shortcuts, add an Automation \u{2192} NFC, scan the tag, set it to Run Immediately, and add Tap Brick tag with this tag.")
                .padding(.horizontal, 4)
        }
        .disabled(store.isBlocking)
    }
}

/// One tag: its name, the mode it starts, and a way to remove it.
private struct BrickTagCard: View {
    let store: BrickStore
    var tag: BrickTag
    @State private var confirming = false

    var body: some View {
        BrickCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: "wave.3.right").font(.system(size: 20, weight: .light)).frame(width: 26)
                    TextField("Name", text: Binding(get: { tag.name }, set: { var t = tag; t.name = $0; store.update(t) }))
                        .font(.system(size: 18))
                    Text(String(tag.id.prefix(8)).uppercased())
                        .font(.system(size: 15).monospacedDigit()).foregroundStyle(BrickLook.soft)
                }
                .padding(.vertical, 20)
                BrickDivider()
                Picker(selection: Binding(get: { tag.profileID }, set: { var t = tag; t.profileID = $0; store.update(t) })) {
                    Text("Any (selected mode)").tag(UUID?.none)
                    ForEach(store.profiles) { p in Text(p.name).tag(Optional(p.id)) }
                } label: {
                    Text("Mode").font(.system(size: 18))
                }
                .padding(.vertical, 14)
                BrickDivider()
                Button("Remove tag", role: .destructive) { confirming = true }
                    .font(.system(size: 17)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                    .confirmationDialog("Remove \(tag.name)? It will stop working as a key.", isPresented: $confirming,
                                        titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { store.delete(tag) }
                    }
            }
            .padding(.horizontal, 24)
        }
    }
}

/// A small allowance of unlocks without the tag.
struct BrickEmergencyPage: View {
    let store: BrickStore
    @State private var confirming = false

    var body: some View {
        BrickPage(title: "Emergency Unbrick") {
            VStack(spacing: 8) {
                Text("\(store.emergencyLeft)").font(.system(size: 72, weight: .light).monospacedDigit())
                Text("of \(BrickStore.emergencyAllowance) left").font(.system(size: 18)).foregroundStyle(BrickLook.soft)
            }
            .padding(.vertical, 32)
            Button { confirming = true } label: {
                Text("Emergency Unbrick")
                    .font(.system(size: 18, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                    .background(BrickLook.pill, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(!store.isBlocking || store.emergencyLeft == 0)
            .opacity(store.isBlocking && store.emergencyLeft > 0 ? 1 : 0.5)
            .confirmationDialog("Use one of your \(store.emergencyLeft) emergency unbricks?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Unbrick", role: .destructive) { store.emergencyUnbrick() }
            }
            Takeaway(text: store.isBlocking
                     ? "Ends this Brick without the tag. They don't come back, so save them for when you really need your phone."
                     : "For when you're bricked and away from your Brick. Ends the session without the tag. They don't come back.")
                .padding(.horizontal, 4).padding(.top, 8)
        }
    }
}
#endif
