import SwiftUI

/// The Fire TV remote: D-pad, playback, volume, power and Open Jellyfin.
struct RemoteSheet: View {
    let entity: HAEntity

    @Environment(AppSession.self) private var session
    @State private var sending: RemoteCommand?
    @State private var toast = Toast()
    @State private var taps = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                HStack {
                    key(.power, "Power", size: 52) { Image(systemName: "power").foregroundStyle(.red) }
                    Spacer()
                    Button {
                        press(.openJellyfin)
                    } label: {
                        if sending == .openJellyfin { ProgressView() } else { Label("Open Jellyfin", systemImage: "play.fill") }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(entity.remoteTarget(.openJellyfin) == nil || sending == .openJellyfin)
                }

                ZStack {
                    Circle().fill(BrickLook.card).frame(width: 260, height: 260)
                    VStack(spacing: 0) {
                        key(.up, "Up", size: 70, plain: true) { Image(systemName: "chevron.up") }
                        HStack(spacing: 0) {
                            key(.left, "Left", size: 70, plain: true) { Image(systemName: "chevron.left") }
                            key(.select, "Select", size: 96) { Text("OK").font(.headline) }
                            key(.right, "Right", size: 70, plain: true) { Image(systemName: "chevron.right") }
                        }
                        key(.down, "Down", size: 70, plain: true) { Image(systemName: "chevron.down") }
                    }
                    .font(.title2.weight(.semibold))
                }

                HStack {
                    key(.back, "Back", size: 60) { Image(systemName: "arrow.uturn.backward") }
                    Spacer()
                    key(.playPause, "Play or pause", size: 60) { Image(systemName: "playpause.fill") }
                    Spacer()
                    key(.home, "Home", size: 60) { Image(systemName: "house.fill") }
                }
                .padding(.horizontal, 24)

                HStack {
                    key(.volumeDown, "Volume down", size: 56, plain: true) { Image(systemName: "speaker.wave.1.fill") }
                    Spacer()
                    key(.mute, "Mute", size: 56, plain: true) { Image(systemName: "speaker.slash.fill") }
                    Spacer()
                    key(.volumeUp, "Volume up", size: 56, plain: true) { Image(systemName: "speaker.wave.3.fill") }
                }
                .padding(.horizontal, 12)
                .background(BrickLook.card, in: .capsule)

                Spacer()
            }
            .padding(24)
            .navigationTitle(entity.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(entity.name).font(.headline)
                        Text(entity.state.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .brickBackdrop()
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
            .toast(toast)
        }
    }

    private func key<Label: View>(
        _ command: RemoteCommand, _ title: String, size: CGFloat, plain: Bool = false, @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            press(command)
        } label: {
            ZStack {
                if !plain { Circle().fill(BrickLook.pill).shadow(color: .black.opacity(0.08), radius: 4, y: 1) }
                if sending == command { ProgressView() } else { label() }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(entity.remoteTarget(command) == nil || sending == command)
        .opacity(entity.remoteTarget(command) == nil ? 0.35 : 1)
        .accessibilityLabel(title)
    }

    private func press(_ command: RemoteCommand) {
        guard let target = entity.remoteTarget(command) else { return }
        taps += 1
        Task {
            if command.waits { sending = command }
            defer { if command.waits { sending = nil } }
            struct Reply: Decodable { let lastError: String? }
            do {
                let reply: Reply? = try await session.api.run("remote", [.string(target), .string(command.rawValue)])
                if let message = reply?.lastError { toast.show(message, error: true) }
            } catch {
                toast.error(error)
            }
        }
    }
}
