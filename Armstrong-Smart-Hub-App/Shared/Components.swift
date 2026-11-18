import ImageIO
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

    /// The cover once loaded, and for which link (a reused view can be handed another).
    @State private var loaded: (url: URL, image: UIImage)?

    private var inset: CGFloat { (width ?? 100) >= 120 ? 5 : 4 }
    private var link: URL? { url.flatMap(URL.init(string:)) }

    var body: some View {
        Group {
            // A cover seen before shows at once, with no placeholder in between.
            if let image = link.flatMap(PosterImages.cached) ?? loaded.flatMap({ $0.url == link ? $0.image : nil }) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            guard let link else { loaded = nil; return }
            if let image = await PosterImages.load(link) { loaded = (link, image) }
        }
        .frame(width: width.map { $0 - inset * 2 }, height: width.map { $0 * 1.5 - inset * 2 })
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: max(radius - inset, 4), style: .continuous))
        .padding(inset)
        .glassGlare(.regular, in: .rect(cornerRadius: radius, style: .continuous))
    }
}

/// Posters and book covers: fetched once, scaled down to about the size they show at and
/// decoded off the main thread, then kept in memory. AsyncImage fetched and decoded the full
/// picture on the main thread again every time a cover scrolled back into view.
enum PosterImages {
    private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    /// The longest side kept: a 220-point poster is 330 points tall, 990 pixels at 3x.
    private static let maxPixels = 1000

    static func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        let limit = maxPixels
        let image = await Task.detached(priority: .userInitiated) { downsample(data, maxPixels: limit) }.value
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Decoded now, at the smaller size, so drawing it later costs nothing.
    nonisolated private static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
