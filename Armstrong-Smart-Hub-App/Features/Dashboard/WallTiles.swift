import SwiftUI

/// The wall's glance row: three soft cards, each opening its page.
private struct GlanceTile<Content: View>: View {
    let title: String
    var dot: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BrickCaps(text: title).foregroundStyle(BrickLook.soft)
                Spacer(minLength: 4)
                if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
            }
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 176, maxHeight: .infinity, alignment: .topLeading)
        .background(BrickLook.card, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
        .foregroundStyle(BrickLook.ink)
        .contentShape(RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
    }
}

/// A big light number with a note beside it, the iPhone's hero style.
private struct BigValue: View {
    let value: String
    var unit: String?
    var tint: Color = BrickLook.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 52, weight: .light).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let unit { Text(unit).font(.system(size: 16)).foregroundStyle(BrickLook.soft).lineLimit(1) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
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

// MARK: Weather

struct WeatherTile: View {
    let store: WeatherStore

    var body: some View {
        GlanceTile(title: store.weather?.place ?? "Weather") {
            if let w = store.weather {
                HStack(alignment: .center) {
                    BigValue(value: "\(w.current.temp)°", unit: w.current.label)
                    Spacer(minLength: 0)
                    Image(systemName: WeatherLook.symbol(w.current.code, isDay: w.current.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 34))
                }
                if let today = w.days.first {
                    Text("H \(today.high)°  L \(today.low)°  ·  Feels \(w.current.feelsLike)°")
                        .font(.system(size: 15)).foregroundStyle(BrickLook.soft).monospacedDigit().lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // The next few hours; only as many as fit.
                ViewThatFits(in: .horizontal) {
                    hours(w, 6)
                    hours(w, 5)
                    hours(w, 4)
                    hours(w, 3)
                }
            } else {
                Placeholder(error: store.error)
            }
        }
    }

    private func hours(_ w: WeatherData, _ count: Int) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(w.hours.prefix(count).enumerated()), id: \.element.id) { i, h in
                VStack(spacing: 4) {
                    Text(WeatherLook.hour(h.time, first: i == 0)).font(.system(size: 12)).foregroundStyle(BrickLook.soft)
                    Image(systemName: WeatherLook.symbol(h.code, isDay: h.isDay)).symbolRenderingMode(.multicolor).font(.system(size: 16))
                    Text("\(h.temp)°").font(.system(size: 14)).monospacedDigit()
                }
                .fixedSize()
            }
        }
        .padding(.top, 2)
    }
}

// MARK: Fitness

struct FitnessTile: View {
    let store: FitnessStore

    var body: some View {
        GlanceTile(title: "Readiness") {
            if store.loaded {
                BigValue(value: store.readinessScore.map(String.init) ?? "–", unit: Status.word(store.readinessScore), tint: Fit.readiness)
                HStack(spacing: 16) {
                    metric("moon.fill", store.sleepScore.map(String.init), Fit.sleep)
                    metric("bolt.fill", store.energy.map(String.init), Fit.energy)
                    metric("figure.walk", steps, BrickLook.ink)
                }
                .font(.system(size: 16)).monospacedDigit()
            } else {
                Placeholder(error: store.error)
            }
        }
    }

    /// Today's steps when the hub has them, else the newest day's.
    private var steps: String? {
        guard let s = (store.today ?? store.days.first(where: { $0.steps != nil }))?.steps else { return nil }
        return s >= 10_000 ? String(format: "%.1fk", Double(s) / 1000) : s.formatted()
    }

    private func metric(_ icon: String, _ value: String?, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 13))
            Text(value ?? "–").lineLimit(1)
        }
    }
}

// MARK: The Pi

struct PiTile: View {
    let store: PiStore

    var body: some View {
        GlanceTile(title: "Raspberry Pi", dot: dot) {
            if let s = store.status {
                if s.available {
                    let total = s.containers?.count ?? 0
                    BigValue(value: "\(s.running)/\(total)", unit: s.troubled.isEmpty ? "running" : "\(s.troubled.count) down")
                    VStack(alignment: .leading, spacing: 7) {
                        if let t = s.temperature { UsageLine(label: "\(Int(t.rounded()))°C", fraction: (t - 30) / 55, warn: t >= 75) }
                        if let m = s.memory { UsageLine(label: "Memory \(Int((m.fraction * 100).rounded()))%", fraction: m.fraction, warn: m.fraction > 0.9) }
                        if let d = s.disk { UsageLine(label: "Disk \(Int((d.fraction * 100).rounded()))%", fraction: d.fraction, warn: d.fraction > 0.9) }
                    }
                } else {
                    Text(s.reason ?? "Not available.").font(.system(size: 15)).foregroundStyle(BrickLook.soft).lineLimit(4)
                }
            } else {
                Placeholder(error: store.error)
            }
        }
    }

    private var dot: Color? {
        guard let s = store.status, s.available else { return store.error != nil ? .red : nil }
        if !s.troubled.isEmpty || (s.temperature ?? 0) >= 75 || (s.disk?.fraction ?? 0) > 0.95 { return .orange }
        return .green
    }
}

/// A label over a thin bar.
private struct UsageLine: View {
    let label: String
    let fraction: Double
    var warn = false

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13)).monospacedDigit().foregroundStyle(warn ? Color.orange : BrickLook.soft)
                .frame(width: 88, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BrickLook.track)
                    Capsule().fill(warn ? Color.orange : BrickLook.bar)
                        .frame(width: geo.size.width * min(max(fraction, 0.02), 1))
                }
            }
            .frame(height: 5)
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
