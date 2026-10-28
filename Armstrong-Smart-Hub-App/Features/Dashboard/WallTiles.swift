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

/// "L 44°" — a cool-to-warm bar with a dot for now — "H 58°".
private struct DayRange: View {
    let low: Int
    let high: Int
    let now: Int

    var body: some View {
        HStack(spacing: 14) {
            label("arrow.down", "\(low)°")
            GeometryReader { geo in
                let span = Double(max(high - low, 1))
                let at = min(max(Double(now - low) / span, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [.cyan, .green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 10)
                    Circle()
                        .fill(BrickLook.ink)
                        .overlay(Circle().strokeBorder(BrickLook.card, lineWidth: 3))
                        .frame(width: 22, height: 22)
                        .offset(x: (geo.size.width - 22) * at)
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

// MARK: Fitness

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
