import Charts
import SwiftUI

/// Every transaction in the loaded window, searchable and filterable by tag.
struct TransactionsView: View {
    let store: FinanceStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @State private var search = ""
    @State private var category: String?
    @State private var retagging: Transaction?

    var body: some View {
        let all = store.dashboard?.transactions ?? []
        let filtered = all.filter { t in
            (category == nil || t.category == category)
                && (search.isEmpty || t.payee.localizedCaseInsensitiveContains(search) || t.accountName.localizedCaseInsensitiveContains(search))
        }
        let byDay = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                if let flow = store.dashboard?.cashFlow, flow.count > 1, category == nil, search.isEmpty {
                    Chart(flow) { m in
                        BarMark(x: .value("Month", m.month), y: .value("In", m.income)).foregroundStyle(Color.positive).position(by: .value("Kind", "In"))
                        BarMark(x: .value("Month", m.month), y: .value("Out", m.spending)).foregroundStyle(Color.negative.opacity(0.7)).position(by: .value("Kind", "Out"))
                    }
                    .chartYAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.axis(d)) } } } }
                    .frame(height: 150)
                }
                ForEach(byDay, id: \.key) { day, items in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                            Spacer()
                            Text(Fmt.signed(items.filter { !$0.pending }.reduce(0) { $0 + $1.netEffect }, store.currency)).monospacedDigit()
                        }
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(items) { t in
                            TransactionRow(transaction: t) { retagging = t }
                                .contentShape(.rect)
                                .onTapGesture { retagging = t }
                        }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Fit.gutter)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .scrollDismissesKeyboard(.interactively)
        .brickList()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrickLook.page, for: .navigationBar)
        .sheet(item: $retagging) { t in
            CategoryPicker(transaction: t, options: store.categoryOptions) { c in
                Task { await store.retag(t, to: c, api: session.api, toast: toast) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(category ?? "Transactions").font(.system(size: 34, weight: .light))
                Spacer()
                Menu {
                    Picker("Category", selection: $category) {
                        Text("All").tag(String?.none)
                        ForEach(store.categoryOptions + ["Uncategorized"], id: \.self) { Text($0).tag(Optional($0)) }
                    }
                } label: {
                    Image(systemName: category == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 20, weight: .light))
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Merchant or account", text: $search).submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(BrickLook.pill, in: .capsule)
        }
    }
}
