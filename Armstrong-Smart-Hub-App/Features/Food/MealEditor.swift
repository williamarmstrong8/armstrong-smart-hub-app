import SwiftUI

/// What the meal sheet is for: a new meal (maybe from a scanned product), or an existing one.
enum MealTarget: Identifiable {
    case new(product: FoodProduct? = nil, barcode: String? = nil)
    case edit(FoodEntry)

    var id: String {
        switch self {
        case .new(let product, let barcode): "new-\(product?.barcode ?? barcode ?? "")"
        case .edit(let entry): entry.id
        }
    }
}

/// Adds, edits or reviews a meal. Photo estimates show what each part was
/// matched to; a scanned product's nutrition scales with the portion.
struct MealEditor: View {
    let target: MealTarget
    let store: FoodStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var eatenAt = Date.now
    @State private var grams = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var saving = false

    private var entry: FoodEntry? { if case .edit(let e) = target { e } else { nil } }
    private var product: FoodProduct? { if case .new(let p, _) = target { p } else { nil } }
    private var reviewing: Bool { entry.map { !$0.confirmed } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if let note { Section { Text(note).font(.subheadline).foregroundStyle(.secondary) } }

                if let items = entry?.items, !items.isEmpty {
                    Section("On the plate") {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    HStack(spacing: 4) {
                                        Text(item.portion ?? "Portion unknown")
                                        if let grocery = item.groceryId.flatMap({ id in store.groceries.first { $0.id == id } }) {
                                            Text("·")
                                            Label(grocery.name, systemImage: "basket").labelStyle(.titleAndIcon)
                                        }
                                    }
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(item.calories.map { "\(Int($0.rounded())) kcal" } ?? "?").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }

                Section {
                    TextField("What you ate", text: $name)
                    DatePicker("When", selection: $eatenAt)
                }

                Section("Nutrition") {
                    NumberRow(label: "Portion", unit: "g", text: $grams)
                    NumberRow(label: "Calories", unit: "kcal", text: $calories)
                    NumberRow(label: "Protein", unit: "g", text: $protein)
                    NumberRow(label: "Carbs", unit: "g", text: $carbs)
                    NumberRow(label: "Fat", unit: "g", text: $fat)
                }

                if let entry {
                    Section {
                        Button(reviewing ? "Dismiss" : "Remove meal", role: .destructive) {
                            Task {
                                await store.delete(entry, api: session.api, toast: toast)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(reviewing ? "Review meal" : entry != nil ? "Edit meal" : product != nil ? "Scanned food" : "Add a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(reviewing ? "Add to day" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onAppear(perform: fill)
            .onChange(of: grams) { _, new in rescale(new) }
        }
    }

    private var note: String? {
        if let entry {
            switch entry.source {
            case "photo": return "Estimated from your photo. Adjust anything that looks off."
            case "doordash": return "From your \(entry.restaurant ?? "DoorDash") receipt. Receipts don't include nutrition, so fill in what you know."
            default: return nil
            }
        }
        if let product {
            return [product.brand.isEmpty ? nil : product.brand, product.serving.isEmpty ? nil : "Label serving: \(product.serving)", "Nutrition scales from 100 g."]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if case .new(nil, let barcode?) = target { return "Barcode \(barcode) isn't in Open Food Facts yet. Add it from the label." }
        return nil
    }

    private func fill() {
        if let e = entry {
            name = e.name
            eatenAt = e.date ?? .now
            grams = text(e.grams); calories = text(e.calories); protein = text(e.protein); carbs = text(e.carbs); fat = text(e.fat)
        } else if let p = product {
            name = [p.brand, p.name].filter { !$0.isEmpty }.joined(separator: " ")
            // Start at the label's serving when it's given in grams; rescale fills in the nutrition.
            let portion = text(Self.servingGrams(p.serving) ?? 100)
            grams = portion
            rescale(portion)
        }
    }

    /// A scanned product is per 100 g, so its nutrition follows the portion.
    private func rescale(_ value: String) {
        guard let p = product, let g = Double(value), g > 0 else { return }
        func scaled(_ v: Double?) -> String { v.map { text(($0 * g / 100 * 10).rounded() / 10) } ?? "" }
        calories = scaled(p.calories); protein = scaled(p.protein); carbs = scaled(p.carbs); fat = scaled(p.fat)
    }

    private func save() {
        saving = true
        let barcode: String? = {
            if let entry { return entry.barcode }
            if case .new(let p, let code) = target { return p?.barcode ?? code }
            return nil
        }()
        let input = MealInput(id: entry?.id, name: name.trimmingCharacters(in: .whitespaces), eatenAt: ISO.string(eatenAt),
                              grams: Double(grams), calories: Double(calories), protein: Double(protein), carbs: Double(carbs), fat: Double(fat),
                              barcode: barcode)
        Task {
            if await store.save(input, api: session.api, toast: toast) {
                toast.show(reviewing ? "Added to your day" : "Meal saved")
                dismiss()
            }
            saving = false
        }
    }

    /// "1 serving (150 g)" → 150.
    static func servingGrams(_ serving: String) -> Double? {
        guard let match = serving.firstMatch(of: /(\d+(?:\.\d+)?)\s*g\b/.ignoresCase()), let g = Double(match.1), g > 0, g < 5000 else { return nil }
        return g
    }

    private func text(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }
}

private struct NumberRow: View {
    let label: String
    let unit: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 100)
            Text(unit).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
        }
    }
}

extension ISO {
    /// An instant as the ISO 8601 string the hub expects.
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
