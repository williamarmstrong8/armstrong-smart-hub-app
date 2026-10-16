import SwiftUI
import UniformTypeIdentifiers

/// Sends watch faces to the watch over Bluetooth: pick from the hub's catalog,
/// or choose a compiled .prg from Files. Experimental until it has run on a real watch.
struct FitnessInstallView: View {
    @Environment(AppSession.self) private var session
    @Environment(WatchLink.self) private var watch
    @State private var faces: [Face] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var importing = false

    struct Face: Decodable, Identifiable {
        var id: String
        var name: String
        var version: Int
        var size: Int
    }

    private struct Catalog: Decodable { var faces: [Face] }
    private struct Download: Decodable { var data: String }

    var body: some View {
        List {
            Section {
                if loading { ProgressView() }
                if let loadError { Text(loadError).foregroundStyle(.secondary).font(.caption) }
                if !loading, loadError == nil, faces.isEmpty {
                    Text("No faces on the hub yet.").foregroundStyle(.secondary)
                }
                ForEach(faces) { face in
                    Button {
                        Task { await install(face) }
                    } label: {
                        HStack(spacing: 12) {
                            TablerIcon(name: "device-watch", size: 22).foregroundStyle(.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(face.name).font(.subheadline.weight(.semibold))
                                Text("Version \(face.version) · \(max(face.size / 1024, 1)) KB")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Install").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!canInstall)
                }
            } header: { Text("On the hub") }

            Section {
                Button("Choose a .prg from Files") { importing = true }
                    .disabled(!canInstall)
            } footer: {
                Text("Experimental. This sends the file over Bluetooth the way Garmin's own app does, and has not been tried on a Forerunner 965 yet. If it fails, nothing on the watch changes.")
            }

            Section {
                let installer = watch.installer
                if let fraction = installer.fraction { ProgressView(value: fraction) }
                if let status = installer.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                if let result = installer.lastResult { Text(result).font(.caption) }
                if watch.state != .connected {
                    Text("Connect your watch first (Fitness, watch icon).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Install to watch")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result else { return }
            Task { await installFile(url) }
        }
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

    private func installFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            await watch.installer.install([UInt8](data), name: url.deletingPathExtension().lastPathComponent, busy: watch.files.isSyncing)
        } catch {
            watch.installer.report(error)
        }
    }
}
