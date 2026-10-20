import SwiftUI

@main
struct HubApp: App {
    @State private var session = AppSession()
    /// One Bluetooth link to the watch for the app's lifetime.
    @State private var watch = WatchLink()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(watch)
                #if DEBUG
                .onAppear { FitnessRenderDebug.runIfAsked(watch: watch, session: session) }
                #endif
        }
    }
}

/// Signed in shows the tabs; signed out shows the login screen.
struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Group {
            if session.isSignedIn {
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
    }
}

enum HubTab: Hashable {
    case home, finance, calendar, fitness, brick
}

/// The iPhone's tabs.
struct MainTabView: View {
    @State private var tab: HubTab = .home

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
    }
}
