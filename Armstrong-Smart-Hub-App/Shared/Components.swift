import SwiftUI

/// A full-page message with an optional retry, for empty and error states.
struct MessageView: View {
    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered)
            }
        }
    }
}

/// An inline error banner that keeps the last good content visible below it.
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HubDesign.warning)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Retry", action: retry)
                    .font(.callout.weight(.medium))
                    .frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
            }
        }
        .padding(12)
        .background(HubDesign.warning.opacity(0.10), in: .rect(cornerRadius: HubLayout.controlRadius))
    }
}

/// A rounded card section used across Finance and Home.
struct Card<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
                }
            }
            content
        }
        .padding(HubLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassGlare(.regular, in: .rect(cornerRadius: HubLayout.cardRadius))
    }
}

/// A transient message shown at the bottom, like the web app's toasts.
@MainActor
@Observable
final class Toast {
    var message: String?
    var isError = false
    private var task: Task<Void, Never>?

    func show(_ message: String, error: Bool = false) {
        self.message = message
        isError = error
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self.message = nil }
        }
    }

    func error(_ error: Error) {
        if error is CancellationError { return }
        show(error.localizedDescription, error: true)
    }
}

struct ToastOverlay: ViewModifier {
    let toast: Toast

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            // Animate only the overlay, not the page or its scroll position.
            VStack {
                if let message = toast.message {
                    Button { toast.message = nil } label: {
                        HStack(spacing: 8) {
                            Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(toast.isError ? HubDesign.danger : HubDesign.positive)
                            Text(message).font(.callout).multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(HubDesign.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: HubLayout.minHitTarget)
                        .glassGlare(.regular, in: .rect(cornerRadius: HubLayout.controlRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismiss message")
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, HubLayout.gutter)
            .padding(.bottom, 12)
            .hubAnimation(value: toast.message)
        }
    }
}

extension View {
    func toast(_ toast: Toast) -> some View { modifier(ToastOverlay(toast: toast)) }
}

/// A poster from a remote URL with a film placeholder, set in a Liquid Glass frame: the poster
/// sits inset in a glass card whose rim catches the light. The outer size is the frame's.
struct Poster: View {
    let url: String?
    var width: CGFloat?
    var radius: CGFloat = 18
    var symbol = "film"

    private var inset: CGFloat { (width ?? 100) >= 120 ? 5 : 4 }

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width.map { $0 - inset * 2 }, height: width.map { $0 * 1.5 - inset * 2 })
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: max(radius - inset, 4), style: .continuous))
        .padding(inset)
        .glassGlare(.regular, in: .rect(cornerRadius: radius, style: .continuous))
    }
}

/// Settings and sign-out, reached from the person icon on each tab.
struct AccountButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Account and settings")
        .sheet(isPresented: $showing) { SettingsView() }
    }
}
