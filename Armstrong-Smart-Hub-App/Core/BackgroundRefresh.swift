import BackgroundTasks
import Foundation
import WidgetKit

/// Work done while the app is closed, when iOS gives it a background refresh
/// (it picks the moments; the app asks for the next one each time):
/// - sends check-ins and drinks waiting for the hub;
/// - loads the newest Fitness snapshot and check-in guess, so widgets and
///   tomorrow's 8 am notification carry it;
/// - writes new data to Apple Health;
/// - sends the morning or night briefing when one is due.
///
/// The watch's Bluetooth syncs wake the app too; those run the same steps.
/// iOS gives no refreshes to an app swiped away in the app switcher.
@MainActor
final class BackgroundRefresh {
    static let shared = BackgroundRefresh()

    nonisolated static let identifier = "com.paularmstrong.ArmstrongSmartHubApp.refresh"

    var api: APIClient?

    private var running = false

    /// Asks for the next refresh: at the next briefing time, or within two hours, whichever is sooner.
    func schedule() {
        guard !Demo.isOn else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = min(HealthBriefing.shared.nextTime(), Date.now.addingTimeInterval(2 * 3600))
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One pass. Safe to call whenever the app gets time (refresh, watch sync, opening).
    func run() async {
        defer { schedule() }
        // A background launch may have no window, so the app's sign-in hand-off hasn't run: read the saved session.
        if api == nil, !Demo.isOn {
            let session = AppSession()
            if session.isSignedIn {
                api = session.api
                HealthBriefing.shared.api = session.api
                CheckinReminders.shared.api = session.api
                AlcoholStore.shared.api = session.api
            }
        }
        guard let api, !running else { return }
        running = true
        defer { running = false }
        AlcoholStore.shared.sync()
        await CheckinStore.shared.load(api: api)
        // The briefing loads the Fitness snapshot, which also goes on to Health and the widgets.
        await HealthBriefing.shared.runIfDue()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
