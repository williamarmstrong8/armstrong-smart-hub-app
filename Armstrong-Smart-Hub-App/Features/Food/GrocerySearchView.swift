import SwiftUI

/// Pick the store, search, tap to add. What you've bought before comes first,
/// then Open Food Facts products with the store's own brands on top. Every
/// pick is remembered with its store and search, so it's the usual next time.
struct GrocerySearchView: View {
    let store: FoodStore
    let toast: Toast
    var initialQuery = ""

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("food.groceryStore") private var shop = "Trader Joe's"
    @State private var query = ""
    @State private var result: GrocerySearchResult?
    @State private var loading = false
    @State private var error: String?
    @State private var added: Set<String> = []
    @State private var adding: String?
    @State private var typingStore = false

    private static let mainStores = ["Trader Joe's", "Whole Foods", "Target"]
    private var otherStores: [String] { result?.stores.other ?? [] }
    private var mainStores: [String] { result?.stores.main ?? Self.mainStores }
    private var isOther: Bool { !mainStores.contains(shop) }
    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section { storePicker }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                results
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add groceries")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: shop.isEmpty ? "Search groceries" : "Search \(shop)")
            .autocorrectionDisabled()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(shop)|\(query)") { await search() }
            .alert("Store", isPresented: $typingStore) {
                TextField("Store name", text: $shop)
                Button("OK") {}
            }
            .overlay { if loading && result == nil { ProgressView() } }
            .onAppear { if query.isEmpty { query = initialQuery } }
            .toast(toast)
        }
    }

    // MARK: Store

    private var storePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(mainStores, id: \.self) { name in
                    chip(name, active: shop == name) { shop = name }
                }
                Menu {
                    ForEach(otherStores, id: \.self) { name in
                        Button(name) { shop = name }
                    }
                    Divider()
                    Button("Somewhere else…", systemImage: "pencil") { shop = ""; typingStore = true }
                } label: {
                    chipLabel(isOther && !shop.isEmpty ? shop : "Other", active: isOther, chevron: true)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, active: active) }.buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, active: Bool, chevron: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title)
            if chevron { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(active ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: .capsule)
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if let error, result == nil {
            Section { Text(error).foregroundStyle(.secondary) }
        }
        if let result {
            if !result.usual.isEmpty {
                Section(typed.isEmpty ? "Usually from \(shop.isEmpty ? "anywhere" : shop)" : "Your usual") {
                    ForEach(result.usual) { u in
                        row(key: "again:\(u.id)", image: u.image, name: u.name,
                            detail: ["\(u.times)×", u.store, u.calories.map { "\(Int($0.rounded())) kcal/serving" }].compactMap { $0 }.joined(separator: " · "),
                            pick: .again(id: u.id))
                    }
                }
            } else if typed.isEmpty {
                Section {
                    Text("Search for something. What you add here becomes your usual.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            let own = result.products.filter(\.atStore)
            let rest = result.products.filter { !$0.atStore }
            if !own.isEmpty {
                Section("At \(shop)") { ForEach(own) { productRow($0) } }
            }
            if !rest.isEmpty {
                Section(own.isEmpty && !shop.isEmpty ? "Products" : "Other brands") { ForEach(rest) { productRow($0) } }
            }

            if typed.count >= 2 {
                Section {
                    Button {
                        add(.named(typed), key: "name:\(typed)")
                    } label: {
                        HStack {
                            Label("Add “\(typed)”", systemImage: added.contains("name:\(typed)") ? "checkmark" : "plus")
                            Spacer()
                            Text("nutrition estimated").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(adding != nil || added.contains("name:\(typed)"))
                } footer: {
                    if let notice = result.notice {
                        Text(notice)
                    } else if result.products.isEmpty && !loading {
                        Text("No packaged products found. Fresh and store-cut foods often aren't in Open Food Facts.")
                    } else {
                        Text("Product data from Open Food Facts (ODbL).")
                    }
                }
            }
        }
    }

    private func productRow(_ p: ProductHit) -> some View {
        row(key: p.barcode, image: p.image, name: p.name,
            detail: [p.brand.isEmpty ? nil : p.brand, p.quantity, p.calories.map { "\(Int($0.rounded())) kcal/100 g" }].compactMap { $0 }.joined(separator: " · "),
            pick: .product(barcode: p.barcode))
    }

    private func row(key: String, image: String?, name: String, detail: String, pick: GroceryPick) -> some View {
        let done = added.contains(key)
        return Button { add(pick, key: key) } label: {
            HStack(spacing: 12) {
                Group {
                    if image != nil {
                        FoodImage(source: image, fit: true, inset: 4)
                    } else {
                        Text(name.prefix(1).uppercased()).font(.title2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 84, height: 84)
                .background(Color.white, in: .rect(cornerRadius: 14))
                .clipShape(.rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                }
                Spacer(minLength: 8)
                if adding == key {
                    ProgressView()
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(done ? Color.green : Color.accentColor)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(done || adding != nil)
    }

    // MARK: Work

    private func search() async {
        // Wait for typing to settle; an empty query (the store's usuals) loads right away.
        if !query.isEmpty { try? await Task.sleep(for: .milliseconds(450)) }
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await store.searchGroceries(query, store: shop.isEmpty ? nil : shop, api: session.api)
            guard !Task.isCancelled else { return }
            result = next
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ pick: GroceryPick, key: String) {
        adding = key
        Task {
            if await store.addGrocery(pick, store: shop.isEmpty ? nil : shop, query: typed, api: session.api, toast: toast) {
                added.insert(key)
            }
            adding = nil
        }
    }
}
