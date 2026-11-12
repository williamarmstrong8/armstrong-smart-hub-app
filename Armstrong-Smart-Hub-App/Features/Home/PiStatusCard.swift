import SwiftUI

/// The Pi on Home, kept quiet: one line on whether the services are up, then four values.
/// Tapping opens the full picture. Hidden when the hub can't see the Pi (it runs on Vercel).
struct PiStatusCard: View {
    let status: PiStatus

    var body: some View {
        BrickCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(healthy ? HubDesign.positive : HubDesign.danger).frame(width: 8, height: 8)
                    Text(headline).font(.body)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(BrickLook.soft)
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.value).font(.system(size: 20, weight: .light).monospacedDigit())
                            BrickCaps(text: v.label).foregroundStyle(BrickLook.soft)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var downServices: [PiService] { (status.services ?? []).filter { !$0.up } }
    private var healthy: Bool { downServices.isEmpty && status.troubled.isEmpty }

    private var headline: String {
        if let s = downServices.first { return downServices.count == 1 ? "\(s.name) is down" : "\(downServices.count) services down" }
        if let c = status.troubled.first { return status.troubled.count == 1 ? "\(c.name) needs a look" : "\(status.troubled.count) containers need a look" }
        if let n = status.services?.count, n > 0 { return "Raspberry Pi · all \(n) services up" }
        return "Raspberry Pi"
    }

    private var values: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if let t = status.temperature { out.append(("Temp", "\(Int(t.rounded()))°")) }
        if let load = status.load?.first, let cores = status.cores, cores > 0 {
            out.append(("CPU", "\(Int((min(load / Double(cores), 1) * 100).rounded()))%"))
        }
        if let m = status.memory { out.append(("Memory", "\(Int((m.fraction * 100).rounded()))%")) }
        if let d = status.disk { out.append(("Disk", "\(Int((d.fraction * 100).rounded()))%")) }
        return out
    }

    static func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = seconds / 3_600
        if hours >= 1 { return "\(hours) hr" }
        return "\(max(seconds / 60, 1)) min"
    }
}
