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

/// The iPad's always-on hub: clock and agenda, home controls and new
/// transactions on the left, today's habits down the right.
struct DashboardTab: View {
    @Environment(AppSession.self) private var session
    @State private var home = HomeStore()
    @State private var finance = FinanceStore()
    @State private var habits = HabitsStore()
    @State private var calendar: CalendarResponse?
    @State private var wake = WakeAlarm()
    @State private var voice = VoiceAgent()

    var body: some View {
        DashboardView(home: home, finance: finance, habits: habits, calendar: calendar, wake: wake, voice: voice) { await refreshSlow() }
            .task { await home.poll(api: session.api) }
            .task {
                // "Hey Jarvis": when it changes something, refresh that part of the dashboard.
                voice.onAction = { kind in
                    switch kind {
                    case .lights: Task { await home.refresh(api: session.api) }
                    case .habits: Task { await habits.load(api: session.api) }
                    case .calendar: Task { await refreshSlow() }
                    case .movie: Task { await home.refresh(api: session.api) }
                    case .finance: break
                    }
                }
                await voice.start(api: session.api)
            }
            .task {
                // Finance, habits and the calendar change slowly; Home polls on its own.
                while !Task.isCancelled {
                    await refreshSlow()
                    try? await Task.sleep(for: .seconds(300))
                }
            }
    }

    private func refreshSlow() async {
        habits.rollDay()
        async let f: Void = finance.load(api: session.api)
        async let h: Void = habits.load(api: session.api)
        async let c: CalendarResponse? = try? session.api.get("/api/mobile/calendar")
        _ = await (f, h)
        if let cal = await c { calendar = cal }
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
    let calendar: CalendarResponse?
    let wake: WakeAlarm
    let voice: VoiceAgent
    let refresh: () async -> Void

    @Environment(AppSession.self) private var session
    @State private var toast = Toast()
    @State private var light: HAEntity?
    @State private var remote: HAEntity?
    @State private var retagging: Transaction?
    @State private var editingHabit: HabitEditTarget?
    @State private var account = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        header
                        homeSection
                        transactionsSection
                        CalendarSection(calendar: calendar)
                    }
                    .padding(28)
                }
                .refreshable {
                    async let a: Void = home.refresh(api: session.api)
                    async let b: Void = refresh()
                    _ = await (a, b)
                }

                HabitsColumn(store: habits, toast: toast) { editingHabit = $0 }
                    .frame(width: min(max(geo.size.width * 0.24, 230), 300))
            }
        }
        // Jarvis takes the stage: the dashboard softens and steps back.
        .blur(radius: voice.presented ? 24 : 0)
        .scaleEffect(voice.presented ? 0.97 : 1)
        .allowsHitTesting(!voice.presented)
        .animation(.smooth(duration: 0.5), value: voice.presented)
        .background(Color(.systemGroupedBackground))
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
        .habitEditor($editingHabit, store: habits)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in habits.rollDay() }
        .toast(toast)
    }

    // MARK: Clock and agenda

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 80, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.title3).foregroundStyle(.secondary)
                }
                // A long press on the clock opens account settings (sign out).
                .onLongPressGesture { account = true }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                VoiceButton(agent: voice)
                WakeControl(alarm: wake, home: home, toast: toast)
            }
            .padding(.top, 12)
        }
    }

    // MARK: Home

    @ViewBuilder
    private var homeSection: some View {
        if let error = home.loadError ?? home.state?.errors.entities {
            ErrorBanner(message: error) { Task { await home.refresh(api: session.api) } }
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
                            Label(item.name, systemImage: item.id.hasPrefix("scene.") ? "sparkles" : "play.circle")
                                .font(.headline)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
            }
        }
        if home.state == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        } else {
            let shown = home.shownEntities
            ForEach(deviceGroups, id: \.title) { group in
                let items = shown.filter { group.kinds.contains($0.control) }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        // Lights read fine at a glance; the count is only kept for the other groups.
                        SectionHeader(title: group.title, meta: group.kinds.contains(.light) ? nil : summary(items))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
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
                    Text("New transactions").font(.title3.weight(.semibold))
                    Text("\(d.toReview.count)").font(.subheadline.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                    Spacer()
                    if d.toReview.count > 1 {
                        Button("Keep all suggestions") {
                            Task { await finance.confirmAll(api: session.api, toast: toast) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
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

/// The whole card is the switch. Long press adjusts lights; TVs open the remote.
/// A device as a card that is itself the switch: tap toggles, hold adjusts.
/// Shared by the iPad dashboard and the iPhone's Home tab (compact).
struct DeviceButton: View {
    let entity: HAEntity
    let pending: Bool
    var compact = false
    let onTap: () -> Void
    let onAdjust: () -> Void

    @State private var pressed = false

    var body: some View {
        let on = entity.isOn
        let tint = tintColor
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack {
                Image(systemName: entity.symbol)
                    .font(compact ? .title3 : .title2)
                    .frame(width: compact ? 40 : 48, height: compact ? 40 : 48)
                    .foregroundStyle(on ? .white : .secondary)
                    .background(on ? tint : Color(.tertiarySystemFill), in: .circle)
                Spacer()
                if pending { ProgressView() }
                else if !compact, entity.hasLightControls || entity.isTV {
                    Image(systemName: entity.isTV ? "chevron.right" : "slider.horizontal.3")
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(compact ? .subheadline.weight(.semibold) : .headline).lineLimit(compact ? 1 : 2).multilineTextAlignment(.leading)
                Text(entity.stateLabel).font(compact ? .caption : .subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(compact ? 14 : 16)
        .frame(maxWidth: .infinity, minHeight: compact ? 108 : 140, alignment: .topLeading)
        .background(on ? tint.opacity(0.18) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(on ? tint.opacity(0.5) : .clear, lineWidth: 1.5))
        .contentShape(.rect(cornerRadius: 20))
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(.spring(duration: 0.2), value: pressed)
        .opacity(entity.isUnavailable ? 0.5 : 1)
        // A quick tap toggles; holding adjusts instead, without also toggling.
        .onTapGesture { if !entity.isUnavailable { onTap() } }
        .onLongPressGesture(minimumDuration: 0.4) {
            if !entity.isUnavailable { onAdjust() }
        } onPressingChanged: { pressed = $0 }
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
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
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
                Text("Calendar").font(.title3.weight(.semibold))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(date.formatted(Date.FormatStyle(timeZone: utc).day()))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? .white : .primary)
                    .frame(width: 40, height: 40)
                    .background(isToday ? Color.googleBlue : .clear, in: .circle)
                Text(index == 0 ? "Today" : index == 1 ? "Tomorrow" : date.formatted(Date.FormatStyle(timeZone: utc).weekday(.wide)))
                    .font(.headline)
                    .foregroundStyle(isToday ? Color.googleBlue : .secondary)
                    .lineLimit(1)
            }

            if events.isEmpty {
                Text("Free")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            } else {
                ForEach(events.prefix(Self.maxShown)) { event in
                    EventChip(event: event, zone: zone, now: now)
                }
                if events.count > Self.maxShown {
                    Text("+\(events.count - Self.maxShown) more")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A solid event chip: title, and when it starts (or "Now" while it's on).
private struct EventChip: View {
    let event: CalendarEvent
    let zone: String
    let now: Date

    var body: some View {
        let color = Color(hex: event.color)
        let start = event.startDate
        let end = ISO.parse(event.end)
        let live = !event.allDay && start.map { $0 <= now } == true && end.map { $0 > now } == true
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(live ? "Now" : timeText(start))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color, in: .rect(cornerRadius: 10))
        .overlay {
            // The event that's on right now gets a ring.
            if live { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.7), lineWidth: 2) }
        }
        .opacity(end.map { $0 < now } == true ? 0.45 : 1)
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

/// Today's habits, one per row. Tapping one fills its circle and it moves to
/// the bottom of the list; tapping a filled one undoes it.
private struct HabitsColumn: View {
    let store: HabitsStore
    let toast: Toast
    let onEdit: (HabitEditTarget) -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        let today = store.today
        let todo = store.habits.filter { !store.isDone($0.id, today) }
        let done = store.habits.filter { store.isDone($0.id, today) }
        // Centered top to bottom; scrolls only if there are more habits than fit.
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 28) {
                if !store.loaded, let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else if !store.loaded {
                    ProgressView()
                } else if store.habits.isEmpty {
                    Text("No habits yet. Add them from the Habits tab on your phone.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }

                // Same ids in a new order, so SwiftUI animates each habit sliding down.
                ForEach(todo + done) { habit in
                    let isDone = store.isDone(habit.id, today)
                    HabitButton(habit: habit, done: isDone, saving: store.isSaving(habit.id, today)) {
                        Task { await store.toggle(habit, today, api: session.api, toast: toast) }
                    }
                    .contextMenu { Button("Edit", systemImage: "pencil") { onEdit(.habit(habit)) } }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
            .animation(.spring(duration: 0.5, bounce: 0.2), value: store.done)
            .sensoryFeedback(.success, trigger: done.count) { old, new in new > old }
        }
        .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// A habit as the dashboard's big circle: tap to fill it for today.
struct HabitButton: View {
    let habit: Habit
    let done: Bool
    let saving: Bool
    var size: CGFloat = 110
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
                Text(habit.name)
                    .font(size > 90 ? .headline : .subheadline.weight(.semibold))
                    .foregroundStyle(done ? color : .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(CardPressStyle())
        .disabled(saving)
        .accessibilityLabel(done ? "\(habit.name), done. Tap to undo." : "Mark \(habit.name) as done today")
    }
}
