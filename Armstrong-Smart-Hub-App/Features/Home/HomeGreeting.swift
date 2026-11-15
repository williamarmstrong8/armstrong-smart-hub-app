import SwiftUI

/// Home's headline: one real number about your day instead of "Good afternoon". Mornings lead
/// with last night's sleep, the day with steps, evenings with habits; the calendar fills gaps.
struct HomeGreeting {
    let name: String
    let glance: FitnessGlance?
    let habitsDone: Int?
    let habitsTotal: Int
    let nextEvent: Date?
    /// "Front door is unlocked", when something's worth saying about the house.
    let house: String?
    var now = Date.now

    var title: String { lines.title }
    var detail: String? { lines.detail }

    private var lines: (title: String, detail: String?) {
        let hour = Calendar.current.component(.hour, from: now)
        let today = glance?.isToday == true ? glance : nil
        var candidates: [String] = []
        var sleepLine: String?

        // Morning: last night first.
        if hour >= 4, hour < 11, let sleep = today?.sleepSeconds, sleep > 0 {
            sleepLine = name.isEmpty ? "You slept \(Self.duration(sleep))" : "\(Self.duration(sleep)) of sleep, \(name)"
            candidates.append(sleepLine!)
        }
        // Evening: habits, when there are any left to talk about.
        if hour >= 17, let done = habitsDone, habitsTotal > 0 {
            candidates.append(done == habitsTotal ? "All \(habitsTotal) habits done" : "\(done) of \(habitsTotal) habits done")
        }
        if let steps = today?.steps, steps > 0 {
            if let goal = today?.stepGoal, goal > 0, steps >= goal {
                candidates.append("\(steps.formatted()) steps, goal hit")
            } else {
                candidates.append("\(steps.formatted()) steps so far")
            }
        }
        if let free = freeUntil { candidates.append(free) }

        let title = candidates.first ?? (name.isEmpty ? "Welcome home" : "Hey, \(name)")
        // The second line: the house if something's on, else the next best number.
        var detail = house
        if detail == nil {
            detail = secondary(afterSleep: title == sleepLine, hour: hour, today: today) ?? candidates.dropFirst().first
        }
        return (title, detail)
    }

    /// "Free until 3 PM", when the next event is later today.
    private var freeUntil: String? {
        guard let start = nextEvent, Calendar.current.isDate(start, inSameDayAs: now),
              start.timeIntervalSince(now) > 30 * 60 else { return nil }
        return "Free until \(start.formatted(.dateTime.hour().minute()))"
    }

    private func secondary(afterSleep: Bool, hour: Int, today: FitnessGlance?) -> String? {
        var parts: [String] = []
        if let score = today?.sleepScore, afterSleep { parts.append("Sleep score \(score)") }
        if let r = today?.readiness, hour < 14 { parts.append("readiness \(r)") }
        if let b = today?.bodyBattery, hour >= 14 { parts.append("body battery \(b)") }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// "7h 42m".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
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
