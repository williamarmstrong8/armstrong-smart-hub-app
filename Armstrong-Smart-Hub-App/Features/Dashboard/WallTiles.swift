import SwiftUI

/// The wall's glance row: three soft cards the same height, each with its label and an icon
/// across the top and one big answer along the bottom.
private struct GlanceTile<Content: View, Corner: View>: View {
    let title: String
    @ViewBuilder var corner: Corner
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                BrickCaps(text: title).foregroundStyle(BrickLook.soft).lineLimit(1)
                Spacer(minLength: 8)
                corner
            }
            .frame(height: 36)
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .topLeading)
        .background(BrickLook.card, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
        .foregroundStyle(BrickLook.ink)
        .contentShape(RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
    }
}

/// One big light value with a short note under it, readable across the room.
private struct BigValue: View {
    let value: String
    var note: String?
    var tint: Color = BrickLook.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 60, weight: .light).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(note ?? " ")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(BrickLook.soft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Placeholder: View {
    let error: String?
    var body: some View {
        if let error {
            Text(error).font(.system(size: 14)).foregroundStyle(BrickLook.soft).lineLimit(3)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 60)
        }
    }
}

// MARK: Lights

/// A light on the wall, styled like the weather and readiness cards: its name big, how bright it
/// is under it, and a bulb in its own color. Tap toggles; hold for brightness and color.
struct WallLightCard: View {
    let entity: HAEntity
    let onTap: () -> Void
    let onAdjust: () -> Void

    @State private var pressed = false

    var body: some View {
        let on = entity.isOn
        let tint = entity.rgbColor.map { Color(rgb: $0) } ?? .orange
        GlanceTile(title: "") {
            Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(on ? tint : BrickLook.soft)
                .contentTransition(.symbolEffect(.replace))
        } content: {
            BigValue(value: entity.name,
                     note: entity.isUnavailable ? "Unavailable" : on ? "\(entity.brightnessPct)%" : "Off",
                     tint: on ? BrickLook.ink : BrickLook.soft)
        }
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.spring(duration: 0.2), value: pressed)
        .animation(.easeOut(duration: 0.2), value: on)
        .opacity(entity.isUnavailable ? 0.5 : 1)
        .onTapGesture { if !entity.isUnavailable { onTap() } }
        .onLongPressGesture(minimumDuration: 0.4) {
            if !entity.isUnavailable { onAdjust() }
        } onPressingChanged: { pressed = $0 }
        .sensoryFeedback(.impact(weight: .medium), trigger: on)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(entity.name), \(entity.stateLabel)")
        .accessibilityAction { onTap() }
        .accessibilityAction(named: "Adjust") { onAdjust() }
    }
}

// MARK: Weather

/// The morning's weather, big: the temperature now, what it's doing, and today's low to high
/// as a bar with a marker for where it is now.
struct WeatherTile: View {
    let store: WeatherStore

    var body: some View {
        let w = store.weather
        GlanceTile(title: "Outside") {
            if let w {
                Image(systemName: WeatherLook.symbol(w.current.code, isDay: w.current.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 34))
            }
        } content: {
            if let w {
                VStack(alignment: .leading, spacing: 18) {
                    BigValue(value: "\(w.current.temp)°", note: w.current.label)
                    if let today = w.days.first {
                        DayRange(low: today.low, high: today.high, now: w.current.temp)
                    }
                }
            } else {
                Placeholder(error: store.error)
            }
        }
    }
}

/// "L 44°" — a cool-to-warm bar with a dot for now (when it's today) — "H 58°".
private struct DayRange: View {
    let low: Int
    let high: Int
    var now: Int?

    var body: some View {
        HStack(spacing: 14) {
            label("arrow.down", "\(low)°")
            GeometryReader { geo in
                let span = Double(max(high - low, 1))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [.cyan, .green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 10)
                    if let now {
                        let at = min(max(Double(now - low) / span, 0), 1)
                        Circle()
                            .fill(BrickLook.ink)
                            .overlay(Circle().strokeBorder(BrickLook.card, lineWidth: 3))
                            .frame(width: 22, height: 22)
                            .offset(x: (geo.size.width - 22) * at)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 22)
            label("arrow.up", "\(high)°")
        }
    }

    private func label(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(BrickLook.soft)
            Text(text).font(.system(size: 26, weight: .light).monospacedDigit())
        }
        .fixedSize()
    }
}

/// At night: the next day's forecast. The high big, what it'll do, the low-to-high bar, and
/// the chance of rain when it's worth knowing. Before 5 AM "next" is the day that just began.
struct ForecastTile: View {
    let store: WeatherStore
    let now: Date

    var body: some View {
        let early = Calendar.current.component(.hour, from: now) < 5
        let day = store.weather.flatMap { w in w.days.count > (early ? 0 : 1) ? w.days[early ? 0 : 1] : nil }
        GlanceTile(title: early ? "Today" : "Tomorrow") {
            if let day {
                Image(systemName: WeatherLook.symbol(day.code))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 34))
            }
        } content: {
            if let day {
                VStack(alignment: .leading, spacing: 18) {
                    BigValue(value: "\(day.high)°", note: note(day))
                    DayRange(low: day.low, high: day.high)
                }
            } else {
                Placeholder(error: store.error)
            }
        }
    }

    private func note(_ d: WeatherDay) -> String {
        var parts = [WeatherLook.label(d.code), "Low \(d.low)°"]
        if let rain = d.precipChance, rain >= 30 { parts.append("\(rain)% rain") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Fitness

/// At night: how the day went. Steps when the hub has today's count (usually after the watch's
/// midnight sync), otherwise Body Battery, otherwise last night's sleep.
struct DayEndTile: View {
    let store: FitnessStore

    var body: some View {
        let today = store.today
        GlanceTile(title: "Your day") {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(tint)
        } content: {
            if store.loaded {
                if let steps = today?.steps {
                    BigValue(value: steps.formatted(), note: stepsNote(today))
                } else if let energy = store.energy {
                    BigValue(value: "\(energy)", note: "Body Battery", tint: Fit.energy)
                } else {
                    BigValue(value: store.sleepScore.map(String.init) ?? "–", note: "Last night's sleep", tint: Fit.sleep)
                }
            } else {
                Placeholder(error: store.error)
            }
        }
    }

    private var icon: String {
        store.today?.steps != nil ? "figure.walk" : store.energy != nil ? "bolt.fill" : "moon.fill"
    }

    private var tint: Color {
        store.today?.steps != nil ? Fit.activity : store.energy != nil ? Fit.energy : Fit.sleep
    }

    private func stepsNote(_ day: FitnessDay?) -> String {
        var parts = ["steps"]
        if let goal = day?.stepGoal, goal > 0 { parts = ["of \(goal.formatted()) steps"] }
        if let energy = store.energy { parts.append("Battery \(energy)") }
        return parts.joined(separator: " · ")
    }
}

/// Today's Training Readiness, big, in its color, and the one word for it.
struct FitnessTile: View {
    let store: FitnessStore

    var body: some View {
        GlanceTile(title: "Readiness") {
            Image(systemName: "figure.run").font(.system(size: 24)).foregroundStyle(Fit.readiness)
        } content: {
            if store.loaded {
                BigValue(value: store.readinessScore.map(String.init) ?? "–", note: Status.word(store.readinessScore), tint: Fit.readiness)
            } else {
                Placeholder(error: store.error)
            }
        }
    }
}

/// The Pi's page from the wall: its health, then every service with start, stop and restart.
struct PiPanel: View {
    let store: PiStore

    @Environment(AppSession.self) private var session
    @State private var toast = Toast()
    @State private var pending: (container: PiContainer, action: PiStore.Action)?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let s = store.status, s.available {
                PiStats(pi: s)
                if let error = s.dockerError { ErrorBanner(message: "Docker: \(error)") }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(s.containers ?? []) { c in
                        ContainerRow(container: c, busy: store.busy == c.name) { action in
                            pending = (c, action)
                        }
                    }
                }
                Text("Rebooting the Pi itself needs sudo, so it isn't offered here.")
                    .font(.footnote).foregroundStyle(BrickLook.soft)
            } else if let s = store.status {
                MessageView(title: "Can't see the Pi", systemImage: "server.rack", message: s.reason)
            } else if let error = store.error {
                MessageView(title: "Can't see the Pi", systemImage: "server.rack", message: error, actionTitle: "Try again") {
                    Task { await store.load(api: session.api) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task { await store.load(api: session.api) }
        .confirmationDialog(pending.map { "\($0.action.rawValue.capitalized) \($0.container.name)?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let p = pending {
                Button(p.action.rawValue.capitalized, role: p.action == .start ? nil : .destructive) {
                    Task { await store.control(p.container, p.action, api: session.api, toast: toast) }
                }
            }
        } message: {
            if pending?.action == .stop { Text("It stays off until you start it again.") }
        }
        .toast(toast)
    }
}

/// Temperature, load, memory, disk and uptime, side by side.
struct PiStats: View {
    let pi: PiStatus

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], alignment: .leading, spacing: 16) {
            if let t = pi.temperature { stat("Temperature", "\(Int(t.rounded()))°C", warn: t >= 75) }
            if let l = pi.load?.first { stat("Load", String(format: "%.2f", l), detail: pi.cores.map { "\($0) cores" }) }
            if let m = pi.memory { stat("Memory", "\(Int((m.fraction * 100).rounded()))%", detail: "\(gb(m.used / 1024)) of \(gb(m.total / 1024))", warn: m.fraction > 0.9) }
            if let d = pi.disk { stat("Disk", "\(Int((d.fraction * 100).rounded()))%", detail: "\(Int(d.total - d.used)) GB free", warn: d.fraction > 0.9) }
            if let u = pi.uptimeSeconds { stat("Up", Uptime.text(u), detail: pi.host) }
        }
    }

    private func gb(_ v: Double) -> String { String(format: "%.1f GB", v) }

    private func stat(_ label: String, _ value: String, detail: String? = nil, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 34, weight: .light).monospacedDigit())
                .foregroundStyle(warn ? Color.orange : .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

enum Uptime {
    /// "13d 11h", "5h 20m", "4m".
    static func text(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = seconds % 86_400 / 3600, m = seconds % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

private struct ContainerRow: View {
    let container: PiContainer
    let busy: Bool
    let onAction: (PiStore.Action) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.system(size: 17, weight: .medium)).lineLimit(1)
                Text(container.status).font(.system(size: 13)).foregroundStyle(BrickLook.soft).lineLimit(1)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView()
            } else {
                Menu {
                    if container.running {
                        Button("Restart", systemImage: "arrow.clockwise") { onAction(.restart) }
                        Button("Stop", systemImage: "stop.fill", role: .destructive) { onAction(.stop) }
                    } else {
                        Button("Start", systemImage: "play.fill") { onAction(.start) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium))
                        .frame(width: 40, height: 40)
                        .background(BrickLook.pill, in: .circle)
                }
            }
        }
        .padding(16)
        .background(BrickLook.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var color: Color {
        if !container.running { return .red }
        switch container.health { case "unhealthy": return .orange; case "starting": return .yellow; default: return .green }
    }
}
