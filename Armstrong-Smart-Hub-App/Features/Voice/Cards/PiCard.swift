import SwiftUI

/// The Pi that runs the house: its health, then each service as a dot. A
/// service Jarvis just started, stopped or restarted is ringed and pulses.
struct PiCard: View {
    let pi: PiStatus
    let changed: String?
    let action: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            CardHeader(title: "Raspberry Pi", detail: detail)
            PiStats(pi: pi)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(pi.containers ?? []) { c in
                    ServiceChip(container: c, changed: c.name == changed)
                }
            }
        }
    }

    private var detail: String {
        if let changed, let action {
            let done = switch action { case "start": "Started"; case "stop": "Stopped"; default: "Restarted" }
            return "\(done) \(changed)"
        }
        let troubled = pi.troubled
        if troubled.isEmpty { return "All \(pi.running) services running" }
        return "\(troubled.count) need\(troubled.count == 1 ? "s" : "") attention"
    }
}

private struct ServiceChip: View {
    let container: PiContainer
    let changed: Bool

    @State private var ring = false

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.7), radius: container.running ? 6 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(container.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white.opacity(changed ? 0.14 : 0.06), in: .rect(cornerRadius: 16))
        .overlay {
            if changed {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(color, lineWidth: 2)
                    .scaleEffect(ring ? 1.08 : 1)
                    .opacity(ring ? 0.3 : 1)
            }
        }
        .onAppear {
            guard changed else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatCount(3, autoreverses: true)) { ring = true }
        }
        .sensoryFeedback(.success, trigger: ring) { _, new in changed && new }
    }

    private var color: Color {
        if !container.running { return .red }
        switch container.health { case "unhealthy": return .orange; case "starting": return .yellow; default: return .green }
    }
}
