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
    var change: Double { price - previousClose }
    var changePct: Double? { previousClose > 0 ? price / previousClose - 1 : nil }
}

enum QuoteFeed {
    private struct Chart: Decodable {
        struct Result: Decodable {
            struct Meta: Decodable { let regularMarketPrice: Double?; let chartPreviousClose: Double? }
            struct Indicators: Decodable { struct Q: Decodable { let close: [Double?]? }; let quote: [Q]? }
            let meta: Meta
            let indicators: Indicators?
        }
        struct Body: Decodable { let result: [Result]? }
        let chart: Body
    }

    static func load(_ symbols: [String]) async -> [String: Quote] {
        await withTaskGroup(of: (String, Quote?).self) { group in
            for symbol in Set(symbols) { group.addTask { (symbol, await fetch(symbol)) } }
            var out: [String: Quote] = [:]
            for await (symbol, quote) in group { if let quote { out[symbol] = quote } }
            return out
        }
    }

    private static func fetch(_ symbol: String) async -> Quote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=5m") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let result = try? JSONDecoder().decode(Chart.self, from: data).chart.result?.first,
              let price = result.meta.regularMarketPrice,
              let previous = result.meta.chartPreviousClose else { return nil }
        let closes = (result.indicators?.quote?.first?.close ?? []).compactMap { $0 }
        return Quote(price: price, previousClose: previous, series: closes.count >= 2 ? closes : [previous, price])
    }
}

/// The positions in one group of accounts (or all of them), each scaled to the
/// shares held there, with today's move from live quotes where there is one.
struct Portfolio {
    let positions: [Holding]
    let accounts: [HoldingsAccount]
    let value: Double
    let cash: Double
    let gain: Double
    let gainPct: Double?
    let dayChange: Double?
    let dayChangePct: Double?
    let history: [SeriesPoint]
    /// Today's value through the session, from the live quotes (empty without them).
    let intraday: [Double]
    /// What these positions were worth at yesterday's close.
    var previousValue: Double? { dayChange.map { value - $0 } }

    var isEmpty: Bool { positions.isEmpty }

    init(_ r: HoldingsResponse, group: InvestmentGroup?, quotes: [String: Quote]) {
        let accounts = (r.accounts ?? []).filter { group == nil || InvestmentGroup.of($0) == group }
        let ids = Set(accounts.map(\.id))
        var scaled: [Holding] = []
        for h in r.positions ?? [] {
            let lots = group == nil ? h.lots : h.lots.filter { ids.contains($0.accountId) }
            let shares = group == nil ? h.shares : lots.reduce(0) { $0 + $1.shares }
            let stored = group == nil ? h.marketValue : lots.reduce(0) { $0 + $1.marketValue }
            guard stored > 0.005 || shares > 0 else { continue }
            let frac = h.marketValue > 0 ? stored / h.marketValue : 0
            let quote = h.isCash ? nil : quotes[h.symbol]
            let price = quote?.price ?? h.price
            let value = quote != nil ? price * shares : stored
            let cost = h.costBasis.map { $0 * frac }
            let gain = cost.map { value - $0 }
            scaled.append(Holding(
                symbol: h.symbol, name: h.name, assetClass: h.assetClass, isCash: h.isCash,
                shares: shares, price: price, marketValue: value,
                costBasis: cost, avgCost: h.avgCost,
                gain: h.isCash ? nil : gain,
                gainPct: h.isCash ? nil : gain.flatMap { g in cost.flatMap { $0 > 0 ? g / $0 : nil } },
                weight: 0,
                dayChange: quote.map { $0.change * shares } ?? h.dayChange.map { $0 * frac },
                dayChangePct: quote?.changePct ?? h.dayChangePct,
                lots: lots,
                history: h.history.map { SeriesPoint(date: $0.date, value: $0.value * frac) }))
        }
        let total = scaled.reduce(0) { $0 + $1.marketValue }
        positions = scaled.map { h in
            Holding(symbol: h.symbol, name: h.name, assetClass: h.assetClass, isCash: h.isCash,
                    shares: h.shares, price: h.price, marketValue: h.marketValue,
                    costBasis: h.costBasis, avgCost: h.avgCost, gain: h.gain, gainPct: h.gainPct,
                    weight: total > 0 ? h.marketValue / total : 0,
                    dayChange: h.dayChange, dayChangePct: h.dayChangePct, lots: h.lots, history: h.history)
        }
        self.accounts = accounts
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

        var byDay: [String: Double] = [:]
        for h in positions { for p in h.history { byDay[p.date, default: 0] += p.value } }
        history = byDay.map { SeriesPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
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
