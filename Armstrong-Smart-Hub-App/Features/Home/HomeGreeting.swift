import SwiftUI

/// Home's headline: a butler-style greeting in Jarvis's voice, picked from preset lines by
/// the time of day. The pick holds for the whole part of the day, so it never flickers.
enum HomeGreeting {
    static func line(name: String, now: Date = .now) -> String {
        let who = name.isEmpty ? "sir" : name
        let hour = Calendar.current.component(.hour, from: now)
        let lines: [String]
        let part: Int
        switch hour {
        case 5..<12:
            part = 0
            lines = ["Good morning, sir", "Morning, \(who). All systems online", "Rise and shine, sir",
                     "Good morning, \(who). The house is awake", "Up and running, sir"]
        case 12..<17:
            part = 1
            lines = ["At your service, sir", "Afternoon, \(who)", "All systems nominal, sir",
                     "Standing by, \(who)", "How can I help, sir?"]
        case 17..<23:
            part = 2
            lines = ["Welcome home, sir", "Good evening, \(who)", "Evening, sir. Everything's in order",
                     "Good to have you back, \(who)", "The house is yours, sir"]
        default:
            part = 3
            lines = ["Working late, sir?", "Still up, \(who)?", "Burning the midnight oil, sir",
                     "Shall I dim the lights, sir?", "It's late, \(who)"]
        }
        // Same line all morning (or evening); a different one tomorrow.
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        return lines[(day * 4 + part) % lines.count]
    }
}

/// Grey glass rows in the shape of Home's light switches, until the hub's first answer.
struct DeviceSkeleton: View {
    @State private var dim = false

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 14) {
                    Circle().fill(.secondary.opacity(0.25)).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(.secondary.opacity(0.25)).frame(width: 120, height: 12)
                        Capsule().fill(.secondary.opacity(0.18)).frame(width: 64, height: 10)
                    }
                    Spacer()
                }
                .padding(.horizontal, HubLayout.cardPadding)
                .frame(maxWidth: .infinity, minHeight: 76)
                .glassGlare(.regular, in: .rect(cornerRadius: HubLayout.cardRadius))
            }
        }
        .opacity(dim ? 0.55 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityLabel("Loading devices")
    }
}
