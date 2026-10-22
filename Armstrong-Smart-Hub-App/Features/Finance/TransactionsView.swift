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

        List {
            if let flow = store.dashboard?.cashFlow, flow.count > 1, category == nil, search.isEmpty {
                Section("Cash flow") {
                    Chart(flow) { m in
                        BarMark(x: .value("Month", m.month), y: .value("In", m.income)).foregroundStyle(Color.positive).position(by: .value("Kind", "In"))
                        BarMark(x: .value("Month", m.month), y: .value("Out", m.spending)).foregroundStyle(Color.negative.opacity(0.7)).position(by: .value("Kind", "Out"))
                    }
                    .chartYAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.axis(d)) } } } }
                    .frame(height: 150)
                }
                .listRowBackground(BrickLook.card)
            }
            ForEach(byDay, id: \.key) { day, items in
                Section {
                    ForEach(items) { t in
                        TransactionRow(transaction: t) { retagging = t }
                            .contentShape(.rect)
                            .onTapGesture { retagging = t }
                    }
                    .listRowBackground(BrickLook.card)
                } header: {
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                        Spacer()
                        Text(Fmt.signed(items.filter { !$0.pending }.reduce(0) { $0 + $1.netEffect }, store.currency)).monospacedDigit()
                    }
                }
            }
        }
        .brickList()
        .overlay { if filtered.isEmpty { ContentUnavailableView.search(text: search) } }
        .searchable(text: $search, prompt: "Merchant or account")
        .navigationTitle(category ?? "Transactions")
        .toolbar {
            Menu {
                Picker("Category", selection: $category) {
                    Text("All").tag(String?.none)
                    ForEach(store.categoryOptions + ["Uncategorized"], id: \.self) { Text($0).tag(Optional($0)) }
                }
            } label: {
                Label("Filter", systemImage: category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        .sheet(item: $retagging) { t in
            CategoryPicker(transaction: t, options: store.categoryOptions) { c in
                Task { await store.retag(t, to: c, api: session.api, toast: toast) }
            }
        }
    }
}
