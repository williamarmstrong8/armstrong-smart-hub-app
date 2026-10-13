import Foundation
import Observation

@MainActor
@Observable
final class FinanceStore {
    private(set) var response: FinanceResponse?
    private(set) var error: String?
    private(set) var syncing = false

    var dashboard: Dashboard? { response?.dashboard }
    var currency: String { dashboard?.currency ?? "USD" }

    /// Every tag the picker offers: built-ins first, then custom tags A to Z.
    var categoryOptions: [String] {
        let custom = (response?.customCategories ?? [])
            .filter { !builtInCategories.contains($0) && $0 != "Uncategorized" }
        return builtInCategories + Array(Set(custom)).sorted()
    }

    func load(api: APIClient) async {
        do {
            let r: FinanceResponse = try await api.get("/api/mobile/finance")
            response = r
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sync(api: APIClient, toast: Toast) async {
        syncing = true
        defer { syncing = false }
        struct Reply: Decodable { let ok: Bool; let message: String?; let error: String? }
        do {
            let r: Reply = try await api.post("/api/mobile/finance")
            if r.ok { toast.show(r.message ?? "Synced") } else { toast.show(r.error ?? "Couldn't refresh.", error: true) }
            await load(api: api)
        } catch {
            toast.error(error)
        }
    }

    /// Re-tags one transaction, optimistically.
    func retag(_ transaction: Transaction, to category: String, api: APIClient, toast: Toast) async {
        let before = response
        mutate { d in
            for i in d.transactions.indices where d.transactions[i].id == transaction.id {
                d.transactions[i].category = category
                d.transactions[i].categorySource = "manual"
            }
            d.toReview.removeAll { $0.id == transaction.id }
        }
        do {
            let r: StatusResult = try await api.action("retagTransaction", [.string(transaction.id), .string(category)])
            if r.status == "error" { throw APIError(message: r.message ?? "Couldn't save that category.") }
        } catch {
            response = before
            toast.error(error)
        }
    }

    /// "Looks good": accept every suggestion in the review list.
    func confirmAll(api: APIClient, toast: Toast) async {
        guard let items = dashboard?.toReview, !items.isEmpty else { return }
        let before = response
        mutate { $0.toReview = [] }
        let args: [JSONValue] = [.array(items.map { .object(["transactionId": .string($0.id), "category": .string($0.category)]) })]
        do {
            let r: StatusResult = try await api.action("confirmCategories", args)
            if r.status == "error" { throw APIError(message: r.message ?? "Couldn't save those categories.") }
            toast.show("Saved \(items.count) categories")
        } catch {
            response = before
            toast.error(error)
        }
    }

    private func mutate(_ change: (inout Dashboard) -> Void) {
        guard let r = response, var d = r.dashboard else { return }
        change(&d)
        response = FinanceResponse(
            configured: r.configured, hasData: r.hasData, sync: r.sync, historyDays: r.historyDays, dashboard: d,
            recurring: r.recurring, history: r.history, goal: r.goal,
            customCategories: r.customCategories, quickCategories: r.quickCategories
        )
    }
}
