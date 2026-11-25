import Charts
import SwiftUI

/// Positions across the connected investment accounts, with the everyday
/// brokerage kept apart from retirement accounts. One number, one line for
/// today and all time, the value chart, a slim allocation bar, then the
/// holdings as Stocks-style rows. Opened from the Investments card on Finance.
struct InvestmentsView: View {
    let store: HoldingsStore
    let finance: FinanceStore
    let toast: Toast
    var initialGroup: InvestmentGroup = .brokerage

    @Environment(AppSession.self) private var session
    @State private var sort: HoldingSort = .value
    @State private var opened: Holding?
    @State private var group: InvestmentGroup?

    var body: some View {
        let groups = store.response?.groups ?? []
        let chosen = group ?? (groups.contains(initialGroup) ? initialGroup : groups.first)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Investments").font(.system(size: 34, weight: .light)).accessibilityAddTraits(.isHeader)
                if store.hasHoldings, let p = store.portfolio(chosen), !p.isEmpty {
                    if groups.count > 1 {
                        Picker("Accounts", selection: Binding(get: { chosen ?? .brokerage }, set: { group = $0 })) {
                            ForEach(groups) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    header(p)
                    HoldingLineChart(points: p.history, color: (p.dayChange ?? 0) >= 0 ? .stockUp : .stockDown, compact: true)
                    AllocationBar(portfolio: p)
                    positionsList(p.positions)
                    if !p.accounts.isEmpty { BrokerageAccounts(accounts: p.accounts) }
                } else if let error = store.error, store.response == nil {
                    MessageView(title: "Couldn't load positions", systemImage: "exclamationmark.triangle", message: error,
                                actionTitle: "Try again") { Task { await store.load(api: session.api) } }
                } else if store.fetched || store.response != nil {
                    MessageView(title: "No positions yet", systemImage: "chart.line.uptrend.xyaxis",
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
        .navigationDestination(item: $opened) { HoldingDetailView(holding: $0, total: store.portfolio(chosen)?.value ?? 0) }
    }

    /// The value, then today's move and the all-time gain, each said once.
    private func header(_ p: Portfolio) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Fmt.currency(p.value)).font(Fit.number(48)).contentTransition(.numericText())
            if let day = p.dayChange {
                Text(Fmt.signed(day) + (p.dayChangePct.map { " (\(Pct.signed($0)))" } ?? "") + " today")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(day >= 0 ? Color.stockUp : .stockDown)
            }
            if p.gainPct != nil {
                Text(Fmt.signed(p.gain) + (p.gainPct.map { " (\(Pct.signed($0)))" } ?? "") + " since bought")
                    .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func positionsList(_ positions: [Holding]) -> some View {
        let sorted = sort.apply(positions)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Holdings").font(.headline)
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
            .padding(.bottom, 4)
            ForEach(sorted) { h in
                Divider().overlay(Fit.hairline)
                Button { opened = h } label: { HoldingRow(holding: h, quote: store.quotes[h.symbol]) }
                    .buttonStyle(.plain)
            }
            Divider().overlay(Fit.hairline)
        }
    }
}

/// How the money is split by asset class: one slim bar and a short legend.
private struct AllocationBar: View {
    let portfolio: Portfolio

    var body: some View {
        let slices = portfolio.allocation.filter { $0.share >= 0.005 }
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(slices, id: \.assetClass) { s in
                        AssetClassColor.of(s.assetClass)
                            .frame(width: max(geo.size.width * s.share - 2, 2))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(slices, id: \.assetClass) { s in
                    HStack(spacing: 6) {
                        Circle().fill(AssetClassColor.of(s.assetClass)).frame(width: 7, height: 7)
                        Text(s.assetClass).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(Pct.plain(s.share)).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Allocation: " + slices.map { "\($0.assetClass) \(Pct.plain($0.share))" }.joined(separator: ", "))
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

/// Apple Stocks-style row: symbol and name, a sparkline, then price over a filled change pill.
private struct HoldingRow: View {
    let holding: Holding
    let quote: Quote?

    var body: some View {
        let h = holding
        let price = quote?.price ?? h.price
        // Move since yesterday's close; without a live quote, the hub's per-share day change.
        let change: Double? = quote?.change ?? h.dayChange.flatMap { h.shares > 0 ? $0 / h.shares : nil }
        let pct: Double? = quote?.changePct ?? h.dayChangePct
        let up = (change ?? pct ?? 0) >= 0
        let color: Color = up ? .stockUp : .stockDown
        let line: [Double] = quote.map(\.series) ?? h.history.sorted { $0.day < $1.day }.map(\.value)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(h.symbol).font(.system(size: 20, weight: .bold)).lineLimit(1)
                Text(h.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TickerSparkline(values: line, color: color, reference: quote?.previousClose)
                .frame(width: 70, height: 34)
            VStack(alignment: .trailing, spacing: 4) {
                Text(price.formatted(.number.precision(.fractionLength(2)))).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                Text(changeText(change, pct))
                    .font(.system(size: 15, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(minWidth: 76)
                    .background(color, in: .rect(cornerRadius: 6))
            }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func changeText(_ change: Double?, _ pct: Double?) -> String {
        if let change {
            return (change < 0 ? "-" : "+") + abs(change).formatted(.number.precision(.fractionLength(2)))
        }
        if let pct { return Pct.signed(pct) }
        return "—"
    }
}

/// A small filled line with no axes; a dashed rule marks the reference (yesterday's close) when it's in range.
struct TickerSparkline: View {
    let values: [Double]
    let color: Color
    var reference: Double?

    var body: some View {
        if values.count < 2 {
            Rectangle().fill(color.opacity(0.35)).frame(height: 1).frame(maxHeight: .infinity)
        } else {
            let lo = min(values.min() ?? 0, reference ?? .infinity), hi = max(values.max() ?? 1, reference ?? -.infinity)
            let pad = max((hi - lo) * 0.08, 0.0001)
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("i", i), yStart: .value("Base", lo - pad), yEnd: .value("V", v))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("i", i), y: .value("V", v))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                if let reference {
                    RuleMark(y: .value("Prev", reference))
                        .foregroundStyle(color.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartLegend(.hidden)
        }
    }
}

extension Color {
    /// Stocks-app red and green for the change pill and sparkline.
    static let stockUp = Color(red: 0.19, green: 0.70, blue: 0.33)
    static let stockDown = Color(red: 0.92, green: 0.30, blue: 0.24)
}

func shareCount(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...3)))
}

/// Portfolio (or one position) value per day: today's shares at each day's public
/// close, back five years, or the sync snapshots when past prices couldn't load.
struct HoldingLineChart: View {
    let points: [SeriesPoint]
    let color: Color
    /// Under a header that already shows the value: no repeat of it, and nothing at all until there are two days.
    var compact = false

    @State private var selected: Date?
    @State private var window = 365

    /// The windows on offer, in days, and what each is called.
    private static let windows = [30, 90, 365, 1825]
    nonisolated private static func name(_ days: Int) -> String {
        switch days {
        case ..<60: "1M"
        case ..<180: "3M"
        case ..<1000: "1Y"
        default: "5Y"
        }
    }

    var body: some View {
        let all = points.map { DayValue(date: $0.day, value: $0.value) }.sorted { $0.date < $1.date }
        let span = all.count >= 2 ? all.last!.date.timeIntervalSince(all.first!.date) / 86_400 : 0
        // Each window that shows more than the one before it; past prices cover them all.
        let offered = Self.windows.enumerated().filter { i, _ in i == 0 || span > Double(Self.windows[i - 1]) + 7 }.map(\.element)
        let chosenWindow = offered.contains(window) ? window : (offered.last ?? window)
        let days = offered.count > 1 ? Self.trim(all, to: chosenWindow) : all
        if days.count < 2, compact {
            EmptyView()
        } else if days.count < 2 {
            VStack(alignment: .leading, spacing: 6) {
                if let only = days.last {
                    Text(Fmt.compact(only.value)).font(Fit.value)
                    Text(only.date.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
                }
                Text("Past prices couldn't load, so the chart fills in a day at a time with each sync.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            let chosen = selected.flatMap { s in days.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
            let shown = chosen ?? days.last!
            let first = days.first!.value
            let scale = ChartScale(low: days.map(\.value).min() ?? 0, high: days.map(\.value).max() ?? 1)
            // Over most of a year, days need their year and the axis reads in months.
            let long = days.last!.date.timeIntervalSince(days.first!.date) > 200 * 86_400
            let dayText: (Date) -> String = { long ? $0.formatted(.dateTime.month(.abbreviated).day().year()) : $0.formatted(.dateTime.month(.abbreviated).day()) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if compact && chosen == nil {
                        Text("Since " + dayText(days.first!.date)).font(Fit.label).foregroundStyle(Fit.muted)
                    } else {
                        Text(Fmt.compact(shown.value)).font(Fit.value)
                    }
                    if first > 0 {
                        let change = shown.value - first
                        Text(Pct.signed(change / first)).font(.footnote.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(change >= 0 ? Color.positive : .negative)
                    }
                    Spacer()
                    Text(dayText(shown.date)).font(Fit.label).foregroundStyle(Fit.muted)
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
                    .glassXLabels(ticks, active: ChartTicks.nearest(ticks, to: chosen?.date)) {
                        long ? $0.formatted(.dateTime.month(.abbreviated).year(.twoDigits)) : $0.formatted(.dateTime.month(.abbreviated).day())
                    }
                    .glassYAxis(scale) { Fmt.axis($0) }
                }
                .padding(.bottom, 24)
                if offered.count > 1 {
                    PeriodPicker(days: Binding(get: { chosenWindow }, set: { window = $0; selected = nil }),
                                 options: offered, label: Self.name)
                }
            }
        }
    }

    /// The days inside the window, thinned to about two hundred so a five-year line stays light.
    private static func trim(_ all: [DayValue], to window: Int) -> [DayValue] {
        guard let last = all.last else { return all }
        let start = last.date.addingTimeInterval(-Double(window) * 86_400)
        let inside = all.filter { $0.date >= start }
        guard inside.count > 2 else { return Array(all.suffix(2)) }
        let step = max(1, inside.count / 200)
        guard step > 1 else { return inside }
        // Count back from the newest so today always stays.
        return inside.enumerated().filter { (inside.count - 1 - $0.offset) % step == 0 }.map(\.element)
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
                // Cash has no price to chart.
                if !h.isCash || h.history.count >= 2 {
                    Card(title: "Value") { HoldingLineChart(points: h.history, color: AssetClassColor.of(h.assetClass)) }
                }
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
