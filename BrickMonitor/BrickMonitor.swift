import DeviceActivity
import Foundation

/// iOS wakes this at the edges of the windows the app registered (BrickEngine.syncSchedules and
/// watchTimer), even with the app closed, so schedules and timers start and end on time.
/// It writes the same shared state the app reads back when it next opens.
class BrickMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if let id = id(activity, "schedule.") { BrickEngine.fire(id) }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if let id = id(activity, "schedule.") { BrickEngine.finish(id) }
        if let id = id(activity, "timer.") { BrickEngine.timerDue(id) }
    }

    private func id(_ activity: DeviceActivityName, _ prefix: String) -> UUID? {
        guard activity.rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(activity.rawValue.dropFirst(prefix.count)))
    }
}
