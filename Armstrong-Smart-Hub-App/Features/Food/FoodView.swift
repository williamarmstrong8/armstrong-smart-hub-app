import PhotosUI
import SwiftUI

/// The food journal, like the web's /food: the day's totals, three ways to log
/// (photo, barcode, by hand), a review queue for photo estimates and DoorDash
/// orders, the day's meals, and the grocery list photos are matched against.
struct FoodView: View {
    @Environment(AppSession.self) private var session
    @State private var store = FoodStore()
    @State private var toast = Toast()
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var editing: MealTarget?
    @State private var scanning = false
    @State private var camera: CameraUse?
    @State private var libraryUse: CameraUse?
    @State private var showingLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var typingGroceries = false
    @State private var showAllGroceries = false

    /// What a picked photo is for.
    enum CameraUse: Identifiable {
        case meal, groceries
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !store.loaded, let error = store.error {
                        MessageView(title: "Couldn't load food", systemImage: "exclamationmark.triangle", message: error,
                                    actionTitle: "Try again") { Task { await store.load(api: session.api) } }
                    } else if !store.loaded {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        totals
                        quickAdd
                        if let working = store.working {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(working).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        if !store.review.isEmpty { reviewCard }
                        mealsCard
                        groceriesCard
                        if store.gmail == "missing_scope" { gmailCard }
                    }
                }
                .padding(16)
                .animation(.smooth(duration: 0.3), value: store.entries)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Food")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                if store.gmail == "connected" {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Sync DoorDash", systemImage: "arrow.clockwise") {
                            Task { await store.syncDoorDash(api: session.api, toast: toast) }
                        }
                        .disabled(store.working != nil)
                    }
                }
            }
            .task { if !store.loaded { await store.load(api: session.api) } }
            .refreshable { await store.load(api: session.api) }
            .sheet(item: $editing) { target in MealEditor(target: target, store: store, toast: toast) }
            .fullScreenCover(isPresented: $scanning) { ScannerSheet { code in lookup(code) } }
            .fullScreenCover(item: $camera) { use in
                CameraPicker { image in handle(image, for: use) }.ignoresSafeArea()
            }
            .photosPicker(isPresented: $showingLibrary, selection: $libraryItem, matching: .images)
            .onChange(of: libraryItem) { _, item in loadLibrary(item) }
            .sheet(isPresented: $typingGroceries) {
                TypeGroceriesSheet { text in Task { await store.addGroceries(text: text, api: session.api, toast: toast) } }
            }
            .toast(toast)
        }
    }

    // MARK: Totals

    private var totals: some View {
        let meals = store.meals(on: day)
        let isToday = Calendar.current.isDateInToday(day)
        func sum(_ key: KeyPath<FoodEntry, Double?>) -> Double { meals.compactMap { $0[keyPath: key] }.reduce(0, +) }
        return Card {
            HStack {
                Button("Previous day", systemImage: "chevron.left") { shift(-1) }.labelStyle(.iconOnly)
                Spacer()
                VStack(spacing: 2) {
                    Text(isToday ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.headline)
                    Text("\(meals.count) meal\(meals.count == 1 ? "" : "s")\(meals.contains { $0.calories == nil } ? " · some calories unknown" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Next day", systemImage: "chevron.right") { shift(1) }.labelStyle(.iconOnly).disabled(isToday)
            }
            .buttonStyle(.borderless)
            HStack(alignment: .top) {
                Macro(label: "Calories", value: sum(\.calories), unit: "kcal")
                Macro(label: "Protein", value: sum(\.protein), unit: "g")
                Macro(label: "Carbs", value: sum(\.carbs), unit: "g")
                Macro(label: "Fat", value: sum(\.fat), unit: "g")
            }
            .padding(.top, 4)
        }
    }

    private func shift(_ days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: day), next <= .now { day = next }
    }

    // MARK: Logging

    private var quickAdd: some View {
        HStack(spacing: 10) {
            Menu {
                if CameraPicker.isAvailable { Button("Take photo", systemImage: "camera") { camera = .meal } }
                Button("Choose photo", systemImage: "photo") { choose(for: .meal) }
            } label: {
                QuickAddTile(symbol: "camera.fill", title: "Photo")
            }
            Button { scanning = true } label: { QuickAddTile(symbol: "barcode.viewfinder", title: "Scan") }
            Button { editing = .new() } label: { QuickAddTile(symbol: "plus", title: "Add") }
        }
        .buttonStyle(.plain)
        .disabled(store.working != nil)
    }

    private func lookup(_ code: String) {
        Task {
            do {
                let product = try await store.lookup(code, api: session.api)
                editing = .new(product: product, barcode: code)
            } catch {
                toast.error(error)
            }
        }
    }

    private func handle(_ image: UIImage, for use: CameraUse) {
        Task {
            switch use {
            case .meal:
                if let entry = await store.logPhoto(image, api: session.api, toast: toast) { editing = .edit(entry) }
            case .groceries:
                await store.addGroceries(photo: image, api: session.api, toast: toast)
            }
        }
    }

    private func choose(for use: CameraUse) {
        libraryUse = use
        showingLibrary = true
    }

    private func loadLibrary(_ item: PhotosPickerItem?) {
        guard let item, let use = libraryUse else { return }
        libraryItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                toast.show("Couldn't open that photo.", error: true)
                return
            }
            handle(image, for: use)
        }
    }

    // MARK: Review and meals

    private var reviewCard: some View {
        Card(title: "To review", trailing: "\(store.review.count)") {
            Text("Photo estimates and DoorDash orders count once you confirm you ate them.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(store.review) { entry in
                HStack(spacing: 12) {
                    SourceBadge(symbol: entry.sourceSymbol)
                    Button { editing = .edit(entry) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(detail(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    if entry.calories != nil {
                        Button("Ate it", systemImage: "checkmark") { Task { await store.accept(entry, api: session.api, toast: toast) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button("Review") { editing = .edit(entry) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func detail(_ entry: FoodEntry) -> String {
        [entry.date?.formatted(.dateTime.month(.abbreviated).day().hour().minute()), entry.restaurant,
         entry.calories.map { "~\(Int($0.rounded())) kcal" } ?? "nutrition unknown"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var mealsCard: some View {
        let meals = store.meals(on: day)
        return Card(title: "Meals") {
            if meals.isEmpty {
                Text(Calendar.current.isDateInToday(day) ? "Nothing logged yet today." : "Nothing logged this day.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(meals) { meal in
                    Button { editing = .edit(meal) } label: {
                        HStack(spacing: 10) {
                            Text(meal.date?.formatted(date: .omitted, time: .shortened) ?? "")
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 70, alignment: .leading)
                            Image(systemName: meal.sourceSymbol).font(.caption).foregroundStyle(.secondary).frame(width: 18)
                            Text(meal.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(meal.calories.map { "\(Int($0.rounded())) kcal" } ?? "—")
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: Groceries

    private var groceriesCard: some View {
        let items = showAllGroceries ? store.groceries : Array(store.groceries.prefix(10))
        return Card {
            HStack {
                Label("Groceries", systemImage: "basket").font(.headline)
                Spacer()
                Menu {
                    if CameraPicker.isAvailable { Button("Photograph a receipt", systemImage: "camera") { camera = .groceries } }
                    Button("Choose a photo", systemImage: "photo") { choose(for: .groceries) }
                    Button("Type a list", systemImage: "character.cursor.ibeam") { typingGroceries = true }
                    if !store.groceries.isEmpty {
                        Divider()
                        Button("Clear list", systemImage: "trash", role: .destructive) {
                            Task { await store.clearGroceries(api: session.api, toast: toast) }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus").font(.subheadline.weight(.medium))
                }
                .disabled(store.working != nil)
            }
            Text("Meal photos are matched to what you bought.").font(.footnote).foregroundStyle(.secondary)
            if store.groceries.isEmpty {
                Text("Snap a grocery receipt or list to get started.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text([item.quantity, item.calories.map { "\(Int($0.rounded())) kcal\(item.serving.map { " / \($0)" } ?? "")" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Remove \(item.name)", systemImage: "xmark") {
                            Task { await store.deleteGrocery(item, api: session.api, toast: toast) }
                        }
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
                if store.groceries.count > 10 {
                    Button(showAllGroceries ? "Show less" : "Show all \(store.groceries.count)") { showAllGroceries.toggle() }
                        .font(.subheadline)
                }
            }
        }
    }

    private var gmailCard: some View {
        Card {
            Label("Import DoorDash orders", systemImage: "envelope").font(.headline)
            Text("Connect Gmail on the hub's Food page and DoorDash order confirmations show up here to review.")
                .font(.footnote).foregroundStyle(.secondary)
            if let url = session.webURL("/food") {
                Link("Open Food on the web", destination: url).font(.subheadline.weight(.medium))
            }
        }
    }
}

private struct Macro: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Int(value.rounded()))").font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Text("\(label) · \(unit)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QuickAddTile: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: .circle)
            Text(title).font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
    }
}

private struct SourceBadge: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
    }
}

private struct TypeGroceriesSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("One item per line, or paste a receipt.\nNutrition is filled in for you.")
                            .foregroundStyle(.tertiary).padding(.horizontal, 17).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
                .navigationTitle("Type groceries")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            onSubmit(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
