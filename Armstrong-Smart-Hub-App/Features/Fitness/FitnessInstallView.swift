import SwiftUI

/// The watch faces on the hub as a row of cards: swipe left and right to browse,
/// drag one up to send it to the watch over Bluetooth.
struct WatchFacesSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(WatchLink.self) private var watch
    @Environment(\.dismiss) private var dismiss
    @State private var faces: [Face] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var lift: [String: CGFloat] = [:]
    @State private var sending: String?

    struct Face: Decodable, Identifiable {
        var id: String
        var name: String
        var version: Int
        var size: Int
    }

    private struct Catalog: Decodable { var faces: [Face] }
    private struct Download: Decodable { var data: String }

    private let sendDistance: CGFloat = 110

    var body: some View {
        VStack(spacing: 18) {
            Text("Watch faces").font(.headline).padding(.top, 22)

            if loading {
                Spacer(); ProgressView(); Spacer()
            } else if let loadError {
                Spacer()
                Text(loadError).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                Spacer()
            } else if faces.isEmpty {
                Spacer(); Text("No faces on the hub yet.").foregroundStyle(.secondary); Spacer()
            } else {
                Spacer(minLength: 0)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 24) {
                        ForEach(faces) { face in card(face) }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, 60, for: .scrollContent)
                .scrollClipDisabled()
                Spacer(minLength: 0)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium])
        .presentationBackground(BrickLook.sheet)
        .task { await load() }
        .sensoryFeedback(.success, trigger: watch.installer.lastResult)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            let installer = watch.installer
            if let fraction = installer.fraction { ProgressView(value: fraction).padding(.horizontal, 60) }
            Text(installer.status ?? installer.lastResult
                 ?? (watch.state == .connected ? "Swipe a face up to install it" : "Connect your watch to install"))
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.bottom, 24)
    }

    private func card(_ face: Face) -> some View {
        let up = lift[face.id] ?? 0
        let ready = -up >= sendDistance
        return VStack(spacing: 12) {
            ZStack {
                Circle().fill(.black)
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 3)
                VStack(spacing: 4) {
                    TablerIcon(name: "device-watch", size: 30).foregroundStyle(.white)
                    Text(face.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 22)
                }
                if sending == face.id && watch.installer.isInstalling { ProgressView().tint(.white).offset(y: 56) }
            }
            .frame(width: 180, height: 180)
            .overlay(alignment: .top) {
                Image(systemName: "chevron.compact.up").font(.title2).foregroundStyle(.secondary)
                    .offset(y: -34).opacity(up == 0 ? 0.7 : 0)
            }
            Text("Version \(face.version) · \(max(face.size / 1024, 1)) KB")
                .font(.caption).foregroundStyle(.secondary)
        }
        .containerRelativeFrame(.horizontal) { width, _ in min(width - 120, 220) }
        .offset(y: up)
        .scaleEffect(ready ? 1.06 : 1)
        .opacity(1 - min(-up / 400, 0.5))
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { g in
                    guard canInstall, abs(g.translation.height) > abs(g.translation.width) else { return }
                    lift[face.id] = min(0, g.translation.height)
                }
                .onEnded { g in
                    let sent = canInstall && g.translation.height <= -sendDistance
                    withAnimation(.spring(duration: 0.35)) { lift[face.id] = 0 }
                    if sent { sending = face.id; Task { await install(face) } }
                }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: ready) { _, now in now }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Install to watch")
        .accessibilityAction(named: "Install to watch") { if canInstall { Task { await install(face) } } }
    }

    private var canInstall: Bool {
        watch.state == .connected && !watch.installer.isInstalling && !watch.files.isSyncing
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let catalog: Catalog = try await session.api.get("/api/mobile/watch/faces")
            faces = catalog.faces
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load the faces. The hub may need the latest update."
        }
    }

    private func install(_ face: Face) async {
        do {
            let download: Download = try await session.api.get("/api/mobile/watch/faces/\(face.id)")
            guard let data = Data(base64Encoded: download.data) else { throw GarminUpload.Failure.notPRG }
            await watch.installer.install([UInt8](data), name: face.name, busy: watch.files.isSyncing)
        } catch {
            watch.installer.report(error)
        }
    }
}
