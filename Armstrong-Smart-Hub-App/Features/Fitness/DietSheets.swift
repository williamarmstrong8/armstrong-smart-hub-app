import SwiftUI

/// The sheets the Diet card and page open.
enum DietSheet: Identifiable {
    /// A new meal (nil) or one to edit.
    case meal(Meal?)
    /// A new meal filled in from an idea.
    case draft(Meal)
    /// How he feels: about a meal or not, new or one to edit.
    case feeling(mealID: String?, check: GutCheck?)

    var id: String {
        switch self {
        case let .meal(meal): "meal.\(meal?.id ?? "new")"
        case let .draft(meal): "draft.\(meal.id)"
        case let .feeling(mealID, check): "feeling.\(check?.id ?? mealID ?? "new")"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case let .meal(meal): MealSheet(meal: meal)
        case let .draft(meal): MealSheet(meal: nil, draft: meal)
        case let .feeling(mealID, check): FeelingSheet(mealID: mealID, check: check)
        }
    }
}

// MARK: Shared parts

/// A titled block in a sheet, like the drinks sheet's.
struct DietSheetSection<Content: View>: View {
    var title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(BrickLook.soft).textCase(.uppercase)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.footnote).foregroundStyle(BrickLook.soft) }
            }
            content
        }
    }
}

/// A capsule choice that fills in when picked.
struct DietChip: View {
    var title: String
    var symbol: String?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.body.weight(.medium))
            .foregroundStyle(selected ? .white : BrickLook.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .glassGlare(selected ? .regular.tint(Fit.action.opacity(0.7)).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The big button pinned to the bottom of a sheet.
struct DietSaveButton: View {
    var title: String
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold)).foregroundStyle(enabled ? .white : BrickLook.soft)
                .frame(maxWidth: .infinity, minHeight: 58)
                .glassGlare(enabled ? .regular.tint(Fit.action.opacity(0.7)).interactive() : .regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, HubLayout.gutter)
        .padding(.top, 8).padding(.bottom, 8)
    }
}

/// A small colored dot for a FODMAP rating.
struct FodmapDot: View {
    var level: FodmapLevel
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(level.color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: Meal sheet

/// Logging a meal in one screen: which meal and when, the foods (searched in
/// the low-FODMAP guide, or typed in and rated), and how he feels if he already
/// knows, then Log. Each food shows its rating as it's added, so a high one is
/// caught before eating it next time.
struct MealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DietStore.shared
    private let editing: Meal?
    @State private var at: Date
    @State private var slot: MealSlot
    @State private var foods: [MealFood]
    @State private var query = ""
    /// How he feels with the meal: symptoms, or "Feeling fine". Neither means not answered yet.
    @State private var feeling: [Symptom: Severity]
    @State private var fine: Bool
    private let existingCheck: GutCheck?
    /// Once he picks the meal himself, changing the time doesn't change it.
    @State private var slotPicked: Bool
    @State private var confirmDelete = false
    @FocusState private var searching: Bool

    /// Edits `meal`, or starts a new one, filled in from `draft` when there is one.
    init(meal: Meal?, draft: Meal? = nil) {
        editing = meal
        let start = meal ?? draft
        let now = Date.now
        _at = State(initialValue: start?.at ?? now)
        _slot = State(initialValue: start?.slot ?? .of(now))
        _foods = State(initialValue: start?.foods ?? [])
        _slotPicked = State(initialValue: start != nil)
        let check = meal.flatMap { DietStore.shared.check(for: $0.id) }
        existingCheck = check
        _feeling = State(initialValue: check?.symptoms ?? [:])
        _fine = State(initialValue: check?.isFine ?? false)
    }

    private var canSave: Bool { !foods.isEmpty }

    /// The foods with any rating that came in since they were added (the phone's model can take a moment).
    private var rated: [MealFood] {
        foods.map { f in
            guard f.level == .unknown, let id = f.foodID, let now = store.food(id), now.level != .unknown else { return f }
            return MealFood(now)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    DietSheetSection(title: "Meal") { slotPicker }
                    DietSheetSection(title: "When") {
                        DatePicker("Eaten at", selection: $at, in: ...Date.now.addingTimeInterval(3600), displayedComponents: [.date, .hourAndMinute])
                            .font(.body).foregroundStyle(BrickLook.ink)
                    }
                    DietSheetSection(title: "What you ate", trailing: foods.isEmpty ? nil : "\(foods.count)") {
                        VStack(alignment: .leading, spacing: 14) {
                            if !foods.isEmpty { chosen }
                            warning
                            searchField
                            if query.trimmingCharacters(in: .whitespaces).isEmpty { suggestions } else { results }
                        }
                    }
                    DietSheetSection(title: "How you feel", trailing: "Optional") { feelingPicker }
                    if editing != nil { deleteButton }
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.top, 8).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .safeAreaInset(edge: .bottom) {
                DietSaveButton(title: saveTitle, enabled: canSave) { save() }
            }
            .hubPageStyle(backdrop: true)
            .navigationTitle(editing == nil ? "Log a meal" : "Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: at) { _, date in if !slotPicked { slot = .of(date) } }
            .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete meal", role: .destructive) {
                    if let editing { store.delete(editing) }
                    dismiss()
                }
            } message: {
                Text("How you felt after it stays in the log.")
            }
        }
        .presentationDetents([.large])
        .presentationBackground { AmbientBackdrop() }
        .sensoryFeedback(.selection, trigger: foods.count)
        .sensoryFeedback(.selection, trigger: slot)
        .sensoryFeedback(.selection, trigger: feeling)
    }

    private var saveTitle: String {
        if editing != nil { return "Save changes" }
        return canSave ? "Log \(slot.title.lowercased())" : "Add a food above"
    }

    private func save() {
        let meal = Meal(id: editing?.id ?? LocalDB.uuid(), at: at, slot: slot, foods: rated, note: editing?.note)
        store.save(meal)
        if fine || !feeling.isEmpty {
            // Felt at the meal, or soon after one logged later.
            let when = existingCheck?.at ?? max(at, min(.now, at.addingTimeInterval(2 * 3600)))
            store.save(GutCheck(id: existingCheck?.id ?? LocalDB.uuid(), at: when, mealID: meal.id,
                                symptoms: fine ? [:] : feeling, note: existingCheck?.note))
        } else if let existingCheck {
            store.deleteCheck(existingCheck)
        }
        dismiss()
    }

    /// "Feeling fine", or the symptoms (tap again for worse). Left alone, he's asked later.
    private var feelingPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            DietChip(title: "Feeling fine", symbol: "face.smiling", selected: fine && feeling.isEmpty) {
                withAnimation(HubMotion.standard) {
                    fine.toggle()
                    if fine { feeling = [:] }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Symptom.allCases) { symptom in
                    SymptomTile(symptom: symptom, severity: feeling[symptom]) {
                        withAnimation(HubMotion.standard) {
                            feeling[symptom] = feeling[symptom].map { $0.next } ?? .mild
                            fine = false
                        }
                    }
                }
            }
            Text(fine || !feeling.isEmpty ? "Tap a symptom again for worse." : "Skip it and you'll be asked about two hours after.")
                .font(.caption).foregroundStyle(BrickLook.soft)
        }
    }

    // MARK: Parts

    private var slotPicker: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(MealSlot.allCases) { s in
                DietChip(title: s.title, symbol: s.symbol, selected: slot == s) {
                    slot = s
                    slotPicked = true
                }
            }
        }
    }

    /// The foods picked so far, each with its rating and an ×.
    private var chosen: some View {
        FlowLayout(spacing: 8) {
            ForEach(rated) { food in
                Button {
                    withAnimation(HubMotion.standard) { foods.removeAll { $0.id == food.id } }
                } label: {
                    HStack(spacing: 7) {
                        if food.foodID.map(store.rating.contains) == true {
                            ProgressView().controlSize(.mini)
                        } else {
                            FodmapDot(level: food.level)
                        }
                        Text(food.name).font(.subheadline.weight(.medium)).foregroundStyle(BrickLook.ink).lineLimit(1)
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(BrickLook.soft)
                    }
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .glassGlare(.regular.tint(food.level.color.opacity(0.12)).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(food.name), \(food.level.title). Remove")
            }
        }
    }

    /// What in the meal isn't low FODMAP, and the tip for it.
    @ViewBuilder private var warning: some View {
        let high = rated.filter { $0.level == .high }
        let watch = rated.filter { $0.level == .moderate }
        if !high.isEmpty || !watch.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !high.isEmpty {
                    hint(color: FodmapLevel.high.color, text: "\(Self.list(high.map(\.name))) \(high.count == 1 ? "is" : "are") high FODMAP.")
                }
                ForEach(watch) { food in
                    hint(color: FodmapLevel.moderate.color,
                         text: "\(food.name): \(food.foodID.flatMap { store.food($0)?.tip } ?? "low only in a small serving.")")
                }
            }
        }
    }

    private func hint(color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text).font(.subheadline).foregroundStyle(BrickLook.soft).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(BrickLook.soft)
            TextField("Search foods or type your own", text: $query)
                .focused($searching)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .onSubmit { addTyped() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BrickLook.soft)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.body)
        .padding(.horizontal, 16).frame(minHeight: 50)
        .glassGlare(.regular, in: .capsule)
    }

    /// With nothing typed: what he usually eats, filled out with common low-FODMAP picks.
    private var suggestions: some View {
        let picked = Set(foods.map(\.id))
        let usual = store.usualFoods()
        let common = Self.common.compactMap { LowFodmap.byID[$0] }.filter { food in !usual.contains { $0.id == food.id } }
        let list = (usual + common).filter { !picked.contains($0.id) }.prefix(16)
        return VStack(alignment: .leading, spacing: 8) {
            Text(usual.isEmpty ? "Common picks" : "Your usual").font(.caption).foregroundStyle(BrickLook.soft)
            FlowLayout(spacing: 8) {
                ForEach(Array(list)) { food in
                    Button { add(food) } label: {
                        HStack(spacing: 7) {
                            FodmapDot(level: food.level)
                            Text(food.name).font(.subheadline.weight(.medium)).foregroundStyle(BrickLook.ink).lineLimit(1)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 36)
                        .glassGlare(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(food.name), \(food.level.title)")
                }
            }
        }
    }

    private static let common = ["eggs", "rice", "chicken", "potato", "carrot", "oats", "banana-firm", "sourdough",
                                 "lf-milk", "coffee", "hard-cheese", "spinach", "tomato", "fish", "beef", "peanuts"]

    /// Matches for what he typed, and a way to add it as his own.
    private var results: some View {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = Array(store.search(typed).prefix(25))
        let exact = matches.contains { $0.name.caseInsensitiveCompare(typed) == .orderedSame || $0.isNamed(typed) }
        return VStack(spacing: 0) {
            ForEach(matches) { food in
                Button { add(food) } label: { FoodRow(food: food, added: foods.contains { $0.id == food.id }) }
                    .buttonStyle(.plain)
                BrickDivider()
            }
            if !exact {
                let preview = store.preview(typed)
                Button { addTyped() } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "plus.circle").font(.title3).foregroundStyle(Fit.action)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Add “\(typed)”").font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                                Spacer(minLength: 4)
                                if let preview {
                                    Text(preview.level.short).font(.caption.weight(.semibold)).foregroundStyle(preview.level.color)
                                }
                            }
                            Text(preview?.tip ?? (DietFoodRater.isAvailable ? "Your phone will rate it from what it's usually made with."
                                                                             : "As your own food. Rate it in the food guide."))
                                .font(.caption).foregroundStyle(BrickLook.soft).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func add(_ food: DietFood) {
        withAnimation(HubMotion.standard) {
            if !foods.contains(where: { $0.id == food.id }) { foods.append(MealFood(food)) }
            query = ""
        }
    }

    /// Adds what's typed: the guide's food when it's an exact match, else a food of his own.
    private func addTyped() {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let match = store.allFoods.first { $0.name.caseInsensitiveCompare(typed) == .orderedSame }
        add(match ?? store.addCustomFood(typed))
    }

    private var deleteButton: some View {
        Button(role: .destructive) { confirmDelete = true } label: {
            Label("Delete meal", systemImage: "trash").font(.body.weight(.medium)).foregroundStyle(HubDesign.danger)
                .frame(maxWidth: .infinity, minHeight: 50)
                .glassGlare(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    /// "Garlic and onion", "Garlic, onion and wheat bread".
    static func list(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        let rest = names.dropFirst().map { $0.lowercased() }
        guard let last = rest.last else { return first }
        return ([first] + rest.dropLast()).joined(separator: ", ") + " and " + last
    }
}

/// A food in a list: its rating, name, and the tip for its serving.
struct FoodRow: View {
    var food: DietFood
    var added = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FodmapDot(level: food.level, size: 10).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(food.name).font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                    Spacer(minLength: 4)
                    Text(food.level.short).font(.caption.weight(.semibold)).foregroundStyle(food.level.color)
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(BrickLook.soft).fixedSize(horizontal: false, vertical: true) }
            }
            if added {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Fit.action).padding(.top, 2)
            }
        }
        .padding(.vertical, 11)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        let groups = food.groups.isEmpty || food.level == .low ? nil : food.groups.map(\.title).joined(separator: ", ")
        let parts = [groups, food.tip].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: Feeling sheet

/// How he feels: which meal it's after, the symptoms (tap again for worse), and
/// when. Nothing picked saves as "Feeling fine".
struct FeelingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DietStore.shared
    private let editing: GutCheck?
    @State private var mealID: String?
    @State private var at: Date
    @State private var symptoms: [Symptom: Severity]
    @State private var confirmDelete = false

    init(mealID: String?, check: GutCheck?) {
        let store = DietStore.shared
        // About a meal: the one asked, else the one that's waiting for an answer.
        let meal = check?.mealID ?? mealID ?? store.awaitingCheck()?.id
        let existing = check ?? meal.flatMap { store.check(for: $0) }
        editing = existing
        _mealID = State(initialValue: meal)
        _at = State(initialValue: existing?.at ?? .now)
        _symptoms = State(initialValue: existing?.symptoms ?? [:])
    }

    private var meal: Meal? { store.meal(mealID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    DietSheetSection(title: "After") { mealPicker }
                    DietSheetSection(title: "Symptoms", trailing: "Tap again for worse") { grid }
                    DietSheetSection(title: "When") {
                        DatePicker("Felt this at", selection: $at, in: ...Date.now.addingTimeInterval(600), displayedComponents: [.date, .hourAndMinute])
                            .font(.body).foregroundStyle(BrickLook.ink)
                    }
                    if editing != nil { deleteButton }
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.top, 8).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .safeAreaInset(edge: .bottom) {
                DietSaveButton(title: symptoms.isEmpty ? "Feeling fine" : "Save \(symptoms.count) \(symptoms.count == 1 ? "symptom" : "symptoms")",
                               enabled: true) { save() }
            }
            .hubPageStyle(backdrop: true)
            .navigationTitle(meal.map { "After \($0.slot.title.lowercased())" } ?? "How I feel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let editing { store.deleteCheck(editing) }
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground { AmbientBackdrop() }
        .sensoryFeedback(.selection, trigger: symptoms)
    }

    private func save() {
        store.save(GutCheck(id: editing?.id ?? LocalDB.uuid(), at: at, mealID: mealID, symptoms: symptoms, note: editing?.note))
        dismiss()
    }

    /// The last few meals, and "Not after a meal".
    private var mealPicker: some View {
        var recent = Array(store.recentMeals(before: max(at, .now)).prefix(4))
        if let meal, !recent.contains(where: { $0.id == meal.id }) { recent.insert(meal, at: 0) }
        return VStack(spacing: 8) {
            ForEach(recent) { m in
                mealChoice(m)
            }
            DietChip(title: recent.isEmpty ? "No meal in the last 14 hours" : "Not after a meal", symbol: nil, selected: mealID == nil) {
                mealID = nil
            }
        }
    }

    private func mealChoice(_ m: Meal) -> some View {
        let selected = mealID == m.id
        return Button { mealID = m.id } label: {
            HStack(spacing: 12) {
                Image(systemName: m.slot.symbol).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(m.slot.title) · \(m.at.formatted(date: .omitted, time: .shortened))").font(.body.weight(.semibold))
                    Text(m.summary).font(.caption).lineLimit(1).opacity(0.8)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
            }
            .foregroundStyle(selected ? .white : BrickLook.ink)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassGlare(selected ? .regular.tint(Fit.action.opacity(0.7)).interactive() : .regular.interactive(),
                        in: .rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Symptom.allCases) { symptom in
                SymptomTile(symptom: symptom, severity: symptoms[symptom]) {
                    withAnimation(HubMotion.standard) {
                        symptoms[symptom] = symptoms[symptom].map { $0.next } ?? .mild
                    }
                }
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) { confirmDelete = true } label: {
            Label("Delete entry", systemImage: "trash").font(.body.weight(.medium)).foregroundStyle(HubDesign.danger)
                .frame(maxWidth: .infinity, minHeight: 50)
                .glassGlare(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// A symptom to tap: off, then mild, moderate and severe, then off again.
private struct SymptomTile: View {
    var symptom: Symptom
    var severity: Severity?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(symptom.emoji).font(.system(size: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text(symptom.title).font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink).lineLimit(1).minimumScaleFactor(0.85)
                    Text(severity?.title ?? "No").font(.caption.weight(severity == nil ? .regular : .semibold))
                        .foregroundStyle(severity?.color ?? BrickLook.soft)
                }
                Spacer(minLength: 0)
                if let severity {
                    HStack(spacing: 3) {
                        ForEach(Severity.allCases) { level in
                            Capsule().fill(level <= severity ? severity.color : BrickLook.soft.opacity(0.25)).frame(width: 4, height: 14)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .glassGlare(severity.map { Glass.regular.tint($0.color.opacity(0.18)).interactive() } ?? Glass.regular.interactive(),
                        in: .rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(symptom.title): \(severity?.title ?? "none")")
        .accessibilityHint("Tap to change how bad it is")
    }
}
