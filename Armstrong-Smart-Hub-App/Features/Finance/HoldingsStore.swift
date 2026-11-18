import Foundation
import Observation

/// Brokerage positions from the hub, kept on the phone between launches.
@MainActor
@Observable
final class HoldingsStore {
    private(set) var response: HoldingsResponse?
    private(set) var error: String?
    private(set) var fetched = false
    /// Live prices for today's move and the sparklines, keyed by symbol.
    private(set) var quotes: [String: Quote] = [:]

    private static let cacheName = "holdings"

    init() { response = DiskCache.read(Self.cacheName) }

    var hasHoldings: Bool { response?.hasHoldings == true && !(response?.positions ?? []).isEmpty }

    func loadQuotes() async {
        let symbols = (response?.positions ?? []).filter { !$0.isCash }.map(\.symbol)
        guard !symbols.isEmpty else { return }
        let fresh = await QuoteFeed.load(symbols)
        if !fresh.isEmpty { quotes.merge(fresh) { _, new in new } }
    }

    /// The positions in one group (nil: every account), priced live where possible.
    func portfolio(_ group: InvestmentGroup?) -> Portfolio? {
        guard let response else { return nil }
        return Portfolio(response, group: response.groups.count > 1 ? group : nil, quotes: quotes)
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
        await loadQuotes()
    }
}
