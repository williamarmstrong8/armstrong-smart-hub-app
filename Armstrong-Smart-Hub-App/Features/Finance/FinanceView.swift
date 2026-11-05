import SwiftUI

/// Finance on the iPhone, kept to what matters: what this month cost, new
/// transactions to tag with one tap, where the money went, and the accounts.
struct FinanceView: View {
    @Environment(AppSession.self) private var session
    @State private var store = FinanceStore()
    @State private var toast = Toast()
    @State private var retagging: Transaction?
    /// All transactions, opened on top.
    @State private var showingAll = false

    var body: some View {
        NavigationStack {
            HubTabPage(topBar: { topBar }, content: {
                content
            })
            .toolbarBackground(HubDesign.page, for: .navigationBar)
            .toolbar(.hidden, for: .navigationBar)
            .task { if !store.fetched { await store.load(api: session.api) } }
            .refreshable { await store.load(api: session.api) }
            .sheet(item: $retagging) { t in
                CategoryPicker(transaction: t, options: store.categoryOptions) { category in
                    Task { await store.retag(t, to: category, api: session.api, toast: toast) }
                }
            }
            .navigationDestination(isPresented: $showingAll) { TransactionsView(store: store, toast: toast) }
            #if DEBUG
            .onAppear {
                DemoCue.on("nav", arg: { name in if name == "transactions" { showingAll = true } })
                DemoCue.on("back") { showingAll = false }
                // `tag`: the next card takes its first suggestion. `tag.other` opens the picker; `tag.pick <Tag>` chooses.
                DemoCue.on("tag") {
                    guard let next = store.tagQueue.first else { return }
                    let pick = next.category == "Uncategorized" ? (store.response?.quickCategories?.out.first ?? "Food & Drinks") : next.category
                    Task { await store.retag(next, to: pick, api: session.api, toast: toast) }
                }
                DemoCue.on("tag.other") { retagging = store.tagQueue.first }
                DemoCue.on("tag.pick", arg: { category in
                    guard let t = retagging else { return }
                    retagging = nil
                    Task { await store.retag(t, to: category, api: session.api, toast: toast) }
                })
            }
            #endif
            .toast(toast)
        }
    }

    private var topBar: some View {
        BrickTopBar {
            if store.response?.configured == true {
                Button {
                    Task { await store.sync(api: session.api, toast: toast) }
                } label: {
                    if store.syncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.syncing)
                .accessibilityLabel("Sync")
            }
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
                            message: r.sync?.failureReason ?? "SimpleFIN is connected, but nothing has synced yet.",
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

        if let failure = r.sync?.failureReason {
            ErrorBanner(message: "Last sync failed: \(failure)")
        }

        BrickHero(caption: "Spent in \(month)", title: money(d.monthSpending.total),
                  subtitle: abs(pace) < 1 ? "Same pace as last month" : "\(money(abs(pace))) \(pace > 0 ? "more" : "less") than last month by now",
                  subtitleColor: pace > 0 ? Color.negative : Color.positive) {
            BrickPill(text: money(d.cash), icon: "banknote")
            BrickPill(text: money(d.netWorth), icon: "chart.line.uptrend.xyaxis")
        }

        if let next = store.tagQueue.first {
            TagCard(transaction: next, remaining: store.tagQueue.count, quick: r.quickCategories) { category in
                Task { await store.retag(next, to: category, api: session.api, toast: toast) }
            } onOther: {
                retagging = next
            }
        }

        MonthBars(items: d.monthSpending.byCategory, currency: d.currency)

        AccountsCard(accounts: d.accounts)

        Button { showingAll = true } label: {
            VStack(spacing: 16) {
                Divider()
                HStack {
                    Text("All transactions").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One new transaction at a time with its three likeliest tags: tap one to
/// replace the current card. "Other" opens the full list.
private struct TagCard: View {
    let transaction: Transaction
    let remaining: Int
    let quick: QuickCategories?
    let onTag: (String) -> Void
    let onOther: () -> Void

    var body: some View {
        let t = transaction
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tag this").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(remaining) left").font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.payee).font(.title3.weight(.semibold)).lineLimit(1)
                    Text("\(Fmt.shortDate(t.date)) · \(t.accountName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Fmt.signed(t.netEffect, t.currency))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(t.netEffect > 0 ? Color.positive : .primary)
            }
            HStack(spacing: 8) {
                ForEach(likely, id: \.self) { c in
                    Button { onTag(c) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: CategoryStyle.symbol(c)).font(.title3).foregroundStyle(.secondary)
                            Text(c).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(HubDesign.raised, in: .rect(cornerRadius: HubLayout.controlRadius))
                    }
                    .buttonStyle(CardPressStyle())
                }
            }
            Button(action: onOther) {
                Text("Something else")
                    .font(.footnote)
                    .foregroundStyle(HubDesign.action)
                    .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(HubLayout.cardPadding)
        .background(HubDesign.surface, in: .rect(cornerRadius: HubLayout.cardRadius))
        .sensoryFeedback(.selection, trigger: transaction.id)
    }

    /// The suggestion first, then the tags used most for money in or out.
    private var likely: [String] {
        let t = transaction
        let ranked = (t.netEffect > 0 ? quick?.in : quick?.out) ?? []
        var list: [String] = t.category == "Uncategorized" ? [] : [t.category]
        for c in ranked + builtInCategories where !list.contains(c) && c != "Uncategorized" && c != "Transfers" { list.append(c) }
        return Array(list.prefix(3))
    }
}

/// Where the month went, as the web's bars: income, each category against its
/// budget, and what's left to invest.
private struct MonthBars: View {
    let items: [CategoryAmount]
    let currency: String

    /// Monthly budgets, as on the web (components/dashboard/month-spending.tsx).
    private static let budgets: [String: Double] = ["Lifestyle": 300, "Food & Drinks": 300, "Groceries": 200, "Transport": 150]
    /// The web's placeholder monthly income.
    private static let income = 5842.6

    private struct Row: Identifiable {
        let category: String
        let amount: Double
        var budget: Double?
        var kind: Kind = .spend
        enum Kind { case income, spend, invest }
        var id: String { category }
    }

    var body: some View {
        let top = items.prefix(6)
        let rest = items.dropFirst(6).reduce(0) { $0 + $1.amount }
        var rows = top.map { Row(category: $0.category, amount: $0.amount, budget: Self.budgets[$0.category]) }
        if rest > 0 { rows.append(Row(category: "Everything else", amount: rest)) }
        let spent = rows.reduce(0) { $0 + $1.amount }
        let sheet = [Row(category: "Income", amount: Self.income, kind: .income)] + rows
            + [Row(category: "Invest", amount: max(Self.income - spent, 0), kind: .invest)]

        return VStack(alignment: .leading, spacing: 18) {
            if items.isEmpty {
                Text("No spending yet this month.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(sheet) { row in
                    let over = row.budget.map { row.amount > $0 } ?? false
                    let fill: Double = row.kind == .income || (row.budget == nil && (row.category == "Rent" || row.category == "Bills & Utilities"))
                        ? 1 : row.budget.map { row.amount / $0 } ?? row.amount / Self.income
                    let color: Color = row.kind == .income ? .positive : over ? .negative : .accentColor
                    HStack(spacing: 14) {
                        Image(systemName: row.kind == .invest ? "chart.line.uptrend.xyaxis" : CategoryStyle.symbol(row.category))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.category).font(.subheadline.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text((row.kind == .income ? "+" : "") + Fmt.compact(row.amount, currency))
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                                if let budget = row.budget {
                                    Text("/ \(Fmt.compact(budget, currency))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(HubDesign.track)
                                    Capsule().fill(color).frame(width: geo.size.width * min(max(fill, 0.02), 1))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
    }
}

/// Accounts with their bank's logo and balance.
private struct AccountsCard: View {
    let accounts: [Account]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text("Accounts").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(accounts) { a in
                HStack(spacing: 14) {
                    BankLogo(institution: a.institution, kind: a.kind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(a.institution).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.compact(a.isLiability ? -a.magnitude : a.rawBalance, a.currency))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(a.isLiability ? Color.negative : .primary)
                }
            }
        }
    }
}

/// The bank's logo, like the web's BankLogo: bundled art for Amex and Discover,
/// otherwise the bank site's icon, falling back to a symbol for the account kind.
struct BankLogo: View {
    let institution: String
    let kind: AccountKind

    @Environment(AppSession.self) private var session

    private static let domains: [(String, String)] = [
        ("chase", "chase.com"), ("bank of america|bofa", "bankofamerica.com"), ("wells\\s?fargo", "wellsfargo.com"),
        ("citi", "citi.com"), ("capital\\s?one", "capitalone.com"), ("american express|amex", "americanexpress.com"),
        ("discover", "discover.com"), ("ally", "ally.com"), ("schwab", "schwab.com"), ("fidelity", "fidelity.com"),
        ("vanguard", "vanguard.com"), ("robinhood", "robinhood.com"), ("e\\*?trade", "etrade.com"),
        ("td\\s?bank|td ameritrade", "td.com"), ("pnc", "pnc.com"), ("u\\.?s\\.? bank", "usbank.com"),
        ("navy federal", "navyfederal.org"), ("usaa", "usaa.com"), ("sofi", "sofi.com"), ("marcus|goldman", "marcus.com"),
        ("apple", "apple.com"), ("venmo", "venmo.com"), ("paypal", "paypal.com"), ("coinbase", "coinbase.com"),
        ("citizens", "citizensbank.com"), ("santander", "santander.us"), ("hsbc", "us.hsbc.com"), ("mercury", "mercury.com"),
        ("wealthfront", "wealthfront.com"), ("betterment", "betterment.com"),
    ]
    private static let local: [(String, String)] = [("american express|amex", "/logos/amex.png"), ("discover", "/logos/discover.png")]

    private var url: URL? {
        func match(_ pattern: String) -> Bool { institution.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if let path = Self.local.first(where: { match($0.0) })?.1 { return session.webURL(path) }
        if let domain = Self.domains.first(where: { match($0.0) })?.1 {
            return URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128")
        }
        return nil
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().clipShape(.rect(cornerRadius: 8))
            } else {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var symbol: String {
        switch kind {
        case .cash: "banknote"
        case .credit: "creditcard"
        case .loan: "building.columns"
        case .investment: "chart.line.uptrend.xyaxis"
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    var onTag: (() -> Void)?

    var body: some View {
        let t = transaction
        HStack(spacing: 12) {
            Image(systemName: CategoryStyle.symbol(t.category))
                .font(.body)
                .frame(width: 24)
                .foregroundStyle(.secondary)
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
                .listRowBackground(BrickLook.card)
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
                .listRowBackground(BrickLook.card)
                Section("New tag") {
                    HStack {
                        TextField("Name", text: $custom).submitLabel(.done).onSubmit(addCustom)
                        Button("Add", action: addCustom).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .listRowBackground(BrickLook.card)
            }
            .brickList()
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
