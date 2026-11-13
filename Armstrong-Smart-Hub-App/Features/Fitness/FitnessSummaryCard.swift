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
                            .font(.body)
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
        HStack(alignment: .firstTextBaseline) {
            Label(isToday ? "Today's read" : "Latest read", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(BrickLook.ink)
            Spacer()
            if let created = summary.flatMap({ ISO.parse($0.createdAt) }) {
                let when = created.formatted(.relative(presentation: .named))
                Text(when.prefix(1).uppercased() + when.dropFirst())
                    .font(.footnote)
                    .foregroundStyle(BrickLook.soft)
            }
        }
    }
}

/// What a subpage's numbers indicate for the person, from the same daily
/// write as Today's read. Hidden when the hub has none for this page.
struct PageSummarySection: View {
    var store: FitnessStore
    var page: FitnessPage

    private var key: String {
        switch page {
        case .readiness: "readiness"
        case .recovery: "recovery"
        case .strain: "strain"
        case .sleep: "sleep"
        case .heart: "heart"
        case .energy: "energy"
        case .training: "training"
        case .health: "health"
        }
    }

    var body: some View {
        if let text = store.snapshot?.summary?.pages?[key] {
            FitSection(title: "What this means") {
                Text(text)
                    .font(.body)
                    .foregroundStyle(BrickLook.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
