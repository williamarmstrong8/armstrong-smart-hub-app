import SwiftUI

/// The wall at night: screen black and at zero brightness, and the idle timer back on so the
/// iPad locks itself after its Auto-Lock time. Waking puts the brightness back and keeps the
/// screen on again. (An app can't switch the iPad off; this is the nearest thing.)
@MainActor
@Observable
final class WallSleep {
    private(set) var asleep = false
    /// Sleep as soon as the conversation that asked for it ends.
    var pending = false
    private var brightness: CGFloat = 0.5

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    func sleep() {
        pending = false
        guard !asleep else { return }
        asleep = true
        if let screen {
            brightness = screen.brightness
            screen.brightness = 0
        }
        KeepAwake.release()
    }

    func wake() {
        pending = false
        guard asleep else { return }
        asleep = false
        screen?.brightness = max(brightness, 0.2)
        KeepAwake.hold()
    }
}

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
    @State private var habits = HabitsStore()
    @State private var weather = WeatherStore()
    @State private var pi = PiStore()
    @State private var fitness = FitnessStore()
    @State private var calendar: CalendarResponse? = DiskCache.read(calendarCacheName)
    @State private var wake = WakeAlarm()
    @State private var voice = VoiceAgent()
    @State private var link = HubLink.shared
    @State private var sleep = WallSleep()

    var body: some View {
        DashboardView(home: home, habits: habits, weather: weather, pi: pi, fitness: fitness,
                      calendar: calendar, wake: wake, voice: voice, sleep: sleep) { await refreshSlow() }
            // Bedtime: once Jarvis has said goodnight, the wall goes dark. Jarvis waking up (or
            // the iPad being unlocked in the morning) brings it back.
            .onChange(of: voice.presented) { _, up in
                if up { sleep.wake() } else if sleep.pending { sleep.sleep() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { sleep.wake() } }
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
                    case .finance, .weather, .fitness, .alarm, .todos, .appChange: break
                    }
                }
                // "Wake me at 6:30": the alarm is this iPad's, so Jarvis sets it here.
                voice.localTool = { name, arguments in
                    switch name {
                    case "bedtime": return await bedtime()
                    case "setWakeAlarm": return await setAlarm(arguments)
                    case "showWakeAlarm":
                        wake.expireIfPast()
                        guard let date = wake.scheduled else {
                            return (["set": false], .alarm(AlarmCardData(time: nil, secondAlarm: false)))
                        }
                        return (["set": true, "alarm": date.formatted(date: .omitted, time: .shortened),
                                 "secondAlarm": wake.followUpScheduled],
                                .alarm(AlarmCardData(time: date, secondAlarm: wake.followUpScheduled)))
                    case "cancelWakeAlarm":
                        await wake.cancel(home: home, api: session.api, toast: Toast())
                        return (["ok": wake.scheduled == nil], .alarm(AlarmCardData(time: nil, secondAlarm: false)))
                    default: return nil
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

    private func setAlarm(_ arguments: String) async -> (output: [String: Any], view: VoiceView?) {
        struct Args: Decodable { let time: String; let secondAlarm: Bool? }
        let args = try? JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        let parts = args?.time.split(separator: ":").compactMap { Int($0) } ?? []
        guard let args, parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
            return (["error": "Give the time as HH:mm."], nil)
        }
        wake.hour = parts[0]
        wake.minute = parts[1]
        if let second = args.secondAlarm { wake.followUp = second }
        let toast = Toast()
        await wake.set(home: home, api: session.api, toast: toast)
        guard let date = wake.scheduled, Calendar.current.component(.hour, from: date) == parts[0] else {
            return (["error": toast.message ?? "Couldn't set the alarm. Alarms may be turned off for this app in Settings."], nil)
        }
        var output: [String: Any] = ["ok": true, "alarm": date.formatted(date: .omitted, time: .shortened), "secondAlarm": wake.followUpScheduled]
        // The alarm is set even if the lamp couldn't be scheduled; say so.
        if toast.isError, let message = toast.message { output["note"] = message }
        return (output, .alarm(AlarmCardData(time: date, secondAlarm: wake.followUpScheduled)))
    }

    /// "It's bedtime": William's room lamp off, then the wall sleeps once Jarvis says goodnight.
    private func bedtime() async -> (output: [String: Any], view: VoiceView?) {
        var output: [String: Any] = ["ok": true]
        if let lamp = home.entity(WakeAlarm.lampEntity) {
            if lamp.isOn { await home.toggle(lamp, api: session.api, toast: Toast()) }
            output["lampOff"] = true
        } else {
            output["lampOff"] = false
            output["note"] = "William's room lamp isn't among the lights the wall can see."
        }
        wake.expireIfPast()
        output["alarm"] = wake.scheduled.map { $0.formatted(date: .omitted, time: .shortened) as Any } ?? NSNull()
        sleep.pending = true
        voice.finishAfterReply()
        return (output, nil)
    }

    private func refreshSlow() async {
        habits.rollDay()
        let api = session.api
        async let h: Void = habits.load(api: api)
        async let w: Void = weather.load(api: api)
        async let fit: Void = fitness.load(api: api)
        async let c: Data? = try? api.data(api.request("/api/mobile/calendar"))
        _ = await (h, w, fit)
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
    let habits: HabitsStore
    let weather: WeatherStore
    let pi: PiStore
    let fitness: FitnessStore
    let calendar: CalendarResponse?
    let wake: WakeAlarm
    let voice: VoiceAgent
    let sleep: WallSleep
    let refresh: () async -> Void

    @Environment(AppSession.self) private var session
    @State private var toast = Toast()
    @State private var light: HAEntity?
    @State private var remote: HAEntity?
    @State private var account = false
    @State private var alerts = WallAlertsStore()

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    glance
                    homeSection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .environment(\.wallCardHeight, cardHeight(screen: geo.size.height))
        }
        .refreshable {
            async let a: Void = home.refresh(api: session.api)
            async let b: Void = refresh()
            async let c: Void = pi.load(api: session.api)
            _ = await (a, b, c)
        }
        // Popups (a service down, tomorrow's wake-up, a birthday), one at a time, under Jarvis.
        .overlay { popups }
        // Jarvis takes the stage once it has a card: the dashboard softens and steps back. While
        // it's only the corner orb, the wall stays as it is.
        .blur(radius: voice.takingOver ? 24 : 0)
        .scaleEffect(voice.takingOver ? 0.97 : 1)
        .allowsHitTesting(!voice.takingOver)
        .animation(.smooth(duration: 0.5), value: voice.takingOver)
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .tint(BrickLook.ink)
        .overlay { VoiceOverlay(agent: voice) }
        // Asleep for the night: black, over everything. A tap wakes it.
        .overlay {
            if sleep.asleep {
                Color.black.ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { sleep.wake() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: sleep.asleep)
        .persistentSystemOverlays(.hidden)
        .onAppear { KeepAwake.hold() }
        .onDisappear { KeepAwake.release() }
        .sheet(item: $light) { e in
            LightSheet(entityID: e.id, store: home, toast: toast).presentationDetents([.medium, .large])
        }
        .sheet(item: $remote) { e in RemoteSheet(entity: home.entity(e.id) ?? e) }
        .sheet(isPresented: $account) { SettingsView() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in habits.rollDay() }
        .toast(toast)
    }

    // MARK: Clock and status

    /// Only a set alarm, as quiet text in the corner; nothing otherwise.
    @ViewBuilder private var header: some View {
        if wake.scheduled != nil {
            HStack {
                Spacer(minLength: 0)
                WakeControl(alarm: wake, home: home, toast: toast)
            }
            .frame(height: Self.headerHeight)
        }
    }

    private static let headerHeight: CGFloat = 20
    private static let spacing: CGFloat = 30
    private static let pillRow: CGFloat = 44

    /// The card height that makes the glance row and the rows of lights (two across, the next
    /// event beside them) fill the screen exactly. Anything else sits below, a scroll away.
    private func cardHeight(screen: CGFloat) -> CGFloat {
        let lights = home.shownEntities.filter { $0.control == .light }.count
        let lightRows = max(1, (lights + 1) / 2)
        var fixed: CGFloat = 24 * 2 + Self.spacing // padding, and the gap between the two sections
        if wake.scheduled != nil { fixed += Self.headerHeight + Self.spacing }
        if let p = home.state?.automations, !(p.scenes + p.scripts).isEmpty { fixed += Self.pillRow + Self.spacing }
        fixed += CGFloat(lightRows - 1) * 14
        let height = (screen - fixed) / CGFloat(1 + lightRows)
        return min(max(height.rounded(.down), 180), 460)
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
            let queue = WallAlert.queue(now: context.date, pi: pi.status, alarm: wake, calendar: calendar,
                                        dismissed: alerts.dismissed, kept: alerts.kept)
            ZStack {
                if let alert = queue.first {
                    WallPopup(alert: alert, pi: pi, alarm: wake, home: home, toast: toast) {
                        alerts.keep(alert)
                    } onClose: {
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
        // Lights on the left in two columns, the next event filling the right half beside them.
        let lights = home.shownEntities.filter { $0.control == .light }
        HStack(alignment: .top, spacing: 14) {
            if home.state == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            } else if !lights.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(lights) { e in
                        WallLightCard(entity: e) {
                            Task { await home.toggle(e, api: session.api, toast: toast) }
                        } onAdjust: {
                            if e.hasLightControls { light = e }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            NextEventTile(calendar: calendar)
                .frame(maxWidth: .infinity)
        }
        if home.state != nil {
            let shown = home.shownEntities
            ForEach(deviceGroups, id: \.title) { group in
                let items = shown.filter { group.kinds.contains($0.control) }
                if !items.isEmpty {
                    if group.kinds.contains(.light) {
                        // Shown above, beside the next event.
                        EmptyView()
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
        // Home's lamps are bare glyphs: the card's own tint already says on or off.
        let bareIcon = compact && entity.control == .light
        VStack(alignment: .leading, spacing: compact ? 10 : large ? 18 : 14) {
            HStack {
                Image(systemName: entity.symbol)
                    .font(compact ? .title3 : large ? .system(size: 30) : .title2)
                    .frame(width: compact ? 40 : large ? 64 : 48, height: compact ? 40 : large ? 64 : 48)
                    .foregroundStyle(bareIcon ? (on ? tint : .secondary) : (on ? .white : .secondary))
                    .background(bareIcon ? Color.clear : (on ? tint : Color(.tertiarySystemFill)), in: .circle)
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
        Button(action: onTap) {
            VStack(spacing: size * 0.09) {
                // Untinted Liquid Glass: regular until it's done, then it fills in with clear glass.
                Circle()
                    .fill(done ? Color.white.opacity(0.22) : .clear)
                    .glassGlare(done ? .clear.interactive() : .regular.interactive(), in: .circle)
                    .overlay {
                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: size * 0.4, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 6)
                                .transition(.scale.combined(with: .opacity))
                        } else if let icon = habit.icon {
                            Text(icon).font(.system(size: size * 0.36))
                        }
                    }
                    .animation(.spring(duration: 0.3, bounce: 0.2), value: done)
                .frame(width: size, height: size)
                if showsName {
                    Text(habit.name)
                        .font(size > 90 ? .headline : size > 60 ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(.primary)
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
