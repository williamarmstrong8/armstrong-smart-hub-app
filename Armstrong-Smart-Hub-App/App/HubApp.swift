import SwiftUI

@main
struct HubApp: App {
    @State private var session = AppSession()
    /// One Bluetooth link to the watch for the app's lifetime.
    @State private var watch = WatchLink()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Lock screen and widget buttons run here, even when they wake the app in the background.
        WorkoutActions.handler = { WorkoutStore.shared.handle($0) }
        TVActions.handler = { await TVActivityController.shared.handle($0) }
        // Check-in notifications answer themselves from the lock screen.
        CheckinReminders.shared.start()
        #if os(iOS)
        WorkoutActivityController.shared.sync(WorkoutStore.shared)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(watch)
                #if DEBUG
                .onAppear { FitnessRenderDebug.runIfAsked(watch: watch, session: session) }
                #endif
                // Brick timers and schedules, whichever tab is open.
                .onChange(of: scenePhase, initial: true) { _, p in if p == .active { BrickStore.shared.check() } }
                // What's playing on the TV, checked while the app is open.
                .onChange(of: scenePhase, initial: true) { _, p in
                    guard session.isSignedIn else { return }
                    if p == .active { TVActivityController.shared.appBecameActive() }
                    if p == .background { TVActivityController.shared.appWentToBackground() }
                }
                // Live watch readings go to the hub from here, whichever tab is open (or none).
                .onChange(of: session.isSignedIn, initial: true) { _, signedIn in
                    watch.api = signedIn ? session.api : nil
                    CheckinReminders.shared.api = signedIn ? session.api : nil
                    TVActivityController.shared.api = signedIn ? session.api : nil
                    // The 8 am and 6 pm check-ins, from the last page the phone has.
                    if signedIn { Task { await CheckinReminders.shared.schedule(CheckinStore.shared) } }
                }
                // A sync after waking brings last night's sleep: guess again so 8 am can say what it thinks.
                .onChange(of: watch.files.lastSync) { if session.isSignedIn { Task { await CheckinStore.shared.load(api: session.api) } } }
                .onChange(of: scenePhase) { _, p in if p == .background { watch.live.save() } }
        }
    }
}

/// Signed in shows the tabs; signed out shows the login screen.
struct RootView: View {
    @Environment(AppSession.self) private var session

    #if DEBUG
    /// BRICK_PREVIEW=1 opens straight on the Brick tab with sample data, for screenshots.
    private var brickPreview: Bool { ProcessInfo.processInfo.environment["BRICK_PREVIEW"] != nil }
    #else
    private let brickPreview = false
    #endif

    var body: some View {
        Group {
            if session.isSignedIn || brickPreview {
                // The iPad is an always-on panel: just the dashboard, no tabs.
                if UIDevice.current.userInterfaceIdiom == .pad {
                    DashboardTab()
                } else {
                    MainTabView()
                }
            } else {
                LoginView()
            }
        }
        .animation(.default, value: session.isSignedIn)
        // No scroll bars on any page: this reaches every scroll view below it.
        .scrollIndicators(.hidden)
    }
}

enum HubTab: Hashable {
    case home, finance, calendar, fitness, brick
}

/// The iPhone's tabs.
struct MainTabView: View {
    @State private var launcherError: String?
    @Environment(WatchLink.self) private var watch
    @State private var workouts = WorkoutStore.shared
    @State private var titles = TitleCardPresenter.shared
    /// A title card's height plus the gap under it (a poster at the screen's width, less the
    /// insets), and enough more that its shadow is gone too.
    private var titleCardTravel: CGFloat {
        let width = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }.first ?? 402
        return (width - 16) * 1.5 + 8 + 32
    }
    @State private var tab: HubTab = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BRICK_PREVIEW"] != nil {
            BrickStore.shared.debugSeed()
            return .brick
        }
        #endif
        return .home
    }()

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: .home) {
                HomeView()
            }
            Tab("Finance", systemImage: "wallet.bifold", value: .finance) {
                FinanceView()
            }
            Tab("Calendar", systemImage: "calendar", value: .calendar) {
                CalendarView()
            }
            Tab("Fitness", systemImage: "figure.run", value: .fitness) {
                FitnessView()
            }
            Tab("Brick", systemImage: "iphone.slash", value: .brick) {
                BrickView()
            }
        }
        // The workout in progress, closed: a card above the tab bar that opens it again.
        .tabViewBottomAccessory(isEnabled: workouts.active != nil) {
            MiniWorkoutBar(store: workouts)
        }
        // A title's card (opened from Home) sits over everything, tab bar included, which blurs
        // behind it in step with it.
        .blur(radius: 14 * titles.reveal)
        .overlay {
            if let p = titles.pick {
                MediaDetailCard(pick: p, poster: titles.poster, toast: titles.toast, reveal: $titles.reveal,
                                onChanged: titles.onChanged, onClose: titles.close, onSent: titles.sent)
                    .id(p.id)
                    // Slides by the card's own height (not the screen's), so it's moving into view
                    // from the first frame, in step with the blur.
                    .transition(.offset(y: titleCardTravel))
            }
        }
        .overlay {
            if let sentAt = titles.sentAt { SendGlow(start: sentAt) }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: titles.sentAt) { _, now in now != nil }
        // Widgets and the TV's Live Activity open their tab: armstronghub://home, /fitness, /brick.
        .onOpenURL { url in
            guard url.scheme == "armstronghub" else { return }
            switch url.host() {
            case "home": tab = .home
            case "finance": tab = .finance
            case "calendar": tab = .calendar
            case "fitness": tab = .fitness
            case "brick":
                tab = .brick
                if url.path == "/launcher" { MinimalLauncherNavigation.shared.requested = true }
            case "launch":
                guard let item = MinimalLauncherSettings.read().item(for: url), let target = item.url else {
                    tab = .brick
                    MinimalLauncherNavigation.shared.requested = true
                    launcherError = "This launcher entry no longer exists. Add it again in Minimal Launcher."
                    return
                }
                UIApplication.shared.open(target, options: [:]) { success in
                    if !success {
                        Task { @MainActor in
                            launcherError = "Couldn't open \(item.name). Check its app link or exact shortcut name in Brick → Minimal Launcher."
                        }
                    }
                }
            default: break
            }
        }
        .alert("Minimal Launcher", isPresented: Binding(get: { launcherError != nil }, set: { if !$0 { launcherError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(launcherError ?? "") }
        .toast(titles.toast)
        .fullScreenCover(isPresented: $workouts.isPresented) {
            ActiveWorkoutView(store: workouts, maxHr: workouts.maxHr)
        }
        // A finished workout asks how it felt.
        .sheet(item: $workouts.justFinished) { finished in
            SessionFeedbackSheet(kind: "workout", id: finished.id, title: finished.name)
        }
        // Live readings go into the workout in progress, whichever screen is showing.
        .onChange(of: watch.heartRateAt) { _, at in
            if let at, let bpm = watch.heartRate?.bpm, workouts.active != nil { workouts.record(bpm: bpm, at: at) }
        }
        // The rest runs out with the workout closed too.
        .task(id: workouts.restEndsAt) {
            guard let end = workouts.restEndsAt else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, workouts.restEndsAt == end else { return }
            workouts.skipRest()
        }
    }
}
