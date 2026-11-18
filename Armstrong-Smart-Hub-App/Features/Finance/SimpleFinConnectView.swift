import SwiftUI

/// Connects SimpleFIN on the phone. A setup token (from SimpleFIN Bridge) is claimed once for an
/// access URL, which stays in this phone's Keychain; an access URL can be pasted directly.
struct SimpleFinConnectView: View {
    let syncing: Bool
    /// Answers an error to show, or nil once connected.
    let connect: (String) async -> String?

    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.columns")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Connect SimpleFIN")
                .font(.title2.bold())
            Text("Paste a setup token from SimpleFIN Bridge, or your access URL. It's kept in this phone's Keychain, and your accounts sync straight from SimpleFIN.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("Setup token or access URL", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task {
                    error = await connect(token.trimmingCharacters(in: .whitespacesAndNewlines))
                    if error == nil { token = "" }
                }
            } label: {
                if syncing { ProgressView() } else { Text("Connect").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(syncing || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}
