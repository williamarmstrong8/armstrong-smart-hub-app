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
    /// The page it's on, when given.
    var page: Int?
    /// The chapter of its book it's filed under; nil (or a deleted chapter) files it under no chapter.
    var chapterID: UUID?

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
        page = try c.decodeIfPresent(Int.self, forKey: .page)
        chapterID = try c.decodeIfPresent(UUID.self, forKey: .chapterID)
    }
}

/// A book's quotes filed under one chapter, or under none when `chapter` is nil.
struct QuoteGroup: Identifiable {
    let chapter: BookChapter?
    let quotes: [ReflectionQuote]
    var id: UUID? { chapter?.id }
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
        #if DEBUG
        if Demo.isOn { seedDemo(); return }
        #endif
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        quotes = saved.quotes
        entries = saved.entries
        sessions = saved.sessions
        books = saved.books
    }

    private func persist() {
        // Demo mode keeps its sample books and quotes in memory and never touches the saved file.
        if Demo.isOn { return }
        let saved = Saved(quotes: quotes, entries: entries, sessions: sessions, books: books)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    var totalMinutes: Int { sessions.reduce(0) { $0 + $1.minutes } }

    func addQuote(text: String, author: String, bookID: UUID? = nil, note: String = "",
                  page: Int? = nil, chapterID: UUID? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var quote = ReflectionQuote(text: text, author: author.trimmingCharacters(in: .whitespacesAndNewlines), bookID: bookID)
        quote.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        quote.page = page.flatMap { $0 > 0 ? $0 : nil }
        quote.chapterID = bookID == nil ? nil : chapterID
        quotes.insert(quote, at: 0)
        persist()
    }

    func setQuoteNote(_ id: UUID, _ note: String) {
        guard let i = quotes.firstIndex(where: { $0.id == id }), quotes[i].note != note else { return }
        quotes[i].note = note
        persist()
    }

    /// Updates a quote's note, page and chapter together.
    func updateQuote(_ id: UUID, note: String, page: Int?, chapterID: UUID?) {
        guard let i = quotes.firstIndex(where: { $0.id == id }) else { return }
        var q = quotes[i]
        q.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        q.page = page.flatMap { $0 > 0 ? $0 : nil }
        q.chapterID = q.bookID == nil ? nil : chapterID
        guard q != quotes[i] else { return }
        quotes[i] = q
        persist()
    }

    /// The chapter to suggest for a new quote from a book: the one its latest quote was filed under.
    func lastChapter(in bookID: UUID) -> UUID? {
        let chapters = Set(book(bookID)?.chapters?.map(\.id) ?? [])
        return quotes.first { $0.bookID == bookID && $0.chapterID.map(chapters.contains) == true }?.chapterID
    }

    /// A book's quotes grouped by chapter, in the book's chapter order, each group sorted by page.
    /// Quotes with no chapter (or whose chapter was deleted) come last, under a nil chapter.
    func quotesByChapter(in bookID: UUID) -> [QuoteGroup] {
        let all = quotes(in: bookID)
        let chapters = book(bookID)?.chapters ?? []
        func ordered(_ list: [ReflectionQuote]) -> [ReflectionQuote] {
            list.sorted { a, b in
                switch (a.page, b.page) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.added < b.added
                }
            }
        }
        var groups: [QuoteGroup] = []
        for chapter in chapters {
            let inChapter = all.filter { $0.chapterID == chapter.id }
            if !inChapter.isEmpty { groups.append(QuoteGroup(chapter: chapter, quotes: ordered(inChapter))) }
        }
        let known = Set(chapters.map(\.id))
        let loose = all.filter { $0.chapterID.map(known.contains) != true }
        if !loose.isEmpty { groups.append(QuoteGroup(chapter: nil, quotes: ordered(loose))) }
        return groups
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

    /// Adds the next chapter in order, "Chapter 1", "Chapter 2" and so on, to be renamed later.
    func addNumberedChapter(_ id: UUID) {
        guard let book = book(id) else { return }
        let taken = Set((book.chapters ?? []).compactMap { c -> Int? in
            guard c.title.hasPrefix("Chapter ") else { return nil }
            return Int(c.title.dropFirst("Chapter ".count))
        })
        var n = (book.chapters?.count ?? 0) + 1
        while taken.contains(n) { n += 1 }
        addChapter(id, title: "Chapter \(n)")
    }

    func renameChapter(_ bookID: UUID, chapter: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = books.firstIndex(where: { $0.id == bookID }),
              let j = books[i].chapters?.firstIndex(where: { $0.id == chapter }) else { return }
        books[i].chapters?[j].title = title
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
        for j in quotes.indices where quotes[j].chapterID == chapter { quotes[j].chapterID = nil }
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

#if DEBUG
extension ReflectionStore {
    /// Demo mode's shelf: public-domain books, quotes from them and a few on their own,
    /// a couple of journal entries and some meditation. In memory only.
    fileprivate func seedDemo() {
        let day: TimeInterval = 86400
        func book(_ key: String, _ title: String, _ author: String, _ year: String, _ pages: Int,
                  chapters: [String], bookmark: Int?, daysAgo: Double) -> Book {
            var b = Book(sourceKey: key, title: title, author: author)
            b.year = year
            b.pages = pages
            b.chapters = chapters.map { BookChapter(title: $0) }
            b.bookmarkPage = bookmark
            b.bookmarkedAt = bookmark.map { _ in Date().addingTimeInterval(-daysAgo * day / 3) }
            b.added = Date().addingTimeInterval(-daysAgo * day)
            return b
        }
        let meditations = book("demo/meditations", "Meditations", "Marcus Aurelius", "180", 254,
                               chapters: ["Book Two", "Book Four", "Book Six", "Book Eight"], bookmark: 142, daysAgo: 40)
        let walden = book("demo/walden", "Walden", "Henry David Thoreau", "1854", 352,
                          chapters: ["Economy", "Where I Lived, and What I Lived For", "Solitude", "Conclusion"], bookmark: 96, daysAgo: 21)
        let seneca = book("demo/letters", "Letters from a Stoic", "Seneca", "65", 254,
                          chapters: ["On Saving Time", "On the Shortness of Life", "On Old Age"], bookmark: 61, daysAgo: 9)
        let emerson = book("demo/self-reliance", "Self-Reliance", "Ralph Waldo Emerson", "1841", 64,
                           chapters: [], bookmark: nil, daysAgo: 3)
        books = [emerson, seneca, walden, meditations]

        func quote(_ text: String, _ b: Book?, author: String? = nil, page: Int? = nil, chapter: Int? = nil,
                   note: String = "", daysAgo: Double) -> ReflectionQuote {
            var q = ReflectionQuote(text: text, author: author ?? b?.author ?? "", bookID: b?.id)
            q.page = page
            q.chapterID = chapter.flatMap { b?.chapters?[$0].id }
            q.note = note
            q.added = Date().addingTimeInterval(-daysAgo * day)
            return q
        }
        quotes = [
            quote("Insist on yourself; never imitate.", emerson, page: 22, daysAgo: 1),
            quote("Nothing can bring you peace but yourself.", emerson, page: 61, note: "Ending of the essay.", daysAgo: 2),
            quote("Hold every hour in your grasp.", seneca, page: 3, chapter: 0, daysAgo: 6),
            quote("Life is long if you know how to use it.", seneca, page: 18, chapter: 1, note: "Re-read on Sundays.", daysAgo: 8),
            quote("I went to the woods because I wished to live deliberately.", walden, page: 90, chapter: 1, daysAgo: 12),
            quote("Our life is frittered away by detail. Simplify, simplify.", walden, page: 92, chapter: 1, daysAgo: 14),
            quote("I never found the companion that was so companionable as solitude.", walden, page: 135, chapter: 2, daysAgo: 17),
            quote("You have power over your mind, not outside events. Realize this, and you will find strength.", meditations,
                  page: 64, chapter: 1, daysAgo: 24),
            quote("The best revenge is not to be like your enemy.", meditations, page: 88, chapter: 2, daysAgo: 29),
            quote("Waste no more time arguing about what a good man should be. Be one.", meditations, page: 141, chapter: 3,
                  note: "Pinned above the desk.", daysAgo: 33),
            quote("Well done is better than well said.", nil, author: "Benjamin Franklin", daysAgo: 4),
            quote("It is not the man who has too little, but the man who craves more, that is poor.", nil, author: "Seneca", daysAgo: 19),
        ]

        func entry(_ text: String, daysAgo: Double) -> JournalEntry {
            var e = JournalEntry(text: text)
            e.created = Date().addingTimeInterval(-daysAgo * day)
            e.updated = e.created
            return e
        }
        entries = [
            entry("Long run before work, then a quiet morning. Phone stayed in the drawer until noon and the day felt twice as long.", daysAgo: 1),
            entry("Finished Walden's Solitude chapter on the porch. Want to try one evening a week with no screens at all.", daysAgo: 5),
            entry("Hard week. Slept badly, skipped two workouts. Tomorrow: bed by 10:30, stretch, read twenty pages.", daysAgo: 11),
        ]
        sessions = (0..<18).map { i in
            var m = MeditationRecord(minutes: [10, 12, 15, 10, 20, 8][i % 6])
            m.date = Date().addingTimeInterval(-Double(i) * 1.6 * day)
            return m
        }
    }
}
#endif
