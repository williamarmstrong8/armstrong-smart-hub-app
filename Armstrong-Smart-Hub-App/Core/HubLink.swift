import Foundation
import Network
import Observation

/// Whether the hub is answering, from every request the app makes, plus the
/// device's own network. The wall dashboard shows it, and loops that wait
/// between retries cut the wait short when the network comes back.
@MainActor
@Observable
final class HubLink {
    static let shared = HubLink()

    enum State: Equatable { case online, reconnecting, offline }

    private(set) var lastOK: Date?
    private(set) var lastError: String?
    /// Failed requests in a row; any success resets it.
    private(set) var failures = 0
    private(set) var networkUp = true
    /// Bumped whenever the network comes back or the hub answers again after failing.
    private(set) var recoveries = 0

    var state: State {
        if !networkUp { return .offline }
        return failures == 0 ? .online : failures < 3 ? .reconnecting : .offline
    }

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in HubLink.shared.setNetwork(up) }
        }
        monitor.start(queue: DispatchQueue(label: "hub.link"))
    }

    private func setNetwork(_ up: Bool) {
        guard up != networkUp else { return }
        networkUp = up
        if up { recoveries += 1 }
    }

    /// Called by APIClient after every request that reached (or failed to reach) the hub.
    nonisolated static func report(ok: Bool, error: String? = nil) {
        Task { @MainActor in
            let link = HubLink.shared
            if ok {
                if link.failures > 0 { link.recoveries += 1 }
                link.failures = 0
                link.lastError = nil
                link.lastOK = .now
            } else {
                link.failures += 1
                link.lastError = error
            }
        }
    }

    /// Sleeps for `seconds`, or less if the link recovers first.
    func wait(_ seconds: Double) async {
        let start = recoveries
        let end = Date.now.addingTimeInterval(seconds)
        while !Task.isCancelled, Date.now < end, recoveries == start {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
