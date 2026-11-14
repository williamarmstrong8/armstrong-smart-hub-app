import Charts
import SwiftUI

/// Income and spending per month, two thin bars each; touch a month to read it.
private struct CashFlowChart: View {
    let flow: [CashFlowMonth]
    let currency: String

    @State private var selected: Date?

    private struct Month: Identifiable {
        var date: Date
        var income: Double
        var spending: Double
        var id: Date { date }
    }

    var body: some View {
        let calendar = Calendar.current
        let months = flow.compactMap { m in
            DateOnly.parse(m.month + "-01").map { Month(date: $0, income: m.income, spending: m.spending) }
        }.sorted { $0.date < $1.date }
        let chosen = selected.flatMap { s in months.first { calendar.isDate($0.date, equalTo: s, toGranularity: .month) } }
        let shown = chosen ?? months.last
        let scale = ChartScale(low: 0, high: max(months.map { max($0.income, $0.spending) }.max() ?? 1, 1))
        // Each month's label sits at the middle of its band.
        let middles = months.map { m in
            calendar.dateInterval(of: .month, for: m.date).map { $0.start.addingTimeInterval($0.duration / 2) } ?? m.date
        }
        VStack(alignment: .leading, spacing: 10) {
            if let shown {
                HStack(spacing: 14) {
                    Text(shown.date.formatted(.dateTime.month(.wide).year())).font(Fit.label).foregroundStyle(Fit.muted)
                    Spacer(minLength: 0)
                    LegendDot(color: .positive, text: "In " + Fmt.compact(shown.income, currency))
                    LegendDot(color: .negative, text: "Out " + Fmt.compact(shown.spending, currency))
                }
                .frame(height: 24)
            }
            ChartContainer(height: 150) { plotWidth in
                let ticks = ChartTicks.fit(middles, width: plotWidth, labelWidth: 56)
                let activeTick = ChartTicks.nearest(ticks, to: chosen.flatMap { c in
                    calendar.dateInterval(of: .month, for: c.date).map { $0.start.addingTimeInterval($0.duration / 2) }
                })
                Chart {
                    ForEach(months) { m in
                        let dim = chosen == nil || chosen?.date == m.date ? 1.0 : 0.35
                        BarMark(x: .value("Month", m.date, unit: .month), y: .value("In", scale.clamp(m.income)))
                            .foregroundStyle(Color.positive.opacity(dim)).position(by: .value("Kind", "In"))
                        BarMark(x: .value("Month", m.date, unit: .month), y: .value("Out", scale.clamp(m.spending)))
                            .foregroundStyle(Color.negative.opacity(0.7 * dim)).position(by: .value("Kind", "Out"))
                    }
                }
                .chartXSelection(value: $selected)
                .chartXAxis {
                    AxisMarks(values: ticks) { value in
                        AxisValueLabel(anchor: .top, collisionResolution: .disabled) {
                            if let date = value.as(Date.self) {
                                ChartTickLabel(text: date.formatted(.dateTime.month(.abbreviated)), active: date == activeTick)
                            }
                        }
                    }
                }
                .glassYAxis(scale) { Fmt.axis($0) }
            }
        }
    }
}

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
                && (search.isEmpty || t.payee.localizedCaseInsensitiveContains(search) || MerchantInfo.resolve(t).name.localizedCaseInsensitiveContains(search) || t.description.localizedCaseInsensitiveContains(search) || t.accountName.localizedCaseInsensitiveContains(search))
        }
        let byDay = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                if let flow = store.dashboard?.cashFlow, flow.count > 1, category == nil, search.isEmpty {
                    Card {
                        CashFlowChart(flow: flow, currency: store.currency)
                    }
                }
                ForEach(byDay, id: \.key) { day, items in
                    Card {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                            Spacer()
                            Text(Fmt.signed(items.filter { !$0.pending }.reduce(0) { $0 + $1.netEffect }, store.currency)).monospacedDigit()
                        }
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(items) { t in
                            TransactionRow(transaction: t, history: all) { retagging = t }
                                .contentShape(.rect)
                                .onTapGesture { retagging = t }
                        }
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
        .demoScroll()
        .hubPageStyle()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: $retagging) { t in
            CategoryPicker(transaction: t, options: store.categoryOptions, history: store.dashboard?.transactions ?? []) { c in
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
            .glassGlare(.regular, in: .capsule)
        }
    }
}
