import Charts
import SwiftUI

/// A night, to open in the log sheet.
struct NightRef: Identifiable {
    var id: String
}

// MARK: Quick log

/// Drinks on the Fitness screen: one tap adds a drink now, the stepper sets how
/// many the next tap adds, Undo takes the last one back. On a rough morning or a
/// weekend evening it also asks, with a one-tap "No drinks".
struct AlcoholCard: View {
    var fitness: FitnessStore
    @State private var store = AlcoholStore.shared
    @State private var count = 1
    @State private var sheet: NightRef?

    var body: some View {
        let tonight = store.tonight
        let logged = store.drinks(on: tonight) > 0
        let dry = store.dryNights.contains(tonight)
        BrickCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drinks").font(.system(size: 22, weight: .regular)).foregroundStyle(BrickLook.ink)
                        Text(store.summary(tonight).map { "Tonight · \($0)" } ?? (dry ? "No drinks tonight" : "Tap to log one"))
                            .font(.subheadline).foregroundStyle(BrickLook.soft)
                    }
                    Spacer(minLength: 8)
                    NavigationLink(value: FitnessPage.alcohol) {
                        Text("Insights").font(.footnote).foregroundStyle(BrickLook.soft)
                            .frame(minHeight: HubLayout.minHitTarget).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if let prompt = store.prompt(fitness) {
                    promptView(prompt)
                    BrickDivider()
                }
                HStack(spacing: 8) {
                    ForEach(DrinkKind.allCases) { kind in
                        Button {
                            store.add(kind, count: count)
                            count = 1
                        } label: {
                            Text(count > 1 ? "\(kind.title) ×\(count)" : kind.title)
                                .font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .glassGlare(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(count) \(kind.longTitle)")
                    }
                }
                HStack(spacing: 10) {
                    stepButton("minus", label: "Fewer drinks", enabled: count > 1) { count -= 1 }
                    Text("\(count)").font(.body.weight(.medium)).monospacedDigit().frame(minWidth: 22)
                        .accessibilityLabel("\(count) drinks")
                    stepButton("plus", label: "More drinks", enabled: count < 12) { count += 1 }
                    Spacer(minLength: 8)
                    if logged || dry {
                        textButton("Undo") { if logged { store.undoLast(on: tonight) } else { store.clearDry(tonight) } }
                    }
                    if logged { textButton("Edit") { sheet = NightRef(id: tonight) } }
                    if !logged, !dry { textButton("No drinks") { store.markDry(tonight) } }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: store.entries.count)
        .sensoryFeedback(.selection, trigger: count)
        .task(id: fitness.updatedAt) { store.recordBattery(fitness.series(.bodyBattery)) }
        .sheet(item: $sheet) { AlcoholSheet(night: $0.id).presentationDetents([.medium, .large]) }
    }

    private func promptView(_ prompt: AlcoholPrompt) -> some View {
        let weekday = MorningCheckin.date(prompt.night)?.formatted(.dateTime.weekday(.wide)) ?? "Tonight"
        let night = prompt.night
        return VStack(alignment: .leading, spacing: 10) {
            switch prompt {
            case let .lastNight(_, reason):
                Text("\(reason). Did you have any drinks \(weekday) night?").font(.subheadline).foregroundStyle(BrickLook.ink)
            case .tonight:
                Text("It's \(weekday) night. Any drinks?").font(.subheadline).foregroundStyle(BrickLook.ink)
            }
            HStack(spacing: 8) {
                Button { store.markDry(night) } label: {
                    Text("No drinks").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .glassGlare(.regular.tint(Fit.action.opacity(0.55)).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                if case .lastNight = prompt {
                    Button { sheet = NightRef(id: night) } label: {
                        Text("Log drinks").font(.footnote.weight(.semibold)).foregroundStyle(BrickLook.ink)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .glassGlare(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(BrickLook.ink)
                .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                .glassGlare(.regular.interactive(enabled), in: .circle)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote).foregroundStyle(BrickLook.soft)
                .padding(.horizontal, 8).frame(minHeight: HubLayout.minHitTarget).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Log sheet

/// One night's drinks: add with a kind, count and time, change a count, delete.
struct AlcoholSheet: View {
    @Environment(\.dismiss) private var dismiss
    var night: String
    @State private var store = AlcoholStore.shared
    @State private var kind = DrinkKind.beer
    @State private var count = 1
    @State private var date: Date

    init(night: String) {
        self.night = night
        _date = State(initialValue: AlcoholStore.night(of: .now) == night ? .now : AlcoholStore.evening(of: night))
    }

    var body: some View {
        NavigationStack {
            GlassForm {
                GlassSection("Add a drink") {
                    Picker("Drink", selection: $kind) {
                        ForEach(DrinkKind.allCases) { Text($0.longTitle).tag($0) }
                    }
                    Stepper("Count: \(count)", value: $count, in: 1...20)
                    DatePicker("When", selection: $date)
                    Button("Add") {
                        store.add(kind, count: count, at: date)
                        count = 1
                    }
                    .fontWeight(.semibold)
                }
                let entries = store.entries(on: night)
                GlassSection(Self.title(night)) {
                    if entries.isEmpty {
                        Text(store.dryNights.contains(night) ? "No drinks this night." : "Nothing logged for this night.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.kind.longTitle)
                                Text(entry.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text("\(entry.count)").monospacedDigit().frame(minWidth: 24)
                            Stepper("Count", value: countBinding(entry), in: 1...20).labelsHidden()
                            Button(role: .destructive) { store.remove(entry.id) } label: {
                                Image(systemName: "trash").frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                            }
                            .accessibilityLabel("Delete \(entry.kind.longTitle)")
                        }
                    }
                    if entries.isEmpty, !store.dryNights.contains(night) {
                        Button("No drinks this night") { store.markDry(night) }
                    }
                }
            }
            .navigationTitle("Drinks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func countBinding(_ entry: DrinkEntry) -> Binding<Int> {
        Binding(get: { store.entries.first { $0.id == entry.id }?.count ?? entry.count },
                set: { store.update(entry.id, kind: entry.kind, count: $0, date: entry.date) })
    }

    static func title(_ night: String) -> String {
        MorningCheckin.date(night)?.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) ?? night
    }
}

// MARK: Insights

extension AlcoholMetric {
    var tint: Color {
        switch self {
        case .sleep: Fit.sleep
        case .hrv, .readiness: Fit.readiness
        case .restingHr: Fit.heart
        case .battery: Fit.energy
        }
    }

    var detail: String {
        switch self {
        case .sleep: "The sleep score the morning after."
        case .hrv: "Overnight HRV; higher generally means better recovered."
        case .restingHr: "The next day's resting heart rate; lower is better."
        case .battery: "Body Battery at its morning peak. It is saved as each morning passes, so it fills in over the coming days."
        case .readiness: "Training Readiness the morning after."
        }
    }
}

/// Drinks per night against what the next morning looked like, one comparison per number.
struct AlcoholPage: View {
    var store: FitnessStore
    @State private var alcohol = AlcoholStore.shared
    @State private var sheet: NightRef?

    var body: some View {
        let insights = AlcoholInsights(store: alcohol, fitness: store)
        FitPage(title: "Alcohol") {
            Button { sheet = NightRef(id: alcohol.tonight) } label: {
                Label("Log drinks", systemImage: "plus").blueButton()
            }
            .buttonStyle(.plain)
            .padding(.top, 12).padding(.bottom, 24)
            if alcohol.loggedNights.isEmpty {
                Takeaway(text: "Log your drinks from the Fitness screen. After a few nights this page shows how sleep, HRV, resting heart rate, Body Battery and readiness changed the morning after one, two or more drinks.")
                    .padding(.bottom, 24)
            } else {
                FitSection(title: "Drinks per night", trailing: "Last 14 days") {
                    DailyBarChart(points: recent, tint: Fit.health, height: 140, period: 14)
                }
                ForEach(AlcoholMetric.allCases) { metric in
                    comparison(metric, insights)
                }
                FitSection(title: "Nights") {
                    VStack(spacing: 0) {
                        let nights = Array(alcohol.loggedNights.prefix(10))
                        ForEach(nights, id: \.self) { night in
                            Button { sheet = NightRef(id: night) } label: {
                                DetailRow(label: AlcoholSheet.title(night), value: alcohol.summary(night) ?? "No drinks", last: night == nights.last)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task { alcohol.recordBattery(store.series(.bodyBattery)) }
        .sheet(item: $sheet) { AlcoholSheet(night: $0.id).presentationDetents([.medium, .large]) }
    }

    private var recent: [DayValue] {
        (0..<14).reversed().compactMap { back in
            let night = addDays(alcohol.tonight, -back)
            return MorningCheckin.date(night).map { DayValue(date: $0, value: Double(alcohol.drinks(on: night))) }
        }
    }

    private func comparison(_ metric: AlcoholMetric, _ insights: AlcoholInsights) -> some View {
        let buckets = insights.buckets(metric)
        let change = insights.change(metric)
        let delta = change?.delta ?? 0
        let tint: Color? = abs(delta) < 0.5 ? nil : (delta > 0) == metric.higherIsBetter ? Fit.positive : Fit.attention
        let trailing = change.map { c in
            "\(c.label) drinks: \(delta < 0 ? "−" : "+")\(metric.format(abs(delta)))"
        }
        return FitSection(title: metric.title, trailing: trailing, trailingTint: tint) {
            if buckets.contains(where: { $0.average != nil }) {
                AlcoholBucketChart(metric: metric, buckets: buckets)
            }
            Takeaway(text: change == nil ? "Needs a morning after a drink and one without. \(metric.detail)"
                                         : "Average by drinks the night before. \(metric.detail)").font(.caption)
        }
    }
}

/// Three bars from zero: the average after no drinks, one or two, and three or more.
private struct AlcoholBucketChart: View {
    var metric: AlcoholMetric
    var buckets: [AlcoholInsights.Bucket]

    var body: some View {
        let top = buckets.compactMap(\.average).max() ?? 1
        Chart(buckets) { bucket in
            if let average = bucket.average {
                BarMark(x: .value("Drinks", bucket.label), y: .value("Average", average), width: .ratio(0.5))
                    .foregroundStyle(metric.tint.opacity(bucket.label == AlcoholInsights.labels[0] ? 0.45 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .annotation(position: .top, spacing: 4) {
                        Text(metric.format(average)).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Color.primary)
                    }
            }
        }
        .chartYScale(domain: 0...(top * 1.2))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        let nights = buckets.first { $0.label == label }?.nights ?? 0
                        Text("\(label)\n\(nights) \(nights == 1 ? "morning" : "mornings")")
                            .font(Fit.axis).foregroundStyle(Fit.muted).multilineTextAlignment(.center)
                    }
                }
            }
        }
        .frame(height: 150)
    }
}
