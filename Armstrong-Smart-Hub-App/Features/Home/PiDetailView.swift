import SwiftUI

/// The Pi in full: four rings for how hard it's working, load and swap as bars, then the Docker
/// containers and Uptime Kuma services as rows of dots.
struct PiDetailView: View {
    let pi: PiStore
    @Environment(AppSession.self) private var session

    var body: some View {
        ScrollView {
            if let s = pi.status, s.available {
                VStack(alignment: .leading, spacing: HubLayout.sectionGap) {
                    header(s)
                    rings(s)
                    bars(s)
                    containers(s)
                    services(s)
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.vertical, 12)
            } else {
                MessageView(title: "Pi unavailable", systemImage: "server.rack",
                            message: pi.status?.reason ?? pi.error ?? "The hub can't see the Pi right now.")
            }
        }
        .navigationTitle("Raspberry Pi")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await pi.load(api: session.api) }
        .task { await pi.load(api: session.api) }
        .hubPageStyle(backdrop: false)
    }

    private func header(_ s: PiStatus) -> some View {
        VStack(spacing: 6) {
            Text(s.host ?? "Raspberry Pi").font(.system(size: 34, weight: .light))
            if let up = s.uptimeSeconds {
                Text("Up \(PiStatusCard.duration(up))").font(.subheadline).foregroundStyle(BrickLook.soft)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func rings(_ s: PiStatus) -> some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: cols, spacing: 12) {
            if let t = s.temperature {
                Ring(label: "Temperature", value: "\(Int(t.rounded()))°", fraction: t / 85, warn: t >= 70, bad: t >= 80)
            }
            if let load = s.load?.first, let cores = s.cores, cores > 0 {
                let f = load / Double(cores)
                Ring(label: "CPU", value: "\(Int((min(f, 1) * 100).rounded()))%", fraction: f, warn: f >= 0.75, bad: f >= 1)
            }
            if let m = s.memory {
                Ring(label: "Memory", value: "\(Int((m.fraction * 100).rounded()))%", fraction: m.fraction,
                     detail: String(format: "%.1f of %.1f GB", m.used / 1024, m.total / 1024), warn: m.fraction >= 0.85, bad: m.fraction >= 0.95)
            }
            if let d = s.disk {
                Ring(label: "Disk", value: "\(Int((d.fraction * 100).rounded()))%", fraction: d.fraction,
                     detail: String(format: "%.0f of %.0f GB", d.used, d.total), warn: d.fraction >= 0.85, bad: d.fraction >= 0.95)
            }
        }
    }

    @ViewBuilder
    private func bars(_ s: PiStatus) -> some View {
        if let load = s.load, let cores = s.cores, cores > 0, load.count >= 3 || s.swap != nil {
            BrickCard {
                VStack(alignment: .leading, spacing: 16) {
                    if load.count >= 3 {
                        ForEach(Array(zip(["1 min", "5 min", "15 min"], load)), id: \.0) { label, v in
                            Bar(label: "Load \(label)", value: String(format: "%.2f", v), fraction: v / Double(cores))
                        }
                    }
                    if let sw = s.swap, sw.total > 0 {
                        Bar(label: "Swap", value: "\(Int((sw.fraction * 100).rounded()))%", fraction: sw.fraction)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func containers(_ s: PiStatus) -> some View {
        if let list = s.containers, !list.isEmpty {
            section("Docker", "\(s.running) of \(list.count) running") {
                ForEach(list) { c in
                    HStack(spacing: 10) {
                        Circle().fill(c.troubled ? HubDesign.danger : HubDesign.positive).frame(width: 8, height: 8)
                        Text(c.name).font(.body)
                        Spacer(minLength: 8)
                        Text(c.status).font(.caption).foregroundStyle(BrickLook.soft).lineLimit(1)
                    }
                }
            }
        } else if let e = s.dockerError {
            section("Docker", nil) { Text(e).font(.footnote).foregroundStyle(BrickLook.soft) }
        }
    }

    @ViewBuilder
    private func services(_ s: PiStatus) -> some View {
        if let list = s.services, !list.isEmpty {
            section("Services", "\(list.filter(\.up).count) of \(list.count) up") {
                ForEach(list) { v in
                    HStack(spacing: 10) {
                        Circle().fill(v.up ? HubDesign.positive : HubDesign.danger).frame(width: 8, height: 8)
                        Text(v.name).font(.body)
                        Spacer(minLength: 8)
                        if let u = v.uptime24h {
                            Text(u >= 99.95 ? "100%" : String(format: "%.1f%%", u))
                                .font(.caption).monospacedDigit().foregroundStyle(BrickLook.soft)
                        }
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, _ trailing: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BrickCaps(text: title).foregroundStyle(BrickLook.soft)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(BrickLook.soft) }
            }
            BrickCard { VStack(alignment: .leading, spacing: 14) { content() } }
        }
    }
}

/// A ring that fills with the value inside; amber, then red, as it nears the limit.
private struct Ring: View {
    let label: String
    let value: String
    let fraction: Double
    var detail: String?
    var warn = false
    var bad = false

    var body: some View {
        let tint = bad ? HubDesign.danger : warn ? HubDesign.warning : BrickLook.ink
        BrickCard {
            VStack(spacing: 12) {
                ZStack {
                    Circle().stroke(HubDesign.track.opacity(0.5), lineWidth: 6)
                    Circle().trim(from: 0, to: min(max(fraction, 0.01), 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(value).font(.system(size: 26, weight: .light).monospacedDigit())
                }
                .frame(width: 96, height: 96)
                VStack(spacing: 2) {
                    BrickCaps(text: label).foregroundStyle(BrickLook.soft)
                    Text(detail ?? " ").font(.caption2).foregroundStyle(BrickLook.soft)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }
}

/// A label and value over a thin bar.
private struct Bar: View {
    let label: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(BrickLook.soft)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(HubDesign.track.opacity(0.5))
                    Capsule().fill(fraction >= 1 ? HubDesign.danger : BrickLook.ink)
                        .frame(width: geo.size.width * min(max(fraction, 0.02), 1))
                }
            }
            .frame(height: 3)
        }
    }
}
