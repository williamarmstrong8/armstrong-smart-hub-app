import SwiftUI

struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
                GlassSection {
                    Button("Sign out", role: .destructive) {
                        Task {
                            await session.signOut()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
