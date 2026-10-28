import SwiftUI

/// The wake-up Jarvis just set, big: the time, and when the lamp starts fading up. Or that it's
/// off.
struct AlarmCard: View {
    let data: AlarmCardData

    @State private var shown = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: data.time == nil ? "alarm" : "alarm.fill")
                .font(.system(size: 110))
                .foregroundStyle(data.time == nil ? Color.secondary : .orange)
                .symbolEffect(.bounce, value: shown)
            if let time = data.time {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 160, weight: .light).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(note(time))
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Alarm off")
                    .font(.system(size: 88, weight: .light))
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.94)
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.2)) { shown = true } }
    }

    private func note(_ time: Date) -> String {
        let lamp = time.addingTimeInterval(-Double(WakeAlarm.rampMinutes) * 60)
        var parts = ["Lamp fades up from \(lamp.formatted(date: .omitted, time: .shortened))"]
        if data.secondAlarm { parts.append("second alarm \(WakeAlarm.followUpMinutes) min later") }
        return parts.joined(separator: " · ")
    }
}
