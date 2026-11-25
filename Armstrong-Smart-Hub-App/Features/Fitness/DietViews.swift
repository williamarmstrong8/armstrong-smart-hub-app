import Charts
import SwiftUI

// MARK: Fitness card

/// Diet on the Fitness page: the plan and phase, then either "How do you feel
/// after lunch?" for a meal waiting on an answer, or today's meals. Log a meal and
/// How I feel are always one tap away; the header opens the Diet page.
struct DietCard: View {
    @State private var store = DietStore.shared
    @State private var sheet: DietSheet?

    var body: some View {
        BrickCard {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink(value: FitnessPage.diet) { header }
                    .buttonStyle(.plain)
                // Re-asks as meals age into (and out of) the window, and moves the ideas on to the next meal.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 16) {
                        if let meal = store.awaitingCheck(now: context.date) { prompt(meal) } else { today }
                        ideas(now: context.date)
                    }
                }
                HStack(spacing: 10) {
                    DietCardButton(title: "Log a meal", symbol: "fork.knife", primary: true) { sheet = .meal(nil) }
                    DietCardButton(title: "How I feel", symbol: "heart.text.square", primary: false) {
                        sheet = .feeling(mealID: nil, check: nil)
                    }
                }
            }
        }
        .sheet(item: $sheet) { $0.view }
        // A notification's "Something else…": open the answer for its meal.
        .onChange(of: store.askAbout, initial: true) { _, id in
            guard let id else { return }
            sheet = .feeling(mealID: id, check: nil)
            store.askAbout = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("🥗").font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text("Diet").font(.system(size: 22, weight: .regular)).foregroundStyle(BrickLook.ink)
                Text(DietPage.planLine(store)).font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).foregroundStyle(BrickLook.soft)
        }
        .contentShape(.rect)
        .accessibilityHint("Opens the diet log")
    }

    /// "How do you feel after lunch?", answered in a tap.
    private func prompt(_ meal: Meal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How do you feel after \(meal.slot.title.lowercased())?")
                    .font(.title3.weight(.semibold)).foregroundStyle(BrickLook.ink)
                Text("\(meal.summary) · \(meal.at.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).foregroundStyle(BrickLook.soft).lineLimit(2)
            }
            HStack(spacing: 10) {
                DietCardButton(title: "Feeling fine", symbol: "face.smiling", primary: true, tint: Fit.positive) {
                    withAnimation(HubMotion.standard) { store.markFine(meal) }
                }
                DietCardButton(title: "Not great", symbol: "exclamationmark.bubble", primary: false) {
                    sheet = .feeling(mealID: meal.id, check: nil)
                }
            }
            Button("Don't ask about this meal") { withAnimation(HubMotion.standard) { store.skip(meal) } }
                .font(.footnote).foregroundStyle(BrickLook.soft)
                .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
        }
        .padding(.top, 2)
        .transition(.opacity)
        .sensoryFeedback(.success, trigger: store.check(for: meal.id) != nil)
    }

    /// The top two low-FODMAP ideas for the next meal, from what's in the kitchen.
    private func ideas(now: Date) -> some View {
        let slot = DietIdeas.upcoming(store, now: now)
        let picks = DietIdeas.suggest(store, slot: slot, now: now, limit: 2)
        let late = slot == .snack && DietIdeas.isLate(now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                BrickCaps(text: late ? "Ideas for a late snack" : "Ideas for \(slot.title.lowercased())").foregroundStyle(BrickLook.soft)
                Spacer(minLength: 8)
                NavigationLink(value: FitnessPage.diet) {
                    Text("More").font(.footnote.weight(.semibold)).foregroundStyle(Fit.action)
                        .frame(minHeight: HubLayout.minHitTarget)
                }
                .buttonStyle(.plain)
            }
            ForEach(picks) { pick in
                Button { sheet = .draft(DietIdeas.draft(pick, slot: slot, at: now)) } label: {
                    IdeaLine(pick: pick, showsHave: !store.pantry.isEmpty)
                }
                .buttonStyle(.plain)
                if pick.id != picks.last?.id { BrickDivider() }
            }
        }
    }

    /// Today's meals, one line each, with how he felt after.
    @ViewBuilder private var today: some View {
        let day = localDay()
        let meals = store.meals(on: day)
        if meals.isEmpty {
            Text(store.meals.isEmpty ? "Log what you eat and how you feel after. The page lines up foods with symptoms over time."
                                     : "Nothing logged today.")
                .font(.subheadline).foregroundStyle(BrickLook.soft)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                ForEach(meals) { meal in
                    Button { sheet = .meal(meal) } label: { MealLine(meal: meal, check: store.check(for: meal.id)) }
                        .buttonStyle(.plain)
                    if meal.id != meals.last?.id { BrickDivider() }
                }
            }
        }
    }
}

/// A wide capsule button for the card.
struct DietCardButton: View {
    var title: String
    var symbol: String
    var primary: Bool
    var tint: Color = Fit.action
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(primary ? .white : BrickLook.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 52)
                .glassGlare(primary ? .regular.tint(tint.opacity(0.7)).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// A meal in a short list: when, what, its worst rating, and how he felt after.
struct MealLine: View {
    var meal: Meal
    var check: GutCheck?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: meal.slot.symbol).font(.body).foregroundStyle(BrickLook.soft).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(meal.slot.title).font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink)
                    Text(meal.at.formatted(date: .omitted, time: .shortened)).font(.subheadline).foregroundStyle(BrickLook.soft)
                    Spacer(minLength: 4)
                    if meal.level != .low {
                        Text(meal.level.short).font(.caption.weight(.semibold)).foregroundStyle(meal.level.color)
                    }
                }
                Text(meal.summary).font(.subheadline).foregroundStyle(BrickLook.ink.opacity(0.85)).lineLimit(2)
                if let check {
                    Label(check.summary, systemImage: check.isFine ? "face.smiling" : "exclamationmark.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(check.worst?.color ?? Fit.positive)
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Diet page

/// The diet log: the plan and its phase, today, how he's felt lately, the
/// foods that tend to come before symptoms, earlier days, and the food guide.
struct DietPage: View {
    @State private var store = DietStore.shared
    @State private var sheet: DietSheet?
    @State private var changingStart = false
    @State private var importing = false

    var body: some View {
        let insights = DietInsights(store: store)
        FitPage(title: "Diet") {
            plan
            IdeasSection(store: store, sheet: $sheet)
            FitSection(title: "Today", trailing: Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                DietDayLog(store: store, day: localDay(), sheet: $sheet)
            }
            kitchen
            if !store.checks.isEmpty { felt }
            foodsToWatch(insights)
            if !insights.agreeable.isEmpty { agreeable(insights) }
            groups(insights)
            earlier
            FitSection(title: "Food guide") {
                NavigationLink { FoodGuidePage() } label: {
                    LinkRow(title: "Low-FODMAP foods", subtitle: "What's low, what to watch, and what to swap")
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $sheet) { $0.view }
        .sheet(isPresented: $changingStart) { PhaseStartSheet() }
        .sheet(isPresented: $importing) { ReceiptImportSheet() }
    }

    // MARK: Kitchen

    /// What he has: a few foods, the last receipt, and the way to import one.
    private var kitchen: some View {
        let fresh = store.freshPantry
        let low = fresh.filter { item in item.foodID.flatMap(store.food)?.level == .low }.count
        let trailing = store.receipts.first.map { "Last: \($0.title)" }
        return FitSection(title: "Your kitchen", trailing: trailing) {
            if fresh.isEmpty {
                Takeaway(text: "Import a grocery receipt (a scan, a screenshot of your Whole Foods order, a PDF or the email's text) and the meal ideas use what you have.")
            } else {
                Text("\(fresh.count) foods, \(low) of them low FODMAP").font(.subheadline).foregroundStyle(BrickLook.ink)
                FlowLayout(spacing: 6) {
                    ForEach(fresh.prefix(12)) { item in
                        HStack(spacing: 5) {
                            FodmapDot(level: item.foodID.flatMap(store.food)?.level ?? .unknown, size: 7)
                            Text(item.name).font(.caption.weight(.medium)).foregroundStyle(BrickLook.ink).lineLimit(1)
                        }
                        .padding(.horizontal, 10).frame(minHeight: 28)
                        .glassGlare(.regular, in: .capsule)
                    }
                }
            }
            HStack(spacing: 10) {
                DietCardButton(title: "Import receipt", symbol: "doc.text.viewfinder", primary: fresh.isEmpty) { importing = true }
                if !store.pantry.isEmpty {
                    NavigationLink { PantryPage() } label: {
                        Label("Kitchen", systemImage: "refrigerator")
                            .font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .glassGlare(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// "Low FODMAP · Elimination, day 3".
    static func planLine(_ store: DietStore) -> String {
        let day = store.phaseDay.map { ", day \($0)" } ?? ""
        return "\(store.plan.title) · \(store.phase.title)\(day)"
    }

    // MARK: Plan

    private var plan: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(store.plan.title).font(.title.weight(.regular)).foregroundStyle(BrickLook.ink)
                Menu {
                    ForEach(store.plan.phases) { phase in
                        Button {
                            store.setPhase(phase)
                        } label: {
                            if phase == store.phase {
                                Label("\(phase.step). \(phase.title)", systemImage: "checkmark")
                            } else {
                                Text("\(phase.step). \(phase.title)")
                            }
                        }
                    }
                    Divider()
                    Button("Change start date…", systemImage: "calendar") { changingStart = true }
                } label: {
                    HStack(spacing: 5) {
                        Text("Step \(store.phase.step) of 3 · \(store.phase.title)\(store.phaseDay.map { ", day \($0)" } ?? "")")
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium)).foregroundStyle(Fit.action)
                    .frame(minHeight: HubLayout.minHitTarget)
                }
                .accessibilityHint("Changes the diet phase")
            }
            Text(store.phase.guidance).font(.subheadline).foregroundStyle(BrickLook.soft)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                DietCardButton(title: "Log a meal", symbol: "fork.knife", primary: true) { sheet = .meal(nil) }
                DietCardButton(title: "How I feel", symbol: "heart.text.square", primary: false) { sheet = .feeling(mealID: nil, check: nil) }
            }
        }
        .padding(.top, 16).padding(.bottom, 28)
    }

    // MARK: How he's felt

    /// The worst symptom of each day, and which symptoms came up most.
    private var felt: some View {
        let days = (0..<14).map { addDays(localDay(), -$0) }
        let points = days.reversed().compactMap { day -> DayValue? in
            let checks = store.checks(on: day)
            guard !checks.isEmpty, let date = MorningCheckin.date(day) else { return nil }
            return DayValue(date: date, value: Double(checks.compactMap(\.worst).max()?.rawValue ?? 0))
        }
        let since = Date.now.addingTimeInterval(-30 * 86400)
        let recent = store.checks.filter { $0.at > since }
        let counts = Symptom.allCases.map { s in (s, recent.filter { $0.symptoms[s] != nil }.count) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let fine = recent.filter(\.isFine).count
        return FitSection(title: "How you've felt", trailing: "Last 14 days") {
            if points.contains(where: { $0.value > 0 }) {
                DailyBarChart(points: points, tint: Fit.attention, domain: 0...3, yTicks: [1, 2, 3], height: 130,
                              format: { Self.severityWord($0) }, colorFor: { Severity(rawValue: Int($0))?.color ?? Fit.positive },
                              period: 14)
            }
            if counts.isEmpty {
                Takeaway(text: fine > 0 ? "No symptoms logged in the last 30 days: \(fine) \(fine == 1 ? "time" : "times") you felt fine." : "Nothing logged in the last 30 days.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { index, entry in
                        DetailRow(label: "\(entry.0.emoji)  \(entry.0.title)", value: "\(entry.1)×", last: index == counts.count - 1 && fine == 0)
                    }
                    if fine > 0 { DetailRow(label: "😌  Felt fine", value: "\(fine)×", valueColor: Fit.positive, last: true) }
                }
                Takeaway(text: "Worst symptom each day above; how often each came up in the last 30 days below.").font(.caption)
            }
        }
    }

    static func severityWord(_ value: Double) -> String {
        Severity(rawValue: Int(value.rounded()))?.title ?? "Felt fine"
    }

    // MARK: Insights

    private func foodsToWatch(_ insights: DietInsights) -> some View {
        let suspects = Array(insights.suspects.prefix(8))
        let base = insights.baseline.map { Int(($0 * 100).rounded()) }
        return FitSection(title: "Foods to watch", trailing: base.map { "Symptoms after \($0)% of meals" }) {
            if suspects.isEmpty {
                Takeaway(text: insights.checked.count < 6
                         ? "After about a week of meals with how you felt after, foods that keep coming before symptoms show up here."
                         : "Nothing stands out yet: no food has come before symptoms more often than your meals overall.")
            } else {
                VStack(spacing: 0) {
                    ForEach(suspects) { stat in
                        DetailRow(label: stat.name, value: "\(stat.withSymptoms) of \(stat.meals) meals",
                                  valueColor: stat.rate >= 0.75 ? Fit.attention : Fit.fair, last: stat.id == suspects.last?.id)
                    }
                }
                Takeaway(text: "Meals with each food that were followed by symptoms. A pattern isn't proof: test a suspect on its own during reintroduction.")
                    .font(.caption)
            }
        }
    }

    private func agreeable(_ insights: DietInsights) -> some View {
        let foods = Array(insights.agreeable.prefix(8))
        return FitSection(title: "Sitting well", trailing: "No symptoms after") {
            VStack(spacing: 0) {
                ForEach(foods) { stat in
                    DetailRow(label: stat.name, value: "\(stat.meals) meals", valueColor: Fit.positive, last: stat.id == foods.last?.id)
                }
            }
        }
    }

    /// Meals with a FODMAP group against meals without it.
    @ViewBuilder private func groups(_ insights: DietInsights) -> some View {
        let groups = insights.groups.filter { $0.with.meals > 0 }
        if !groups.isEmpty {
            FitSection(title: "FODMAP groups", trailing: "Symptoms after") {
                VStack(spacing: 0) {
                    ForEach(groups) { g in
                        let with = g.rateWith.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
                        let without = g.rateWithout.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
                        DetailRow(label: g.group.title, value: "\(with) with (\(g.with.meals)) · \(without) without",
                                  valueColor: (g.rateWith ?? 0) > (g.rateWithout ?? 0) + 0.2 && g.with.meals >= 3 ? Fit.attention : nil,
                                  last: g.id == groups.last?.id)
                    }
                }
                Takeaway(text: "From the foods rated high or watch in each meal, against meals without that group. Helps pick what to test first in reintroduction.")
                    .font(.caption)
            }
        }
    }

    // MARK: Earlier days

    @ViewBuilder private var earlier: some View {
        let today = localDay()
        let days = Array(store.loggedDays.filter { $0 != today }.prefix(10))
        if !days.isEmpty {
            FitSection(title: "Earlier") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 2) {
                            BrickCaps(text: AlcoholSheet.title(day)).foregroundStyle(BrickLook.soft)
                            DietDayLog(store: store, day: day, sheet: $sheet)
                        }
                    }
                }
            }
        }
    }
}

/// A day's meals and check-ins in time order. Tap a meal to edit it; a meal with no
/// answer yet offers one.
struct DietDayLog: View {
    var store: DietStore
    var day: String
    @Binding var sheet: DietSheet?

    private enum Item: Identifiable {
        case meal(Meal)
        case check(GutCheck)
        var id: String {
            switch self {
            case let .meal(m): "m.\(m.id)"
            case let .check(c): "c.\(c.id)"
            }
        }
        var at: Date {
            switch self {
            case let .meal(m): m.at
            case let .check(c): c.at
            }
        }
    }

    var body: some View {
        let items = (store.meals(on: day).map(Item.meal) + store.checks(on: day).filter { $0.mealID == nil || store.meal($0.mealID) == nil }.map(Item.check))
            .sorted { $0.at < $1.at }
        if items.isEmpty {
            Takeaway(text: "Nothing logged yet.")
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    switch item {
                    case let .meal(meal): mealRow(meal)
                    case let .check(check): checkRow(check)
                    }
                    if item.id != items.last?.id { BrickDivider() }
                }
            }
        }
    }

    private func mealRow(_ meal: Meal) -> some View {
        let check = store.check(for: meal.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { sheet = .meal(meal) } label: { MealLine(meal: meal, check: check) }
                .buttonStyle(.plain)
            if let check {
                Button("Edit how you felt") { sheet = .feeling(mealID: meal.id, check: check) }
                    .font(.footnote).foregroundStyle(Fit.action)
                    .padding(.leading, 36).padding(.bottom, 10)
            } else if meal.at < .now {
                Button { sheet = .feeling(mealID: meal.id, check: nil) } label: {
                    Label("How did you feel after?", systemImage: "plus.circle").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Fit.action)
                .padding(.leading, 36).padding(.bottom, 10)
            }
        }
    }

    private func checkRow(_ check: GutCheck) -> some View {
        Button { sheet = .feeling(mealID: nil, check: check) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: check.isFine ? "face.smiling" : "exclamationmark.circle")
                    .font(.body).foregroundStyle(check.worst?.color ?? Fit.positive).frame(width: 24).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(check.isFine ? "Felt fine" : "Symptoms").font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink)
                        Text(check.at.formatted(date: .omitted, time: .shortened)).font(.subheadline).foregroundStyle(BrickLook.soft)
                    }
                    if !check.isFine { Text(check.summary).font(.subheadline).foregroundStyle(check.worst?.color ?? BrickLook.ink) }
                    if let note = check.note { Text(note).font(.caption).foregroundStyle(BrickLook.soft).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Picks the day the current phase started.
private struct PhaseStartSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DietStore.shared
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                DatePicker("\(store.phase.title) started", selection: $date, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HubLayout.gutter)
            .hubPageStyle(backdrop: true)
            .navigationTitle("\(store.phase.title) start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setPhase(store.phase, since: localDay(date))
                        dismiss()
                    }
                }
            }
            .onAppear { date = store.phaseSince.flatMap(MorningCheckin.date) ?? .now }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground { AmbientBackdrop() }
    }
}

// MARK: Food guide

/// The low-FODMAP food list: search it, filter by rating, and rate foods of his own.
struct FoodGuidePage: View {
    @State private var store = DietStore.shared
    @State private var query = ""
    @State private var level: FodmapLevel?

    var body: some View {
        FitPage(title: "Food guide") {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(BrickLook.soft)
                    TextField("Search foods", text: $query).autocorrectionDisabled()
                }
                .padding(.horizontal, 16).frame(minHeight: 50)
                .glassGlare(.regular, in: .capsule)
                HStack(spacing: 8) {
                    filter(nil, "All")
                    ForEach([FodmapLevel.low, .moderate, .high]) { filter($0, $0.short) }
                }
            }
            .padding(.top, 12).padding(.bottom, 24)

            ForEach(FoodCategory.allCases) { category in
                let foods = filtered(store.plan.foods.filter { $0.category == category })
                if !foods.isEmpty {
                    FitSection(title: category.title, trailing: "\(foods.count)") { list(foods) }
                }
            }
            let mine = filtered(store.customFoods)
            if !mine.isEmpty {
                FitSection(title: "Your foods", trailing: "Hold to rate") {
                    VStack(spacing: 0) {
                        ForEach(mine) { food in
                            FoodRow(food: food)
                                .contextMenu {
                                    ForEach(FodmapLevel.allCases) { l in
                                        Button(l.title) { store.rate(food, l) }
                                    }
                                    Divider()
                                    Button("Remove", role: .destructive) { store.removeCustomFood(food) }
                                }
                            if food.id != mine.last?.id { BrickDivider() }
                        }
                    }
                }
            }
            FitSection(title: "The FODMAP groups") {
                VStack(spacing: 0) {
                    ForEach(FodmapGroup.allCases) { g in
                        DetailRow(label: g.title, value: g.examples, last: g == FodmapGroup.allCases.last)
                    }
                }
                Takeaway(text: "Ratings are for an everyday serving, following Monash University's published low-FODMAP guidance; many \"watch\" foods are low in the serving given. The Monash FODMAP app has exact servings, and a dietitian can tailor the diet to you.")
                    .font(.caption)
            }
        }
    }

    private func filtered(_ foods: [DietFood]) -> [DietFood] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return foods.filter { (level == nil || $0.level == level) && (q.isEmpty || $0.matches(q)) }
    }

    private func list(_ foods: [DietFood]) -> some View {
        VStack(spacing: 0) {
            ForEach(foods) { food in
                FoodRow(food: food)
                if food.id != foods.last?.id { BrickDivider() }
            }
        }
    }

    private func filter(_ value: FodmapLevel?, _ title: String) -> some View {
        let selected = level == value
        return Button { withAnimation(HubMotion.standard) { level = value } } label: {
            HStack(spacing: 6) {
                if let value { FodmapDot(level: value, size: 8) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? .white : BrickLook.ink)
            .frame(maxWidth: .infinity, minHeight: 40)
            .glassGlare(selected ? .regular.tint(Fit.action.opacity(0.7)).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
