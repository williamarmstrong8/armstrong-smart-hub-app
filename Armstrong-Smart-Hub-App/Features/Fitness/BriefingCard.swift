import SwiftUI

/// Today's health briefings on Fitness, under This week: the morning one, and
/// the night one once it's written. Written on the phone (HealthBriefing);
/// the refresh button writes the current one again from the newest data.
struct BriefingCard: View {
    @State private var briefing = HealthBriefing.shared
    @State private var workout = TodayWorkout.shared

    /// Today's slots that have a brief, night first.
    private var shown: [HealthBriefing.Slot] {
        HealthBriefing.Slot.allCases.reversed().filter { briefing.isCurrent($0) && briefing.briefs[$0] != nil }
    }

    var body: some View {
        if briefing.morningOn || briefing.nightOn {
            BrickCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        BrickCaps(text: "Briefing").foregroundStyle(BrickLook.soft)
                        Spacer()
                        Button {
                            Task { await briefing.writeNow() }
                        } label: {
                            Group {
                                if briefing.writing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise").font(.footnote.weight(.semibold))
                                }
                            }
                            .foregroundStyle(BrickLook.soft)
                            .frame(width: HubLayout.minHitTarget, height: 24)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(briefing.writing)
                        .accessibilityLabel("Write the \(HealthBriefing.currentSlot == .morning ? "morning" : "night") briefing again")
                    }
                    if workout.sentToday, let sent = workout.sent {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "applewatch")
                                Text("Today's session")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(BrickLook.soft)
                            Text(sent.title).font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink)
                            Text(sent.why).font(.subheadline).foregroundStyle(BrickLook.soft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if shown.isEmpty {
                        Text(briefing.writing ? "Writing…" : "Your morning briefing comes after the watch syncs your sleep, and the night one from 9:30 pm.")
                            .font(.subheadline)
                            .foregroundStyle(BrickLook.soft)
                    } else {
                        ForEach(shown, id: \.self) { slot in
                            let brief = briefing.briefs[slot]!
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: slot == .morning ? "sunrise" : "moon.stars")
                                    Text(slot == .morning ? "Morning" : "Night")
                                    Text("·")
                                    Text(brief.at.formatted(date: .omitted, time: .shortened))
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(BrickLook.soft)
                                Text(brief.text)
                                    .font(.body)
                                    .foregroundStyle(BrickLook.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .animation(.snappy, value: briefing.briefs)
        }
    }
}
