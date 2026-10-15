import PhotosUI
import SwiftUI

/// The food journal, visual first: the day's calories as a ring split by
/// macros, three ways to log (snap, scan, upload), the day's meals as photo
/// tiles, and the groceries meal photos are matched against.
struct FoodView: View {
    @Environment(AppSession.self) private var session
    @State private var store = FoodStore()
    @State private var toast = Toast()
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var sheet: FoodSheetTarget?
    @State private var scanning: Purpose?
    @State private var camera: Purpose?
    @State private var libraryFor: Purpose?
    @State private var showingLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var finding = false

    /// What a photo or scan is for.
    enum Purpose: Identifiable {
        case meal, groceries
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if !store.loaded, let error = store.error {
                        MessageView(title: "Couldn't load food", systemImage: "exclamationmark.triangle", message: error,
                                    actionTitle: "Try again") { Task { await store.load(api: session.api) } }
                    } else if !store.loaded {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        today
                        logActions
                        if let working = store.working {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(working).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        }
                        meals
                        groceries
                        Text("Product data from Open Food Facts (ODbL). Photo nutrition is an estimate.")
                            .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                }
                .padding(16)
                .animation(.smooth(duration: 0.35), value: store.entries)
                .animation(.smooth(duration: 0.35), value: store.groceries)
                .animation(.smooth, value: store.working)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Food")
            .toolbar { ToolbarItem(placement: .topBarLeading) { AccountButton() } }
            .task { if !store.loaded { await store.load(api: session.api) } }
            .refreshable { await store.load(api: session.api) }
            .sheet(item: $sheet) { target in FoodSheet(target: target, store: store, toast: toast) }
            .sheet(isPresented: $finding) { GrocerySearchView(store: store, toast: toast) }
            .fullScreenCover(item: $scanning) { purpose in ScannerSheet { code in scanned(code, for: purpose) } }
            .fullScreenCover(item: $camera) { purpose in
                CameraPicker { image in picked(image, for: purpose) }.ignoresSafeArea()
            }
            .photosPicker(isPresented: $showingLibrary, selection: $libraryItem, matching: .images)
            .onChange(of: libraryItem) { _, item in loadLibrary(item) }
            .toast(toast)
        }
    }

    // MARK: The day

    private var today: some View {
        let meals = store.meals(on: day)
        func sum(_ key: KeyPath<FoodEntry, Double?>) -> Double { meals.compactMap { $0[keyPath: key] }.reduce(0, +) }
        let isToday = Calendar.current.isDateInToday(day)
        return VStack(spacing: 20) {
            HStack {
                Button("Previous day", systemImage: "chevron.left") { shift(-1) }
                Spacer()
                Text(isToday ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.headline)
                Spacer()
                Button("Next day", systemImage: "chevron.right") { shift(1) }.disabled(isToday)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)

            CalorieRing(calories: sum(\.calories), protein: sum(\.protein), carbs: sum(\.carbs), fat: sum(\.fat))
                .frame(width: 220, height: 220)
            MacroBars(protein: sum(\.protein), carbs: sum(\.carbs), fat: sum(\.fat))
                .padding(.horizontal, 12)
        }
    }

    private func shift(_ days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: day), next <= .now { day = next }
    }

    // MARK: Logging

    private var logActions: some View {
        HStack(spacing: 12) {
            BigAction(symbol: "camera.fill", title: "Snap") { open(.camera, for: .meal) }
            BigAction(symbol: "barcode.viewfinder", title: "Scan") { scanning = .meal }
            BigAction(symbol: "photo.on.rectangle", title: "Upload") { open(.library, for: .meal) }
        }
        .disabled(store.working != nil)
    }

    private enum Source { case camera, library }

    private func open(_ source: Source, for purpose: Purpose) {
        switch source {
        case .camera where CameraPicker.isAvailable: camera = purpose
        default:
            libraryFor = purpose
            showingLibrary = true
        }
    }

    private func scanned(_ code: String, for purpose: Purpose) {
        Task {
            switch purpose {
            case .meal:
                if let product = await store.lookup(code, api: session.api, toast: toast) { sheet = .product(product) }
            case .groceries:
                // Store-weighed items (cheese wedges, meat, deli) print a new
                // "02…" barcode on every package, so they never look up.
                if code.count >= 12, code.hasPrefix("02") || code.hasPrefix("002") {
                    toast.show("Store-weighed items have a different barcode on every package. Search for it instead.")
                    // Let the scanner finish closing before the search sheet opens.
                    try? await Task.sleep(for: .milliseconds(600))
                    finding = true
                } else if !(await store.addGroceries(barcode: code, api: session.api, toast: toast)) {
                    finding = true
                }
            }
        }
    }

    private func picked(_ image: UIImage, for purpose: Purpose) {
        Task {
            switch purpose {
            case .meal:
                if let estimate = await store.estimate(image, api: session.api, toast: toast) { sheet = .photo(estimate, image) }
            case .groceries:
                await store.addGroceries(photo: image, api: session.api, toast: toast)
            }
        }
    }

    private func loadLibrary(_ item: PhotosPickerItem?) {
        guard let item, let purpose = libraryFor else { return }
        libraryItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                toast.show("Couldn't open that photo.", error: true)
                return
            }
            picked(image, for: purpose)
        }
    }

    // MARK: Meals

    @ViewBuilder private var meals: some View {
        let meals = store.meals(on: day)
        if meals.isEmpty {
            Text(Calendar.current.isDateInToday(day) ? "Nothing logged yet today." : "Nothing logged this day.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(meals) { meal in
                    Button { sheet = .entry(meal) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            FoodImage(source: meal.image, fit: meal.source == "barcode")
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .background(Color(.tertiarySystemFill))
                                .clipped()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meal.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(meal.calories.map { "\(Int($0.rounded())) kcal" } ?? "—")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 18))
                        .contentShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: Groceries

    private var groceries: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Groceries", systemImage: "basket").font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Button("Find", systemImage: "magnifyingglass") { finding = true }
                        .buttonStyle(.borderedProminent)
                    Button("Photo", systemImage: "camera") { open(.camera, for: .groceries) }
                    Button("Scan", systemImage: "barcode.viewfinder") { scanning = .groceries }
                    Button("Upload", systemImage: "photo") { open(.library, for: .groceries) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(store.working != nil)
            }
            if store.groceries.isEmpty {
                Text("Find what you're getting, photograph a receipt or scan what you bought. Meal photos match against this.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(store.groceries) { item in
                        VStack(spacing: 6) {
                            Group {
                                if item.image != nil {
                                    FoodImage(source: item.image, fit: true, inset: 6)
                                } else {
                                    Text(item.name.prefix(1).uppercased())
                                        .font(.title.weight(.semibold)).foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12))
                            .clipShape(.rect(cornerRadius: 12))
                            VStack(spacing: 1) {
                                Text(item.name).font(.caption.weight(.medium)).lineLimit(1)
                                if let shop = item.store {
                                    Text(shop).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await store.deleteGrocery(item, api: session.api, toast: toast) }
                            }
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                Button("Clear groceries", role: .destructive) { Task { await store.clearGroceries(api: session.api, toast: toast) } }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// Calories in the middle of a ring split into protein, carbs and fat by their calories.
private struct CalorieRing: View {
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double

    var body: some View {
        let parts = [(MacroColor.protein, protein * 4), (MacroColor.carbs, carbs * 4), (MacroColor.fat, fat * 9)]
        let total = parts.reduce(0) { $0 + $1.1 }
        let gap = total > 0 ? 0.012 : 0
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 16)
            if total > 0 {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    let start = parts.prefix(i).reduce(0) { $0 + $1.1 } / total
                    let end = start + part.1 / total
                    if part.1 > 0 {
                        Circle()
                            .trim(from: start + gap, to: max(start + gap, end - gap))
                            .stroke(part.0, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
            }
            VStack(spacing: 2) {
                Text("\(Int(calories.rounded()))")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("calories").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .animation(.smooth(duration: 0.6), value: calories)
    }
}

private struct BigAction: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.12), in: .circle)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}
