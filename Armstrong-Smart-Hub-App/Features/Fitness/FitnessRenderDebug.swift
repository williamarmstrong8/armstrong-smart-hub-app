#if DEBUG
import SwiftUI

/// TEMPORARY: renders the Fitness overview and pages from a snapshot file to PNGs, then quits.
/// Launch with FITNESS_RENDER=/path/snapshot.json; images land next to it.
enum FitnessRenderDebug {
    @MainActor static func runIfAsked(watch: WatchLink, session: AppSession) {
        guard let path = ProcessInfo.processInfo.environment["FITNESS_RENDER"] else { return }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { print("RENDER: no file"); exit(1) }
        let snapshot: FitnessSnapshot
        do { snapshot = try JSONDecoder().decode(FitnessSnapshot.self, from: data) } catch { print("RENDER decode:", error); exit(1) }
        let store = FitnessStore()
        store.debugSet(snapshot)
        let dir = url.deletingLastPathComponent()
        func save<V: View>(_ name: String, _ view: V, scheme: ColorScheme) {
            let content = view
                .environment(watch).environment(session)
                .environment(\.fitnessRenderFlat, true)
                .environment(\.colorScheme, scheme)
                .frame(width: 393)
                .background(scheme == .dark ? Color.black : Color.white)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = .init(width: 393, height: nil)
            if let png = renderer.uiImage?.pngData() {
                try? png.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                print("RENDER wrote", name)
            } else { print("RENDER failed", name) }
        }
        // Activity details saved next to the snapshot as activity-*.json.
        var activities: [FitnessActivity] = []
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("activity-") && file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let detail = try? JSONDecoder().decode(FitnessActivityDetail.self, from: data) {
                store.debugSetDetail(detail)
                activities.append(detail.activity)
            }
        }
        let overview = VStack(spacing: 0) {
            TodayScores(store: store)
            FitSection(title: "Body") {
                OverviewList(store: store, liveBpm: nil, steps: store.today?.steps ?? 0, stepGoal: store.today?.stepGoal)
            }
            RecentActivities(activities: store.activities)
        }.padding(20)
        for scheme in [ColorScheme.dark, .light] {
            save("overview", overview, scheme: scheme)
            for page in [FitnessPage.readiness, .recovery, .strain, .sleep, .heart, .energy, .training, .health] {
                save("page-\(page)", page.view(store: store), scheme: scheme)
            }
            for activity in activities {
                save("activity-\(activity.sport)", ActivityPage(activity: activity, store: store), scheme: scheme)
            }
        }
        exit(0)
    }
}
#endif
