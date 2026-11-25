import Foundation
import Observation

/// Brokerage positions from the hub, kept on the phone between launches, priced
/// from public market data so the numbers move without a SimpleFIN sync.
@MainActor
@Observable
final class HoldingsStore {
    private(set) var response: HoldingsResponse?
    private(set) var error: String?
    private(set) var fetched = false
    /// Live prices for today's move and the sparklines, keyed by symbol.
    private(set) var quotes: [String: Quote] = [:]
    /// Past closes for the value charts, keyed by symbol; fetched once a day.
    private(set) var closes: [String: DailyCloses] = [:]
    private var closesFetched: Date?

    private static let cacheName = "holdings"
    private static let closesName = "holdings-closes"

    private struct SavedCloses: Codable {
        let fetched: Date
        let symbols: [String: DailyCloses]
    }

    init() {
        response = DiskCache.read(Self.cacheName)
        if let saved: SavedCloses = DiskCache.read(Self.closesName) {
            closes = saved.symbols
            closesFetched = saved.fetched
        }
    }

    var hasHoldings: Bool { response?.hasHoldings == true && !(response?.positions ?? []).isEmpty }

    private var symbols: [String] { (response?.positions ?? []).filter { !$0.isCash }.map(\.symbol) }

    func loadQuotes() async {
        guard !symbols.isEmpty else { return }
        let fresh = await QuoteFeed.load(symbols)
        if !fresh.isEmpty { quotes.merge(fresh) { _, new in new } }
    }

    /// Past closes change once a day, so they're fetched once a day (and for any new symbol).
    func loadCloses() async {
        let fresh = closesFetched.map { Calendar.current.isDateInToday($0) } ?? false
        let wanted = fresh ? symbols.filter { closes[$0] == nil } : symbols
        guard !wanted.isEmpty else { return }
        let loaded = await PriceHistory.load(wanted)
        guard !loaded.isEmpty else { return }
        closes.merge(loaded) { _, new in new }
        closesFetched = .now
        DiskCache.write(SavedCloses(fetched: .now, symbols: closes), Self.closesName)
    }

    /// The positions in one group (nil: every account), priced live where possible.
    func portfolio(_ group: InvestmentGroup?) -> Portfolio? {
        guard let response else { return nil }
        return Portfolio(response, group: response.groups.count > 1 ? group : nil, quotes: quotes, closes: closes)
    }

    /// Each investment account's balance at today's prices, by account id.
    var liveBalances: [String: Double] {
        guard !quotes.isEmpty || !closes.isEmpty, let p = portfolio(nil) else { return [:] }
        return Dictionary(p.accounts.map { ($0.id, $0.balance) }, uniquingKeysWith: { a, _ in a })
    }

    func load(api: APIClient) async {
        do {
            let data = try await api.data(api.request("/api/mobile/finance/holdings"))
            response = try APIClient.decoder.decode(HoldingsResponse.self, from: data)
            fetched = true
            error = nil
            DiskCache.write(data, Self.cacheName)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        // Even when the hub is unreachable, the cached positions still get today's prices.
        async let today: Void = loadQuotes()
        async let past: Void = loadCloses()
        _ = await (today, past)
    }
}
