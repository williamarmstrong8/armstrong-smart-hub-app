import Foundation
import Observation

struct ReflectionQuote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var author: String
    var added = Date()
    /// The book this quote was saved from; nil for a quote typed in on its own.
    var bookID: UUID?
    var note = ""

    init(text: String, author: String, bookID: UUID? = nil) {
        self.text = text
        self.author = author
        self.bookID = bookID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        author = try c.decode(String.self, forKey: .author)
        added = try c.decode(Date.self, forKey: .added)
        bookID = try c.decodeIfPresent(UUID.self, forKey: .bookID)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct BookChapter: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var notes = ""
}

struct Book: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The Open Library work key, so a book isn't added twice.
    var sourceKey: String
    var title: String
    var author: String
    var coverURL: String?
    var year: String?
    var pages: Int?
    var publisher: String?
    var notes = ""
    /// The page the reader has reached, set after a reading session.
    var bookmarkPage: Int?
    var bookmarkedAt: Date?
    var added = Date()
    /// nil until the chapter list has been looked up; empty when none was found.
    var chapters: [BookChapter]?
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
    private(set) var books: [Book] = []

    private struct Saved: Codable {
        var quotes: [ReflectionQuote]
        var entries: [JournalEntry]
        var sessions: [MeditationRecord]
        var books: [Book]

        init(quotes: [ReflectionQuote], entries: [JournalEntry], sessions: [MeditationRecord], books: [Book]) {
            self.quotes = quotes
            self.entries = entries
            self.sessions = sessions
            self.books = books
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            quotes = try c.decode([ReflectionQuote].self, forKey: .quotes)
            entries = try c.decode([JournalEntry].self, forKey: .entries)
            sessions = try c.decode([MeditationRecord].self, forKey: .sessions)
            books = try c.decodeIfPresent([Book].self, forKey: .books) ?? []
        }
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "Reflection.json")

    init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        quotes = saved.quotes
        entries = saved.entries
        sessions = saved.sessions
        books = saved.books
    }

    private func persist() {
        let saved = Saved(quotes: quotes, entries: entries, sessions: sessions, books: books)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    var totalMinutes: Int { sessions.reduce(0) { $0 + $1.minutes } }

    func addQuote(text: String, author: String, bookID: UUID? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quotes.insert(ReflectionQuote(text: text, author: author.trimmingCharacters(in: .whitespacesAndNewlines), bookID: bookID), at: 0)
        persist()
    }

    func setQuoteNote(_ id: UUID, _ note: String) {
        guard let i = quotes.firstIndex(where: { $0.id == id }), quotes[i].note != note else { return }
        quotes[i].note = note
        persist()
    }

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    func quotes(in bookID: UUID) -> [ReflectionQuote] { quotes.filter { $0.bookID == bookID } }

    func hasBook(_ sourceKey: String) -> Bool { books.contains { $0.sourceKey == sourceKey } }

    func addBook(_ r: BookResult) {
        guard !hasBook(r.id) else { return }
        let book = Book(sourceKey: r.id, title: r.title, author: r.author, coverURL: r.coverURL,
                        year: r.year, pages: r.pages, publisher: r.publisher)
        books.insert(book, at: 0)
        persist()
        Task { await lookUpChapters(book.id) }
    }

    func addManualBook(title: String, author: String, year: String, pages: Int?, publisher: String, coverURL: String) {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        guard let title = clean(title) else { return }
        let book = Book(sourceKey: "/manual/\(UUID().uuidString)", title: title,
                        author: clean(author) ?? "Unknown author", coverURL: clean(coverURL),
                        year: clean(year), pages: pages.flatMap { $0 > 0 ? $0 : nil }, publisher: clean(publisher))
        books.insert(book, at: 0)
        persist()
        Task { await lookUpChapters(book.id) }
    }

    /// Books whose chapters are being looked up right now.
    private(set) var lookingUp: Set<UUID> = []

    /// Fills in a book's chapters from free online sources. Leaves them unset if every source was
    /// unreachable, so a later attempt can retry; sets an empty list when none was found.
    func lookUpChapters(_ id: UUID) async {
        guard let current = self.book(id), current.chapters == nil, !lookingUp.contains(id) else { return }
        lookingUp.insert(id)
        defer { lookingUp.remove(id) }
        guard let titles = await BookSearch.chapters(for: current), self.book(id)?.chapters == nil else { return }
        setChapters(id, titles.map { BookChapter(title: $0) })
    }

    func setBookNotes(_ id: UUID, _ notes: String) {
        guard let i = books.firstIndex(where: { $0.id == id }), books[i].notes != notes else { return }
        books[i].notes = notes
        persist()
    }

    func setChapters(_ id: UUID, _ chapters: [BookChapter]) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].chapters = chapters
        persist()
    }

    func addChapter(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].chapters = (books[i].chapters ?? []) + [BookChapter(title: title)]
        persist()
    }

    func setChapterNotes(_ bookID: UUID, chapter: UUID, _ notes: String) {
        guard let i = books.firstIndex(where: { $0.id == bookID }),
              let j = books[i].chapters?.firstIndex(where: { $0.id == chapter }),
              books[i].chapters?[j].notes != notes else { return }
        books[i].chapters?[j].notes = notes
        persist()
    }

    func deleteChapter(_ bookID: UUID, chapter: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].chapters?.removeAll { $0.id == chapter }
        persist()
    }

    func setBookmark(_ id: UUID, page: Int?) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].bookmarkPage = page
        books[i].bookmarkedAt = page == nil ? nil : Date()
        persist()
    }

    /// Removes the book and the quotes saved from it.
    func deleteBook(_ id: UUID) {
        books.removeAll { $0.id == id }
        quotes.removeAll { $0.bookID == id }
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
