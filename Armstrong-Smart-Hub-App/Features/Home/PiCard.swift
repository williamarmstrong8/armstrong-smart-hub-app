import SwiftUI

/// The Pi at a glance on Home: whether Uptime Kuma's services are up, then temperature, CPU,
/// memory and disk as thin bars. Hidden when the hub can't see the Pi (it runs on Vercel).
struct PiCard: View {
    let status: PiStatus

    var body: some View {
        BrickCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    BrickCaps(text: "Raspberry Pi").foregroundStyle(BrickLook.soft)
                    Spacer(minLength: 8)
                    if let up = status.uptimeSeconds {
                        Text("Up \(Self.duration(up))")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(BrickLook.soft)
                    }
                }

                if let services = status.services, !services.isEmpty { servicesLine(services) }

                HStack(alignment: .top, spacing: 16) {
                    if let t = status.temperature {
                        PiGauge(label: "Temp", value: "\(Int(t.rounded()))°", fraction: t / 85,
                                warn: t >= 70, bad: t >= 80)
                    }
                    if let load = status.load?.first, let cores = status.cores, cores > 0 {
                        let f = load / Double(cores)
                        PiGauge(label: "CPU", value: "\(Int((min(f, 1) * 100).rounded()))%", fraction: f,
                                warn: f >= 0.75, bad: f >= 1)
                    }
                    if let m = status.memory {
                        PiGauge(label: "Memory", value: "\(Int((m.fraction * 100).rounded()))%", fraction: m.fraction,
                                warn: m.fraction >= 0.85, bad: m.fraction >= 0.95)
                    }
                    if let d = status.disk {
                        PiGauge(label: "Disk", value: "\(Int((d.fraction * 100).rounded()))%", fraction: d.fraction,
                                warn: d.fraction >= 0.85, bad: d.fraction >= 0.95)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "All 14 services up", or which ones are down, with the day's uptime beside it.
    private func servicesLine(_ services: [PiService]) -> some View {
        let down = services.filter { !$0.up }
        let uptimes = services.compactMap(\.uptime24h)
        let average = uptimes.isEmpty ? nil : uptimes.reduce(0, +) / Double(uptimes.count)
        let text: String = switch down.count {
        case 0: "All \(services.count) services up"
        case 1: "\(down[0].name) is down"
        case 2: "\(down[0].name) and \(down[1].name) are down"
        default: "\(down.count) of \(services.count) services down"
        }
        return HStack(spacing: 10) {
            Circle()
                .fill(down.isEmpty ? HubDesign.positive : HubDesign.danger)
                .frame(width: 8, height: 8)
            Text(text).font(.body)
            Spacer(minLength: 8)
            if let average {
                Text(average >= 99.95 ? "100% today" : String(format: "%.1f%% today", average))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(BrickLook.soft)
            }
        }
    }

    static func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = seconds / 3_600
        if hours >= 1 { return "\(hours) hr" }
        return "\(max(seconds / 60, 1)) min"
    }
}

/// A value over a caps label, on a thin bar that turns amber, then red, as it fills.
private struct PiGauge: View {
    let label: String
    let value: String
    let fraction: Double
    var warn = false
    var bad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 22, weight: .light).monospacedDigit())
                .foregroundStyle(BrickLook.ink)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(HubDesign.track.opacity(0.5))
                    Capsule()
                        .fill(bad ? HubDesign.danger : warn ? HubDesign.warning : BrickLook.ink)
                        .frame(width: geo.size.width * min(max(fraction, 0.02), 1))
                }
            }
            .frame(height: 3)
            BrickCaps(text: label).foregroundStyle(BrickLook.soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }
}
