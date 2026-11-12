import SwiftUI

// MARK: Search source

/// A book from Open Library's search, ready to add to the catalog.
struct BookResult: Identifiable, Hashable {
    /// The Open Library work key.
    let id: String
    let title: String
    let author: String
    let coverURL: String?
    let year: String?
    let pages: Int?
    let publisher: String?
}

enum BookSearch {
    private struct Response: Decodable { let docs: [Doc] }
    private struct Doc: Decodable {
        let key: String
        let title: String?
        let authorName: [String]?
        let firstPublishYear: Int?
        let coverI: Int?
        let numberOfPagesMedian: Int?
        let publisher: [String]?
    }

    static func search(_ query: String) async throws -> [BookResult] {
        var parts = URLComponents(string: "https://openlibrary.org/search.json")
        parts?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,cover_i,number_of_pages_median,publisher"),
        ]
        guard let url = parts?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("ArmstrongHub/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let docs = try decoder.decode(Response.self, from: data).docs
        let books = docs.compactMap { d -> BookResult? in
            guard let title = d.title, !title.isEmpty else { return nil }
            return BookResult(id: d.key, title: title, author: d.authorName?.first ?? "Unknown author",
                              coverURL: d.coverI.map { "https://covers.openlibrary.org/b/id/\($0)-L.jpg" },
                              year: d.firstPublishYear.map(String.init), pages: d.numberOfPagesMedian,
                              publisher: d.publisher?.first)
        }
        // Covers first: the gallery is mostly artwork.
        return books.filter { $0.coverURL != nil } + books.filter { $0.coverURL == nil }
    }

    /// Chapter titles from the first edition of the work that lists a table of contents.
    static func chapters(workKey: String) async throws -> [String] {
        guard let url = URL(string: "https://openlibrary.org\(workKey)/editions.json?limit=50") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("ArmstrongHub/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else { return [] }
        for entry in entries {
            guard let toc = entry["table_of_contents"] as? [Any] else { continue }
            var titles: [String] = []
            for item in toc {
                var title = ""
                var label = ""
                if let s = item as? String {
                    title = s
                } else if let d = item as? [String: Any] {
                    title = (d["title"] as? String) ?? ""
                    label = (d["label"] as? String) ?? ""
                }
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let full = label.isEmpty ? title : (title.isEmpty ? label : "\(label). \(title)")
                if !full.isEmpty, !titles.contains(full) { titles.append(full) }
            }
            if titles.count >= 2 { return Array(titles.prefix(100)) }
        }
        return []
    }
}

// MARK: Catalog

/// Home's movie shelf, for books: the covers of what's been added, newest first.
struct BookShelf: View {
    let books: [Book]
    let onPick: (Book) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(books) { b in
                    Button { onPick(b) } label: {
                        Poster(url: b.coverURL, width: 150, symbol: "book.closed")
                            .clipShape(.rect(cornerRadius: 18))
                            .shadow(color: .black.opacity(0.14), radius: 10, y: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(b.title), \(b.author)")
                    .accessibilityHint("Opens the book")
                }
            }
            .padding(.horizontal, HubLayout.gutter)
        }
        .padding(.horizontal, -HubLayout.gutter)
        .scrollClipDisabled()
    }
}

/// The movie search page, for books: a Liquid Glass field over a grid of covers. Tapping a cover
/// adds the book to the catalog.
struct BookSearchView: View {
    let store: ReflectionStore
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @State private var searchID = UUID()
    @State private var query = ""
    @State private var results: [BookResult]?
    @State private var error: String?
    @State private var searching = false
    @State private var showClose = false
    @FocusState private var focused: Bool

    private var typing: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(HubDesign.secondary)
                        TextField("Search books", text: $query)
                            .focused($focused)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if searching { ProgressView().controlSize(.small) }
                        Button {
                            query = ""
                            results = nil
                            error = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Clear search")
                        .foregroundStyle(HubDesign.secondary)
                        .buttonStyle(.plain)
                        .opacity(typing ? 1 : 0)
                        .disabled(!typing)
                        .accessibilityHidden(!typing)
                    }
                    .padding(.leading, 18).padding(.trailing, 4).padding(.vertical, 4)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("field", in: glass)

                    if showClose {
                        Button { focused = false; onClose() } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("close", in: glass)
                        .accessibilityLabel("Close search")
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { Text(error).font(.footnote).foregroundStyle(HubDesign.danger) }
                    if !typing {
                        Text("Search by title or author, then tap a cover to add it.")
                            .font(.subheadline).foregroundStyle(HubDesign.secondary)
                    } else if results?.isEmpty == true, !searching {
                        Text("Nothing found.").font(.subheadline).foregroundStyle(HubDesign.secondary)
                    } else {
                        grid(results ?? [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, HubLayout.gutter)
        .padding(.top, HubLayout.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .hubPageStyle()
        .sensoryFeedback(.success, trigger: store.books.count)
        .task {
            withAnimation(HubMotion.animation(reduceMotion: reduceMotion)) { showClose = true }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            focused = true
        }
        .task(id: query) {
            let id = UUID()
            searchID = id
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            searching = !q.isEmpty
            error = nil
            defer { if searchID == id { searching = false } }
            guard !q.isEmpty else { results = nil; return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let found = try await BookSearch.search(q)
                guard !Task.isCancelled, searchID == id else { return }
                results = found
            } catch {
                guard !Task.isCancelled, searchID == id else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func grid(_ items: [BookResult]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 16) {
            ForEach(items) { r in
                let added = store.hasBook(r.id)
                Button {
                    focused = false
                    store.addBook(r)
                } label: {
                    Poster(url: r.coverURL, radius: 16, symbol: "book.closed")
                        .overlay {
                            if added {
                                ZStack {
                                    Color.black.opacity(0.45)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.white)
                                }
                                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(added)
                .accessibilityLabel("\(r.title), \(r.author)\(added ? ", added" : "")")
                .accessibilityHint(added ? "" : "Adds the book")
            }
        }
    }
}

// MARK: Detail

/// A book in full: its cover and details, a bookmark to move after reading, notes, and the
/// quotes saved from it.
struct BookDetailView: View {
    let store: ReflectionStore
    let bookID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var notes: String
    @State private var showsGeneralNotes: Bool
    @State private var openChapterID: UUID?
    @State private var addingChapter = false
    @State private var chapterTitle = ""
    @State private var askingPage = false
    @State private var pageText = ""
    @State private var confirmRemove = false
    @State private var editingQuote: ReflectionQuote?
    @State private var scanning = false
    @FocusState private var notesFocused: Bool

    init(store: ReflectionStore, bookID: UUID) {
        self.store = store
        self.bookID = bookID
        _notes = State(initialValue: store.book(bookID)?.notes ?? "")
        _showsGeneralNotes = State(initialValue: !(store.book(bookID)?.notes ?? "").isEmpty)
    }

    var body: some View {
        ScrollView {
            if let book = store.book(bookID) {
                VStack(spacing: HubLayout.sectionGap) {
                    header(book)
                    bookmarkCard(book)
                    chaptersSection(book)
                    if showsGeneralNotes { notesCard }
                    quotesSection(book)
                    Button("Remove book", role: .destructive) { confirmRemove = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HubDesign.danger)
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(store.book(bookID)?.title ?? "Book")
        .navigationBarTitleDisplayMode(.inline)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hubPageStyle()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { notesFocused = false }
            }
        }
        .onChange(of: notes) { _, value in store.setBookNotes(bookID, value) }
        .navigationDestination(item: $openChapterID) { id in
            ChapterNotesView(store: store, bookID: bookID, chapterID: id)
        }
        .task(id: bookID) { await loadChapters() }
        .alert("New chapter", isPresented: $addingChapter) {
            TextField("Chapter title", text: $chapterTitle)
            Button("Add") { store.addChapter(bookID, title: chapterTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Bookmark", isPresented: $askingPage) {
            TextField("Page", text: $pageText).keyboardType(.numberPad)
            Button("Save") { saveBookmark() }
            if store.book(bookID)?.bookmarkPage != nil {
                Button("Remove bookmark", role: .destructive) { store.setBookmark(bookID, page: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Which page did you get to?")
        }
        .confirmationDialog("Remove this book?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove book and its quotes", role: .destructive) {
                store.deleteBook(bookID)
                dismiss()
            }
        } message: {
            Text("Its notes and saved quotes are removed too.")
        }
        .sheet(item: $editingQuote) { q in
            QuoteNoteSheet(quote: q, store: store)
                .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $scanning) {
            QuoteScanFlow(store: store, bookID: bookID) { scanning = false }
        }
    }

    // MARK: Pieces

    private func header(_ book: Book) -> some View {
        VStack(spacing: 16) {
            Poster(url: book.coverURL, width: 220, radius: 24, symbol: "book.closed")
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                .accessibilityLabel("Cover of \(book.title)")
            VStack(spacing: 6) {
                Text(book.title)
                    .font(.largeTitle.weight(.light))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(book.author).font(.title3).foregroundStyle(HubDesign.secondary)
                    .multilineTextAlignment(.center)
            }
            let facts = details(book)
            if !facts.isEmpty {
                BrickCard {
                    VStack(spacing: 0) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { i, fact in
                            if i > 0 { Divider().overlay(HubDesign.separator) }
                            HStack(alignment: .firstTextBaseline) {
                                Text(fact.0).foregroundStyle(HubDesign.secondary)
                                Spacer(minLength: 16)
                                Text(fact.1).multilineTextAlignment(.trailing)
                            }
                            .font(.subheadline)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    private func details(_ book: Book) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let year = book.year { rows.append(("First published", year)) }
        if let pages = book.pages, pages > 0 { rows.append(("Pages", "\(pages)")) }
        if let publisher = book.publisher { rows.append(("Publisher", publisher)) }
        rows.append(("Added", book.added.formatted(date: .abbreviated, time: .omitted)))
        return rows
    }

    private func bookmarkCard(_ book: Book) -> some View {
        BrickCard {
            VStack(alignment: .leading, spacing: 12) {
                BrickCaps(text: "Bookmark").foregroundStyle(HubDesign.secondary)
                if let page = book.bookmarkPage {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Page \(page)").font(.title2.weight(.regular)).monospacedDigit()
                        if let pages = book.pages, pages > 0 {
                            Text("of \(pages)").font(.callout).foregroundStyle(HubDesign.secondary).monospacedDigit()
                        }
                    }
                    if let pages = book.pages, pages > 0 {
                        ProgressView(value: min(Double(page) / Double(pages), 1)).tint(.teal)
                    }
                    if let at = book.bookmarkedAt {
                        Text("Marked \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(HubDesign.secondary)
                    }
                } else {
                    Text("After a reading session, tap to keep your place. It's optional.")
                        .font(.subheadline).foregroundStyle(HubDesign.secondary)
                }
                Button {
                    pageText = book.bookmarkPage.map(String.init) ?? ""
                    askingPage = true
                } label: {
                    Label(book.bookmarkPage == nil ? "Bookmark my place" : "Move bookmark",
                          systemImage: book.bookmarkPage == nil ? "bookmark" : "bookmark.fill")
                        .font(.headline)
                        .foregroundStyle(HubDesign.ink)
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                        .glassGlare(.regular.tint(HubDesign.action.opacity(0.55)), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chaptersSection(_ book: Book) -> some View {
        let chapters = book.chapters ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chapters").font(.title2.weight(.regular)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    chapterTitle = ""
                    addingChapter = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HubDesign.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: HubLayout.minHitTarget)
                        .glassGlare(.regular, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a chapter")
            }
            if chapters.isEmpty {
                HStack(spacing: 8) {
                    if book.chapters == nil { ProgressView().controlSize(.small) }
                    Text(book.chapters == nil ? "Looking up chapters\u{2026}" : "No chapters found. Add them yourself to keep notes by chapter.")
                        .font(.subheadline).foregroundStyle(HubDesign.secondary)
                }
                .padding(.horizontal, 4)
            } else {
                BrickCard {
                    VStack(spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { i, chapter in
                            if i > 0 { Divider().overlay(HubDesign.separator) }
                            Button { openChapterID = chapter.id } label: {
                                HStack(spacing: 12) {
                                    Text(chapter.title)
                                        .font(.body)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if !chapter.notes.isEmpty {
                                        Image(systemName: "note.text").foregroundStyle(HubDesign.action)
                                            .accessibilityLabel("Has notes")
                                    }
                                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(HubDesign.secondary)
                                }
                                .foregroundStyle(HubDesign.ink)
                                .padding(.vertical, 10)
                                .frame(minHeight: HubLayout.minHitTarget)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens notes for this chapter")
                            .contextMenu {
                                Button("Delete chapter", systemImage: "trash", role: .destructive) {
                                    store.deleteChapter(bookID, chapter: chapter.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadChapters() async {
        guard let book = store.book(bookID), book.chapters == nil else { return }
        guard let titles = try? await BookSearch.chapters(workKey: book.sourceKey), !Task.isCancelled else { return }
        guard store.book(bookID)?.chapters == nil else { return }
        store.setChapters(bookID, titles.map { BookChapter(title: $0) })
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General notes").font(.title2.weight(.regular)).accessibilityAddTraits(.isHeader)
            BrickCard {
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden)
                    .focused($notesFocused)
                    .frame(minHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("Thoughts on this book")
                                .foregroundStyle(HubDesign.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotesSection(_ book: Book) -> some View {
        let quotes = store.quotes(in: book.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quotes").font(.title2.weight(.regular)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { scanning = true } label: {
                    Label("Scan", systemImage: "text.viewfinder")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HubDesign.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: HubLayout.minHitTarget)
                        .glassGlare(.regular, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan a quote from this book")
            }
            if quotes.isEmpty {
                Text("Quotes you scan from this book show up here.")
                    .font(.subheadline).foregroundStyle(HubDesign.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(quotes) { q in
                    Button { editingQuote = q } label: {
                        BrickCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\u{201C}\(q.text)\u{201D}").font(.body).multilineTextAlignment(.leading)
                                if q.note.isEmpty {
                                    Label("Add a note", systemImage: "square.and.pencil")
                                        .font(.footnote).foregroundStyle(HubDesign.action)
                                } else {
                                    Text(q.note).font(.subheadline).foregroundStyle(HubDesign.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                        }
                        .foregroundStyle(HubDesign.ink)
                        .contentShape(.rect(cornerRadius: HubLayout.cardRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the quote to add a note")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveBookmark() {
        guard var page = Int(pageText.trimmingCharacters(in: .whitespacesAndNewlines)), page > 0 else { return }
        if let pages = store.book(bookID)?.pages, pages > 0 { page = min(page, pages) }
        store.setBookmark(bookID, page: page)
    }
}

/// One chapter's page: a place to write notes for it.
private struct ChapterNotesView: View {
    let store: ReflectionStore
    let bookID: UUID
    let chapterID: UUID

    @State private var notes: String
    @FocusState private var focused: Bool

    init(store: ReflectionStore, bookID: UUID, chapterID: UUID) {
        self.store = store
        self.bookID = bookID
        self.chapterID = chapterID
        let chapter = store.book(bookID)?.chapters?.first { $0.id == chapterID }
        _notes = State(initialValue: chapter?.notes ?? "")
    }

    private var chapter: BookChapter? { store.book(bookID)?.chapters?.first { $0.id == chapterID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(chapter?.title ?? "Chapter")
                    .font(.largeTitle.weight(.light))
                    .accessibilityAddTraits(.isHeader)
                if let title = store.book(bookID)?.title {
                    Text(title).font(.subheadline).foregroundStyle(HubDesign.secondary)
                }
                BrickCard {
                    TextEditor(text: $notes)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(minHeight: 280)
                        .overlay(alignment: .topLeading) {
                            if notes.isEmpty {
                                Text("Notes for this chapter")
                                    .foregroundStyle(HubDesign.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .padding(.horizontal, HubLayout.gutter)
            .padding(.vertical, 12)
        }
        .navigationTitle("Chapter notes")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hubPageStyle()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .onChange(of: notes) { _, value in store.setChapterNotes(bookID, chapter: chapterID, value) }
    }
}

/// A saved quote with its note, which can be edited or cleared; the quote can also be deleted.
private struct QuoteNoteSheet: View {
    let quote: ReflectionQuote
    let store: ReflectionStore

    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    init(quote: ReflectionQuote, store: ReflectionStore) {
        self.quote = quote
        self.store = store
        _note = State(initialValue: quote.note)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\u{201C}\(quote.text)\u{201D}").font(.title3)
                    Text("Your note").font(.headline)
                    TextEditor(text: $note)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(minHeight: 160)
                        .padding(8)
                        .background(HubDesign.track.opacity(0.5), in: .rect(cornerRadius: HubLayout.controlRadius))
                    Button("Delete quote", role: .destructive) { confirmDelete = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HubDesign.danger)
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                }
                .padding(HubLayout.gutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.setQuoteNote(quote.id, note); dismiss() }
                }
            }
            .confirmationDialog("Delete this quote?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.deleteQuote(quote.id); dismiss() }
            }
        }
        .hubPageStyle()
    }
}
