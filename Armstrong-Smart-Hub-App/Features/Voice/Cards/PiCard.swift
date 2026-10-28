import SwiftUI

/// The Pi in one answer, big: all good, what's down, or the service Jarvis
/// just started, stopped or restarted. The full list and controls live on the
/// wall's Pi page.
struct PiCard: View {
    let pi: PiStatus
    let changed: String?
    let action: String?

    @State private var shown = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 120, weight: .regular))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: shown)
            Text(headline)
                .font(.system(size: 88, weight: .light))
                .lineLimit(2)
                .minimumScaleFactor(0.4)
                .multilineTextAlignment(.center)
            Text(note)
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.94)
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.2)) { shown = true } }
    }

    private var changedContainer: PiContainer? { pi.containers?.first { $0.name == changed } }

    private var headline: String {
        if let changed, let action {
            let done = switch action { case "start": "Started"; case "stop": "Stopped"; default: "Restarted" }
            return "\(done) \(changed)"
        }
        let down = pi.troubled
        if down.isEmpty { return "All good" }
        return down.count == 1 ? "\(down[0].name) is down" : "\(down.count) services down"
    }

    private var note: String {
        if let c = changedContainer { return c.status }
        let down = pi.troubled
        if down.count > 1 { return down.map(\.name).joined(separator: ", ") }
        var parts = ["\(pi.running) services running"]
        if let t = pi.temperature { parts.append("\(Int(t.rounded()))°C") }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        if changed != nil { return action == "stop" ? "stop.circle.fill" : "checkmark.circle.fill" }
        return pi.troubled.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        if changed != nil { return action == "stop" ? .secondary : .green }
        return pi.troubled.isEmpty ? .green : .orange
    }
}
