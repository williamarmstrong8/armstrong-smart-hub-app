import SwiftUI

// MARK: Morning check-in

/// One question a morning: how you feel, as the hub's three best guesses as
/// plain text options (from last night's numbers and what you said the days before), the
/// likeliest outlined. Once answered: the answer as one line.
/// Under both, a past day to confirm if there is one. Straight on the page;
/// the days' answers show in the week strip (WeekStrip). Every answer is a
/// label the hub learns from (checkin-engine.ts).
struct MorningCheckin: View {
    @Environment(AppSession.self) private var session
    var store: CheckinStore
    @State private var changing = false
    /// The card just tapped, shown at once: the saved answer only arrives after
    /// the save, and waiting for it flashed the old answer in between.
    @State private var picked: String?

    private var day: String { store.day }
    /// What the day's answer is now, as far as this view knows.
    private var feeling: String? { picked ?? store.entry(for: day).flatMap(Feeling.of) }

    /// Swaps between the question and the answer: fade, with a slight settle.
    private static let swap = AnyTransition.opacity.combined(with: .scale(scale: 0.97, anchor: .top))

    var body: some View {
        BrickCard {
            VStack(alignment: .leading, spacing: 20) {
                if let feeling, !changing {
                    answered(feeling).transition(Self.swap)
                } else {
                    asking.transition(Self.swap)
                }
                if let stretch = store.suggestions.first, !changing, feeling != nil {
                    past(stretch)
                }
            }
        }
        .onChange(of: store.entry(for: day)) { _, entry in
            if let entry, Feeling.of(entry) == picked { picked = nil }
        }
        .onChange(of: day) { picked = nil }
    }

    /// "How are you today?", then the three guesses as cards, the likeliest first.
    private var asking: some View {
        let options = store.options
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How are you today?").font(.system(size: 22, weight: .regular)).foregroundStyle(BrickLook.ink)
                Text(store.guess == nil ? "Pick the closest" : "Our three best guesses from your data")
                    .font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Rectangle().fill(BrickLook.line).frame(width: 1).padding(.vertical, 6) }
                    CheckinChoice(option: option, guessed: store.guess != nil && index == 0) {
                        answer(option.key, offered: options.map(\.key))
                    }
                }
            }
            // The feelings the cards don't show, for a morning the guesses missed.
            Menu {
                ForEach(Feeling.all.filter { key in !options.contains { $0.key == key } }, id: \.self) { key in
                    Button { answer(key, offered: options.map(\.key)) } label: { Text(Feeling.label(key)) }
                }
            } label: {
                Text("Other").font(.footnote).foregroundStyle(BrickLook.soft)
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .contentShape(.rect)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The answer as one line, in its color. Tap Change to pick again.
    private func answered(_ feeling: String) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Feeling.answer(feeling)).font(.system(size: 22, weight: .regular)).foregroundStyle(Feeling.tint(feeling))
                Text("Checked in").font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            Spacer(minLength: 8)
            Button("Change") { withAnimation(.snappy) { changing = true } }
                .font(.footnote).foregroundStyle(BrickLook.soft)
                .buttonStyle(.plain)
        }
    }

    /// "Were you sick around July 15–17?" with yes, no and not sure.
    private func past(_ stretch: PastStretch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Were you sick around \(Self.range(stretch))?").font(.subheadline).foregroundStyle(BrickLook.ink)
            HStack(spacing: 8) {
                CheckinButton(title: "Yes", small: true) { Task { await store.answer(stretch, yes: true, api: session.api) } }
                CheckinButton(title: "No", small: true) { Task { await store.answer(stretch, yes: false, api: session.api) } }
                CheckinButton(title: "Not sure", small: true) { Task { await store.skip(stretch, api: session.api) } }
            }
        }
        .transition(.opacity)
    }

    /// Yes for sick, no for any other answer, nil when the day's check-in didn't say how it felt.
    static func sick(_ c: Checkin) -> Bool? {
        c.tags.contains("sick") ? true : c.rejected.contains("sick") || Feeling.of(c) != nil ? false : nil
    }

    private func answer(_ feeling: String, offered: [String]) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) {
            picked = feeling
            changing = false
        }
        Task { await store.answer(day: day, feeling: feeling, offered: offered, api: session.api) }
    }

    static func range(_ s: PastStretch) -> String {
        guard let from = date(s.from), let to = date(s.to) else { return s.from }
        let f = from.formatted(.dateTime.month(.wide).day())
        if s.from == s.to { return f }
        let sameMonth = Calendar.current.isDate(from, equalTo: to, toGranularity: .month)
        return "\(f)–\(sameMonth ? to.formatted(.dateTime.day()) : to.formatted(.dateTime.month(.wide).day()))"
    }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: day)
    }
}

/// This week, Monday to Sunday, one column a day: a circle filled blue for a
/// workout, and under the letter a dot in the color of that morning's
/// check-in (none when there wasn't one).
struct WeekStrip: View {
    var store: CheckinStore
    /// Local midnights of the days with a workout.
    var workoutDays: Set<Date>
    var trailing: String
    var trailingTint: Color?

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let week = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? today
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
        BrickCard {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                BrickCaps(text: "This week").foregroundStyle(BrickLook.soft)
                Spacer()
                BrickCaps(text: trailing).foregroundStyle(trailingTint ?? BrickLook.soft).monospacedDigit()
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(days, id: \.self) { date in
                    let worked = workoutDays.contains(date)
                    let isToday = date == today
                    let feeling = date > today ? nil : store.entry(for: CheckinStore.dayString(date)).flatMap(Feeling.of)
                    VStack(spacing: 7) {
                        // As wide as the column allows, up to 40, so the seven fill the page.
                        Color.clear
                            .glassGlare(worked ? .regular.tint(Fit.action.opacity(0.85)) : .regular, in: .circle)
                            .overlay { if isToday && !worked { Circle().strokeBorder(BrickLook.ink, lineWidth: 1.5) } }
                        .frame(maxWidth: 40)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.horizontal, 4)
                        Text(date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption.weight(isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? BrickLook.ink : Fit.muted)
                        Circle().fill(feeling.map(Feeling.tint) ?? .clear).frame(width: 8, height: 8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(.smooth, value: workoutDays.count)
        }
        }
    }
}

/// A morning option: the feeling and a few words why, plain text on the page.
/// The hub's likeliest guess is set in its color with a bar under it, so it is one tap to agree.
struct CheckinChoice: View {
    var option: CheckinOption
    var guessed: Bool
    var action: () -> Void

    var body: some View {
        let tint = Feeling.tint(option.key)
        Button(action: action) {
            VStack(spacing: 6) {
                Text(option.label)
                    .font(.system(size: 17, weight: guessed ? .semibold : .regular))
                    .foregroundStyle(guessed ? tint : BrickLook.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Capsule().fill(guessed ? tint : .clear).frame(width: 18, height: 2)
                Text(option.reason ?? " ")
                    .font(.caption2).foregroundStyle(BrickLook.soft)
                    .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// How each morning answer looks and reads. The keys are the hub's states
/// (checkin-engine.ts) plus "fine" for a normal day.
enum Feeling {
    static let all = ["fine", "energized", "run_down", "stressed", "hungover", "sick"]

    static func icon(_ key: String) -> String {
        switch key {
        case "sick": "thermometer.medium"
        case "hungover": "wineglass"
        case "run_down": "battery.25"
        case "stressed": "bolt.heart"
        case "energized": "bolt.fill"
        default: "face.smiling"
        }
    }

    static func tint(_ key: String) -> Color {
        switch key {
        case "sick": Fit.attention
        case "hungover": Fit.health
        case "run_down": Fit.fair
        case "stressed": Fit.adaptive(0xD6336C, 0xFF6B9A)
        case "energized": Fit.energy
        default: Fit.positive
        }
    }

    static func label(_ key: String) -> String {
        switch key {
        case "sick": "Sick"
        case "hungover": "Hungover"
        case "run_down": "Run down"
        case "stressed": "Stressed"
        case "energized": "Energized"
        default: "Normal"
        }
    }

    /// The line once answered.
    static func answer(_ key: String) -> String {
        switch key {
        case "sick": "Sick today"
        case "energized": "Full of energy"
        case "fine": "Feeling normal"
        default: label(key)
        }
    }

    /// A day's answer: the worst state it has, else "fine" for a check-in that named none.
    static func of(_ c: Checkin) -> String? {
        if let state = all.reversed().first(where: { $0 != "fine" && c.tags.contains($0) }) { return state }
        return c.tags.contains("fine") || !c.rejected.isEmpty ? "fine" : nil
    }
}

/// An answer, full width in its row. `filled` marks the hub's guess: solid
/// ink, the other answer a plain pill beside it.
struct CheckinButton: View {
    var title: String
    var filled = false
    var small = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(small ? .footnote.weight(.medium) : .body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: small ? 34 : 46)
                .foregroundStyle(filled ? BrickLook.card : BrickLook.ink)
                .background(filled ? BrickLook.ink : BrickLook.pill, in: .capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: filled)
    }
}

// MARK: Sessions

/// How a logged workout or watch activity felt: one question, three plain-text
/// answers, one tap. The hub's guess (from Training Effect or set RPE) is set
/// in its color with a bar, like the morning check-in. The tap saves; it sets
/// "versus expected" and puts effort in that band (keeping the hub's number
/// when it already fits). A saved note or tags from before are kept.
struct SessionFeedbackSection: View {
    @Environment(AppSession.self) private var session
    var kind: String
    var id: String
    var onSaved: (() -> Void)? = nil
    @State private var store = CheckinStore.shared
    @State private var guess: SessionGuess?
    @State private var saved: SessionFeedback?
    @State private var picked: Int?
    @State private var editing = false
    @State private var loaded = false

    /// Hard, as expected, easy: versus expected, the effort band and the color.
    private struct Level {
        let vs: Int
        let word: String
        let band: ClosedRange<Int>
        let tint: Color
    }
    private static let levels = [
        Level(vs: 1, word: "Easy", band: 1...4, tint: Fit.positive),
        Level(vs: 0, word: "Just right", band: 5...7, tint: Fit.action),
        Level(vs: -1, word: "Hard", band: 8...10, tint: Fit.attention),
    ]

    private static func level(forEffort e: Int?) -> Int? {
        guard let e else { return nil }
        return levels.firstIndex { $0.band.contains(e) }
    }

    /// What the card highlights: the answer once given, else the hub's guess.
    private var answer: Int? {
        if let picked { return picked }
        if let vs = saved?.vsExpected { return Self.levels.firstIndex { $0.vs == vs } }
        return nil
    }

    var body: some View {
        FitSection(title: "How was it?", trailing: saved == nil && guess?.effort != nil ? "Our guess" : nil) {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if let index = answer, !editing {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.levels[index].word).font(.system(size: 22, weight: .regular)).foregroundStyle(Self.levels[index].tint)
                    Spacer()
                    Button("Change") { withAnimation(.snappy) { editing = true } }
                        .font(.footnote).foregroundStyle(BrickLook.soft).buttonStyle(.plain)
                }
            } else {
                let guessed = Self.level(forEffort: guess?.effort)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(Self.levels.enumerated()), id: \.offset) { index, level in
                        if index > 0 { Rectangle().fill(BrickLook.line).frame(width: 1).padding(.vertical, 6) }
                        Button { Task { await save(index) } } label: {
                            VStack(spacing: 6) {
                                Text(level.word)
                                    .font(.system(size: 17, weight: guessed == index ? .semibold : .regular))
                                    .foregroundStyle(guessed == index ? level.tint : BrickLook.ink)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Capsule().fill(guessed == index ? level.tint : .clear).frame(width: 18, height: 2)
                            }
                            .padding(.vertical, 10).frame(maxWidth: .infinity).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: id) { await load() }
    }

    private func load() async {
        let result = await store.session(kind: kind, id: id, api: session.api)
        guess = result.guess
        saved = result.feedback
        loaded = true
    }

    private func save(_ index: Int) async {
        let level = Self.levels[index]
        let hub = guess?.effort ?? saved?.effort
        let effort = hub.flatMap { level.band.contains($0) ? $0 : nil } ?? (level.band.lowerBound + level.band.upperBound) / 2
        let feedback = SessionFeedback(kind: kind, refId: id, feel: saved?.feel, effort: effort, vsExpected: level.vs,
                                       tags: saved?.tags ?? [], note: saved?.note)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) {
            picked = index
            saved = feedback
            editing = false
        }
        onSaved?()
        await store.save(feedback, api: session.api)
    }
}

/// Right after a workout: the one question in a short sheet, dismissed by answering or skipping.
struct SessionFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    var kind: String
    var id: String
    var title: String

    var body: some View {
        NavigationStack {
            ScrollView {
                SessionFeedbackSection(kind: kind, id: id) {
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        dismiss()
                    }
                }
                .padding(.horizontal, Fit.gutter)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } } }
        }
        .presentationDetents([.height(300)])
    }
}
