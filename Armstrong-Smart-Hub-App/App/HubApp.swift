import SwiftUI

@main
struct HubApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
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
    case agent, home, finance, calendar, habits, food
}

/// The web app's sidebar (and its iPhone tab bar), as a native tab bar.
struct MainTabView: View {
    @State private var tab: HubTab = .agent

    var body: some View {
        TabView(selection: $tab) {
            Tab("Agent", systemImage: "bubble.left.and.text.bubble.right", value: .agent) {
                AgentView(switchTab: { tab = $0 })
            }
            Tab("Home", systemImage: "house", value: .home) {
                HomeView()
            }
            Tab("Finance", systemImage: "wallet.bifold", value: .finance) {
                FinanceView()
            }
            Tab("Calendar", systemImage: "calendar", value: .calendar) {
                CalendarView()
            }
            Tab("Habits", systemImage: "checkmark.circle", value: .habits) {
                HabitsView()
            }
            Tab("Food", systemImage: "fork.knife", value: .food) {
                FoodView()
            }
        }
    }
}
