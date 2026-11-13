import SwiftUI

/// Today's read: one paragraph from the hub, written once a day after the
/// morning sync brings last night in, that says what the numbers mean.
/// Hidden until the hub has written one.
struct HealthSummaryCard: View {
    @Environment(AppSession.self) private var session
    var store: FitnessStore

    private var summary: FitnessSummary? { store.snapshot?.summary }
    private var writing: Bool { store.snapshot?.summaryWriting == true }

    /// Written for a night that ended in the last 20 hours: it's today's.
    private var isToday: Bool {
        guard let end = summary.flatMap({ ISO.parse($0.nightEnd) }) else { return false }
        return Date.now.timeIntervalSince(end) < 20 * 3600
    }

    var body: some View {
        if summary != nil || writing {
            BrickCard {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if writing && !isToday {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading last night's data…").font(.subheadline).foregroundStyle(BrickLook.soft)
                        }
                    }
                    if let summary {
                        Text(summary.text)
                            .font(.title3)
                            .foregroundStyle(BrickLook.ink)
                            .opacity(isToday ? 1 : 0.6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            // The hub writes in the background after the sync; check back until it's there.
            .task(id: writing) {
                guard writing else { return }
                for _ in 0..<8 {
                    try? await Task.sleep(for: .seconds(8))
                    if Task.isCancelled { return }
                    await store.load(api: session.api)
                    if store.snapshot?.summaryWriting != true { return }
                }
            }
        }
    }

    private var header: some View {
        Label(isToday ? "Today's read" : "Latest read", systemImage: "sparkles")
            .font(.headline)
            .foregroundStyle(BrickLook.ink)
    }
}
