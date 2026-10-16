import Foundation
import Observation

/// Sends a Connect IQ app (a watch face or a glance) to the watch over the same
/// Bluetooth link the sync uses. WatchLink hands every inbound GFDI message to
/// `handle` first, so only the replies to an install in flight are consumed.
///
/// Experimental: the protocol is ported from Gadgetbridge and has not been
/// run against a real Forerunner 965.
@MainActor
@Observable
final class WatchInstaller {
    private(set) var isInstalling = false
    /// 0...1 while sending.
    private(set) var fraction: Double?
    private(set) var status: String?
    private(set) var lastResult: String?

    weak var link: WatchLink?
    private let idleTimeout: TimeInterval = 20

    // Replies, filled in by `handle` and consumed by `install`.
    private var createReply: Result<GarminUpload.CreateReply, GarminUpload.Failure>?
    private var uploadReply: Result<Int, GarminUpload.Failure>?
    private var transferReply: Result<Int, GarminUpload.Failure>?
    private var lastProgress = Date()

    func install(_ data: [UInt8], name: String, busy: Bool) async {
        guard !isInstalling else { return }
        guard let link else { return }
        isInstalling = true
        fraction = 0
        lastResult = nil
        defer {
            isInstalling = false
            fraction = nil
            createReply = nil
            uploadReply = nil
            transferReply = nil
        }
        do {
            guard !busy else { throw GarminUpload.Failure.busy }
            guard link.state == .connected else { throw GarminUpload.Failure.disconnected }
            guard GarminUpload.looksLikePRG(data) else { throw GarminUpload.Failure.notPRG }
            guard data.count <= GarminUpload.maxBytes else { throw GarminUpload.Failure.tooLarge }

            status = "Asking the watch for space"
            createReply = nil
            link.send(GarminUpload.createFile(size: data.count))
            try await waitFor("create") { self.createReply != nil }
            let index = try createReply!.get().fileIndex

            status = "Starting the transfer"
            uploadReply = nil
            link.send(GarminUpload.uploadRequest(index: index, size: data.count))
            try await waitFor("upload request") { self.uploadReply != nil }
            let start = try uploadReply!.get()
            guard start == 0 else { throw GarminUpload.Failure.protocolError("watch wants offset \(start), not 0") }

            status = "Sending \(name)"
            var offset = 0
            var crc: UInt16 = 0
            while offset < data.count {
                let end = min(offset + GarminUpload.chunkSize, data.count)
                let slice = Array(data[offset..<end])
                crc = GarminCRC.compute(slice, initial: crc)
                transferReply = nil
                link.send(GarminUpload.chunk(slice, offset: offset, runningCRC: crc))
                try await waitFor("data at \(offset)") { self.transferReply != nil }
                let next = try transferReply!.get()
                guard next == end else { throw GarminUpload.Failure.protocolError("watch acknowledged \(next), expected \(end)") }
                offset = end
                fraction = Double(offset) / Double(data.count)
            }

            link.send(GFDIMessage.systemEvent(.syncComplete))
            status = nil
            // Hub glances are named "Glance: …"; everything else is a watch face.
            let howTo = name.hasPrefix("Glance:")
                ? "On the watch: swipe up to your glances, scroll to the bottom, Edit, then Add and pick it."
                : "On the watch: hold Up, then Watch Face, and pick it."
            lastResult = "Sent \(name) (\(data.count / 1024) KB). \(howTo)"
        } catch {
            status = nil
            lastResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Shows an error that happened before the install could start (a failed download, say).
    func report(_ error: Error) {
        lastResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func waitFor(_ what: String, until done: () -> Bool) async throws {
        lastProgress = .now
        while !done() {
            guard link?.state == .connected else { throw GarminUpload.Failure.disconnected }
            if Date.now.timeIntervalSince(lastProgress) > idleTimeout { throw GarminUpload.Failure.timeout(what) }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// True when the message answered an install step.
    func handle(_ message: GFDIMessage) -> Bool {
        guard isInstalling, message.type == Garmin.Message.response.rawValue else { return false }
        if let reply = GarminUpload.createReply(message.payload) {
            createReply = reply
        } else if let reply = GarminUpload.uploadReply(message.payload) {
            uploadReply = reply
        } else if let reply = GarminUpload.transferReply(message.payload) {
            transferReply = reply
        } else {
            return false
        }
        lastProgress = .now
        return true
    }
}
