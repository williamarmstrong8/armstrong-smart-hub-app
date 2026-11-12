import SwiftUI

#if os(iOS)
import FamilyControls

// MARK: Modes

/// Every mode as a card. Tap a card to edit it; which tag starts it is set on the tag.
struct BrickModesPage: View {
    let store: BrickStore
    @Binding var path: [BrickRoute]

    var body: some View {
        BrickPage(title: "Modes") {
            ForEach(store.profiles) { p in
                NavigationLink(value: BrickRoute.mode(p.id)) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name).font(.system(size: 19, weight: .medium))
                            Text(modeSummary(p)).font(.system(size: 15)).foregroundStyle(BrickLook.soft)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(BrickLook.soft)
                    }
                    .padding(20)
                    .glassGlare(.regular.interactive(), in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)
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
        if p.restrictions.count > 0 { parts.append("\(p.restrictions.count) restrictions") }
        if p.lockdown { parts.append(store.isOn(p.id) ? "Lockdown on" : "Lockdown") }
        if p.strict { parts.append("Strict") }
        if let m = p.timerMinutes { parts.append("\(m) min") }
        let tags = store.tags.filter { $0.profileID == p.id }.map(\.name)
        parts.append(tags.isEmpty ? "No tag" : tags.joined(separator: ", "))
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
    private var locked: Bool { store.isOn(id) }

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
                        BrickDivider()
                        NavigationLink(value: BrickRoute.restrictions(p.id)) {
                            BrickRow(icon: "hand.raised", title: "Restrictions",
                                     value: p.restrictions.count == 0 ? "None" : "\(p.restrictions.count)")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
                BrickCard {
                    Toggle(isOn: Binding(get: { p.lockdown }, set: { var q = p; q.lockdown = $0; store.update(q) })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lockdown").font(.system(size: 18))
                            Text("Stays on alongside your Bricks and doesn't count as Brick time. Only its own tag ends it.")
                                .font(.system(size: 15)).foregroundStyle(BrickLook.soft)
                        }
                    }
                    .tint(BrickLook.bar)
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

/// Content & Privacy limits for one mode, on only while it's bricked.
struct BrickRestrictionsPage: View {
    let store: BrickStore
    var id: UUID

    private var profile: BrickProfile? { store.profiles.first { $0.id == id } }

    var body: some View {
        BrickPage(title: "Restrictions") {
            if let p = profile {
                BrickCard {
                    toggle(p, \.adultWebsites, "Block adult websites", "Filters adult sites in Safari and other browsers.")
                    BrickDivider().padding(.vertical, 18)
                    toggle(p, \.explicitMedia, "Block explicit content", "Hides explicit music, podcasts, books and video.")
                    BrickDivider().padding(.vertical, 18)
                    toggle(p, \.inAppPurchases, "Block in-app purchases", "No buying inside apps.")
                }
                BrickCard {
                    toggle(p, \.appInstalls, "Block installing apps", "No new apps, so there's no way around the block.")
                    BrickDivider().padding(.vertical, 18)
                    toggle(p, \.appRemoval, "Block deleting apps", "Apps can't be removed while bricked.")
                    BrickDivider().padding(.vertical, 18)
                    toggle(p, \.automaticTime, "Lock date and time", "Keeps date and time automatic, so a timer can't be skipped.")
                }
                BrickCard {
                    toggle(p, \.siri, "Turn off Siri", "Siri is off while bricked.")
                    BrickDivider().padding(.vertical, 18)
                    toggle(p, \.multiplayerGames, "Block multiplayer games", "No Game Center multiplayer and adding friends.")
                }
                Takeaway(text: "These turn on when \(p.name) bricks and lift when it ends, like Screen Time's Content & Privacy Restrictions.")
                    .padding(.horizontal, 4)
            }
        }
        .disabled(store.isOn(id))
    }

    private func toggle(_ p: BrickProfile, _ key: WritableKeyPath<BrickRestrictions, Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: Binding(get: { p.restrictions[keyPath: key] },
                             set: { var q = p; q.restrictions[keyPath: key] = $0; store.update(q) })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 18))
                Text(detail).font(.system(size: 15)).foregroundStyle(BrickLook.soft)
            }
        }
        .tint(BrickLook.bar)
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
                    DatePicker("Starts at", selection: timeBinding(s), displayedComponents: .hourAndMinute)
                        .font(.system(size: 18))
                    BrickDivider().padding(.vertical, 18)
                    Toggle("Ends at a set time", isOn: Binding(
                        get: { s.endHour != nil },
                        set: { var q = s; q.endHour = $0 ? 17 : nil; q.endMinute = $0 ? 0 : nil; store.update(q) }))
                        .font(.system(size: 18)).tint(BrickLook.bar)
                    if s.endHour != nil {
                        DatePicker("Ends at", selection: endBinding(s), displayedComponents: .hourAndMinute)
                            .font(.system(size: 18)).padding(.top, 14)
                    }
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
                Takeaway(text: s.endHour == nil
                         ? "Starts within an hour of the start time while the app is open or next opened. A tag ends it."
                         : "Starts at the start time, or whenever the app next opens before the end, and lifts at the end time. A tag can still end it early.")
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

    private func endBinding(_ s: BrickSchedule) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: s.endHour ?? 17, minute: s.endMinute ?? 0, second: 0, of: Date()) ?? Date() },
            set: { d in
                var q = s
                q.endHour = Calendar.current.component(.hour, from: d)
                q.endMinute = Calendar.current.component(.minute, from: d)
                store.update(q)
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
                .glassGlare(.regular, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
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
        .hubPageStyle()
        .navigationBarTitleDisplayMode(.inline)
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

/// Every tag that locks and unlocks, one row each. Each can start its own mode, so a tag by the bed and one on the desk block different things.
struct BrickTagPage: View {
    let store: BrickStore
    @Binding var path: [BrickRoute]

    var body: some View {
        BrickPage(title: Demo.copy("My Bricks", "My Tags")) {
            Image("BrickDevice").resizable().scaledToFit().frame(width: 140, height: 140)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 12)
                .padding(.vertical, 28)
            BrickCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(store.tags) { tag in
                        let mode = store.profile(for: tag)
                        NavigationLink(value: BrickRoute.tagDetail(tag.id)) {
                            BrickRow(icon: store.isKey(tag) ? "lock.fill" : "wave.3.right", title: tag.name,
                                     value: mode?.name ?? "Pick a mode", dot: mode == nil)
                        }
                        .buttonStyle(.plain)
                        BrickDivider()
                    }
                    Button { store.registerTag { path.append(.tagDetail($0)) } } label: {
                        BrickRow(icon: "plus.viewfinder", title: store.hasTag ? "Add another tag" : "Register tag", value: nil)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
            }
            Takeaway(text: "Any NFC sticker works (NTAG213 and up). Each tag runs one mode: tap it to start that mode, tap it again to end it. A lockdown is paired with one tag, and no other tag can end it.")
                .padding(.horizontal, 4)
            Takeaway(text: "To use a tag without opening the app: in Shortcuts, add an Automation \u{2192} NFC, scan the tag, set it to Run Immediately, and add Tap Brick tag with this tag.")
                .padding(.horizontal, 4)
        }
    }
}

/// One tag: its name, which mode it starts, and a way to remove it. Laid out like the Modes page.
struct BrickTagDetailPage: View {
    let store: BrickStore
    var id: String
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    private var tag: BrickTag? { store.tags.first { $0.id == id } }

    var body: some View {
        BrickPage(title: tag?.name ?? "Tag") {
            if let tag {
                BrickCard(padding: 0) {
                    VStack(spacing: 0) {
                        TextField("Name", text: Binding(get: { tag.name }, set: { var t = tag; t.name = $0; store.update(t) }))
                            .font(.system(size: 18)).padding(.vertical, 20)
                        BrickDivider()
                        BrickRow(icon: "wave.3.right", title: "Tag ID", value: String(tag.id.prefix(8)).uppercased(), chevron: false)
                    }
                    .padding(.horizontal, 24)
                }
                BrickCaps(text: "Mode").foregroundStyle(BrickLook.soft).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).padding(.leading, 4)
                ForEach(store.profiles) { p in
                    // A lockdown paired with another tag, or a mode that's on, can't be picked here.
                    let other = store.pairedTag(p.id).flatMap { $0.id == tag.id ? nil : $0 }
                    let taken = tag.profileID != p.id && (other != nil || store.isOn(p.id))
                    choice(tag, p.id, p.name,
                           other.map { "Lockdown · paired with \($0.name)" }
                           ?? (p.lockdown ? "Lockdown · only its paired tag ends it" : "Brick · counts as Brick time"))
                        .disabled(taken)
                        .opacity(taken ? 0.5 : 1)
                }
                NavigationLink(value: BrickRoute.modes) {
                    Text("Edit modes").font(.system(size: 16)).foregroundStyle(BrickLook.soft)
                }
                .buttonStyle(.plain)
                if store.isKey(tag) {
                    Text("\(tag.name) would end something that's on, so it can't change until that's off.")
                        .font(.footnote).foregroundStyle(BrickLook.soft)
                }
                Button("Remove tag", role: .destructive) { confirming = true }
                    .font(.system(size: 17)).padding(.top, 12)
                    .confirmationDialog("Remove \(tag.name)? It will stop working as a key.", isPresented: $confirming,
                                        titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { store.delete(tag); dismiss() }
                    }
            }
        }
        .disabled(tag.map(store.isKey) ?? true)
    }

    /// A mode as a card with a circle; the filled one is what this tag starts and ends.
    private func choice(_ tag: BrickTag, _ profileID: UUID, _ title: String, _ detail: String) -> some View {
        let chosen = tag.profileID == profileID
        return Button { var t = tag; t.profileID = profileID; store.update(t) } label: {
            HStack(spacing: 14) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(chosen ? BrickLook.bar : BrickLook.soft)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 19, weight: .medium))
                    Text(detail).font(.system(size: 15)).foregroundStyle(BrickLook.soft)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .glassGlare(.regular.interactive(), in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chosen ? "\(title), selected" : "Start \(title)")
    }
}

/// A small allowance of unlocks without the tag.
struct BrickEmergencyPage: View {
    let store: BrickStore
    @State private var confirming = false

    var body: some View {
        BrickPage(title: Demo.copy("Emergency Unbrick", "Emergency Unlock")) {
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
            .disabled(!store.anyOn || store.emergencyLeft == 0)
            .opacity(store.anyOn && store.emergencyLeft > 0 ? 1 : 0.5)
            .confirmationDialog("Use one of your \(store.emergencyLeft) emergency unbricks?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Unbrick", role: .destructive) { store.emergencyUnbrick() }
            }
            Takeaway(text: store.anyOn
                     ? "Ends this Brick and any lockdowns without the tag. They don't come back, so save them for when you really need your phone."
                     : "For when you're bricked and away from your Brick. Ends the session without the tag. They don't come back.")
                .padding(.horizontal, 4).padding(.top, 8)
        }
    }
}
#endif
