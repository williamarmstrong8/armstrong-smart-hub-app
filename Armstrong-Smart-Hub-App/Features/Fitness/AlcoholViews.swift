import Charts
import SwiftUI

/// A night to open in the log sheet, and the drink to start it with.
struct NightRef: Identifiable {
    var id: String
    var kind: DrinkKind?
}

// MARK: Weekend card

/// On Friday, Saturday and Sunday mornings: did you drink last night? Three
/// big answers, and once one is given the card goes away for the day.
struct AlcoholCard: View {
    var fitness: FitnessStore
    @State private var store = AlcoholStore.shared
    @State private var sheet: NightRef?

    var body: some View {
        if let night = store.promptNight() {
            let weekday = MorningCheckin.date(night)?.formatted(.dateTime.weekday(.wide)) ?? "Last"
            BrickCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Text("🍻").font(.system(size: 26))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Drinks last night?").font(.system(size: 22, weight: .regular)).foregroundStyle(BrickLook.ink)
                            Text("\(weekday) night").font(.subheadline).foregroundStyle(BrickLook.soft)
                        }
                    }
                    HStack(spacing: 10) {
                        answer("No drinks", primary: true) { store.markDry(night) }
                        answer("Log drinks", primary: false) { sheet = NightRef(id: night) }
                    }
                    answer("Drank, not sure how much", primary: false) { store.markDrank(night) }
                }
            }
            .sensoryFeedback(.success, trigger: store.isAnswered(night))
            .sheet(item: $sheet) { AlcoholSheet(night: $0.id, start: $0.kind) }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private func answer(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(HubMotion.standard) { action() } } label: {
            Text(title).font(.body.weight(.semibold))
                .foregroundStyle(primary ? .white : BrickLook.ink)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 54)
                .glassGlare(primary ? .regular.tint(Fit.action.opacity(0.7)).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Drinks among the Fitness stats: this week's count, how many nights, and two weeks of bars. Opens the drinks page.
struct DrinksOverviewRow: View {
    var fitness: FitnessStore
    @State private var store = AlcoholStore.shared

    var body: some View {
        let nights = (0..<7).map { addDays(store.tonight, -$0) }
        let week = nights.reduce(0) { $0 + store.drinks(on: $1) }
        let drinking = nights.filter { store.drinks(on: $0) > 0 || store.amountUnknown($0) }.count
        let caption = store.loggedNights.isEmpty ? "Not tracked yet"
                    : drinking == 0 ? "No drinking nights" : "\(drinking) \(drinking == 1 ? "night" : "nights") this week"
        OverviewRow(title: "Drinks", value: "\(week)", unit: "this week", caption: caption,
                    tint: drinking == 0 ? Fit.positive : Fit.health) {
            MiniTrend(values: (0..<14).reversed().map { Double(store.drinks(on: addDays(store.tonight, -$0))) }, tint: Fit.health, bars: true)
        }
        .task(id: fitness.updatedAt) { store.recordBattery(fitness.series(.bodyBattery)) }
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

    /// Opens on the night most likely meant: last night in the morning and afternoon, tonight from 5 pm.
    static var likelyNight: String {
        let tonight = AlcoholStore.night(of: .now)
        let hour = Calendar.current.component(.hour, from: .now)
        return hour >= 5 && hour < 17 ? addDays(tonight, -1) : tonight
    }

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
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .hubPageStyle(backdrop: true)
            .navigationTitle("Log drinks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground { AmbientBackdrop() }
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
        let unknown = store.amountUnknown(night)
        section("Logged for \(Self.title(night))") {
            VStack(spacing: 10) {
                if entries.isEmpty {
                    Text(dry ? "Marked as no drinks." : unknown ? "Marked as drank, amount unknown. Log drinks above if you remember." : "Nothing yet.")
                        .font(.subheadline).foregroundStyle(BrickLook.soft)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    HStack(spacing: 10) {
                        if dry {
                            plainButton("Undo no drinks", symbol: "arrow.uturn.backward") { store.clearDry(night) }
                        } else if unknown {
                            plainButton("Undo", symbol: "arrow.uturn.backward") { store.clearDrank(night) }
                        } else {
                            plainButton("No drinks", symbol: "checkmark") { store.markDry(night); dismiss() }
                            plainButton("Drank, unsure", symbol: "questionmark") { store.markDrank(night); dismiss() }
                        }
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
                    if entry.id != entries.last?.id { BrickDivider() }
                }
            }
        }
    }

    private func plainButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 50)
                .glassGlare(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    static func title(_ night: String) -> String {
        MorningCheckin.date(night)?.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) ?? night
    }

    /// "Sat", or "Sat, Nov 7" past the last week.
    static func short(_ night: String) -> String {
        guard let date = MorningCheckin.date(night) else { return night }
        return night >= addDays(localDay(), -6) ? date.formatted(.dateTime.weekday(.abbreviated)) + " night"
                                               : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
            Button { sheet = NightRef(id: AlcoholSheet.likelyNight) } label: {
                Label("Log or backfill a night", systemImage: "plus").blueButton()
            }
            .buttonStyle(.plain)
            .padding(.top, 12).padding(.bottom, 24)
            if alcohol.loggedNights.isEmpty {
                Takeaway(text: "Log a night above, or answer the weekend-morning card on Fitness. After a few nights this page shows how sleep, HRV, resting heart rate, Body Battery and readiness changed the morning after one, two or more drinks.")
                    .padding(.bottom, 24)
            } else {
                FitSection(title: "Last 30 nights") { totals }
                FitSection(title: "Calendar", trailing: "Last 12 weeks") {
                    DrinkCalendar(store: alcohol) { sheet = NightRef(id: $0) }
                }
                FitSection(title: "Drinks per night", trailing: "Last 14 days") {
                    DailyBarChart(points: recent, tint: Fit.health, height: 140, period: 14)
                }
                ForEach(AlcoholMetric.allCases) { metric in
                    comparison(metric, insights)
                }
                timing(insights)
                FitSection(title: "Nights") {
                    VStack(spacing: 0) {
                        let nights = Array(alcohol.loggedNights.prefix(30))
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

    /// Totals over the last 30 nights. Amount-unknown nights count as drinking nights, not as drinks.
    private var totals: some View {
        let nights = (0..<30).map { addDays(alcohol.tonight, -$0) }
        let drinks = nights.reduce(0) { $0 + alcohol.drinks(on: $1) }
        let counted = nights.filter { alcohol.drinks(on: $0) > 0 }
        let drinking = nights.filter { alcohol.drinks(on: $0) > 0 || alcohol.amountUnknown($0) }.count
        let heavy = counted.filter { alcohol.drinks(on: $0) >= 5 }.count
        let perNight = counted.isEmpty ? nil : Double(drinks) / Double(counted.count)
        return HStack(spacing: 0) {
            stat("\(drinks)", "drinks")
            stat("\(drinking)", drinking == 1 ? "drinking night" : "drinking nights")
            stat(perNight.map { String(format: "%.1f", $0) } ?? "–", "per drinking night")
            stat("\(heavy)", "nights of 5+")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(.primary)
            Text(label).font(.caption).foregroundStyle(Fit.muted).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity)
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

/// Nights as a habit grid: a column per week, Monday at the top. Darker is more
/// drinks; a ring is "drank, amount unknown"; dry nights are a pale fill. Tap a night to edit it.
private struct DrinkCalendar: View {
    var store: AlcoholStore
    var open: (String) -> Void
    private let weeks = 12

    var body: some View {
        let start = Self.monday(weeksBack: weeks - 1, from: store.tonight)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { day in
                            let night = addDays(start, week * 7 + day)
                            cell(night)
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                legend(Fit.health.opacity(0.18), "Dry")
                legend(Fit.health.opacity(0.55), "1–2")
                legend(Fit.health, "3+")
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Fit.health, lineWidth: 1.5).frame(width: 11, height: 11)
                    Text("Unsure").font(.caption2).foregroundStyle(Fit.muted)
                }
            }
        }
    }

    @ViewBuilder private func cell(_ night: String) -> some View {
        let future = night > store.tonight
        let n = store.drinks(on: night)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Button { open(night) } label: {
            shape
                .fill(fill(night, n))
                .overlay { if store.amountUnknown(night) { shape.strokeBorder(Fit.health, lineWidth: 1.5) } }
                .aspectRatio(1, contentMode: .fit)
                .opacity(future ? 0 : 1)
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel("\(AlcoholSheet.title(night)): \(store.detail(night) ?? (store.dryNights.contains(night) ? "no drinks" : "not logged"))")
    }

    private func fill(_ night: String, _ n: Int) -> Color {
        if n >= 3 { return Fit.health }
        if n > 0 { return Fit.health.opacity(0.55) }
        if store.dryNights.contains(night) { return Fit.health.opacity(0.18) }
        return Fit.muted.opacity(0.1)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11)
            Text(label).font(.caption2).foregroundStyle(Fit.muted)
        }
    }

    /// The Monday that starts the week some weeks before the one holding `day`.
    static func monday(weeksBack: Int, from day: String) -> String {
        guard let date = DayFormat.parse(day) else { return day }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let weekday = calendar.component(.weekday, from: date)
        let sinceMonday = (weekday + 5) % 7
        return addDays(day, -sinceMonday - weeksBack * 7)
    }
}
