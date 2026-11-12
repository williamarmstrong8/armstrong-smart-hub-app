import SwiftUI

private let durations = [1, 3, 5, 10]

private let floodColors: [(name: String, hex: String)] = [
    ("Ocean", "#2F5BD3"),
    ("Forest", "#1F7A5A"),
    ("Dusk", "#6B46C1"),
    ("Ember", "#C2512D"),
]

private struct MeditationRun: Identifiable {
    let id = UUID()
    let minutes: Int
    let hex: String
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
    @AppStorage("reflection.minutes") private var minutes = 3
    @AppStorage("reflection.goal") private var goal = 60
    @AppStorage("reflection.colorHex") private var colorHex = floodColors[0].hex
    @State private var showSettings = false
    @State private var run: MeditationRun?
    @State private var quoteText = ""
    @State private var quoteAuthor = ""
    @State private var quoteToDelete: ReflectionQuote?
    @State private var confirmQuoteDelete = false
    @State private var journal: JournalTarget?
    @State private var searchingBooks = false
    @State private var openBookID: UUID?
    @State private var scanning = false
    @FocusState private var quoteFocused: Bool

    var body: some View {
        NavigationStack {
            HubTabPage(topBar: {
                BrickTopBar {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Reflection settings")
                }
            }, hero: {
                hero
            }, content: {
                meditateSection
                booksSection
                quotesSection
                journalSection
            }, mountains: true)
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if !quoteFocused && !searchingBooks { scanButton }
            }
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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { quoteFocused = false }
                }
            }
            .fullScreenCover(item: $run) { r in
                MeditationFlood(color: Color(hexForWhiteText: r.hex), minutes: r.minutes) { done in
                    store.finishedMeditation(minutes: done)
                } onClose: {
                    run = nil
                }
            }
            .sheet(isPresented: $showSettings) {
                ReflectionSettings(goal: $goal, minutes: $minutes, colorHex: $colorHex)
                    .presentationDetents([.medium, .large])
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
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: HubLayout.heroHeight, alignment: .top)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title2.weight(.regular)).accessibilityAddTraits(.isHeader)
    }

    // MARK: Meditate

    private var meditateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrickCard {
                VStack(alignment: .leading, spacing: 16) {
                    BrickCaps(text: "Length").foregroundStyle(HubDesign.secondary)
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

                    Button { run = MeditationRun(minutes: minutes, hex: colorHex) } label: {
                        Label("Begin \(minutes) min", systemImage: "wind")
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

    private var scanButton: some View {
        Button { scanning = true } label: {
            Label("Scan a quote", systemImage: "text.viewfinder")
                .font(.headline)
                .foregroundStyle(HubDesign.ink)
                .padding(.horizontal, 24)
                .frame(minHeight: 52)
                .glassGlare(.regular.tint(HubDesign.action.opacity(0.55)), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .fullScreenCover(isPresented: $scanning) {
            QuoteScanFlow(store: store, bookID: nil) { scanning = false }
        }
    }

    // MARK: Quotes

    private var looseQuotes: [ReflectionQuote] { store.quotes.filter { $0.bookID == nil } }

    private var quotesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Quotes")
            BrickCard {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("A quote you like", text: $quoteText, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($quoteFocused)
                        .modifier(FieldBackground())
                    TextField("Who said it (optional)", text: $quoteAuthor)
                        .focused($quoteFocused)
                        .modifier(FieldBackground())
                    Button {
                        store.addQuote(text: quoteText, author: quoteAuthor)
                        quoteText = ""
                        quoteAuthor = ""
                        quoteFocused = false
                    } label: {
                        Label("Save quote", systemImage: "quote.opening")
                            .font(.headline)
                            .foregroundStyle(HubDesign.ink)
                            .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                            .glassGlare(.regular, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }
            }

            if looseQuotes.isEmpty {
                Text("Quotes you save show up here. Ones scanned from a book live on its page.")
                    .font(.subheadline).foregroundStyle(HubDesign.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(looseQuotes) { q in
                    BrickCard {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\u{201C}\(q.text)\u{201D}").font(.body)
                                if !q.author.isEmpty {
                                    Text("\u{2014} \(q.author)").font(.subheadline).foregroundStyle(HubDesign.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Menu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    quoteToDelete = q
                                    confirmQuoteDelete = true
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Quote options")
                        }
                    }
                }
            }
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
                                Text(e.text).font(.body).lineLimit(5).multilineTextAlignment(.leading)
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
    @FocusState private var focused: Bool

    init(entry: JournalEntry?, onSave: @escaping (String) -> Void, onDelete: (() -> Void)?) {
        self.entry = entry
        self.onSave = onSave
        self.onDelete = onDelete
        _text = State(initialValue: entry?.text ?? "")
    }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 16)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What's on your mind?")
                            .foregroundStyle(HubDesign.secondary)
                            .padding(.horizontal, 21).padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
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
                        Button("Save") { onSave(text); dismiss() }.disabled(empty)
                    }
                }
                .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { onDelete?(); dismiss() }
                }
        }
        .hubPageStyle()
        .presentationDetents([.large])
        .onAppear { focused = true }
    }
}

// MARK: Meditation

private enum BreathPhase: CaseIterable {
    case inhale, hold, exhale

    var label: String {
        switch self {
        case .inhale: "Breathe in"
        case .hold: "Hold"
        case .exhale: "Breathe out"
        }
    }

    var seconds: Double {
        switch self {
        case .inhale: 4
        case .hold: 4
        case .exhale: 6
        }
    }
}

/// A solid colour floods the screen on the breath in, stays through the hold, and drains on the breath out.
private struct MeditationFlood: View {
    let color: Color
    let minutes: Int
    let onFinish: (Int) -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level: CGFloat = 0
    @State private var phase: BreathPhase?
    @State private var cycle = 1
    @State private var finished = false

    private var cycles: Int {
        let length = BreathPhase.allCases.reduce(0) { $0 + $1.seconds }
        return max(1, Int((Double(minutes) * 60 / length).rounded()))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let diameter = hypot(geo.size.width, geo.size.height)
                Circle()
                    .fill(color)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(reduceMotion ? 1 : max(level, 0.05))
                    .opacity(reduceMotion ? level : 1)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack(spacing: 12) {
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
                if finished {
                    Text("Well done").font(.largeTitle.weight(.light))
                    Text("\(minutes) minutes of calm").font(.body).opacity(0.85)
                    Button("Done", action: onClose)
                        .font(.headline)
                        .padding(.horizontal, 32)
                        .frame(minHeight: 52)
                        .glassGlare(.regular, in: .capsule)
                        .buttonStyle(.plain)
                        .padding(.top, 16)
                } else {
                    Text(phase?.label ?? "Get ready").font(.largeTitle.weight(.light))
                        .accessibilityAddTraits(.updatesFrequently)
                    Text("Breath \(cycle) of \(cycles)").font(.subheadline).monospacedDigit().opacity(0.85)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(HubLayout.gutter)
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .sensoryFeedback(.impact(weight: .light), trigger: phase) { _, now in now != nil }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task { await run() }
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(1.5))
        for n in 1...cycles {
            cycle = n
            for p in BreathPhase.allCases {
                if Task.isCancelled { return }
                phase = p
                switch p {
                case .inhale: withAnimation(.easeInOut(duration: p.seconds)) { level = 1 }
                case .hold: break
                case .exhale: withAnimation(.easeInOut(duration: p.seconds)) { level = 0 }
                }
                try? await Task.sleep(for: .seconds(p.seconds))
            }
        }
        if Task.isCancelled { return }
        phase = nil
        finished = true
        onFinish(minutes)
    }
}

/// Reflection's settings: the colour that floods the screen, the weekly goal, and the default sitting length.
private struct ReflectionSettings: View {
    @Binding var goal: Int
    @Binding var minutes: Int
    @Binding var colorHex: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Meditation background") {
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
                Section("Weekly goal") {
                    Stepper("\(goal) min a week", value: $goal, in: 15...600, step: 15)
                }
                Section("Default length") {
                    Picker("Length", selection: $minutes) {
                        ForEach(durations, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Reflection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
