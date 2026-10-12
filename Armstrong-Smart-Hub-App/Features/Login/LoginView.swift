import SwiftUI

/// Signs in to a hub with the same email and password as the website.
struct LoginView: View {
    @Environment(AppSession.self) private var session
    @AppStorage("hub.serverURL") private var savedServer = ""
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case server, email, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("hub.your-tailnet.ts.net", text: $server)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focus = .email }
                } header: {
                    Text("Hub address")
                } footer: {
                    Text("The URL your hub is served on, for example its Tailscale address. Your phone needs to be on the tailnet.")
                }

                Section("Account") {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: signIn) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Sign in").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || server.isEmpty || email.isEmpty || password.isEmpty)
                }
            }
            .onAppear {
                if server.isEmpty { server = savedServer }
                if let user = session.user, email.isEmpty { email = user.email }
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
                try await session.signIn(server: server, email: email, password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
