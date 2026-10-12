import Charts
import SwiftUI

struct FinanceView: View {
    @Environment(AppSession.self) private var session
    @State private var store = FinanceStore()
    @State private var toast = Toast()
    @State private var retagging: Transaction?
    @State private var editingGoal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Finance")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                if store.response?.configured == true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await store.sync(api: session.api, toast: toast) }
                        } label: {
                            if store.syncing { ProgressView() } else { Label("Sync from SimpleFIN", systemImage: "arrow.clockwise") }
                        }
                        .disabled(store.syncing)
                    }
                }
            }
            .task { if store.response == nil { await store.load(api: session.api) } }
            .refreshable { await store.load(api: session.api) }
            .sheet(item: $retagging) { t in
                CategoryPicker(transaction: t, options: store.categoryOptions) { category in
                    Task { await store.retag(t, to: category, api: session.api, toast: toast) }
                }
            }
            .sheet(isPresented: $editingGoal) {
                GoalEditor(goal: store.goal) { goal in
                    Task { await store.saveGoal(goal, api: session.api, toast: toast) }
                }
            }
            .toast(toast)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let r = store.response {
            if !r.configured {
                MessageView(title: "Connect SimpleFIN", systemImage: "building.columns",
                            message: "Set SIMPLEFIN_ACCESS_URL on the hub to see your accounts.")
            } else if r.hasData != true {
                MessageView(title: "No data yet", systemImage: "tray",
                            message: r.sync?.failureReason ?? "SimpleFIN is connected, but nothing has synced yet. Sync to pull your history.",
                            actionTitle: "Sync now") { Task { await store.sync(api: session.api, toast: toast) } }
            } else if let d = r.dashboard {
                overview(r, d)
            }
        } else if let error = store.error {
            MessageView(title: "Couldn't load finances", systemImage: "exclamationmark.triangle", message: error,
                        actionTitle: "Try again") { Task { await store.load(api: session.api) } }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    @ViewBuilder
    private func overview(_ r: FinanceResponse, _ d: Dashboard) -> some View {
        let money = { (v: Double) in Fmt.compact(v, d.currency) }
        let month = Date.now.formatted(.dateTime.month(.wide))
        let pace = d.monthSpending.total - d.monthSpending.lastMonthToDate
        let cards = d.accounts.filter(\.isLiability)

        if let ms = r.sync?.lastSuccessAt {
            Text("Synced \(Fmt.relative(ms: ms))").font(.footnote).foregroundStyle(.secondary)
        }
        if let failure = r.sync?.failureReason {
            ErrorBanner(message: "Last sync failed: \(failure) Showing the most recent stored data.")
        }
        ForEach(d.errors, id: \.self) { ErrorBanner(message: $0) }

        VStack(spacing: 10) {
            SummaryTile(label: "Spent in \(month)", value: money(d.monthSpending.total),
                        detail: abs(pace) < 1 ? "Same pace as last month" : "\(money(abs(pace))) \(pace > 0 ? "more" : "less") than this point last month",
                        tone: pace > 0 ? .negative : .positive)
            HStack(spacing: 10) {
                SummaryTile(label: "Cash", value: money(d.cash),
                            detail: d.totalLiabilities > 0 ? "\(money(d.totalLiabilities)) owed on \(cards.count) card\(cards.count == 1 ? "" : "s")" : "Nothing owed on cards")
                SummaryTile(label: "Net worth", value: money(d.netWorth), detail: "Cash and investments, minus cards")
            }
        }

        if !d.toReview.isEmpty {
            ReviewCard(transactions: d.toReview, quick: r.quickCategories, currency: d.currency,
                       onPick: { t, c in Task { await store.retag(t, to: c, api: session.api, toast: toast) } },
                       onMore: { retagging = $0 },
                       onConfirmAll: { Task { await store.confirmAll(api: session.api, toast: toast) } })
        }

        if let history = r.history {
            GoalCard(netWorth: d.netWorth, history: history, goal: store.goal, currency: d.currency) { editingGoal = true }
        }

        MonthSpendingCard(month: month, items: d.monthSpending.byCategory, currency: d.currency)

        if let recurring = r.recurring, !recurring.isEmpty {
            SubscriptionsCard(charges: recurring, currency: d.currency) { c in
                Task { await store.ignoreRecurring(c, api: session.api, toast: toast) }
            }
        }

        AccountsCard(accounts: d.accounts)

        NavigationLink {
            TransactionsView(store: store, toast: toast)
        } label: {
            HStack {
                Label("All transactions", systemImage: "list.bullet.rectangle")
                Spacer()
                Text("\(d.transactions.count)").foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)

        Card(title: "Recent") {
            ForEach(d.transactions.prefix(8)) { t in
                TransactionRow(transaction: t) { retagging = t }
                if t.id != d.transactions.prefix(8).last?.id { Divider() }
            }
        }
    }
}

struct SummaryTile: View {
    enum Tone { case neutral, positive, negative }
    let label: String
    let value: String
    let detail: String
    var tone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption)
                .foregroundStyle(tone == .negative ? Color.negative : tone == .positive ? Color.positive : .secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    var onTag: (() -> Void)?

    var body: some View {
        let t = transaction
        HStack(spacing: 12) {
            Image(systemName: CategoryStyle.symbol(t.category))
                .frame(width: 34, height: 34)
                .foregroundStyle(CategoryStyle.color(t.category))
                .background(CategoryStyle.color(t.category).opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.payee).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Button { onTag?() } label: {
                        Text(t.category).underline(onTag != nil, pattern: .dot)
                    }
                    .buttonStyle(.plain)
                    .disabled(onTag == nil)
                    Text("·")
                    Text(Fmt.shortDate(t.date))
                    if t.pending { Text("· Pending") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.signed(t.netEffect, t.currency))
                .font(.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(t.netEffect > 0 ? Color.positive : .primary)
        }
        .opacity(t.hold ? 0.5 : 1)
    }
}

struct ReviewCard: View {
    let transactions: [Transaction]
    let quick: QuickCategories?
    let currency: String
    let onPick: (Transaction, String) -> Void
    let onMore: (Transaction) -> Void
    let onConfirmAll: () -> Void

    var body: some View {
        Card(title: "To review", trailing: "\(transactions.count) new") {
            Text("Check the suggested tag on new transactions. Tags you pick are remembered for that merchant.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(transactions.prefix(6)) { t in
                VStack(alignment: .leading, spacing: 8) {
                    TransactionRow(transaction: t) { onMore(t) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips(for: t), id: \.self) { c in
                                Button(c) { onPick(t, c) }
                                    .font(.caption.weight(.medium))
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .tint(c == t.category ? CategoryStyle.color(c) : .secondary)
                            }
                            Button("More…") { onMore(t) }.font(.caption).buttonStyle(.borderless)
                        }
                    }
                }
                Divider()
            }
            Button("Looks good, keep all \(transactions.count)", action: onConfirmAll)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    private func chips(for t: Transaction) -> [String] {
        let ranked = (t.netEffect > 0 ? quick?.in : quick?.out) ?? []
        var list = [t.category]
        for c in ranked where !list.contains(c) && c != "Uncategorized" { list.append(c) }
        return Array(list.prefix(5))
    }
}

private struct GoalCard: View {
    let netWorth: Double
    let history: History
    let goal: GoalSettings
    let currency: String
    let onEdit: () -> Void

    var body: some View {
        let p = GoalMath.project(current: netWorth, series: history.series, goal: goal)
        Card(title: "Net worth goal", trailing: Fmt.compact(goal.target, currency)) {
            Chart(history.series) { point in
                AreaMark(x: .value("Day", point.day), y: .value("Net worth", point.value))
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", point.day), y: .value("Net worth", point.value))
                    .interpolationMethod(.monotone)
            }
            .chartYAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.axis(d)) } } } }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
            .frame(height: 140)

            ProgressView(value: p.progress) {
                HStack {
                    Text("\(Int(p.progress * 100))% of the way").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(history.source == "recorded" ? "Recorded" : "Estimated from transactions").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if let date = p.targetDate {
                    Text("At \(Fmt.compact(p.monthly, currency))/mo and \(goal.annualReturnPct.formatted())%: **\(date.formatted(.dateTime.month(.wide).year()))** (\(GoalMath.duration(p.invested.months)))")
                } else {
                    Text("At \(Fmt.compact(p.monthly, currency))/mo, the goal isn't reached within 100 years.")
                }
                Text("In cash only: \(GoalMath.duration(p.cash.months))").foregroundStyle(.secondary)
                ForEach(p.boosts, id: \.extra) { b in
                    Text("+\(Fmt.compact(b.extra, currency))/mo: \(GoalMath.duration(b.months))").foregroundStyle(.secondary)
                }
                if let observed = p.observedMonthly, goal.monthlyContribution != nil {
                    Text("You've been saving about \(Fmt.compact(observed, currency))/mo lately.").foregroundStyle(.secondary)
                }
            }
            .font(.footnote)

            Button("Edit goal", systemImage: "pencil", action: onEdit).font(.subheadline)
        }
    }
}

private struct GoalEditor: View {
    @State var goal: GoalSettings
    let onSave: (GoalSettings) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var useObserved: Bool

    init(goal: GoalSettings, onSave: @escaping (GoalSettings) -> Void) {
        _goal = State(initialValue: goal)
        _useObserved = State(initialValue: goal.monthlyContribution == nil)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    TextField("Target", value: $goal.target, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .keyboardType(.numberPad)
                }
                Section("Monthly savings") {
                    Toggle("Use what I've actually been saving", isOn: $useObserved)
                    if !useObserved {
                        TextField("Per month", value: Binding(get: { goal.monthlyContribution ?? 0 }, set: { goal.monthlyContribution = $0 }),
                                  format: .currency(code: "USD").precision(.fractionLength(0)))
                            .keyboardType(.numberPad)
                    }
                }
                Section("Expected annual return") {
                    Stepper("\(goal.annualReturnPct.formatted())%", value: $goal.annualReturnPct, in: 0...30, step: 0.5)
                }
            }
            .navigationTitle("Net worth goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if useObserved { goal.monthlyContribution = nil }
                        onSave(goal)
                        dismiss()
                    }
                    .disabled(goal.target < 1_000)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MonthSpendingCard: View {
    let month: String
    let items: [CategoryAmount]
    let currency: String

    var body: some View {
        let total = items.reduce(0) { $0 + $1.amount }
        Card(title: "Where \(month) went", trailing: Fmt.compact(total, currency)) {
            if items.isEmpty {
                Text("No spending yet this month.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Chart(items) { item in
                    BarMark(x: .value("Amount", item.amount), stacking: .normalized)
                        .foregroundStyle(CategoryStyle.color(item.category))
                }
                .chartXAxis(.hidden)
                .frame(height: 14)
                .clipShape(.capsule)

                ForEach(items) { item in
                    HStack {
                        Circle().fill(CategoryStyle.color(item.category)).frame(width: 8, height: 8)
                        Text(item.category).font(.subheadline)
                        Spacer()
                        Text(Fmt.compact(item.amount, currency)).font(.subheadline).monospacedDigit()
                        Text(total > 0 ? "\(Int((item.amount / total * 100).rounded()))%" : "")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private struct SubscriptionsCard: View {
    let charges: [RecurringCharge]
    let currency: String
    let onIgnore: (RecurringCharge) -> Void

    var body: some View {
        let monthly = charges.reduce(0) { $0 + $1.monthlyCost }
        Card(title: "Subscriptions & bills", trailing: "\(Fmt.compact(monthly, currency))/mo") {
            ForEach(charges.prefix(8)) { c in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("\(c.cadence.capitalized) · next \(Fmt.shortDate(Date(timeIntervalSince1970: c.nextExpected)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.currency(c.amount, currency)).font(.subheadline).monospacedDigit()
                        if let prev = c.previousAmount {
                            Text("was \(Fmt.currency(prev, currency))").font(.caption).foregroundStyle(Color.negative)
                        }
                    }
                }
                .contextMenu {
                    Button("Not recurring", systemImage: "eye.slash") { onIgnore(c) }
                }
            }
            if charges.count > 8 {
                Text("+ \(charges.count - 8) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AccountsCard: View {
    let accounts: [Account]

    var body: some View {
        Card(title: "Accounts") {
            ForEach(accounts) { a in
                HStack {
                    Image(systemName: icon(a.kind)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(a.institution).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.currency(a.isLiability ? -a.magnitude : a.rawBalance, a.currency))
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(a.isLiability ? Color.negative : .primary)
                }
            }
        }
    }

    private func icon(_ kind: AccountKind) -> String {
        switch kind {
        case .cash: return "banknote"
        case .credit: return "creditcard"
        case .loan: return "building.columns"
        case .investment: return "chart.line.uptrend.xyaxis"
        }
    }
}

/// Pick or type a tag for a transaction.
struct CategoryPicker: View {
    let transaction: Transaction
    let options: [String]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TransactionRow(transaction: transaction)
                }
                Section("Tag") {
                    ForEach(options, id: \.self) { c in
                        Button {
                            onPick(c)
                            dismiss()
                        } label: {
                            HStack {
                                Label(c, systemImage: CategoryStyle.symbol(c)).foregroundStyle(.primary)
                                Spacer()
                                if c == transaction.category { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                Section("New tag") {
                    HStack {
                        TextField("Name", text: $custom).submitLabel(.done).onSubmit(addCustom)
                        Button("Add", action: addCustom).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func addCustom() {
        let name = custom.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40 else { return }
        onPick(name)
        dismiss()
    }
}
