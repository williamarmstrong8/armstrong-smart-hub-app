import SwiftUI

/// What the sheet shows: a scanned product, a read meal photo, or a meal already logged.
enum FoodSheetTarget: Identifiable {
    case product(FoodProduct)
    case photo(MealEstimate, UIImage)
    case entry(FoodEntry)

    var id: String {
        switch self {
        case .product(let p): "product-\(p.barcode)"
        case .photo(let m, _): "photo-\(m.name)-\(m.calories ?? 0)"
        case .entry(let e): e.id
        }
    }
}

enum MacroColor {
    static let protein = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let carbs = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let fat = Color(red: 0.93, green: 0.28, blue: 0.6)
}

/// The food, big: its picture, the calories, and the macros as bars. A
/// stepper scales the portion; one tap logs it.
struct FoodSheet: View {
    let target: FoodSheetTarget
    let store: FoodStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var amount = 1.0
    @State private var saving = false

    private struct Numbers { var grams, calories, protein, carbs, fat: Double? }

    /// The base numbers for an amount of 1, what the stepper counts, and its step.
    private var basis: (numbers: Numbers, unit: String, step: Double) {
        switch target {
        case .product(let p):
            // Products are per 100 g; the stepper counts label servings.
            let grams = p.servingGrams ?? 100
            func per(_ v: Double?) -> Double? { v.map { $0 * grams / 100 } }
            return (Numbers(grams: grams, calories: per(p.calories), protein: per(p.protein), carbs: per(p.carbs), fat: per(p.fat)),
                    p.servingGrams == nil ? "× 100 g" : "serving", 0.5)
        case .photo(let m, _):
            return (Numbers(grams: m.grams, calories: m.calories, protein: m.protein, carbs: m.carbs, fat: m.fat), "portion", 0.25)
        case .entry(let e):
            return (Numbers(grams: e.grams, calories: e.calories, protein: e.protein, carbs: e.carbs, fat: e.fat), "portion", 0.25)
        }
    }

    private func scaled(_ v: Double?) -> Double? { v.map { ($0 * amount * 10).rounded() / 10 } }

    private var title: String {
        switch target {
        case .product(let p): [p.brand.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }, p.name]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        case .photo(let m, _): m.name
        case .entry(let e): e.name
        }
    }

    private var items: [MealItem] {
        switch target {
        case .photo(let m, _): m.items
        case .entry(let e): e.items ?? []
        case .product: []
        }
    }

    private var logged: Bool { if case .entry = target { true } else { false } }

    var body: some View {
        let n = basis.numbers
        ScrollView {
            VStack(spacing: 24) {
                header

                VStack(spacing: 4) {
                    Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

                VStack(spacing: 2) {
                    Text(scaled(n.calories).map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("calories").font(.subheadline).foregroundStyle(.secondary)
                }

                MacroBars(protein: scaled(n.protein), carbs: scaled(n.carbs), fat: scaled(n.fat))
                    .padding(.horizontal, 24)

                if !items.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            let grocery = item.groceryId.flatMap { id in store.groceries.first { $0.id == id } }
                            HStack(spacing: 4) {
                                if grocery != nil { Image(systemName: "basket.fill").foregroundStyle(Color.accentColor) }
                                Text(item.name)
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: .capsule)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                actions.padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
            .animation(.snappy, value: amount)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var subtitle: String {
        if case .entry(let e) = target { return e.date?.formatted(date: .omitted, time: .shortened) ?? "" }
        if let g = scaled(basis.numbers.grams) { return "\(Int(g.rounded())) g" }
        return "Estimated"
    }

    @ViewBuilder private var header: some View {
        Group {
            switch target {
            case .photo(_, let image):
                Image(uiImage: image).resizable().scaledToFill()
            case .product(let p):
                FoodImage(source: p.image, fit: true)
            case .entry(let e):
                FoodImage(source: e.image, fit: e.source == "barcode")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(Color(.secondarySystemBackground))
        .clipped()
    }

    @ViewBuilder private var actions: some View {
        if case .entry(let entry) = target {
            Button("Remove", role: .destructive) {
                Task {
                    await store.delete(entry, api: session.api, toast: toast)
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            VStack(spacing: 14) {
                HStack(spacing: 20) {
                    Button("Less", systemImage: "minus") { amount = max(basis.step, amount - basis.step) }
                        .disabled(amount <= basis.step)
                    Text("\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(basis.unit)\(amount == 1 || basis.unit.hasPrefix("×") ? "" : "s")")
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                        .frame(minWidth: 110)
                    Button("More", systemImage: "plus") { amount += basis.step }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)

                Button { log() } label: {
                    Text("Log it").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saving)

                if case .product(let p) = target {
                    Button("Add to groceries", systemImage: "basket") {
                        Task { await store.addGroceries(barcode: p.barcode, api: session.api, toast: toast) }
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func log() {
        saving = true
        let n = basis.numbers
        var input = MealInput(name: title.isEmpty ? "Food" : String(title.prefix(200)), eatenAt: ISO.string(.now),
                              grams: scaled(n.grams), calories: scaled(n.calories), protein: scaled(n.protein), carbs: scaled(n.carbs), fat: scaled(n.fat))
        switch target {
        case .product(let p):
            input.barcode = p.barcode
            input.image = p.image
            input.source = "barcode"
        case .photo(let m, let image):
            input.image = image.thumbnailDataURL
            input.source = "photo"
            input.items = m.items.map {
                MealItemInput(name: $0.name, groceryId: $0.groceryId, portion: $0.portion, grams: scaled($0.grams), calories: scaled($0.calories),
                              protein: scaled($0.protein), carbs: scaled($0.carbs), fat: scaled($0.fat))
            }
        case .entry:
            return
        }
        Task {
            if await store.log(input, api: session.api, toast: toast) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                toast.show("Logged")
                dismiss()
            }
            saving = false
        }
    }
}

/// Protein, carbs and fat as big numbers over bars sized by their share of the calories.
struct MacroBars: View {
    let protein: Double?
    let carbs: Double?
    let fat: Double?

    var body: some View {
        let kcal = [(protein ?? 0) * 4, (carbs ?? 0) * 4, (fat ?? 0) * 9]
        let total = max(kcal.reduce(0, +), 1)
        HStack(spacing: 16) {
            bar("Protein", protein, kcal[0] / total, MacroColor.protein)
            bar("Carbs", carbs, kcal[1] / total, MacroColor.carbs)
            bar("Fat", fat, kcal[2] / total, MacroColor.fat)
        }
    }

    private func bar(_ label: String, _ grams: Double?, _ share: Double, _ color: Color) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(grams.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                Text("g").font(.subheadline).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(color).frame(width: geo.size.width * share)
                }
            }
            .frame(height: 6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A product photo URL or a "data:image/jpeg;base64," thumbnail, with a fork-and-knife placeholder.
struct FoodImage: View {
    let source: String?
    var fit = false
    /// Space around a fitted product photo.
    var inset: CGFloat = 16

    var body: some View {
        if let source, source.hasPrefix("data:image"), let comma = source.firstIndex(of: ","),
           let data = Data(base64Encoded: String(source[source.index(after: comma)...])), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
        } else if let source, let url = URL(string: source) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: fit ? .fit : .fill).padding(fit ? inset : 0)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: "fork.knife").font(.largeTitle).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
