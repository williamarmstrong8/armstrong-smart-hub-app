import SwiftUI
import UIKit

/// "Hey Jarvis, in my app…": the app being changed (its icon, big and centered),
/// what was asked, and where the Mac is with it.
struct AppChangeCard: View {
    let data: AppChangeCardData

    @State private var shown = false

    var body: some View {
        VStack(spacing: 28) {
            icon
                .frame(width: 168, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .scaleEffect(shown ? 1 : 0.85)
                .opacity(shown ? 1 : 0)

            VStack(spacing: 10) {
                Text(data.app.name)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(data.kind == "undo" ? "Undo the last change" : "“\(data.request)”")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
            }

            Label(statusText, systemImage: statusSymbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, options: .repeating, isActive: working)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect()
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(duration: 0.55, bounce: 0.3)) { shown = true }
        }
    }

    @ViewBuilder private var icon: some View {
        if let image = Self.image(from: data.app.icon) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 38, style: .continuous).fill(.white.opacity(0.1))
                Image(systemName: "app.dashed").font(.system(size: 72, weight: .light)).foregroundStyle(.secondary)
            }
        }
    }

    private var working: Bool { data.status == "queued" || data.status == "running" }

    private var statusText: String {
        switch data.status {
        case "queued": data.macOnline ? "Sent to your Mac" : "Waiting for your Mac to wake up"
        case "running": (data.stage.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Working") + "…"
        case "done": data.summary ?? "On your iPhone"
        case "failed": data.error ?? "That didn't work"
        case "cancelled": "Cancelled"
        default: data.status
        }
    }

    private var statusSymbol: String {
        switch data.status {
        case "queued": data.macOnline ? "laptopcomputer.and.arrow.down" : "moon.zzz"
        case "running": "hammer"
        case "done": "checkmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        default: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case "done": .green
        case "failed": .orange
        default: .primary
        }
    }

    private static func image(from dataURL: String?) -> UIImage? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ","),
              let bytes = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return UIImage(data: bytes)
    }
}
