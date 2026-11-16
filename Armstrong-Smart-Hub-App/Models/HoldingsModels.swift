import Foundation

/// Mirrors HoldingsResponse in lib/holdings.ts (GET /api/mobile/finance/holdings).
struct HoldingsResponse: Decodable, Sendable {
    let configured: Bool
    let hasHoldings: Bool?
    let asOf: Double?
    let totals: HoldingsTotals?
    let accounts: [HoldingsAccount]?
    let positions: [Holding]?
    let allocation: [AllocationSlice]?
    let history: [SeriesPoint]?
}

struct HoldingsTotals: Decodable, Sendable {
    let value: Double
    let cash: Double
    let invested: Double
    let costBasis: Double
    let gain: Double
    let gainPct: Double?
    let dayChange: Double?
    let dayChangePct: Double?
}

struct HoldingsAccount: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let institution: String
    let balance: Double
    let value: Double
    let cash: Double
    let costBasis: Double
    let gain: Double
    let gainPct: Double?
    let positions: Int
}

struct HoldingLot: Decodable, Identifiable, Sendable {
    let accountId: String
    let accountName: String
    let institution: String
    let shares: Double
    let marketValue: Double
    let costBasis: Double?
    var id: String { accountId }
}

struct Holding: Decodable, Identifiable, Sendable {
    let symbol: String
    let name: String
    let assetClass: String
    let isCash: Bool
    let shares: Double
    let price: Double
    let marketValue: Double
    let costBasis: Double?
    let avgCost: Double?
    let gain: Double?
    let gainPct: Double?
    let weight: Double
    let dayChange: Double?
    let dayChangePct: Double?
    let lots: [HoldingLot]
    let history: [SeriesPoint]
    var id: String { symbol }
}

struct AllocationSlice: Decodable, Identifiable, Sendable {
    let assetClass: String
    let value: Double
    let share: Double
    var id: String { assetClass }
}
