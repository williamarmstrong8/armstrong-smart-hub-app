import Foundation
import Observation

// MARK: Models

/// The hub's guess for a morning (lib/fitness/checkin-engine.ts) and what it has learned so far.
struct CheckinPage: Decodable {
    var day: String
    var guess: DayGuess?
    var entry: Checkin?
    var recent: [Checkin]
    var suggestions: [PastStretch]
    var learning: Learning
    var vocabulary: Vocabulary

    struct Learning: Decodable {
        var labelledDays: Int
        var daysOfData: Int
        var states: [StateCount]
        var energy: EnergyLearning
    }
    struct StateCount: Decodable, Identifiable {
        var state: String
        var label: String
        var yes: Int
        var no: Int
        var personal: Double
        var id: String { state }
    }
    struct EnergyLearning: Decodable {
        var ratings: Int
        var error: Double?
        var drivers: [Driver]
    }
    struct Driver: Decodable, Identifiable {
        var input: String
        var effect: Double
        var id: String { input }
    }
    struct Vocabulary: Decodable {
        var states: [Tag]
        var causes: [Tag]
        var symptoms: [Tag]
    }
}

struct Tag: Decodable, Hashable, Identifiable {
    var key: String
    var label: String
    var id: String { key }
}

struct DayGuess: Decodable {
    var day: String
    var energy: Double
    var states: [StateGuess]
    var metrics: [GuessReason]
    var calibrated: Bool
}

struct StateGuess: Decodable, Identifiable {
    var state: String
    var label: String
    var probability: Double
    /// How much of the guess comes from the person's own labels (0–1).
    var personal: Double
    var reasons: [GuessReason]
    var id: String { state }
}

struct GuessReason: Decodable, Identifiable, Hashable {
    var metric: String
    var label: String
    var value: String
    var usual: String
    var z: Double
    var id: String { metric }
}

struct PastStretch: Decodable, Identifiable, Hashable {
    var state: String
    var label: String
    var from: String
    var to: String
    var peak: Double
    var id: String { "\(state) \(from)" }
}

struct Checkin: Codable, Equatable {
    var day: String
    var energy: Int?
    var mood: Int?
    var soreness: Int?
    var tags: [String]
    var rejected: [String]
    var note: String?
}

struct SessionGuess: Decodable {
    var feel: Int?
    var effort: Int?
    var reasons: [String]
}

struct SessionFeedback: Codable, Equatable {
    var kind: String
    var refId: String
    var feel: Int?
    var effort: Int?
    var vsExpected: Int?
    var tags: [String]
    var note: String?
}

// MARK: Store

/// Morning check-ins and how sessions felt. Answers are kept on the phone and
/// sent when the hub answers, so checking in works with no hub in reach.
@MainActor
@Observable
final class CheckinStore {
    static let shared = CheckinStore()

    private(set) var page: CheckinPage?
    private(set) var error: String?
    private(set) var loading = false
    /// Answers the hub hasn't confirmed yet.
    private(set) var pending: [Pending] = []

    /// A guess counts as a guess from this probability up.
    static let threshold = 0.4

    /// When the newest sleep ended, from the Fitness snapshot.
    var lastWake: Date?

    /// The morning being asked about. It turns over when the person wakes up,
    /// not at midnight: up at 12:30 am, last night's sleep hasn't happened yet,
    /// so it's still yesterday. With no sleep ended today, 6 am is the cutover.
    var day: String {
        let calendar = Calendar.current
        if let lastWake, calendar.isDateInToday(lastWake) { return localDay() }
        if calendar.component(.hour, from: .now) < 6 { return addDays(localDay(), -1) }
        return localDay()
    }

    enum Pending: Codable, Equatable {
        case checkin(Checkin, guess: GuessEcho?)
        case stretch(state: String, from: String, to: String, yes: Bool)
        case session(SessionFeedback)
    }

    /// What the hub guessed, sent back with the answer so guess and answer can be compared later.
    struct GuessEcho: Codable, Equatable {
        var energy: Double
        var states: [String: Double]
    }

    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "Fitness/checkin.json")
    private static let pendingURL = URL.applicationSupportDirectory.appending(path: "Fitness/checkin-pending.json")

    init() {
        if let data = try? Data(contentsOf: Self.pendingURL), let saved = try? JSONDecoder().decode([Pending].self, from: data) {
            pending = saved
        }
        if let data = try? Data(contentsOf: Self.cacheURL), let cached = try? APIClient.decoder.decode(CheckinPage.self, from: data) {
            page = cached
        }
    }

    /// Today's answer: the one waiting to send, else the hub's.
    func entry(for day: String) -> Checkin? {
        for case let .checkin(c, _) in pending.reversed() where c.day == day { return c }
        return page?.day == day ? page?.entry : page?.recent.first { $0.day == day }
    }

    /// The guess for today, once the hub has last night.
    var guess: DayGuess? { page?.day == day ? page?.guess : nil }

    /// States the hub thinks are likely this morning, most likely first.
    var likely: [StateGuess] { (guess?.states ?? []).filter { $0.probability >= Self.threshold } }

    /// Past stretches still to answer, without the ones answered on this phone.
    var suggestions: [PastStretch] {
        let answered = Set(pending.compactMap { p -> String? in
            if case let .stretch(state, from, _, _) = p { return "\(state) \(from)" }
            return nil
        })
        return (page?.suggestions ?? []).filter { !answered.contains($0.id) }
    }

    func load(api: APIClient, day: String? = nil) async {
        let day = day ?? self.day
        await flush(api: api)
        loading = true
        defer { loading = false }
        do {
            let data = try await api.data(api.request("/api/mobile/fitness/checkin?day=\(day)&tz=\(TimeZone.current.secondsFromGMT())"))
            page = try APIClient.decoder.decode(CheckinPage.self, from: data)
            error = nil
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(_ checkin: Checkin, api: APIClient) async {
        let echo = guess.map { g in GuessEcho(energy: g.energy, states: Dictionary(uniqueKeysWithValues: g.states.map { ($0.state, $0.probability) })) }
        pending.removeAll { if case let .checkin(c, _) = $0 { c.day == checkin.day } else { false } }
        enqueue(.checkin(checkin, guess: echo))
        await flush(api: api)
    }

    func answer(_ stretch: PastStretch, yes: Bool, api: APIClient) async {
        enqueue(.stretch(state: stretch.state, from: stretch.from, to: stretch.to, yes: yes))
        await flush(api: api)
    }

    func save(_ feedback: SessionFeedback, api: APIClient) async {
        pending.removeAll { if case let .session(f) = $0 { f.kind == feedback.kind && f.refId == feedback.refId } else { false } }
        enqueue(.session(feedback))
        await flush(api: api)
    }

    /// The hub's guess for a session and the saved answer, when there is one.
    func session(kind: String, id: String, api: APIClient) async -> (guess: SessionGuess?, feedback: SessionFeedback?) {
        struct Response: Decodable { var guess: SessionGuess; var feedback: SessionFeedback? }
        let waiting = pending.lazy.compactMap { p -> SessionFeedback? in
            if case let .session(f) = p, f.kind == kind, f.refId == id { return f }
            return nil
        }.last
        let response: Response? = try? await api.get("/api/mobile/fitness/feedback?kind=\(kind)&id=\(id)&tz=\(TimeZone.current.secondsFromGMT())")
        return (response?.guess, waiting ?? response?.feedback)
    }

    // MARK: Sending

    private func enqueue(_ item: Pending) {
        pending.append(item)
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pending) { try? data.write(to: Self.pendingURL, options: .atomic) }
    }

    private var flushing = false

    /// Sends what's waiting, oldest first, and stops at the first failure so the order holds.
    func flush(api: APIClient) async {
        guard !flushing, !pending.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        while let item = pending.first {
            do {
                switch item {
                case let .checkin(c, guess):
                    struct Body: Encodable {
                        var day: String; var energy: Int?; var mood: Int?; var soreness: Int?
                        var tags: [String]; var rejected: [String]; var note: String?; var guess: GuessEcho?
                    }
                    let body = Body(day: c.day, energy: c.energy, mood: c.mood, soreness: c.soreness, tags: c.tags, rejected: c.rejected, note: c.note, guess: guess)
                    let _: Empty = try await api.send(api.request("/api/mobile/fitness/checkin", method: "PUT", body: body))
                    if page?.day == c.day { page?.entry = c }
                case let .stretch(state, from, to, yes):
                    struct Stretch: Encodable { var state: String; var from: String; var to: String; var yes: Bool }
                    struct Body: Encodable { var stretch: Stretch }
                    let _: Empty = try await api.send(api.request("/api/mobile/fitness/checkin", method: "PUT",
                                                                  body: Body(stretch: Stretch(state: state, from: from, to: to, yes: yes))))
                    page?.suggestions.removeAll { $0.state == state && $0.from == from }
                case let .session(f):
                    let _: Empty = try await api.send(api.request("/api/mobile/fitness/feedback", method: "PUT", body: f))
                }
                pending.removeFirst()
                persist()
            } catch {
                return
            }
        }
    }
}
