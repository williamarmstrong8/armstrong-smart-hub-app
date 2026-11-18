import SwiftUI

/// Pairs this device with the house hub on the Pi: just its address. The phone makes its own
/// key and keeps it in the Keychain; the hub is only reachable on the tailnet.
struct LoginView: View {
    @Environment(AppSession.self) private var session
    @AppStorage("hub.serverURL") private var savedServer = ""
    @State private var server = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case server }

    var body: some View {
        NavigationStack {
            GlassForm {
                VStack(spacing: 10) {
                    Image(systemName: "house.and.flag.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Armstrong Hub").font(.title.bold())
                    Text("Home, money, calendar and habits, with an agent that can use them all.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                GlassSection {
                    TextField("hub.your-tailnet.ts.net", text: $server)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .server)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } header: {
                    Text("Hub address")
                } footer: {
                    Text("The URL your hub is served on, for example its Tailscale address. Your phone needs to be on the tailnet.")
                }

                if let error {
                    GlassSection {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                GlassSection {
                    Button(action: signIn) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Connect").bold() }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(busy || server.isEmpty)
                }
            }
            .onAppear {
                if server.isEmpty { server = savedServer }
            }
        }
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await session.signIn(server: server)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
