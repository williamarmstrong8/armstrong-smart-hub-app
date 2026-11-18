import SwiftUI

struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// The demo switch as set here; it takes effect on the next launch.
    @State private var demo = Demo.isOn
    @State private var restartAsk = false

    var body: some View {
        NavigationStack {
            GlassForm {
                if let user = session.user {
                    GlassSection("Signed in") {
                        LabeledContent("Name", value: user.name)
                        LabeledContent("Email", value: user.email)
                    }
                }
                GlassSection("Hub") {
                    LabeledContent("Address", value: session.serverURL?.host() ?? "Not set")
                    if let url = session.webURL("/") {
                        Button("Open the hub in Safari") { openURL(url) }
                    }
                }
                if let url = session.webURL("/calendar") {
                    GlassSection {
                        Button("Reconnect Google Calendar", systemImage: "arrow.triangle.2.circlepath") { openURL(url) }
                    } header: {
                        Text("Google Calendar")
                    } footer: {
                        Text("Opens the hub's Calendar page in Safari, where Google is linked. Reconnect to let Jarvis add events.")
                    }
                }
                PhoneFeaturesSettings()
                GlassSection {
                    NavigationLink {
                        TestFeaturesView()
                    } label: {
                        Label("Test features", systemImage: "testtube.2")
                    }
                } footer: {
                    Text("Set off check-ins, briefings, Health, places and background refresh now, to see how they work.")
                }
                #if DEBUG
                GlassSection {
                    Toggle(isOn: Binding(get: { demo }, set: { on in
                        demo = on
                        Demo.setOnAtNextLaunch(on)
                        restartAsk = on != Demo.isOn
                    })) {
                        Label("Demo mode", systemImage: "play.rectangle")
                    }
                } footer: {
                    Text(Demo.isOn
                         ? "Showing made-up data. Turn off and restart to get your own back; nothing of yours was changed."
                         : "Swaps everything for made-up data, for showing the app or filming it. Nothing reaches the hub, the watch or your saved data. Takes effect after a restart.")
                }
                #endif
                GlassSection {
                    Button("Sign out", role: .destructive) {
                        Task {
                            await session.signOut()
                            dismiss()
                        }
                    }
                }
            }
            .alert(demo ? "Restart into demo mode?" : "Restart to leave demo mode?", isPresented: $restartAsk) {
                Button("Restart now") { Demo.restart() }
                Button("Later", role: .cancel) {}
            } message: {
                Text("The app closes; open it again from the Home Screen.")
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
