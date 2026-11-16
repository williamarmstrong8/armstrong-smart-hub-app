import Foundation
import Observation

/// Brokerage positions from the hub, kept on the phone between launches.
@MainActor
@Observable
final class HoldingsStore {
    private(set) var response: HoldingsResponse?
    private(set) var error: String?
    private(set) var fetched = false

    private static let cacheName = "holdings"

    init() { response = DiskCache.read(Self.cacheName) }

    var hasHoldings: Bool { response?.hasHoldings == true && !(response?.positions ?? []).isEmpty }

    func load(api: APIClient) async {
        do {
            let data = try await api.data(api.request("/api/mobile/finance/holdings"))
            response = try APIClient.decoder.decode(HoldingsResponse.self, from: data)
            fetched = true
            error = nil
            DiskCache.write(data, Self.cacheName)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
