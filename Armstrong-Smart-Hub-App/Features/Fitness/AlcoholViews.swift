import Charts
import SwiftUI

/// A night to open in the log sheet, and the drink to start it with.
struct NightRef: Identifiable {
    var id: String
    var kind: DrinkKind?
}

// MARK: Quick log

/// Drinks on the Fitness screen: a big tile per drink opens the log with one of
/// it already counted, so a drink is tap, (pick the time), Log. "No drinks"
/// answers the night in one tap. On a rough morning or a weekend evening it asks.
struct AlcoholCard: View {
    var fitness: FitnessStore
    @State private var store = AlcoholStore.shared
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
                        Text(store.detail(tonight).map { "Tonight · \($0)" } ?? (dry ? "No drinks tonight" : "Nothing logged tonight"))
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
                HStack(spacing: 10) {
                    ForEach(DrinkKind.allCases) { kind in
                        Button { sheet = NightRef(id: tonight, kind: kind) } label: {
                            VStack(spacing: 4) {
                                Text(kind.emoji).font(.system(size: 28))
                                Text(kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(BrickLook.ink)
                            }
                            .frame(maxWidth: .infinity, minHeight: 76)
                            .glassGlare(.regular.interactive(), in: .rect(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Log \(kind.longTitle)")
                    }
                }
                HStack(spacing: 10) {
                    if logged {
                        wideButton("Edit tonight", symbol: "pencil") { sheet = NightRef(id: tonight) }
                    } else if dry {
                        wideButton("Undo no drinks", symbol: "arrow.uturn.backward") { store.clearDry(tonight) }
                    } else {
                        wideButton("No drinks tonight", symbol: "checkmark") { store.markDry(tonight) }
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: store.dryNights.count)
        .task(id: fitness.updatedAt) { store.recordBattery(fitness.series(.bodyBattery)) }
        .sheet(item: $sheet) { AlcoholSheet(night: $0.id, start: $0.kind) }
    }

    private func promptView(_ prompt: AlcoholPrompt) -> some View {
        let weekday = MorningCheckin.date(prompt.night)?.formatted(.dateTime.weekday(.wide)) ?? "Tonight"
        let night = prompt.night
        return VStack(alignment: .leading, spacing: 12) {
            switch prompt {
            case let .lastNight(_, reason):
                Text("\(reason). Did you have any drinks \(weekday) night?").font(.subheadline).foregroundStyle(BrickLook.ink)
            case .tonight:
                Text("It's \(weekday) night. Any drinks?").font(.subheadline).foregroundStyle(BrickLook.ink)
            }
            if case .lastNight = prompt {
                HStack(spacing: 10) {
                    Button { store.markDry(night) } label: {
                        Text("No drinks").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .glassGlare(.regular.tint(Fit.action.opacity(0.55)).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    Button { sheet = NightRef(id: night) } label: {
                        Text("Log drinks").font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .glassGlare(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func wideButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .glassGlare(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Log sheet

/// Logging a round in one screen: which night, how many of each drink, what
/// time of day, then one big Log button. Below it, what's already logged for
/// that night, each with a delete.
struct AlcoholSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = AlcoholStore.shared
    @State private var night: String
    @State private var counts: [DrinkKind: Int]
    @State private var time: DrinkTime
    @State private var otherDay = false

    init(night: String, start: DrinkKind? = nil) {
        let tonight = AlcoholStore.night(of: .now)
        _night = State(initialValue: night)
        _counts = State(initialValue: start.map { [$0: 1] } ?? [:])
        _time = State(initialValue: night == tonight ? .of(.now) : .evening)
        _otherDay = State(initialValue: night != tonight && night != addDays(tonight, -1))
    }

    private var tonight: String { store.tonight }
    private var total: Int { counts.values.reduce(0, +) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section("Night") { nightPicker }
                    section("Drinks") {
                        VStack(spacing: 10) {
                            ForEach(DrinkKind.allCases) { counter($0) }
                        }
                    }
                    section("Time of day") { timePicker }
                    Button {
                        store.log(counts, night: night, time: time)
                        dismiss()
                    } label: {
                        Text(total == 0 ? "Add a drink above" : "Log \(total) \(total == 1 ? "drink" : "drinks")")
                            .font(.title3.weight(.semibold)).foregroundStyle(total == 0 ? BrickLook.soft : .white)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .glassGlare(total == 0 ? .regular : .regular.tint(Fit.action.opacity(0.7)).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(total == 0)
                    logged
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.top, 8).padding(.bottom, HubLayout.bottomInset)
            }
            .navigationTitle("Log drinks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large])
        .sensoryFeedback(.selection, trigger: counts)
        .sensoryFeedback(.selection, trigger: time)
    }

    // MARK: Parts

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(BrickLook.soft).textCase(.uppercase)
            content()
        }
    }

    private var nightPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                chip("Tonight", selected: !otherDay && night == tonight) { otherDay = false; night = tonight }
                chip("Last night", selected: !otherDay && night == addDays(tonight, -1)) { otherDay = false; night = addDays(tonight, -1) }
                chip("Earlier", selected: otherDay) { otherDay = true; if night == tonight { night = addDays(tonight, -2) } }
            }
            if otherDay {
                DatePicker("Night of", selection: nightDate, in: ...Date.now, displayedComponents: .date)
                    .font(.body).foregroundStyle(BrickLook.ink)
            }
        }
    }

    private var nightDate: Binding<Date> {
        Binding(get: { MorningCheckin.date(night) ?? .now }, set: { night = localDay($0) })
    }

    private func counter(_ kind: DrinkKind) -> some View {
        let n = counts[kind] ?? 0
        return HStack(spacing: 12) {
            Button { counts[kind] = min(n + 1, 20) } label: {
                HStack(spacing: 12) {
                    Text(kind.emoji).font(.system(size: 30))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.longTitle).font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink)
                        Text(kind.serving).font(.caption).foregroundStyle(BrickLook.soft)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a \(kind.longTitle)")
            stepper("minus", enabled: n > 0, label: "One less \(kind.title)") { counts[kind] = max(n - 1, 0) }
            Text("\(n)").font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(n > 0 ? BrickLook.ink : BrickLook.soft)
                .frame(minWidth: 28)
                .accessibilityLabel("\(n) \(kind.title)")
            stepper("plus", enabled: n < 20, label: "One more \(kind.title)") { counts[kind] = min(n + 1, 20) }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .glassGlare(n > 0 ? .regular.tint(Fit.action.opacity(0.15)) : .regular, in: .rect(cornerRadius: 20, style: .continuous))
    }

    private func stepper(_ symbol: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(BrickLook.ink)
                .frame(width: 48, height: 48)
                .glassGlare(.regular.interactive(enabled), in: .circle)
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var timePicker: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(DrinkTime.allCases) { slot in
                Button { time = slot } label: {
                    Label(slot.title, systemImage: slot.symbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(time == slot ? .white : BrickLook.ink)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .glassGlare(time == slot ? .regular.tint(Fit.action.opacity(0.7)).interactive() : .regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(time == slot ? .isSelected : [])
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.medium))
                .foregroundStyle(selected ? .white : BrickLook.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .glassGlare(selected ? .regular.tint(Fit.action.opacity(0.7)).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var logged: some View {
        let entries = store.entries(on: night)
        let dry = store.dryNights.contains(night)
        section("Logged for \(Self.title(night))") {
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text(dry ? "Marked as no drinks." : "Nothing yet.")
                        .font(.subheadline).foregroundStyle(BrickLook.soft)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    if !dry {
                        Button { store.markDry(night) } label: {
                            Label("No drinks this night", systemImage: "checkmark").font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .glassGlare(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        Text(entry.kind.emoji).font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.count) \(entry.kind.title)").font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                            Text(entry.slot.title).font(.caption).foregroundStyle(BrickLook.soft)
                        }
                        Spacer(minLength: 8)
                        Button(role: .destructive) { store.remove(entry.id) } label: {
                            Image(systemName: "trash").font(.body).foregroundStyle(HubDesign.danger)
                                .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(entry.count) \(entry.kind.title)")
                    }
                    .padding(.vertical, 6)
                    if entry.id != entries.last?.id { BrickDivider() }
                }
            }
        }
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
                timing(insights)
                FitSection(title: "Nights") {
                    VStack(spacing: 0) {
                        let nights = Array(alcohol.loggedNights.prefix(10))
                        ForEach(nights, id: \.self) { night in
                            Button { sheet = NightRef(id: night) } label: {
                                DetailRow(label: AlcoholSheet.title(night), value: alcohol.detail(night) ?? "No drinks", last: night == nights.last)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task { alcohol.recordBattery(store.series(.bodyBattery)) }
        .sheet(item: $sheet) { AlcoholSheet(night: $0.id) }
    }

    private var recent: [DayValue] {
        (0..<14).reversed().compactMap { back in
            let night = addDays(alcohol.tonight, -back)
            return MorningCheckin.date(night).map { DayValue(date: $0, value: Double(alcohol.drinks(on: night))) }
        }
    }

    /// Sleep by when the drinking ran latest: the same drinks late at night usually cost more sleep than at lunch.
    private func timing(_ insights: AlcoholInsights) -> some View {
        let buckets = insights.timing(.sleep).filter { $0.label == AlcoholInsights.timingLabels[0] || $0.nights > 0 }
        return FitSection(title: "When you drank", trailing: "Sleep score") {
            if buckets.count > 1 {
                AlcoholBucketChart(metric: .sleep, buckets: buckets)
            }
            Takeaway(text: buckets.count > 1 ? "Next-morning sleep score by when the drinking ran latest. All day counts on its own."
                                             : "Needs a few nights logged with a time of day.").font(.caption)
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
