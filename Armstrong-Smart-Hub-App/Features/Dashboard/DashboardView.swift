import SwiftUI

/// Keeps the screen on while the dashboard is showing.
@MainActor
enum KeepAwake {
    private static var holders = 0
    static func hold() { holders += 1; UIApplication.shared.isIdleTimerDisabled = true }
    static func release() {
        holders = max(holders - 1, 0)
        if holders == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// The iPad's always-on hub on the wall, in the iPhone app's look: the time and how you're
/// doing, a glance at the weather, your fitness and the Pi, then the house, new transactions
/// and the next three days, with today's habits down the side.
struct DashboardTab: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var home = HomeStore()
    @State private var finance = FinanceStore()
    @State private var habits = HabitsStore()
    @State private var weather = WeatherStore()
    @State private var pi = PiStore()
    @State private var fitness = FitnessStore()
    @State private var calendar: CalendarResponse? = DiskCache.read(calendarCacheName)
    @State private var wake = WakeAlarm()
    @State private var voice = VoiceAgent()
    @State private var link = HubLink.shared

    var body: some View {
        DashboardView(home: home, finance: finance, habits: habits, weather: weather, pi: pi, fitness: fitness,
                      calendar: calendar, wake: wake, voice: voice) { await refreshSlow() }
            // Home polls on its own; restarted whenever the app comes back to the front.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                voice.resume()
                await home.poll(api: session.api)
            }
            .task {
                // "Hey Jarvis": when it changes something, refresh that part of the dashboard.
                voice.onAction = { kind in
                    switch kind {
                    case .lights, .movie: Task { await home.refresh(api: session.api) }
                    case .habits: Task { await habits.load(api: session.api) }
                    case .calendar: Task { await refreshSlow() }
                    case .pi: Task { await pi.load(api: session.api) }
                    case .finance, .weather, .fitness: break
                    }
                }
                await voice.start(api: session.api)
            }
            .task(id: scenePhase) {
                // The rest changes slowly: every few minutes, and at once when the app comes
                // back to the front or the hub answers again after being out of reach.
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await refreshSlow()
                    await link.wait(300)
                }
            }
            .task(id: scenePhase) {
                // The Pi's temperature and services, more often than the rest.
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await pi.load(api: session.api)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }

    private func refreshSlow() async {
        habits.rollDay()
        let api = session.api
        async let f: Void = finance.load(api: api)
        async let h: Void = habits.load(api: api)
        async let w: Void = weather.load(api: api)
        async let fit: Void = fitness.load(api: api)
        async let c: Data? = try? api.data(api.request("/api/mobile/calendar"))
        _ = await (f, h, w, fit)
        if let raw = await c, let cal = try? APIClient.decoder.decode(CalendarResponse.self, from: raw) {
            calendar = cal
            DiskCache.write(raw, calendarCacheName)
        }
    }
}

private let deviceGroups: [(title: String, kinds: Set<ControlKind>)] = [
    ("Lights", [.light]),
    ("Entertainment", [.remote, .mediaPlayer]),
    ("Climate", [.climate]),
    ("Locks", [.lock]),
    ("Switches", [.toggle]),
]

struct DashboardView: View {
    let home: HomeStore
    let finance: FinanceStore
    let habits: HabitsStore
    let weather: WeatherStore
    let pi: PiStore
    let fitness: FitnessStore
    let calendar: CalendarResponse?
    let wake: WakeAlarm
    let voice: VoiceAgent
    let refresh: () async -> Void

    @Environment(AppSession.self) private var session
    @State private var toast = Toast()
    @State private var light: HAEntity?
    @State private var remote: HAEntity?
    @State private var retagging: Transaction?
    @State private var account = false
    @State private var alerts = WallAlertsStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                glance
                homeSection
                transactionsSection
                CalendarSection(calendar: calendar)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .refreshable {
            async let a: Void = home.refresh(api: session.api)
            async let b: Void = refresh()
            async let c: Void = pi.load(api: session.api)
            _ = await (a, b, c)
        }
        // Popups (a service down, tomorrow's wake-up, a birthday), one at a time, under Jarvis.
        .overlay { popups }
        // Jarvis takes the stage: the dashboard softens and steps back.
        .blur(radius: voice.presented ? 24 : 0)
        .scaleEffect(voice.presented ? 0.97 : 1)
        .allowsHitTesting(!voice.presented)
        .animation(.smooth(duration: 0.5), value: voice.presented)
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .tint(BrickLook.ink)
        .overlay { VoiceOverlay(agent: voice) }
        .persistentSystemOverlays(.hidden)
        .onAppear { KeepAwake.hold() }
        .onDisappear { KeepAwake.release() }
        .sheet(item: $light) { e in
            LightSheet(entityID: e.id, store: home, toast: toast).presentationDetents([.medium, .large])
        }
        .sheet(item: $remote) { e in RemoteSheet(entity: home.entity(e.id) ?? e) }
        .sheet(item: $retagging) { t in
            CategoryPicker(transaction: t, options: finance.categoryOptions) { c in
                Task { await finance.retag(t, to: c, api: session.api, toast: toast) }
            }
        }
        .sheet(isPresented: $account) { SettingsView() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in habits.rollDay() }
        .toast(toast)
    }

    // MARK: Clock and status

    /// Only a set alarm, as quiet text in the corner; nothing otherwise.
    private var header: some View {
        HStack {
            Spacer(minLength: 0)
            WakeControl(alarm: wake, home: home, toast: toast)
        }
    }

    // MARK: Glance

    /// What the time of day calls for: the weather from 5 AM, readiness joining it at 8; from
    /// 10 PM, tomorrow's forecast and how the day went.
    private var glance: some View {
        TimelineView(.everyMinute) { context in
            let hour = Calendar.current.component(.hour, from: context.date)
            let night = hour >= 22 || hour < 5
            let readinessTime = hour >= 8 && hour < 22
            HStack(alignment: .top, spacing: 14) {
                if night {
                    ForecastTile(store: weather, now: context.date)
                    DayEndTile(store: fitness).frame(maxWidth: 300)
                } else {
                    WeatherTile(store: weather)
                    if readinessTime { FitnessTile(store: fitness).frame(maxWidth: 300) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .animation(.smooth(duration: 0.6), value: readinessTime)
            .animation(.smooth(duration: 0.6), value: night)
        }
        // Holding the cards for two seconds opens account settings (sign out).
        .onLongPressGesture(minimumDuration: 2) { account = true }
    }

    // MARK: Popups

    private var popups: some View {
        TimelineView(.everyMinute) { context in
            let queue = WallAlert.queue(now: context.date, pi: pi.status, alarm: wake, calendar: calendar, dismissed: alerts.dismissed)
            ZStack {
                if let alert = queue.first {
                    WallPopup(alert: alert, pi: pi, alarm: wake, home: home, toast: toast) {
                        withAnimation(.smooth(duration: 0.35)) { alerts.dismiss(alert) }
                    }
                    .id(alert.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.smooth(duration: 0.35), value: queue.first?.id)
        }
    }

    // MARK: Home

    @ViewBuilder
    private var homeSection: some View {
        if let error = home.loadError ?? home.state?.errors.entities {
            ErrorBanner(message: home.entities.isEmpty ? error : "\(error) Showing the last known state.") {
                Task { await home.refresh(api: session.api) }
            }
        }
        if let payload = home.state?.automations, !(payload.scenes + payload.scripts).isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(payload.scenes + payload.scripts) { item in
                        Button {
                            Task {
                                do {
                                    let _: Empty? = try await session.api.run("runAutomation", [.string(item.id)])
                                    toast.show("Ran \(item.name)")
                                } catch { toast.error(error) }
                            }
                        } label: {
                            BrickPill(text: item.name, icon: item.id.hasPrefix("scene.") ? "sparkles" : "play.circle")
                        }
                        .buttonStyle(CardPressStyle())
                    }
                }
            }
            .scrollClipDisabled()
        }
        if home.state == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        } else {
            let shown = home.shownEntities
            ForEach(deviceGroups, id: \.title) { group in
                let items = shown.filter { group.kinds.contains($0.control) }
                if !items.isEmpty {
                    if group.kinds.contains(.light) {
                        // Lights need no heading: each is a card like the weather's, in its own color.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                            ForEach(items) { e in
                                WallLightCard(entity: e) {
                                    Task { await home.toggle(e, api: session.api, toast: toast) }
                                } onAdjust: {
                                    if e.hasLightControls { light = e }
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            WallHeading(title: group.title, meta: summary(items))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                                ForEach(items) { e in
                                    DeviceButton(entity: e, pending: home.pending.contains(e.id)) {
                                        if e.isTV { remote = e } else { Task { await home.toggle(e, api: session.api, toast: toast) } }
                                    } onAdjust: {
                                        if e.isTV { remote = e } else if e.hasLightControls { light = e }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func summary(_ items: [HAEntity]) -> String {
        let on = items.filter(\.isOn).count
        if items[0].control == .lock { return on > 0 ? "\(on) unlocked" : "All locked" }
        return on > 0 ? "\(on) of \(items.count) on" : "All off"
    }

    // MARK: New transactions

    @ViewBuilder
    private var transactionsSection: some View {
        if let r = finance.response, let d = r.dashboard, !d.toReview.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    WallHeading(title: "New transactions", meta: "\(d.toReview.count) to review")
                    Spacer()
                    if d.toReview.count > 1 {
                        Button("Keep all suggestions") {
                            Task { await finance.confirmAll(api: session.api, toast: toast) }
                        }
                        .font(.system(size: 16, weight: .medium))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                    ForEach(d.toReview) { t in
                        TagCard(transaction: t, chips: chips(for: t, quick: r.quickCategories)) { c in
                            Task { await finance.retag(t, to: c, api: session.api, toast: toast) }
                        } onMore: {
                            retagging = t
                        }
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                }
                .animation(.spring(duration: 0.35), value: d.toReview.map(\.id))
            }
            .transition(.opacity)
        } else if let error = finance.error {
            ErrorBanner(message: "Finances: \(error)") { Task { await finance.load(api: session.api) } }
        }
    }

    /// The suggestion first, then the likeliest other tags.
    private func chips(for t: Transaction, quick: QuickCategories?) -> [String] {
        let ranked = (t.netEffect > 0 ? quick?.in : quick?.out) ?? []
        var list = t.category == "Uncategorized" ? [] : [t.category]
        for c in ranked where !list.contains(c) && c != "Uncategorized" { list.append(c) }
        return Array(list.prefix(6))
    }
}

/// A section's name on the wall: the iPhone's light title with a caps note beside it.
private struct WallHeading: View {
    let title: String
    var meta: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 26, weight: .regular))
            if let meta { BrickCaps(text: meta).foregroundStyle(BrickLook.soft).monospacedDigit() }
        }
    }
}

/// The whole card is the switch. Long press adjusts lights; TVs open the remote.
/// A device as a card that is itself the switch: tap toggles, hold adjusts.
/// Shared by the iPad dashboard and the iPhone's Home tab (compact).
struct DeviceButton: View {
    let entity: HAEntity
    let pending: Bool
    var compact = false
    /// The wall's lights: a bigger icon, name and card, readable from across the room.
    var large = false
    let onTap: () -> Void
    let onAdjust: () -> Void

    @GestureState private var pressed = false
    @State private var held = false

    var body: some View {
        let on = entity.isOn
        let tint = tintColor
        VStack(alignment: .leading, spacing: compact ? 10 : large ? 18 : 14) {
            HStack {
                Image(systemName: entity.symbol)
                    .font(compact ? .title3 : large ? .system(size: 30) : .title2)
                    .frame(width: compact ? 40 : large ? 64 : 48, height: compact ? 40 : large ? 64 : 48)
                    .foregroundStyle(on ? .white : .secondary)
                    .background(on ? tint : Color(.tertiarySystemFill), in: .circle)
                Spacer()
                if !compact, entity.hasLightControls || entity.isTV {
                    Image(systemName: entity.isTV ? "chevron.right" : "slider.horizontal.3")
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(compact ? .subheadline.weight(.semibold) : large ? .system(size: 22, weight: .semibold) : .headline)
                    .lineLimit(compact ? 1 : 2).multilineTextAlignment(.leading)
                Text(entity.stateLabel).font(compact ? .caption : large ? .system(size: 17) : .subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(compact ? 14 : large ? 20 : 16)
        .frame(maxWidth: .infinity, minHeight: compact ? 108 : large ? 184 : 140, alignment: .topLeading)
        .background(on ? tint.opacity(0.18) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(on ? tint.opacity(0.5) : .clear, lineWidth: 1.5))
        .contentShape(.rect(cornerRadius: 20))
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(.spring(duration: 0.2), value: pressed)
        .opacity(entity.isUnavailable ? 0.5 : 1)
        // A quick tap toggles; holding adjusts instead, without also toggling.
        // Both run side by side so neither waits on the other; the release after a hold is swallowed.
        .onTapGesture {
            if held { held = false } else if !entity.isUnavailable { onTap() }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .updating($pressed) { value, state, _ in state = value }
                .onEnded { _ in
                    held = true
                    if !entity.isUnavailable { onAdjust() }
                }
        )
        .onChange(of: pressed) { _, down in if down { held = false } }
        .sensoryFeedback(.impact(weight: .medium), trigger: on)
        .animation(.easeOut(duration: 0.2), value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(entity.name), \(entity.stateLabel)")
        .accessibilityAction { onTap() }
        .accessibilityAction(named: "Adjust") { onAdjust() }
    }

    private var tintColor: Color {
        switch entity.control {
        case .light:
            if let rgb = entity.rgbColor { return Color(rgb: rgb) }
            return .orange
        case .lock: return .red
        case .climate: return .teal
        case .remote, .mediaPlayer: return .indigo
        default: return .accentColor
        }
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// One new transaction with big tag buttons. One tap tags it and it slides away.
private struct TagCard: View {
    let transaction: Transaction
    let chips: [String]
    let onTag: (String) -> Void
    let onMore: () -> Void

    var body: some View {
        let t = transaction
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.payee).font(.headline).lineLimit(1)
                    Text("\(Fmt.shortDate(t.date)) · \(t.accountName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Fmt.signed(t.netEffect, t.currency))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(t.netEffect > 0 ? Color.positive : .primary)
            }
            FlowLayout(spacing: 8) {
                ForEach(Array(chips.enumerated()), id: \.element) { i, c in
                    let suggested = i == 0 && c == t.category
                    Button { onTag(c) } label: {
                        Label(c, systemImage: suggested ? "checkmark" : CategoryStyle.symbol(c))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(suggested ? .white : .primary)
                            .background(suggested ? CategoryStyle.color(c) : Color(.tertiarySystemFill), in: .capsule)
                    }
                    .buttonStyle(CardPressStyle())
                    .accessibilityHint(suggested ? "Suggested tag" : "")
                }
                Button(action: onMore) {
                    Label("Other", systemImage: "ellipsis")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                }
                .buttonStyle(CardPressStyle())
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(BrickLook.card, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// The next three days from Google Calendar, side by side: a Google-style date
/// marker, then each event as a solid chip with just its title and start time.
private struct CalendarSection: View {
    let calendar: CalendarResponse?

    var body: some View {
        if let calendar, calendar.status == "connected", let today = calendar.today {
            let byDay = Dictionary(uniqueKeysWithValues: calendar.days.map { ($0.day, $0.events) })
            let days = (0..<3).map { addDays(today, $0) }
            VStack(alignment: .leading, spacing: 16) {
                WallHeading(title: "Calendar")
                TimelineView(.everyMinute) { context in
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(Array(days.enumerated()), id: \.element) { i, day in
                            DayColumn(day: day, index: i, events: byDay[day] ?? [], zone: calendar.timeZone, now: context.date)
                        }
                    }
                }
            }
        }
    }
}

private struct DayColumn: View {
    let day: String
    let index: Int
    let events: [CalendarEvent]
    let zone: String
    let now: Date

    private static let maxShown = 4

    var body: some View {
        let date = DayFormat.parse(day) ?? .now
        let utc = TimeZone(identifier: "UTC")!
        let isToday = index == 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(date.formatted(Date.FormatStyle(timeZone: utc).day()))
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? .white : .primary)
                    .frame(width: 48, height: 48)
                    .background(isToday ? Color.googleBlue : .clear, in: .circle)
                Text(index == 0 ? "Today" : index == 1 ? "Tomorrow" : date.formatted(Date.FormatStyle(timeZone: utc).weekday(.wide)))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isToday ? Color.googleBlue : .secondary)
                    .lineLimit(1)
            }

            if events.isEmpty {
                Text("Free")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            } else {
                ForEach(events.prefix(Self.maxShown)) { event in
                    EventChip(event: event, zone: zone, now: now)
                }
                if events.count > Self.maxShown {
                    Text("+\(events.count - Self.maxShown) more")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A solid event chip in the calendar's color, darkened where needed so the white text reads
/// (Google's pastel calendars were too pale): title, and when it starts, or "Now" while it's on.
private struct EventChip: View {
    let event: CalendarEvent
    let zone: String
    let now: Date

    var body: some View {
        let color = Color(hexForWhiteText: event.color)
        let start = event.startDate
        let end = ISO.parse(event.end)
        let live = !event.allDay && start.map { $0 <= now } == true && end.map { $0 > now } == true
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(2)
            Text(live ? "Now" : timeText(start))
                .font(.system(size: 16, weight: .medium))
                .monospacedDigit()
                .opacity(0.9)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            // The event that's on right now gets a ring.
            if live { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.8), lineWidth: 2.5) }
        }
        .opacity(end.map { $0 < now } == true ? 0.55 : 1)
    }

    /// "6 PM" or "6:30 PM", like Google Calendar.
    private func timeText(_ start: Date?) -> String {
        if event.allDay { return "All day" }
        guard let start else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone) ?? .current
        var style = Date.FormatStyle.dateTime.hour()
        if cal.component(.minute, from: start) != 0 { style = style.minute() }
        style.timeZone = cal.timeZone
        return start.formatted(style)
    }
}

/// A habit as the dashboard's big circle: tap to fill it for today.
struct HabitButton: View {
    let habit: Habit
    let done: Bool
    let saving: Bool
    var size: CGFloat = 110
    /// Off for the wall header's small circles, where the emoji says which habit it is.
    var showsName = true
    let onTap: () -> Void

    var body: some View {
        let color = Color(hex: habit.color)
        Button(action: onTap) {
            VStack(spacing: size * 0.09) {
                ZStack {
                    Circle().strokeBorder(color, lineWidth: size > 90 ? 5 : 4)
                    Circle().fill(done ? color : color.opacity(0.08)).padding(done ? 0 : 5)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.4, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    } else if let icon = habit.icon {
                        Text(icon).font(.system(size: size * 0.36))
                    }
                }
                .frame(width: size, height: size)
                if showsName {
                    Text(habit.name)
                        .font(size > 90 ? .headline : size > 60 ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(done ? color : .primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(CardPressStyle())
        .disabled(saving)
        .accessibilityLabel(done ? "\(habit.name), done. Tap to undo." : "Mark \(habit.name) as done today")
    }
}
