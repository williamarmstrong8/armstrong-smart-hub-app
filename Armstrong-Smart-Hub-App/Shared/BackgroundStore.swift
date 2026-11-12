import AVFoundation
import CoreMotion
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

nonisolated private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

/// The app-wide background: the bundled snow mountain, or a photo / live photo / video the user chose.
@Observable
final class BackgroundStore {
    static let shared = BackgroundStore()

    enum Kind: String { case standard, photo, motion }

    private(set) var kind: Kind = .standard
    private(set) var image: UIImage?
    private(set) var player: AVQueuePlayer?
    private(set) var tilt: CGSize = .zero
    private(set) var importing = false
    private(set) var note: String?

    var blur: Double { didSet { UserDefaults.standard.set(blur, forKey: Self.blurKey) } }
    var parallax: Bool {
        didSet {
            UserDefaults.standard.set(parallax, forKey: Self.parallaxKey)
            updateMotion()
        }
    }

    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var reference: (roll: Double, pitch: Double)?

    private static let kindKey = "background.kind"
    private static let blurKey = "background.blur"
    private static let parallaxKey = "background.parallax"

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Background", isDirectory: true)
    }
    private static var photoURL: URL { directory.appendingPathComponent("background.jpg") }
    private static var motionURL: URL { directory.appendingPathComponent("background.mov") }

    private init() {
        let defaults = UserDefaults.standard
        blur = defaults.object(forKey: Self.blurKey) as? Double ?? 4
        parallax = defaults.object(forKey: Self.parallaxKey) as? Bool ?? true
        switch Kind(rawValue: defaults.string(forKey: Self.kindKey) ?? "") {
        case .photo:
            if let img = UIImage(contentsOfFile: Self.photoURL.path) { image = img; kind = .photo }
        case .motion:
            if FileManager.default.fileExists(atPath: Self.motionURL.path) { startPlayer(Self.motionURL); kind = .motion }
        default: break
        }
        updateMotion()
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.pause() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.play() }
        }
    }

    func reset() {
        clearFiles()
        stopPlayer()
        image = nil
        kind = .standard
        note = nil
        UserDefaults.standard.set(Kind.standard.rawValue, forKey: Self.kindKey)
        updateMotion()
    }

    func importItem(_ item: PhotosPickerItem) async {
        importing = true
        note = nil
        defer { importing = false }
        let types = item.supportedContentTypes
        do {
            if types.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw CocoaError(.fileReadUnknown) }
                try installMotion(from: movie.url)
                return
            }
            if types.contains(where: { $0.conforms(to: .livePhoto) }) {
                if let id = item.itemIdentifier, let url = await Self.pairedVideo(identifier: id) {
                    try installMotion(from: url)
                    return
                }
                note = "Allow Photos access to use the Live Photo's motion. Using its still image."
            }
            guard let data = try await item.loadTransferable(type: Data.self), let jpeg = Self.jpeg(from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try installPhoto(jpeg)
        } catch {
            note = "Couldn't use that file."
        }
    }

    private func installPhoto(_ jpeg: Data) throws {
        clearFiles()
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try jpeg.write(to: Self.photoURL, options: .atomic)
        stopPlayer()
        image = UIImage(data: jpeg)
        kind = .photo
        UserDefaults.standard.set(Kind.photo.rawValue, forKey: Self.kindKey)
        updateMotion()
    }

    private func installMotion(from source: URL) throws {
        clearFiles()
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: Self.motionURL)
        image = nil
        startPlayer(Self.motionURL)
        kind = .motion
        UserDefaults.standard.set(Kind.motion.rawValue, forKey: Self.kindKey)
        updateMotion()
    }

    private func clearFiles() {
        try? FileManager.default.removeItem(at: Self.photoURL)
        try? FileManager.default.removeItem(at: Self.motionURL)
    }

    private func startPlayer(_ url: URL) {
        stopPlayer()
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        queue.play()
    }

    private func stopPlayer() {
        player?.pause()
        looper = nil
        player = nil
    }

    private func updateMotion() {
        guard parallax, kind == .motion, motion.isDeviceMotionAvailable else {
            motion.stopDeviceMotionUpdates()
            reference = nil
            tilt = .zero
            return
        }
        guard !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let attitude = data?.attitude else { return }
            MainActor.assumeIsolated { self?.apply(roll: attitude.roll, pitch: attitude.pitch) }
        }
    }

    private func apply(roll: Double, pitch: Double) {
        let ref = reference ?? (roll, pitch)
        reference = ref
        let limit = 0.5
        let dx = max(-limit, min(limit, roll - ref.roll)) / limit
        let dy = max(-limit, min(limit, pitch - ref.pitch)) / limit
        let reach = 22.0
        let target = CGSize(width: -dx * reach, height: -dy * reach)
        tilt = CGSize(width: tilt.width + (target.width - tilt.width) * 0.2,
                      height: tilt.height + (target.height - tilt.height) * 0.2)
    }

    private nonisolated static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }

    private static func pairedVideo(identifier: String) async -> URL? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .pairedVideo })
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            return url
        } catch {
            return nil
        }
    }
}

struct BackgroundSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store = BackgroundStore.shared
    @State private var picked: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                        Label("Choose photo or video", systemImage: "photo.on.rectangle")
                    }
                    if store.importing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading…").foregroundStyle(HubDesign.secondary)
                        }
                    }
                    if let note = store.note {
                        Text(note).font(.footnote).foregroundStyle(HubDesign.secondary)
                    }
                    if store.kind != .standard {
                        Button("Use default background", role: .destructive) { store.reset() }
                    }
                }
                .listRowBackground(HubDesign.raised)

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "circle").accessibilityHidden(true)
                        Slider(value: $store.blur, in: 0...40)
                            .accessibilityLabel("Blur amount")
                        Image(systemName: "circle.dotted").accessibilityHidden(true)
                    }
                } header: {
                    Text("Blur")
                }
                .listRowBackground(HubDesign.raised)

                Section {
                    Toggle("Parallax", isOn: $store.parallax)
                        .disabled(store.kind != .motion)
                } header: {
                    Text("Motion")
                } footer: {
                    Text("Live Photos and video clips play on a loop and shift as you tilt your phone.")
                }
                .listRowBackground(HubDesign.raised)
            }
            .hubListStyle()
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    await store.importItem(item)
                    picked = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
