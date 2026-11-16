import Charts
import SwiftUI

/// Brokerage positions across every connected account (Fidelity, Wells Fargo, …):
/// what it's all worth, how it's split, what's up and down, and each holding.
/// Opened from the Investments card on Finance.
struct InvestmentsView: View {
    let store: HoldingsStore
    let finance: FinanceStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @State private var sort: HoldingSort = .value
    @State private var opened: Holding?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let r = store.response, r.hasHoldings == true, let totals = r.totals {
                    header(r, totals)
                    Card(title: "Value") {
                        HoldingLineChart(points: r.history ?? [], color: HubDesign.action)
                    }
                    if let allocation = r.allocation, !allocation.isEmpty {
                        Card(title: "Allocation") { AllocationDonut(slices: allocation, total: totals.value) }
                    }
                    let positions = r.positions ?? []
                    if positions.contains(where: { !$0.isCash && $0.gainPct != nil }) {
                        Card(title: "Gain since bought") { GainBars(positions: positions) }
                    }
                    if let accounts = r.accounts, !accounts.isEmpty {
                        BrokerageAccounts(accounts: accounts)
                    }
                    positionsCard(positions)
                } else if let error = store.error, store.response == nil {
                    MessageView(title: "Couldn't load positions", systemImage: "exclamationmark.triangle", message: error,
                                actionTitle: "Try again") { Task { await store.load(api: session.api) } }
                } else if store.fetched || store.response != nil {
                    MessageView(title: "No positions yet", systemImage: "chart.pie",
                                message: "SimpleFIN hasn't reported holdings for any brokerage account. Pull to sync.")
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.horizontal, Fit.gutter)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .demoScroll()
        .hubPageStyle()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await store.load(api: session.api) }
        .refreshable {
            await finance.sync(api: session.api, toast: toast)
            await store.load(api: session.api)
        }
        .navigationDestination(item: $opened) { HoldingDetailView(holding: $0, total: store.response?.totals?.value ?? 0) }
    }

    private func header(_ r: HoldingsResponse, _ t: HoldingsTotals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Investments").font(.system(size: 34, weight: .light)).accessibilityAddTraits(.isHeader)
            Text(Fmt.compact(t.value)).font(Fit.number(52))
            HStack(spacing: 8) {
                ChangePill(amount: t.gain, pct: t.gainPct, label: "all time")
                if let day = t.dayChange { ChangePill(amount: day, pct: t.dayChangePct, label: "today") }
            }
            HStack(spacing: 14) {
                LegendDot(color: HubDesign.action, text: "Invested " + Fmt.compact(t.invested))
                LegendDot(color: AssetClassColor.of("Cash"), text: "Cash " + Fmt.compact(t.cash))
            }
            if let asOf = r.asOf {
                Text("Prices as of " + Fmt.relative(ms: asOf * 1000)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func positionsCard(_ positions: [Holding]) -> some View {
        let sorted = sort.apply(positions)
        return Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Positions").font(.headline)
                    Text("\(positions.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(HoldingSort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sort.title)
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .font(.footnote.weight(.medium))
                    }
                }
                .padding(.bottom, 8)
                ForEach(sorted) { h in
                    Button { opened = h } label: { HoldingRow(holding: h) }
                        .buttonStyle(.plain)
                    if h.id != sorted.last?.id { Divider().overlay(Fit.hairline) }
                }
            }
        }
    }
}

extension Holding: Hashable {
    static func == (a: Holding, b: Holding) -> Bool { a.symbol == b.symbol && a.marketValue == b.marketValue }
    func hash(into hasher: inout Hasher) { hasher.combine(symbol) }
}

enum HoldingSort: String, CaseIterable, Identifiable {
    case value, gain, gainPct, today, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .value: "Value"
        case .gain: "Gain $"
        case .gainPct: "Gain %"
        case .today: "Today"
        case .name: "A–Z"
        }
    }
    func apply(_ list: [Holding]) -> [Holding] {
        switch self {
        case .value: list.sorted { $0.marketValue > $1.marketValue }
        case .gain: list.sorted { ($0.gain ?? -.infinity) > ($1.gain ?? -.infinity) }
        case .gainPct: list.sorted { ($0.gainPct ?? -.infinity) > ($1.gainPct ?? -.infinity) }
        case .today: list.sorted { ($0.dayChangePct ?? -.infinity) > ($1.dayChangePct ?? -.infinity) }
        case .name: list.sorted { $0.symbol < $1.symbol }
        }
    }
}

/// One color per asset class, shared by the donut, the badges and the bars.
enum AssetClassColor {
    static func of(_ assetClass: String) -> Color {
        switch assetClass {
        case "US stock funds": HubDesign.action
        case "International": HubDesign.adaptive(0x0F7C8C, 0x5FD3E0)
        case "Individual stocks": Fit.sleep
        case "Nuclear & uranium": Fit.readiness
        case "Energy": Fit.activity
        case "Gold": HubDesign.adaptive(0x8C6D1F, 0xD9B45A)
        case "Bonds": Fit.health
        case "Cash": HubDesign.adaptive(0x8A827D, 0x9C948F)
        default: HubDesign.adaptive(0x6B5B95, 0xA898D6)
        }
    }
}

enum Pct {
    static func signed(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(abs(value) >= 10 ? 0 : 1)).sign(strategy: .always(includingZero: false)))
    }
    static func plain(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(value < 0.01 && value > 0 ? 1 : 0)))
    }
}

/// "+$1,875 · +17.9% all time" on glass, green or red.
private struct ChangePill: View {
    let amount: Double
    let pct: Double?
    let label: String

    var body: some View {
        let color: Color = amount >= 0 ? .positive : .negative
        HStack(spacing: 4) {
            Image(systemName: amount >= 0 ? "arrow.up.right" : "arrow.down.right").font(.caption2.weight(.bold))
            Text((amount < 0 ? "−" : "+") + Fmt.compact(abs(amount)) + (pct.map { " · " + Pct.signed($0) } ?? ""))
                .monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

/// The ticker on a tile in its asset class's color.
struct SymbolBadge: View {
    let symbol: String
    let assetClass: String
    var size: CGFloat = 44

    var body: some View {
        let color = AssetClassColor.of(assetClass)
        Text(symbol.prefix(5))
            .font(.system(size: symbol.count > 4 ? 10 : 12, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

private struct HoldingRow: View {
    let holding: Holding

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: holding.symbol, assetClass: holding.assetClass)
            VStack(alignment: .leading, spacing: 2) {
                Text(holding.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(holding.isCash
                     ? "Cash · \(Pct.plain(holding.weight))"
                     : "\(shareCount(holding.shares)) sh · \(Fmt.currency(holding.price)) · \(Pct.plain(holding.weight))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.currency(holding.marketValue)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let pct = holding.gainPct, let gain = holding.gain {
                    Text(Pct.signed(pct)).font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(gain >= 0 ? Color.positive : .negative)
                } else if holding.isCash {
                    Text("Cash").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

func shareCount(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...3)))
}

/// Portfolio (or one position) value per day, from the hub's daily snapshots.
struct HoldingLineChart: View {
    let points: [SeriesPoint]
    let color: Color

    @State private var selected: Date?

    var body: some View {
        let days = points.map { DayValue(date: $0.day, value: $0.value) }.sorted { $0.date < $1.date }
        if days.count < 2 {
            VStack(alignment: .leading, spacing: 6) {
                if let only = days.last {
                    Text(Fmt.compact(only.value)).font(Fit.value)
                    Text(only.date.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
                }
                Text("The chart fills in a day at a time: each sync records what every position is worth.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            let chosen = selected.flatMap { s in days.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
            let shown = chosen ?? days.last!
            let first = days.first!.value
            let scale = ChartScale(low: days.map(\.value).min() ?? 0, high: days.map(\.value).max() ?? 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.compact(shown.value)).font(Fit.value)
                    if first > 0 {
                        let change = shown.value - first
                        Text(Pct.signed(change / first)).font(.footnote.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(change >= 0 ? Color.positive : .negative)
                    }
                    Spacer()
                    Text(shown.date.formatted(.dateTime.month(.abbreviated).day())).font(Fit.label).foregroundStyle(Fit.muted)
                }
                ChartContainer(height: 160) { plotWidth in
                    let ticks = ChartTicks.fit(days.map(\.date), width: plotWidth, labelWidth: 52)
                    Chart {
                        ForEach(days) { d in
                            AreaMark(x: .value("Day", d.date), yStart: .value("Base", scale.domain.lowerBound), yEnd: .value("Value", scale.clamp(d.value)))
                                .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Day", d.date), y: .value("Value", scale.clamp(d.value)))
                                .foregroundStyle(color)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                        if let chosen {
                            RuleMark(x: .value("Day", chosen.date)).foregroundStyle(Fit.hairline)
                            PointMark(x: .value("Day", chosen.date), y: .value("Value", scale.clamp(chosen.value)))
                                .foregroundStyle(color).symbolSize(50)
                        }
                    }
                    .chartXSelection(value: $selected)
                    .glassXLabels(ticks, active: ChartTicks.nearest(ticks, to: chosen?.date)) { $0.formatted(.dateTime.month(.abbreviated).day()) }
                    .glassYAxis(scale) { Fmt.axis($0) }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

/// How the money is split by asset class: a donut, then the classes as rows.
/// Touch a slice to read it in the middle.
private struct AllocationDonut: View {
    let slices: [AllocationSlice]
    let total: Double

    @State private var angle: Double?

    var body: some View {
        let picked = pick(angle)
        VStack(spacing: 18) {
            Chart(slices) { s in
                SectorMark(angle: .value("Value", s.value), innerRadius: .ratio(0.64), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(AssetClassColor.of(s.assetClass))
                    .opacity(picked == nil || picked?.id == s.id ? 1 : 0.35)
            }
            .chartAngleSelection(value: $angle)
            .chartLegend(.hidden)
            .frame(height: 200)
            .chartBackground { _ in
                VStack(spacing: 2) {
                    Text(picked?.assetClass ?? "Total").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.compact(picked?.value ?? total)).font(.title3.weight(.semibold)).monospacedDigit()
                    if let picked { Text(Pct.plain(picked.share)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
            }
            VStack(spacing: 10) {
                ForEach(slices) { s in
                    HStack(spacing: 10) {
                        Circle().fill(AssetClassColor.of(s.assetClass)).frame(width: 9, height: 9)
                        Text(s.assetClass).font(.subheadline)
                        Spacer()
                        Text(Fmt.compact(s.value)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        Text(Pct.plain(s.share)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// The slice under the finger: SectorMark's selection value is a running total.
    private func pick(_ angle: Double?) -> AllocationSlice? {
        guard let angle else { return nil }
        var running = 0.0
        for s in slices {
            running += s.value
            if angle <= running { return s }
        }
        return nil
    }
}

/// Each position's gain over what was paid, best to worst, as bars from zero.
private struct GainBars: View {
    let positions: [Holding]

    var body: some View {
        let rows = positions.filter { !$0.isCash && $0.gainPct != nil }.sorted { ($0.gainPct ?? 0) > ($1.gainPct ?? 0) }
        let up = rows.filter { ($0.gainPct ?? 0) >= 0 }.count
        let maxAbs = max(rows.map { abs($0.gainPct ?? 0) }.max() ?? 1, 0.0001)
        VStack(alignment: .leading, spacing: 10) {
            Text("\(up) up, \(rows.count - up) down").font(.footnote).foregroundStyle(.secondary)
            ForEach(rows) { h in
                let pct = h.gainPct ?? 0
                let color: Color = pct >= 0 ? .positive : .negative
                HStack(spacing: 10) {
                    Text(h.symbol).font(.caption.weight(.semibold)).frame(width: 50, alignment: .leading)
                    GeometryReader { geo in
                        let half = geo.size.width / 2
                        let width = max(half * abs(pct) / maxAbs, 2)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Fit.hairline).frame(width: 1).offset(x: half)
                            Capsule().fill(color)
                                .frame(width: width, height: 8)
                                .offset(x: pct >= 0 ? half : half - width)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 14)
                    Text(Pct.signed(pct)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(h.symbol), \(Pct.signed(pct))")
            }
        }
    }
}

/// Each brokerage account: what its positions are worth and their gain.
private struct BrokerageAccounts: View {
    let accounts: [HoldingsAccount]

    var body: some View {
        Card(title: "Accounts") {
            VStack(spacing: 14) {
                ForEach(accounts) { a in
                    HStack(spacing: 14) {
                        BankLogo(institution: a.institution, kind: .investment)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("\(a.institution) · \(a.positions) positions").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Fmt.compact(a.value)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            if let pct = a.gainPct {
                                Text(Pct.signed(pct)).font(.caption.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(a.gain >= 0 ? Color.positive : .negative)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One position: its value over time, the numbers, and which accounts hold it.
struct HoldingDetailView: View {
    let holding: Holding
    let total: Double

    var body: some View {
        let h = holding
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    SymbolBadge(symbol: h.symbol, assetClass: h.assetClass, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.symbol).font(.system(size: 30, weight: .light))
                        Text(h.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(Fmt.currency(h.marketValue)).font(Fit.number(44))
                    if let gain = h.gain, !h.isCash {
                        let color: Color = gain >= 0 ? .positive : .negative
                        Text(Fmt.signed(gain) + (h.gainPct.map { " (\(Pct.signed($0)))" } ?? "") + " since bought")
                            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                    }
                    Text(h.assetClass).font(.caption.weight(.semibold))
                        .foregroundStyle(AssetClassColor.of(h.assetClass))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                }
                Card(title: "Value") { HoldingLineChart(points: h.history, color: AssetClassColor.of(h.assetClass)) }
                Card(title: "Details") {
                    let stats: [(String, String)] = [
                        ("Shares", shareCount(h.shares)),
                        ("Price", Fmt.currency(h.price)),
                        ("Avg cost", h.avgCost.map { Fmt.currency($0) } ?? "—"),
                        ("Cost basis", h.costBasis.map { Fmt.currency($0) } ?? "—"),
                        ("Today", h.dayChangePct.map { Pct.signed($0) } ?? "—"),
                        ("Of portfolio", Pct.plain(h.weight)),
                    ]
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 16) {
                        ForEach(stats, id: \.0) { stat in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stat.0).font(.caption).foregroundStyle(.secondary)
                                Text(stat.1).font(.body.weight(.medium)).monospacedDigit()
                            }
                        }
                    }
                    if let avg = h.avgCost, avg > 0, !h.isCash {
                        PriceVsCost(price: h.price, avgCost: avg).padding(.top, 8)
                    }
                }
                Card(title: "Held in") {
                    VStack(spacing: 14) {
                        ForEach(h.lots) { lot in
                            HStack(spacing: 14) {
                                BankLogo(institution: lot.institution, kind: .investment)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(lot.accountName).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(shareCount(lot.shares)) shares").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Fmt.currency(lot.marketValue)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Fit.gutter)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .hubPageStyle()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// Where today's price sits against the average paid: a track from the lower
/// of the two to the higher, with a marker for each.
private struct PriceVsCost: View {
    let price: Double
    let avgCost: Double

    var body: some View {
        let up = price >= avgCost
        let color: Color = up ? .positive : .negative
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let lo = min(price, avgCost) * 0.9, hi = max(price, avgCost) * 1.05
                let x = { (v: Double) in geo.size.width * (v - lo) / max(hi - lo, 0.0001) }
                ZStack(alignment: .leading) {
                    Capsule().fill(HubDesign.track).frame(height: 6)
                    Capsule().fill(color.opacity(0.6))
                        .frame(width: abs(x(price) - x(avgCost)), height: 6)
                        .offset(x: min(x(price), x(avgCost)))
                    Circle().fill(Fit.muted).frame(width: 10, height: 10).offset(x: x(avgCost) - 5)
                    Circle().fill(color).frame(width: 14, height: 14).offset(x: x(price) - 7)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            HStack {
                LegendDot(color: Fit.muted, text: "Paid " + Fmt.currency(avgCost))
                Spacer()
                LegendDot(color: color, text: "Now " + Fmt.currency(price))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
