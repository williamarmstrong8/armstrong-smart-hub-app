import AuthenticationServices
import CryptoKit
import UIKit

/// Google sign-in for Calendar, inside the app: a system sheet (no trip to Safari), PKCE and the
/// iOS OAuth client, which has no secret. The app only gets a one-time code; the hub trades it
/// for tokens and keeps them, so the app never holds a Google token.
@MainActor
enum GoogleSignIn {
    static let clientID = "1054880549796-srql0pu9h4ku37t2delvuhuqkk82corj.apps.googleusercontent.com"
    /// Google's iOS clients redirect to the reversed client id (registered in the Info.plist).
    static let scheme = "com.googleusercontent.apps.1054880549796-srql0pu9h4ku37t2delvuhuqkk82corj"
    static let redirectURI = "\(scheme):/oauth2redirect"
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events",
    ]

    private struct LinkBody: Encodable {
        let code: String
        let codeVerifier: String
        let redirectUri: String
    }

    private static var holder: PresentationContext?

    /// Runs the sheet and hands the code to the hub. Returns false when the user cancels.
    static func connect(api: APIClient) async throws -> Bool {
        let verifier = randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // Offline plus consent is what makes Google return a refresh token.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: scheme) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
            }
            let context = PresentationContext()
            holder = context
            session.presentationContextProvider = context
            session.start()
        }
        holder = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw APIError(message: items.first(where: { $0.name == "error" })?.value ?? "Google didn't send a code.")
        }
        let _: Empty = try await api.post("/api/mobile/google/link", body: LinkBody(code: code, codeVerifier: verifier, redirectUri: redirectURI))
        return true
    }

    private static func randomString() -> String {
        Data((0..<48).map { _ in UInt8.random(in: .min ... .max) }).base64URL
    }

    private final class PresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
