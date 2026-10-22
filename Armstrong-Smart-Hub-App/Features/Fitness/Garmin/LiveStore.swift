import Foundation
import Observation

/// The watch's live heart rate, stress and Body Battery, kept on the phone.
///
/// The watch hands over its all-day file only at midnight, so today exists
/// nowhere but here until then. Every reading is kept for two days (one per
/// kind and minute, the newest wins) in Application Support/Fitness/live.json,
/// so the app can chart today with no hub at all; readings the hub hasn't
/// acknowledged stay marked until an upload succeeds, whenever that is.
@MainActor
@Observable
final class LiveStore {
    static let shared = LiveStore()

    enum Kind: String, Codable, CaseIterable { case heartRate = "heart_rate", stress, bodyBattery = "body_battery" }

    struct Sample: Codable, Equatable {
        var kind: Kind
        var at: Date
        var value: Int
    }

    /// Bumped once per new minute of readings, so views redraw per minute rather than per packet.
    private(set) var revision = 0

    @ObservationIgnored private var samples: [String: Sample] = [:]
    /// Keys of readings the hub doesn't have yet.
    @ObservationIgnored private var unsent: Set<String> = []
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let keep: TimeInterval = 2 * 86400
    private let url = URL.applicationSupportDirectory.appending(path: "Fitness/live.json")

    private struct File: Codable { var samples: [Sample]; var unsent: [String] }

    init() {
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            for sample in file.samples { samples[Self.key(sample)] = sample }
            unsent = Set(file.unsent).intersection(samples.keys)
        }
        prune()
    }

    private static func key(_ sample: Sample) -> String { "\(sample.kind.rawValue)|\(Int(sample.at.timeIntervalSince1970))" }

    // MARK: Recording

    func record(_ kind: Kind, _ value: Int, at date: Date = .now) {
        let minute = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let sample = Sample(kind: kind, at: minute, value: value)
        let key = Self.key(sample)
        let isNew = samples[key] == nil
        guard samples[key] != sample else { return }
        samples[key] = sample
        unsent.insert(key)
        WidgetSync.live(kind, value, at: minute)
        if isNew {
            revision += 1
            prune()
        }
        scheduleSave()
    }

    /// Writes at most every 30 seconds; HR alone changes every second.
    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(30))
            saveTask = nil
            save()
        }
    }

    /// Writes now, for when the app is about to be suspended.
    func save() {
        guard dirty else { return }
        dirty = false
        let file = File(samples: samples.values.sorted { $0.at < $1.at }, unsent: Array(unsent))
        guard let data = try? JSONEncoder().encode(file) else { return }
        // Readable after the first unlock: the watch writes here with the phone locked.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-Self.keep)
        let old = samples.filter { $0.value.at < cutoff }.map(\.key)
        guard !old.isEmpty else { return }
        for key in old {
            samples[key] = nil
            unsent.remove(key)
        }
        dirty = true
    }

    // MARK: Hub

    /// Readings not yet acknowledged by the hub, oldest first.
    func pending(limit: Int) -> [Sample] {
        Array(unsent.compactMap { samples[$0] }.sorted { $0.at < $1.at }.prefix(limit))
    }

    /// The hub has these. A reading that changed since it was taken stays unsent.
    func markSent(_ sent: [Sample]) {
        for sample in sent where samples[Self.key(sample)] == sample { unsent.remove(Self.key(sample)) }
        dirty = true
        save()
    }

    var unsentCount: Int { unsent.count }

    // MARK: Reading

    /// Readings of one kind since `date`, oldest first.
    func series(_ kind: Kind, since date: Date = .distantPast) -> [Sample] {
        _ = revision
        return samples.values.filter { $0.kind == kind && $0.at >= date }.sorted { $0.at < $1.at }
    }

    /// The newest reading of a kind, if it's under `maxAge` old.
    func latest(_ kind: Kind, maxAge: TimeInterval = 600) -> Sample? {
        _ = revision
        return samples.values.filter { $0.kind == kind }.max { $0.at < $1.at }
            .flatMap { Date.now.timeIntervalSince($0.at) < maxAge ? $0 : nil }
    }
}
