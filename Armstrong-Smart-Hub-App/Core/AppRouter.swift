import Foundation
import Observation

/// Where a notification tap should land: a tab, and the card on it.
/// The notification delegate sets a request; the tab view and the page pick it
/// up, even on a cold launch where the request arrives before any view exists.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Card: String { case checkin, briefing, diet }

    struct Request: Equatable {
        var tab: HubTab
        var card: Card?
        var id = UUID()
    }

    /// The newest request; the tab view switches tabs from it.
    private(set) var request: Request?
    /// The card still to scroll to, cleared by the page once it has.
    var pendingCard: Card?

    func open(_ tab: HubTab, card: Card? = nil) {
        pendingCard = card
        request = Request(tab: tab, card: card)
    }
}
