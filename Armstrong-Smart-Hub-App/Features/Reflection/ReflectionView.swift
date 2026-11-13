import SwiftUI

private let durations = [1, 3, 5, 10]

private let floodColors: [(name: String, hex: String)] = [
    ("Ocean", "#2F5BD3"),
    ("Forest", "#1F7A5A"),
    ("Dusk", "#6B46C1"),
    ("Ember", "#C2512D"),
]

private struct BreathPattern: Identifiable, Hashable {
    let id: String
    let name: String
    let inhale: Double
    let holdIn: Double
    let exhale: Double
    let holdOut: Double

    var length: Double { inhale + holdIn + exhale + holdOut }

    var timing: String {
        func n(_ v: Double) -> String { String(Int(v)) }
        if holdIn == 0 && holdOut == 0 { return "\(n(inhale))-\(n(exhale))" }
        if holdOut == 0 { return "\(n(inhale))-\(n(holdIn))-\(n(exhale))" }
        return "\(n(inhale))-\(n(holdIn))-\(n(exhale))-\(n(holdOut))"
    }

    var title: String { "\(name) \(timing)" }

    static let all: [BreathPattern] = [
        BreathPattern(id: "box", name: "Box", inhale: 4, holdIn: 4, exhale: 4, holdOut: 4),
        BreathPattern(id: "478", name: "Relaxing", inhale: 4, holdIn: 7, exhale: 8, holdOut: 0),
        BreathPattern(id: "46", name: "Relaxed", inhale: 4, holdIn: 0, exhale: 6, holdOut: 0),
        BreathPattern(id: "resonance", name: "Resonance", inhale: 5, holdIn: 0, exhale: 5, holdOut: 0),
        BreathPattern(id: "66", name: "Slow coherent", inhale: 6, holdIn: 0, exhale: 6, holdOut: 0),
    ]

    static func find(_ id: String) -> BreathPattern { all.first { $0.id == id } ?? all[0] }
}

private struct MeditationRun: Identifiable {
    let id = UUID()
    let minutes: Int
    let hex: String
    let pattern: BreathPattern
}

private enum JournalTarget: Identifiable {
    case new
    case entry(JournalEntry)

    var id: String {
        switch self {
        case .new: "new"
        case .entry(let e): e.id.uuidString
        }
    }
}

/// Reflection: guided breathing that floods the screen with colour, quotes worth keeping, and a journal.
struct ReflectionView: View {
    @State private var store = ReflectionStore()
    @AppStorage("reflection.goal") private var goal = 60
    @State private var startingSession = false
    @State private var addingQuote = false
    @State private var quoteToDelete: ReflectionQuote?
    @State private var confirmQuoteDelete = false
    @State private var journal: JournalTarget?
    @State private var searchingBooks = false
    @State private var openBookID: UUID?

    var body: some View {
        NavigationStack {
            HubTabPage(hero: {
                hero
            }, content: {
                meditateSection
                booksSection
                quotesSection
                journalSection
            }, mountains: true)
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            // The book search page's keyboard mustn't resize the page underneath it.
            .ignoresSafeArea(searchingBooks ? .keyboard : [])
            .allowsHitTesting(!searchingBooks)
            .accessibilityHidden(searchingBooks)
            .overlay {
                ZStack {
                    if searchingBooks {
                        BookSearchView(store: store) { searchingBooks = false }
                            .transition(.opacity)
                    }
                }
                .hubAnimation(value: searchingBooks)
            }
            .navigationDestination(item: $openBookID) { id in
                BookDetailView(store: store, bookID: id)
            }
            .sheet(isPresented: $addingQuote) {
                NewQuoteCard { text, author in store.addQuote(text: text, author: author) }
                    .presentationDetents([.medium])
                    .presentationBackground(.clear)
            }
            .navigationDestination(isPresented: $startingSession) {
                StartSessionPage(store: store)
            }
            .sheet(item: $journal) { target in
                switch target {
                case .new:
                    JournalEditor(entry: nil, onSave: { store.saveEntry(id: nil, text: $0) }, onDelete: nil)
                case .entry(let e):
                    JournalEditor(entry: e, onSave: { store.saveEntry(id: e.id, text: $0) }, onDelete: { store.deleteEntry(e.id) })
                }
            }
            .confirmationDialog("Delete this quote?", isPresented: $confirmQuoteDelete, titleVisibility: .visible, presenting: quoteToDelete) { q in
                Button("Delete", role: .destructive) { store.deleteQuote(q.id) }
            }
        }
    }

    // MARK: Hero

    /// A message about the sitting streak over a gauge of this week's time against a weekly goal.
    private var hero: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let weekMinutes = store.sessions.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.minutes }
        let sitDays = Set(store.sessions.map { cal.startOfDay(for: $0.date) })
        let satToday = sitDays.contains(today)
        var cursor = satToday ? today : (cal.date(byAdding: .day, value: -1, to: today) ?? today)
        var streak = 0
        while sitDays.contains(cursor) {
            streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? .distantPast
        }
        let message: String
        if store.sessions.isEmpty { message = "A few quiet minutes is all it takes." }
        else if satToday { message = streak > 1 ? "\(streak) days in a row. Well kept." : "You sat today. Nicely done." }
        else if streak > 0 { message = "\(streak)-day streak. Sit today to keep it." }
        else { message = "A quiet minute is waiting." }
        let h = weekMinutes / 60, m = weekMinutes % 60
        return VStack(spacing: 0) {
            Text(message)
                .font(.system(size: 34, weight: .light))
                .multilineTextAlignment(.center)
                .lineLimit(3).minimumScaleFactor(0.7)
                .padding(.horizontal, 16).padding(.top, 24)
                .accessibilityAddTraits(.isHeader)
            ArcGauge(fraction: Double(weekMinutes) / Double(goal), tint: .teal) {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        if h > 0 {
                            Text("\(h)").font(.system(size: 56, weight: .light))
                            Text("h").font(.title3).foregroundStyle(HubDesign.secondary).padding(.trailing, 6)
                        }
                        Text("\(m)").font(.system(size: 56, weight: .light))
                        Text("m").font(.title3).foregroundStyle(HubDesign.secondary)
                    }
                    .monospacedDigit()
                    Text("of \(goal) min goal").font(.callout).foregroundStyle(HubDesign.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 16)
            HStack(spacing: 0) {
                heroStat(value: "\(streak)", label: "Day streak")
                heroStat(value: "\(store.sessions.count)", label: "Sessions")
                heroStat(value: totalTime(store.totalMinutes), label: "All time")
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: HubLayout.heroHeight, alignment: .top)
    }

    private func heroStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.regular)).monospacedDigit()
            Text(label).font(.footnote).foregroundStyle(HubDesign.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func totalTime(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title2.weight(.regular)).accessibilityAddTraits(.isHeader)
    }

    // MARK: Meditate

    private var meditateSection: some View {
        BrickCard {
            VStack(alignment: .leading, spacing: 16) {
                BrickCaps(text: "Meditation").foregroundStyle(HubDesign.secondary)
                Text("Guided breathing over a wash of colour.")
                    .font(.subheadline).foregroundStyle(HubDesign.secondary)
                Button { startingSession = true } label: {
                    Label("Start session", systemImage: "wind")
                        .font(.headline)
                        .foregroundStyle(HubDesign.ink)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .glassGlare(.regular.tint(HubDesign.action.opacity(0.55)), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Books

    /// The movie catalog's look: a search bar, then a shelf of covers.
    private var booksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Books")
            MediaSearchBar(prompt: "Search books") { searchingBooks = true }
                .opacity(searchingBooks ? 0 : 1)
                .accessibilityHidden(searchingBooks)
            if store.books.isEmpty {
                Text("Books you add show up here.")
                    .font(.subheadline).foregroundStyle(HubDesign.secondary)
                    .padding(.horizontal, 4)
            } else {
                BookShelf(books: store.books) { openBookID = $0.id }
            }
        }
    }

    // MARK: Quotes

    private var looseQuotes: [ReflectionQuote] { store.quotes.filter { $0.bookID == nil } }

    private var quotesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Quotes")
            if looseQuotes.isEmpty {
                Text("Quotes you save show up here. Ones scanned from a book live on its page.")
                    .font(.subheadline).foregroundStyle(HubDesign.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(looseQuotes) { q in
                    BrickCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\u{201C}\(q.text)\u{201D}").font(.body)
                            if !q.author.isEmpty {
                                Text("\u{2014} \(q.author)").font(.subheadline).foregroundStyle(HubDesign.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(.rect(cornerRadius: HubLayout.cardRadius))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = q.author.isEmpty ? q.text : "\(q.text) \u{2014} \(q.author)"
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            quoteToDelete = q
                            confirmQuoteDelete = true
                        }
                    }
                    .accessibilityHint("Touch and hold for options")
                }
            }

            Button { addingQuote = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(HubDesign.ink)
                    .frame(width: 56, height: 56)
                    .glassGlare(.regular.tint(HubDesign.action.opacity(0.55)), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .accessibilityLabel("Add a quote")
        }
    }

    // MARK: Journal

    private var journalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("Journal")
                Spacer()
                Button { journal = .new } label: {
                    Label("New entry", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HubDesign.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: HubLayout.minHitTarget)
                        .glassGlare(.regular, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }

            if store.entries.isEmpty {
                Text("Write your first entry. It's saved on this phone.")
                    .font(.subheadline).foregroundStyle(HubDesign.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(store.entries) { e in
                    Button { journal = .entry(e) } label: {
                        BrickCard {
                            VStack(alignment: .leading, spacing: 8) {
                                BrickCaps(text: e.created.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(HubDesign.secondary)
                                Text(JournalMarkdown.preview(e.text)).font(.body).lineLimit(5).multilineTextAlignment(.leading)
                            }
                        }
                        .foregroundStyle(HubDesign.ink)
                        .contentShape(.rect(cornerRadius: HubLayout.cardRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the entry to edit")
                }
            }
        }
    }
}

/// A glass card for typing in a new quote and who said it.
private struct NewQuoteCard: View {
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var author = ""
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New quote").font(.headline).accessibilityAddTraits(.isHeader)
            TextField("A quote you like", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .modifier(FieldBackground())
            TextField("Who said it (optional)", text: $author)
                .modifier(FieldBackground())
            Button {
                onSave(text, author)
                dismiss()
            } label: {
                Label("Save quote", systemImage: "quote.opening")
                    .font(.headline)
                    .foregroundStyle(HubDesign.ink)
                    .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                    .glassGlare(.regular.tint(HubDesign.action.opacity(0.55)), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .opacity(empty ? 0.5 : 1)
        }
        .padding(HubLayout.cardPadding)
        .glassEffect(.regular, in: .rect(cornerRadius: HubLayout.cardRadius))
        .padding(HubLayout.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
    }
}

private struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(minHeight: HubLayout.minHitTarget)
            .background(HubDesign.track.opacity(0.5), in: .rect(cornerRadius: HubLayout.controlRadius))
    }
}

// MARK: Journal editor

private struct JournalEditor: View {
    let entry: JournalEntry?
    let onSave: (String) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var confirmDelete = false
    @State private var editing: Bool
    @FocusState private var focused: Bool

    init(entry: JournalEntry?, onSave: @escaping (String) -> Void, onDelete: (() -> Void)?) {
        self.entry = entry
        self.onSave = onSave
        self.onDelete = onDelete
        _text = State(initialValue: entry?.text ?? "")
        _editing = State(initialValue: entry == nil)
    }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @ViewBuilder private var content: some View {
        if editing {
            MarkdownTextView(text: $text, focused: $focused)
                .padding(.horizontal, 16)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What's on your mind? Markdown works.")
                            .foregroundStyle(HubDesign.secondary)
                            .padding(.horizontal, 21).padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            ScrollView {
                JournalMarkdown(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(entry == nil ? "New entry" : "Entry")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    if onDelete != nil {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if editing {
                            Button("Save") { onSave(text); dismiss() }.disabled(empty)
                        } else {
                            Button("Edit") { editing = true; focused = true }
                        }
                    }
                }
                .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { onDelete?(); dismiss() }
                }
        }
        .hubPageStyle()
        .presentationDetents([.large])
        .onAppear { focused = editing }
    }
}

/// Journal text rendered as markdown: headings, bullets, numbered lists, quotes, bold, italics, code, links.
private struct JournalMarkdown: View {
    let text: String

    private static let inline = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: inline)) ?? AttributedString(s)
    }

    /// One flat attributed string for card previews: heading marks dropped (line made bold), bullets as dots.
    static func preview(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if let h = heading(t) { return "**\(h.text)**" }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") { return "• " + t.dropFirst(2) }
            if t.hasPrefix("> ") { return String(t.dropFirst(2)) }
            return line
        }
        return inline(lines.joined(separator: "\n"))
    }

    private static func heading(_ t: String) -> (level: Int, text: String)? {
        let hashes = t.prefix(while: { $0 == "#" }).count
        guard (1...4).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        return (hashes, t.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw.trimmingCharacters(in: .whitespaces))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func line(_ t: String) -> some View {
        if t.isEmpty {
            Color.clear.frame(height: 4)
        } else if let h = Self.heading(t) {
            Text(Self.inline(h.text))
                .font(h.level == 1 ? .title2.bold() : h.level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(Self.inline(String(t.dropFirst(2))))
            }
        } else if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty,
                  t[t.index(after: dot)...].hasPrefix(" ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(t[...dot])).monospacedDigit()
                Text(Self.inline(t[t.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            }
        } else if t.hasPrefix("> ") {
            Text(Self.inline(String(t.dropFirst(2))))
                .foregroundStyle(HubDesign.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(HubDesign.secondary.opacity(0.5)).frame(width: 3) }
        } else if t == "---" || t == "***" {
            Divider()
        } else {
            Text(Self.inline(t))
        }
    }
}

/// A text editor that styles markdown as you type, like Notion: headings grow, **bold**, *italic*, `code` and quotes
/// show styled with their marks dimmed; "- " becomes a bullet and Return continues the list.
private struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        v.alwaysBounceVertical = true
        v.keyboardDismissMode = .interactive
        v.text = text
        Coordinator.style(v)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text; Coordinator.style(v) }
        if focused.wrappedValue, !v.isFirstResponder { v.becomeFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        init(_ p: MarkdownTextView) { parent = p }

        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            Self.style(v)
        }

        func textViewDidBeginEditing(_ v: UITextView) { parent.focused.wrappedValue = true }
        func textViewDidEndEditing(_ v: UITextView) { parent.focused.wrappedValue = false }

        func textView(_ v: UITextView, shouldChangeTextIn range: NSRange, replacementText t: String) -> Bool {
            let ns = v.text as NSString
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let before = ns.substring(with: NSRange(location: line.location, length: range.location - line.location))
            func replace(_ r: NSRange, with s: String, caret: Int) {
                v.textStorage.replaceCharacters(in: r, with: s)
                v.selectedRange = NSRange(location: caret, length: 0)
                textViewDidChange(v)
            }
            if t == " ", range.length == 0, before == "-" || before == "*" {
                replace(NSRange(location: line.location, length: 1), with: "• ", caret: line.location + 2)
                return false
            }
            if t == "\n", range.length == 0, before.hasPrefix("• ") {
                if before == "• " {
                    replace(NSRange(location: line.location, length: 2), with: "", caret: line.location)
                } else {
                    replace(NSRange(location: range.location, length: 0), with: "\n• ", caret: range.location + 3)
                }
                return false
            }
            return true
        }

        static func style(_ v: UITextView) {
            let storage = v.textStorage
            let full = NSRange(location: 0, length: storage.length)
            let selected = v.selectedRange
            let base = UIFont.preferredFont(forTextStyle: .body)
            storage.beginEditing()
            storage.setAttributes([.font: base, .foregroundColor: UIColor.label], range: full)
            let dim = UIColor.tertiaryLabel
            let str = storage.string as NSString
            str.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, _, lineRange, _ in
                let line = str.substring(with: lineRange)
                let hashes = line.prefix(while: { $0 == "#" }).count
                if (1...4).contains(hashes), line.dropFirst(hashes).first == " " {
                    let style: UIFont.TextStyle = hashes == 1 ? .title1 : hashes == 2 ? .title2 : .title3
                    let f = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: .bold)
                    storage.addAttribute(.font, value: f, range: lineRange)
                    storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: lineRange.location, length: hashes + 1))
                } else if line.hasPrefix("> ") {
                    storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: lineRange)
                    storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: lineRange.location, length: 2))
                }
            }
            func mark(_ pattern: String, trait: UIFontDescriptor.SymbolicTraits?, mono: Bool = false, marks: Int) {
                guard let re = try? NSRegularExpression(pattern: pattern) else { return }
                for m in re.matches(in: storage.string, range: full) {
                    let r = m.range
                    storage.enumerateAttribute(.font, in: r) { val, sub, _ in
                        let cur = (val as? UIFont) ?? base
                        var f = cur
                        if let trait, let d = cur.fontDescriptor.withSymbolicTraits(cur.fontDescriptor.symbolicTraits.union(trait)) {
                            f = UIFont(descriptor: d, size: cur.pointSize)
                        }
                        if mono { f = UIFont.monospacedSystemFont(ofSize: cur.pointSize * 0.92, weight: .regular) }
                        storage.addAttribute(.font, value: f, range: sub)
                    }
                    if mono { storage.addAttribute(.backgroundColor, value: UIColor.secondarySystemFill, range: r) }
                    storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: r.location, length: marks))
                    storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: r.location + r.length - marks, length: marks))
                }
            }
            mark("\\*\\*[^*\\n]+\\*\\*", trait: .traitBold, marks: 2)
            mark("(?<![*\\w])\\*[^*\\n]+\\*(?![*\\w])", trait: .traitItalic, marks: 1)
            mark("`[^`\\n]+`", trait: nil, mono: true, marks: 1)
            storage.endEditing()
            v.selectedRange = selected
            v.typingAttributes = [.font: base, .foregroundColor: UIColor.label]
        }
    }
}

// MARK: Meditation

private enum BreathPhase: CaseIterable {
    case inhale, holdIn, exhale, holdOut

    var label: String {
        switch self {
        case .inhale: "Breathe in"
        case .holdIn, .holdOut: "Hold"
        case .exhale: "Breathe out"
        }
    }

    func seconds(_ p: BreathPattern) -> Double {
        switch self {
        case .inhale: p.inhale
        case .holdIn: p.holdIn
        case .exhale: p.exhale
        case .holdOut: p.holdOut
        }
    }
}

/// A solid colour floods the screen on the breath in, stays through the hold, and drains on the breath out.
private struct MeditationFlood: View {
    let color: Color
    let minutes: Int
    let pattern: BreathPattern
    let onFinish: (Int) -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level: CGFloat = 0
    @State private var phase: BreathPhase?
    @State private var phaseEnd: Date?
    @State private var cycle = 1
    @State private var finished = false

    private var cycles: Int {
        max(1, Int((Double(minutes) * 60 / pattern.length).rounded()))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // One full-screen frame for the flood, the disc and its text, so they all share the exact same centre.
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let diameter = hypot(geo.size.width, geo.size.height)
                let d = min(geo.size.width - HubLayout.gutter * 2, 320)
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(reduceMotion ? 1 : max(level, 0.05))
                        .opacity(reduceMotion ? level : 1)
                        .position(center)
                        .accessibilityHidden(true)

                    Group {
                        if finished {
                            VStack(spacing: 12) {
                                Text("Well done").font(.largeTitle.weight(.light))
                                Text("\(minutes) minutes of calm").font(.body).opacity(0.85)
                                Button("Done", action: onClose)
                                    .font(.headline)
                                    .padding(.horizontal, 32)
                                    .frame(minHeight: 52)
                                    .glassGlare(.regular, in: .capsule)
                                    .buttonStyle(.plain)
                                    .padding(.top, 16)
                            }
                        } else {
                            breathingCircle(diameter: d)
                        }
                    }
                    .position(center)
                }
            }
            .ignoresSafeArea()
            .foregroundStyle(.white)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                            .glassGlare(.regular, in: .circle)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("End session")
                }
                Spacer()
                if !finished {
                    Text(pattern.title).font(.footnote).monospacedDigit().opacity(0.7)
                        .padding(.bottom, 24)
                }
            }
            .foregroundStyle(.white)
            .padding(HubLayout.gutter)
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task { await run() }
    }

    /// A soft disc swells and shrinks with the flood. The countdown sits at its exact centre with the phase word just above,
    /// and the breath counter just below, so the whole group reads as one centred object.
    private func breathingCircle(diameter d: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.07)],
                        center: .center, startRadius: 0, endRadius: d / 2
                    )
                )
                .frame(width: d, height: d)
                .scaleEffect(reduceMotion ? 0.8 : 0.62 + 0.38 * level)
                .accessibilityHidden(true)

            TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                let left = phaseEnd.map { max(1, Int(ceil($0.timeIntervalSince(ctx.date)))) }
                Text(left.map { String($0) } ?? " ")
                    .font(.system(size: 64, weight: .ultraLight))
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                Text(phase?.label ?? "Get ready")
                    .font(.title3.weight(.light))
                    .lineLimit(1)
                    .fixedSize()
                    .alignmentGuide(.top) { $0[.bottom] + 2 }
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .overlay(alignment: .bottom) {
                Text("Breath \(cycle) of \(cycles)")
                    .font(.footnote).monospacedDigit()
                    .opacity(0.75)
                    .fixedSize()
                    .alignmentGuide(.bottom) { $0[.top] - 6 }
            }
        }
        .frame(width: d, height: d)
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(1.5))
        for n in 1...cycles {
            cycle = n
            for p in BreathPhase.allCases {
                let seconds = p.seconds(pattern)
                if seconds <= 0 { continue }
                if Task.isCancelled { return }
                phase = p
                phaseEnd = Date().addingTimeInterval(seconds)
                switch p {
                case .inhale: withAnimation(.easeInOut(duration: seconds)) { level = 1 }
                case .exhale: withAnimation(.easeInOut(duration: seconds)) { level = 0 }
                case .holdIn, .holdOut: break
                }
                if p == .inhale || p == .exhale {
                    await pulse(seconds: seconds, speedingUp: p == .inhale)
                } else {
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
        }
        if Task.isCancelled { return }
        phase = nil
        phaseEnd = nil
        finished = true
        onFinish(minutes)
    }

    /// Paced haptic taps across a breath: slow and soft to quick and firm on the way in, mirrored on the way out. Lasts the full `seconds`.
    private func pulse(seconds: Double, speedingUp: Bool) async {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        let clock = ContinuousClock()
        let start = clock.now
        var t = 0.0
        while t < seconds {
            if Task.isCancelled { return }
            let f = speedingUp ? t / seconds : 1 - t / seconds
            generator.impactOccurred(intensity: 0.45 + 0.55 * f)
            t += 0.7 - 0.55 * f
            try? await Task.sleep(until: start.advanced(by: .seconds(min(t, seconds))), clock: clock)
        }
    }
}

/// Where a session is set up: how long, which breathing, the colour, and the weekly goal. Begin starts it.
private struct StartSessionPage: View {
    let store: ReflectionStore
    @AppStorage("reflection.minutes") private var minutes = 3
    @AppStorage("reflection.goal") private var goal = 60
    @AppStorage("reflection.colorHex") private var colorHex = floodColors[0].hex
    @AppStorage("reflection.pattern") private var patternID = "box"
    @State private var run: MeditationRun?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: HubLayout.sectionGap) {
                group("Length") {
                    HStack(spacing: 8) {
                        ForEach(durations, id: \.self) { m in
                            let selected = m == minutes
                            Button { minutes = m } label: {
                                HStack(spacing: 4) {
                                    if selected { Image(systemName: "checkmark") }
                                    Text("\(m) min")
                                }
                                .font(.subheadline.weight(selected ? .semibold : .regular)).monospacedDigit()
                                .foregroundStyle(HubDesign.ink)
                                .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                                .glassGlare(selected ? .regular.tint(HubDesign.action.opacity(0.55)) : .regular, in: .capsule)
                                .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                group("Breathing") {
                    Menu {
                        Picker("Breathing pattern", selection: $patternID) {
                            ForEach(BreathPattern.all) { Text($0.title).tag($0.id) }
                        }
                    } label: {
                        HStack {
                            Text(BreathPattern.find(patternID).title).monospacedDigit()
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down").font(.footnote)
                        }
                        .font(.subheadline)
                        .foregroundStyle(HubDesign.ink)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                        .glassGlare(.regular, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .accessibilityLabel("Breathing pattern, \(BreathPattern.find(patternID).title)")
                }
                group("Background") {
                    HStack(spacing: 16) {
                        ForEach(floodColors, id: \.hex) { c in
                            Button { colorHex = c.hex } label: {
                                Circle().fill(Color(hexForWhiteText: c.hex))
                                    .overlay { if c.hex == colorHex { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.white) } }
                                    .frame(width: 36, height: 36)
                                    .frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.name)
                            .accessibilityAddTraits(c.hex == colorHex ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }
                }
                group("Weekly goal") {
                    Stepper("\(goal) min a week", value: $goal, in: 15...600, step: 15)
                        .padding(.horizontal, 16)
                        .frame(minHeight: HubLayout.minHitTarget)
                        .glassGlare(.regular, in: .capsule)
                }
                Button { run = MeditationRun(minutes: minutes, hex: colorHex, pattern: BreathPattern.find(patternID)) } label: {
                    Label("Begin \(minutes) min", systemImage: "wind")
                        .font(.headline)
                        .foregroundStyle(HubDesign.ink)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .glassGlare(.regular.tint(HubDesign.action.opacity(0.55)).interactive(), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, HubLayout.gutter)
            .padding(.top, HubLayout.topInset)
            .padding(.bottom, HubLayout.bottomInset)
            .containerRelativeFrame(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .hubPageStyle(backdrop: true)
        .navigationTitle("Start session")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $run) { r in
            MeditationFlood(color: Color(hexForWhiteText: r.hex), minutes: r.minutes, pattern: r.pattern) { done in
                store.finishedMeditation(minutes: done)
            } onClose: {
                run = nil
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BrickCaps(text: title).foregroundStyle(HubDesign.secondary)
            content()
        }
    }
}
