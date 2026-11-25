import Foundation

/// Which pile an investment account belongs to: the everyday brokerage account,
/// or the retirement and tax-advantaged ones (401k, IRA, Roth, HSA, 529…).
enum InvestmentGroup: String, CaseIterable, Identifiable, Hashable {
    case brokerage, retirement
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brokerage: "Brokerage"
        case .retirement: "Retirement"
        }
    }

    private static let retirementPattern = try! NSRegularExpression(
        pattern: #"\b(401\s?\(?k\)?|403\s?\(?b\)?|457|ira|roth|retirement|pension|hsa|529|tsp|rollover|sep|simple ira)\b"#,
        options: [.caseInsensitive])

    static func of(_ account: HoldingsAccount) -> InvestmentGroup {
        let text = account.name + " " + account.institution
        let range = NSRange(text.startIndex..., in: text)
        return retirementPattern.firstMatch(in: text, range: range) == nil ? .brokerage : .retirement
    }
}

/// Today's price move for one symbol, from Yahoo's public chart endpoint (no key).
struct Quote: Sendable {
    let price: Double
    let previousClose: Double
    /// Intraday closes, 5 minutes apart.
    let series: [Double]
    /// The trading day the price is from (yyyy-MM-dd, exchange time): on a weekend, Friday.
    let marketDay: String?
    var change: Double { price - previousClose }
    var changePct: Double? { previousClose > 0 ? price / previousClose - 1 : nil }
}

/// One symbol's past closes, oldest first: daily for the last year, weekly for
/// the four before. Split-adjusted, so today's share count times a past close is
/// what those shares were worth that day.
struct DailyCloses: Codable, Sendable {
    /// yyyy-MM-dd in the exchange's time zone.
    let days: [String]
    let closes: [Double]
}

/// Yahoo's chart endpoint, shared by today's quotes and the price history.
private enum YahooChart {
    struct Response: Decodable {
        struct Result: Decodable {
            struct Meta: Decodable {
                let regularMarketPrice: Double?
                let chartPreviousClose: Double?
                let regularMarketTime: Double?
                let gmtoffset: Double?
            }
            struct Indicators: Decodable { struct Q: Decodable { let close: [Double?]? }; let quote: [Q]? }
            let meta: Meta
            let timestamp: [Double]?
            let indicators: Indicators?
            var closes: [Double?] { indicators?.quote?.first?.close ?? [] }
            /// The exchange-local day of a bar's timestamp.
            func day(_ time: Double) -> String {
                DayFormat.formatter.string(from: Date(timeIntervalSince1970: time + (meta.gmtoffset ?? 0)))
            }
        }
        struct Body: Decodable { let result: [Result]? }
        let chart: Body
    }

    static func fetch(_ symbol: String, _ query: String) async -> Response.Result? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?\(query)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data).chart.result?.first
    }

    /// Fetches every symbol at once, keeping the ones that answered.
    static func each<T: Sendable>(_ symbols: [String], _ load: @escaping @Sendable (String) async -> T?) async -> [String: T] {
        await withTaskGroup(of: (String, T?).self) { group in
            for symbol in Set(symbols) { group.addTask { (symbol, await load(symbol)) } }
            var out: [String: T] = [:]
            for await (symbol, value) in group { if let value { out[symbol] = value } }
            return out
        }
    }
}

enum QuoteFeed {
    static func load(_ symbols: [String]) async -> [String: Quote] {
        await YahooChart.each(symbols) { await fetch($0) }
    }

    private static func fetch(_ symbol: String) async -> Quote? {
        guard let result = await YahooChart.fetch(symbol, "range=1d&interval=5m"),
              let price = result.meta.regularMarketPrice,
              let previous = result.meta.chartPreviousClose else { return nil }
        let closes = result.closes.compactMap { $0 }
        return Quote(price: price, previousClose: previous, series: closes.count >= 2 ? closes : [previous, price],
                     marketDay: result.meta.regularMarketTime.map(result.day))
    }
}

/// Past closes from the same public endpoint, so the value chart doesn't wait on
/// a sync for each day: a year of daily closes and five years of weekly ones.
enum PriceHistory {
    static func load(_ symbols: [String]) async -> [String: DailyCloses] {
        await YahooChart.each(symbols) { await fetch($0) }
    }

    private static func fetch(_ symbol: String) async -> DailyCloses? {
        async let daily = bars(symbol, "range=1y&interval=1d")
        async let weekly = bars(symbol, "range=5y&interval=1wk")
        let (recent, older) = await (daily, weekly)
        guard let recent, let first = recent.first else { return nil }
        let merged = (older ?? []).filter { $0.day < first.day } + recent
        return DailyCloses(days: merged.map(\.day), closes: merged.map(\.close))
    }

    private static func bars(_ symbol: String, _ query: String) async -> [(day: String, close: Double)]? {
        guard let result = await YahooChart.fetch(symbol, query), let times = result.timestamp else { return nil }
        let closes = result.closes
        var out: [(day: String, close: Double)] = []
        for (i, time) in times.enumerated() where i < closes.count {
            // A fund's NAV for today isn't out until evening: that bar has no close yet.
            guard let close = closes[i], close > 0 else { continue }
            let day = result.day(time)
            if out.last?.day == day { out[out.count - 1].close = close } else { out.append((day, close)) }
        }
        return out.isEmpty ? nil : out
    }
}

/// The positions in one group of accounts (or all of them), each scaled to the
/// shares held there and priced from public data: today's quote, else the latest
/// close, and only without either the price at the last sync. Gains are against
/// what was paid (SimpleFIN's purchase price times the shares).
struct Portfolio {
    let positions: [Holding]
    let accounts: [HoldingsAccount]
    let value: Double
    let cash: Double
    let gain: Double
    let gainPct: Double?
    let dayChange: Double?
    let dayChangePct: Double?
    /// Value per day: today's shares at each day's close (the sync snapshots without past prices).
    let history: [SeriesPoint]
    /// Today's value through the session, from the live quotes (empty without them).
    let intraday: [Double]
    /// What these positions were worth at yesterday's close.
    var previousValue: Double? { dayChange.map { value - $0 } }

    var isEmpty: Bool { positions.isEmpty }

    init(_ r: HoldingsResponse, group: InvestmentGroup?, quotes: [String: Quote], closes: [String: DailyCloses] = [:]) {
        let accounts = (r.accounts ?? []).filter { group == nil || InvestmentGroup.of($0) == group }
        let ids = Set(accounts.map(\.id))
        var scaled: [Holding] = []
        // Positions whose history comes from past closes rather than the sync snapshots.
        var priced = Set<String>()
        for h in r.positions ?? [] {
            let lots = group == nil ? h.lots : h.lots.filter { ids.contains($0.accountId) }
            let shares = group == nil ? h.shares : lots.reduce(0) { $0 + $1.shares }
            let stored = group == nil ? h.marketValue : lots.reduce(0) { $0 + $1.marketValue }
            guard stored > 0.005 || shares > 0 else { continue }
            let frac = h.marketValue > 0 ? stored / h.marketValue : 0
            let quote = h.isCash ? nil : quotes[h.symbol]
            let past = h.isCash || shares <= 0 ? nil : closes[h.symbol].flatMap { $0.closes.isEmpty ? nil : $0 }
            let live = shares > 0 ? (quote?.price ?? past?.closes.last) : nil
            let price = live ?? h.price
            let value = live.map { $0 * shares } ?? stored
            let cost = h.costBasis.map { $0 * frac }
            let gain = cost.map { value - $0 }

            // Today's move: the quote, else the last two closes, else the hub's from two syncs.
            var dayChange = h.dayChange.map { $0 * frac }
            var dayChangePct = h.dayChangePct
            if let quote {
                dayChange = quote.change * shares
                dayChangePct = quote.changePct
            } else if let c = past?.closes, c.count >= 2, c[c.count - 2] > 0 {
                dayChange = (c[c.count - 1] - c[c.count - 2]) * shares
                dayChangePct = c[c.count - 1] / c[c.count - 2] - 1
            }

            var history = h.history.map { SeriesPoint(date: $0.date, value: $0.value * frac) }
            if let past {
                priced.insert(h.symbol)
                // Today's value replaces the close of the day the quote is from (a fund's NAV may lag a day).
                let liveDay = quote?.marketDay
                history = zip(past.days, past.closes)
                    .filter { day, _ in liveDay.map { day < $0 } ?? true }
                    .map { day, close in SeriesPoint(date: day, value: close * shares) }
                if let liveDay { history.append(SeriesPoint(date: liveDay, value: value)) }
            }

            scaled.append(Holding(
                symbol: h.symbol, name: h.name, assetClass: h.assetClass, isCash: h.isCash,
                shares: shares, price: price, marketValue: value,
                costBasis: cost, avgCost: h.avgCost,
                gain: h.isCash ? nil : gain,
                gainPct: h.isCash ? nil : gain.flatMap { g in cost.flatMap { $0 > 0 ? g / $0 : nil } },
                weight: 0,
                dayChange: dayChange,
                dayChangePct: dayChangePct,
                lots: lots,
                history: history))
        }
        let total = scaled.reduce(0) { $0 + $1.marketValue }
        positions = scaled.map { h in
            Holding(symbol: h.symbol, name: h.name, assetClass: h.assetClass, isCash: h.isCash,
                    shares: h.shares, price: h.price, marketValue: h.marketValue,
                    costBasis: h.costBasis, avgCost: h.avgCost, gain: h.gain, gainPct: h.gainPct,
                    weight: total > 0 ? h.marketValue / total : 0,
                    dayChange: h.dayChange, dayChangePct: h.dayChangePct, lots: h.lots, history: h.history)
        }
        self.accounts = Self.repriced(accounts, positions)
        value = total
        cash = positions.filter(\.isCash).reduce(0) { $0 + $1.marketValue }

        let invested = positions.filter { !$0.isCash && $0.costBasis != nil }
        let costTotal = invested.reduce(0) { $0 + ($1.costBasis ?? 0) }
        gain = invested.reduce(0) { $0 + ($1.gain ?? 0) }
        gainPct = costTotal > 0 ? gain / costTotal : nil

        let moved = positions.filter { !$0.isCash && $0.dayChange != nil }
        if moved.isEmpty {
            dayChange = nil
            dayChangePct = nil
        } else {
            let change = moved.reduce(0) { $0 + ($1.dayChange ?? 0) }
            let before = moved.reduce(0) { $0 + $1.marketValue } - change
            dayChange = change
            dayChangePct = before > 0 ? change / before : nil
        }

        // Resample every quoted series to the same length and add them up, holding the rest flat.
        let n = 48
        var line = [Double](repeating: 0, count: n)
        var anyQuoted = false
        for h in positions {
            if let q = h.isCash ? nil : quotes[h.symbol], q.series.count >= 2 {
                anyQuoted = true
                for i in 0..<n {
                    let x = Double(i) / Double(n - 1) * Double(q.series.count - 1)
                    let lo = Int(x), hi = min(lo + 1, q.series.count - 1)
                    let v = q.series[lo] + (q.series[hi] - q.series[lo]) * (x - Double(lo))
                    line[i] += v * h.shares
                }
            } else {
                for i in 0..<n { line[i] += h.marketValue }
            }
        }
        intraday = anyQuoted ? line : []

        if priced.isEmpty {
            var byDay: [String: Double] = [:]
            for h in positions { for p in h.history { byDay[p.date, default: 0] += p.value } }
            history = byDay.map { SeriesPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
        } else {
            // Every day any priced position traded: each one at its close on or before that day
            // (its first close before its history starts), the rest held at today's value.
            let lines = positions.filter { priced.contains($0.symbol) }.map(\.history).filter { !$0.isEmpty }
            let flat = positions.filter { !priced.contains($0.symbol) }.reduce(0) { $0 + $1.marketValue }
            var cursor = [Int](repeating: 0, count: lines.count)
            history = Set(lines.flatMap { $0.map(\.date) }).sorted().map { day in
                var sum = flat
                for (i, line) in lines.enumerated() {
                    while cursor[i] + 1 < line.count && line[cursor[i] + 1].date <= day { cursor[i] += 1 }
                    sum += line[cursor[i]].value
                }
                return SeriesPoint(date: day, value: sum)
            }
        }
    }

    /// Each account at today's prices: its share of every position, with the gain
    /// on what it holds against what was paid.
    private static func repriced(_ accounts: [HoldingsAccount], _ positions: [Holding]) -> [HoldingsAccount] {
        var value: [String: Double] = [:], cost: [String: Double] = [:], gain: [String: Double] = [:]
        for h in positions {
            for lot in h.lots {
                let v = h.isCash || lot.shares <= 0 ? lot.marketValue : h.price * lot.shares
                value[lot.accountId, default: 0] += v
                if !h.isCash, let c = lot.costBasis {
                    cost[lot.accountId, default: 0] += c
                    gain[lot.accountId, default: 0] += v - c
                }
            }
        }
        return accounts.map { a in
            guard let v = value[a.id] else { return a }
            let c = cost[a.id] ?? 0, g = gain[a.id] ?? 0
            return HoldingsAccount(id: a.id, name: a.name, institution: a.institution,
                                   balance: a.balance + (v - a.value), value: v, cash: a.cash,
                                   costBasis: c, gain: g, gainPct: c > 0 ? g / c : nil, positions: a.positions)
        }
    }

    /// Share of the money in each asset class, biggest first.
    var allocation: [(assetClass: String, value: Double, share: Double)] {
        var by: [String: Double] = [:]
        for h in positions { by[h.assetClass, default: 0] += h.marketValue }
        let total = value
        let rows: [(assetClass: String, value: Double, share: Double)] = by.map { (assetClass: $0.key, value: $0.value, share: total > 0 ? $0.value / total : 0) }
        return rows.sorted { $0.value > $1.value }
    }
}

extension HoldingsResponse {
    /// The groups that actually hold something, brokerage first.
    var groups: [InvestmentGroup] {
        let present = Set((accounts ?? []).map(InvestmentGroup.of))
        return InvestmentGroup.allCases.filter(present.contains)
    }
}
