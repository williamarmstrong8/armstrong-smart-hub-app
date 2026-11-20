import SwiftUI

/// The Pi on Home, kept to one line: whether everything's up, and the temperature.
/// Tapping opens the full picture. Hidden when the hub can't see the Pi (it runs on Vercel).
/// When the phone can't reach the hub at all, it says so instead of showing the last answer.
struct PiStatusCard: View {
    let status: PiStatus
    var unreachable = false
    /// When the hub last answered, shown while it's out of reach.
    var lastSeen: Date?

    var body: some View {
        BrickCard {
            HStack(spacing: 10) {
                Circle().fill(healthy ? HubDesign.positive : HubDesign.danger).frame(width: 8, height: 8)
                Text(headline).font(.body)
                Spacer(minLength: 8)
                if unreachable {
                    if let ago = Self.ago(lastSeen) {
                        Text("seen \(ago)").font(.subheadline).foregroundStyle(BrickLook.soft)
                    }
                } else if let t = status.temperature {
                    Text("\(Int(t.rounded()))°").font(.body.monospacedDigit()).foregroundStyle(BrickLook.soft)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(BrickLook.soft)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var downServices: [PiService] { (status.services ?? []).filter { !$0.up } }
    private var healthy: Bool { !unreachable && downServices.isEmpty && status.troubled.isEmpty }

    private var headline: String {
        if unreachable { return "Can't reach the Pi" }
        if let s = downServices.first { return downServices.count == 1 ? "\(s.name) is down" : "\(downServices.count) services down" }
        if let c = status.troubled.first { return status.troubled.count == 1 ? "\(c.name) needs a look" : "\(status.troubled.count) containers need a look" }
        if let n = status.services?.count, n > 0 { return "Raspberry Pi · all \(n) services up" }
        return "Raspberry Pi"
    }

    static func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = seconds / 3_600
        if hours >= 1 { return "\(hours) hr" }
        return "\(max(seconds / 60, 1)) min"
    }

    /// "5 min ago", "6 hr ago"; nil when the hub has never answered on this phone.
    static func ago(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        return "\(duration(max(Int(now.timeIntervalSince(date)), 0))) ago"
    }
}
