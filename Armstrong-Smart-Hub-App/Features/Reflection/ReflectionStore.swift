import Foundation
import Observation

struct ReflectionQuote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var author: String
    var added = Date()
}

struct JournalEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var created = Date()
    var updated = Date()
}

struct MeditationRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var minutes: Int
}

/// Quotes, journal entries and finished meditations, kept in a file on the phone.
@MainActor
@Observable
final class ReflectionStore {
    private(set) var quotes: [ReflectionQuote] = []
    private(set) var entries: [JournalEntry] = []
    private(set) var sessions: [MeditationRecord] = []

    private struct Saved: Codable {
        var quotes: [ReflectionQuote]
        var entries: [JournalEntry]
        var sessions: [MeditationRecord]
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "Reflection.json")

    init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        quotes = saved.quotes
        entries = saved.entries
        sessions = saved.sessions
    }

    private func persist() {
        let saved = Saved(quotes: quotes, entries: entries, sessions: sessions)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    var totalMinutes: Int { sessions.reduce(0) { $0 + $1.minutes } }

    func addQuote(text: String, author: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quotes.insert(ReflectionQuote(text: text, author: author.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
        persist()
    }

    func deleteQuote(_ id: UUID) {
        quotes.removeAll { $0.id == id }
        persist()
    }

    func saveEntry(id: UUID?, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id, let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].text = text
            entries[i].updated = Date()
        } else {
            entries.insert(JournalEntry(text: text), at: 0)
        }
        persist()
    }

    func deleteEntry(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func finishedMeditation(minutes: Int) {
        sessions.insert(MeditationRecord(minutes: minutes), at: 0)
        persist()
    }
}
