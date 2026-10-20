import SwiftUI

#if os(iOS)
import FamilyControls
import DeviceActivity

/// Brick's own look: warm gray page, the device picture in the middle (like the Fitness page's watch),
/// one pill button. Everything else is on this one page and opens in place.
private enum BrickLook {
    static let page = Fit.adaptive(0xD9D4D3, 0x1C1A1A)
    static let pill = Fit.adaptive(0xE4E0DE, 0x2A2727)
    static let ink = Fit.adaptive(0x262322, 0xECE8E6)
    static let soft = Fit.adaptive(0x8A8584, 0x8F8A89)
}

private enum BrickDetail { case focus, streak, screen }

struct BrickView: View {
    @State private var store = BrickStore()
    @State private var picking: UUID?
    @State private var managing = false
    @State private var open: BrickDetail?
    @State private var days = 7
    @Environment(\.scenePhase) private var scenePhase

    private var cal: Calendar { .current }
    private func length(_ s: BrickSession) -> TimeInterval { (s.end ?? Date()).timeIntervalSince(s.start) }
    private func minutes(on day: Date) -> Double {
        (store.sessions.filter { cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + length($1) } / 60).rounded()
    }
    private func lastDays(_ n: Int) -> [DayValue] {
        (0..<n).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: Date())) ?? Date()
            return DayValue(date: d, value: minutes(on: d))
        }
    }
    private var today: Double { minutes(on: Date()) }
    private var streak: Int {
        let set = Set(store.sessions.map { cal.startOfDay(for: $0.start) })
        var d = cal.startOfDay(for: Date())
        if !set.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        var n = 0
        while set.contains(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        return n
    }
    private func format(_ minutes: Double) -> String {
        let m = Int(minutes)
        return "\(m / 60)h \(m % 60)m"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                todayPill.padding(.top, 8)
                device.padding(.top, 36)
                modeBlock.padding(.top, 20)
                if managing { modes.padding(.top, 8) }
                brickButton.padding(.top, 32)
                summary.padding(.top, 48)
            }
            .padding(.horizontal, Fit.gutter)
            .padding(.bottom, 48)
            .animation(.smooth, value: managing)
            .animation(.smooth, value: open)
        }
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .alert("Brick", isPresented: Binding(get: { store.message != nil },
                                             set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.message ?? "") }
        .onChange(of: scenePhase) { _, p in if p == .active { store.checkTimer() } }
        .familyActivityPicker(isPresented: Binding(get: { picking != nil },
                                                   set: { if !$0 { picking = nil } }),
                              selection: pickerBinding)
    }

    private var pickerBinding: Binding<FamilyActivitySelection> {
        Binding(
            get: { store.profiles.first { $0.id == picking }?.selection ?? FamilyActivitySelection() },
            set: { new in
                guard var p = store.profiles.first(where: { $0.id == picking }) else { return }
                p.selection = new
                store.update(p)
            })
    }

    // MARK: Top of the page

    private var todayPill: some View {
        HStack(spacing: 8) {
            Text(format(today)).font(.system(size: 20, weight: .regular).monospacedDigit())
            Text("today").font(.subheadline).foregroundStyle(BrickLook.soft)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(BrickLook.pill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The device, like the watch on the Fitness page. Tap it to Brick.
    private var device: some View {
        Button { store.tapTag() } label: {
            Image("BrickDevice")
                .resizable().scaledToFit()
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.18), radius: 22, y: 16)
                .opacity(store.isBlocking ? 0.55 : 1)
                .overlay {
                    if store.isBlocking {
                        TablerIcon(name: "lock", size: 44).foregroundStyle(BrickLook.ink)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isBlocking ? "Unlock with tag" : "Start blocking with tag")
    }

    private var modeBlock: some View {
        let p = store.blockingProfile ?? store.selected
        let count = (p?.selection.applicationTokens.count ?? 0) + (p?.selection.categoryTokens.count ?? 0)
            + (p?.selection.webDomainTokens.count ?? 0)
        return VStack(spacing: 10) {
            Text(p?.name ?? "Focus").font(.system(size: 30, weight: .regular))
            if store.isBlocking, let end = store.endsAt {
                Text(end, style: .timer).font(.title3.monospacedDigit()).foregroundStyle(BrickLook.soft)
            } else {
                Text(count == 1 ? "Blocks 1 app" : "Blocks \(count) apps").font(.body).foregroundStyle(BrickLook.soft)
            }
            Button { managing.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Manage modes")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(managing ? 90 : 0))
                }
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }

    private var brickButton: some View {
        VStack(spacing: 12) {
            if !store.authorized {
                Button("Allow Screen Time access") { Task { await store.authorize() } }
                    .font(.subheadline.weight(.semibold))
            }
            Button { store.tapTag() } label: {
                Text(store.isBlocking ? "Tap to unlock" : "Tap or hold to Brick")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                    .background(BrickLook.pill, in: Capsule())
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            if store.isBlocking, store.blockingProfile?.strict == false {
                Button("Unlock without tag") { store.unlockWithoutTag() }.font(.footnote)
            }
        }
    }

    // MARK: Modes, opened in place

    private var modes: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, p in
                mode(p, last: index == store.profiles.count - 1)
            }
            if !store.isBlocking {
                HStack {
                    Button { store.addProfile() } label: {
                        HStack(spacing: 8) { TablerIcon(name: "plus", size: 18); Text("New mode").font(.subheadline) }
                    }
                    Spacer()
                    Button(store.tagID == nil ? "Register tag" : "Replace tag") { store.registerTag() }
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            if let id = store.tagID {
                Text("Tag \(String(id.prefix(8)))").font(.caption).foregroundStyle(BrickLook.soft).padding(.top, 10)
            }
        }
        .padding(.top, 8)
    }

    private func mode(_ p: BrickProfile, last: Bool) -> some View {
        let count = p.selection.applicationTokens.count + p.selection.categoryTokens.count + p.selection.webDomainTokens.count
        let chosen = store.selectedID == p.id
        return VStack(spacing: 0) {
            Button { if !store.isBlocking { store.selectedID = p.id } } label: {
                HStack {
                    TablerIcon(name: chosen ? "circle-check" : "circle", size: 20)
                    TextField("Name", text: Binding(get: { p.name }, set: { var q = p; q.name = $0; store.update(q) }))
                        .font(.subheadline.weight(.semibold)).disabled(store.isBlocking)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            if chosen {
                Button { picking = p.id } label: {
                    DetailRow(label: "Apps and sites", value: count == 0 ? "Choose" : "\(count) selected")
                }
                .buttonStyle(.plain).disabled(store.isBlocking)
                HStack {
                    Text("Strict, only the tag unlocks").font(.subheadline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { p.strict }, set: { var q = p; q.strict = $0; store.update(q) }))
                        .labelsHidden().disabled(store.isBlocking)
                }
                .padding(.vertical, 6)
                Stepper(value: Binding(get: { p.timerMinutes ?? 0 }, set: { var q = p; q.timerMinutes = $0 > 0 ? $0 : nil; store.update(q) }),
                        in: 0...480, step: 15) {
                    HStack {
                        Text("Auto-unlock").font(.subheadline)
                        Spacer()
                        Text(p.timerMinutes.map { "\($0) min" } ?? "Off").font(.subheadline).foregroundStyle(BrickLook.soft)
                    }
                }
                .padding(.vertical, 6).disabled(store.isBlocking)
                if store.profiles.count > 1 {
                    Button("Delete mode", role: .destructive) { store.delete(p) }
                        .font(.footnote).padding(.vertical, 8).disabled(store.isBlocking)
                }
            }
            if !last { Rectangle().fill(BrickLook.soft.opacity(0.25)).frame(height: 1) }
        }
    }

    // MARK: Summary visuals, each opens in place

    private var summary: some View {
        VStack(spacing: 0) {
            Rectangle().fill(BrickLook.soft.opacity(0.25)).frame(height: 1)
            Button { open = open == .focus ? nil : .focus } label: {
                OverviewRow(title: "Focus", value: format(lastDays(7).reduce(0) { $0 + $1.value }), unit: "this week",
                            caption: nil, tint: Fit.activity) {
                    MiniTrend(values: lastDays(7).map(\.value), tint: Fit.activity, bars: true)
                }
            }
            .buttonStyle(.plain)
            if open == .focus { focusDetail }
            Rectangle().fill(BrickLook.soft.opacity(0.25)).frame(height: 1)
            Button { open = open == .streak ? nil : .streak } label: {
                OverviewRow(title: "Streak", value: "\(streak)", unit: "days", caption: nil, tint: Fit.activity) {
                    streakDots
                }
            }
            .buttonStyle(.plain)
            if open == .streak { streakDetail }
            Rectangle().fill(BrickLook.soft.opacity(0.25)).frame(height: 1)
            Button { open = open == .screen ? nil : .screen } label: {
                OverviewRow(title: "Screen Time", value: "Today", unit: nil, caption: nil, tint: Fit.activity) {
                    TablerIcon(name: "device-watch", size: 22).opacity(0)
                }
            }
            .buttonStyle(.plain)
            if open == .screen {
                DeviceActivityReport(DeviceActivityReport.Context("BrickScreenTime"),
                                     filter: DeviceActivityFilter(segment: .daily(during: DateInterval(start: cal.startOfDay(for: Date()), end: Date())),
                                                                  users: .all, devices: .init([.iPhone])))
                    .frame(minHeight: 420)
            }
        }
    }

    private var streakDots: some View {
        let list = lastDays(7)
        return HStack(spacing: 5) {
            ForEach(list) { d in
                Circle().fill(d.value > 0 ? Fit.activity : BrickLook.soft.opacity(0.3)).frame(width: 9, height: 9)
            }
        }
    }

    private var focusDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Spacer(); PeriodPicker(days: $days, options: [7, 30]); Spacer() }
            DailyBarChart(points: lastDays(days), tint: Fit.activity, format: { "\(Int($0.rounded())) min" })
            let latest = Array(store.sessions.suffix(5).reversed())
            VStack(spacing: 0) {
                ForEach(Array(latest.enumerated()), id: \.element.id) { index, s in
                    DetailRow(label: "\(s.profileName), \(s.start.formatted(date: .abbreviated, time: .shortened))",
                              value: s.end == nil ? "Running" : format(length(s) / 60),
                              last: index == latest.count - 1)
                }
            }
            if latest.isEmpty { Text("No sessions yet").font(.footnote).foregroundStyle(BrickLook.soft) }
        }
        .padding(.bottom, 20)
    }

    private var streakDetail: some View {
        let list = lastDays(28)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 10) {
            ForEach(list) { d in
                Circle().fill(d.value > 0 ? Fit.activity : BrickLook.soft.opacity(0.25)).frame(width: 22, height: 22)
            }
        }
        .padding(.vertical, 12).padding(.bottom, 8)
    }
}
#else
struct BrickView: View {
    var body: some View { Text("Brick needs an iPhone.").foregroundStyle(.secondary) }
}
#endif
