import SwiftUI

// MARK: Morning check-in

/// The hub's guess for this morning, put as a question: "looks like you're
/// hungover, here's why. Right?". One tap accepts the whole guess; anything
/// tapped instead corrects it. Every answer teaches the hub (checkin-engine.ts).
struct MorningCheckin: View {
    @Environment(AppSession.self) private var session
    var store: CheckinStore
    @State private var energy: Int?
    @State private var tags: Set<String> = []
    @State private var rejected: Set<String> = []
    @State private var note = ""
    @State private var editing = false
    @State private var touched = false
    @State private var showingMore = false

    private var day: String { localDay() }
    private var saved: Checkin? { store.entry(for: day) }
    private var guess: DayGuess? { store.guess }
    private var guessedEnergy: Int? { guess.map { Int($0.energy.rounded()) } }

    var body: some View {
        FitSection(title: saved == nil || editing ? "How are you feeling?" : "Checked in", trailing: trailing) {
            if let saved, !editing {
                summary(saved)
            } else {
                form
            }
        }
        .onAppear(perform: reset)
        .onChange(of: store.page?.day) { reset() }
        // Last night arrived after the card was showing: start from the guess.
        .onChange(of: guessedEnergy) {
            if saved == nil, !touched { energy = guessedEnergy }
        }
    }

    private var trailing: String? {
        guard saved == nil || editing else { return nil }
        guard let guess else { return nil }
        let personal = guess.states.map(\.personal).max() ?? 0
        return personal > 0.05 ? "Our guess · \(Int(personal * 100))% from you" : "Our guess"
    }

    // MARK: Answered

    private func summary(_ c: Checkin) -> some View {
        let labels = c.tags.map(label)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.energy.map { "Energy \($0) of 5" } ?? "Checked in").font(Fit.value)
                if !labels.isEmpty {
                    Text(labels.joined(separator: ", ")).font(.subheadline).foregroundStyle(Fit.muted)
                }
            }
            Spacer(minLength: 8)
            Button("Edit") { editing = true }.font(.subheadline)
        }
    }

    // MARK: Asking

    @ViewBuilder private var form: some View {
        if let guess {
            let likely = store.likely.prefix(2)
            if likely.isEmpty {
                Text("Looks like a normal morning").font(Fit.value)
                if let top = guess.metrics.first, abs(top.z) >= 1 {
                    reasonLine(top)
                }
            } else {
                ForEach(Array(likely)) { state in stateRow(state) }
            }
        } else {
            Takeaway(text: store.loading ? "Reading last night…" : "No sleep from last night yet. Sync the watch and the hub will guess; you can still check in now.")
        }

        energyRow

        TagCloud(tags: chipTags, selected: tags) { toggle($0) }

        if tags.contains("sick") {
            TagCloud(tags: store.page?.vocabulary.symptoms ?? [], selected: tags) { toggle($0) }
        }

        if showingMore {
            TextField("Anything else? Late dinner, big week, new supplement…", text: $note, axis: .vertical)
                .font(.subheadline).lineLimit(1...4)
                .padding(10).background(Fit.track.opacity(0.5), in: .rect(cornerRadius: 10))
                .onChange(of: note) { touched = true }
        }

        HStack(spacing: 12) {
            Button {
                Task { await save() }
            } label: {
                Text(touched || guess == nil ? "Save" : "Looks right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Fit.readiness)
            .disabled(energy == nil && tags.isEmpty && guess == nil)
            if !showingMore {
                Button("Add note") { withAnimation(.smooth) { showingMore = true } }.buttonStyle(.bordered).tint(Fit.muted)
            }
            if editing {
                Button("Cancel") { editing = false; reset() }.buttonStyle(.bordered).tint(Fit.muted)
            }
        }
        .controlSize(.large)

        if guess != nil {
            NavigationLink(value: CheckinRoute.detail) {
                HStack(spacing: 4) {
                    Text("Why we think this")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.footnote).foregroundStyle(Fit.muted)
            }
        }
    }

    /// One guessed state with its top reasons and a yes / no.
    private func stateRow(_ state: StateGuess) -> some View {
        let answer: Bool? = tags.contains(state.state) ? true : rejected.contains(state.state) ? false : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Text("Looks like ").foregroundStyle(Fit.muted))\(state.label.lowercased())")
                    .font(Fit.value)
                Spacer(minLength: 8)
                Text(likelihood(state.probability)).font(.caption).foregroundStyle(Fit.muted)
            }
            ForEach(state.reasons) { reasonLine($0) }
            HStack(spacing: 8) {
                AnswerButton(title: "Yes", selected: answer == true, tint: Fit.positive) { set(state.state, true) }
                AnswerButton(title: "No", selected: answer == false, tint: Fit.attention) { set(state.state, false) }
            }
        }
    }

    private func reasonLine(_ r: GuessReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: r.z > 0 ? "arrow.up" : "arrow.down").font(.caption2.weight(.bold)).foregroundStyle(Fit.faint)
            Text(r.label).font(.subheadline)
            Text(r.value).font(.subheadline).monospacedDigit()
            Text("usual \(r.usual)").font(.caption).foregroundStyle(Fit.muted).monospacedDigit()
        }
    }

    private var energyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Energy").font(.subheadline)
                Spacer()
                if let g = guessedEnergy, !touched || energy == g {
                    Text("guessed \(g)").font(.caption).foregroundStyle(Fit.muted)
                }
            }
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { value in
                    let on = energy == value
                    Button {
                        energy = value
                        touched = true
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(value)").font(.system(size: 20, weight: on ? .semibold : .light)).monospacedDigit()
                            Text(Self.energyWords[value - 1]).font(.caption2).foregroundStyle(Fit.muted).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(on ? Fit.energy.opacity(0.15) : Fit.track.opacity(0.5), in: .rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(on ? Fit.energy : .clear, style: StrokeStyle(lineWidth: 1.5, dash: on && !touched ? [4, 3] : []))
                        }
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: on)
                }
            }
        }
    }

    static let energyWords = ["Drained", "Low", "OK", "Good", "Great"]

    /// Every state and cause, the guessed states first.
    private var chipTags: [Tag] {
        let vocab = store.page?.vocabulary
        let shown = Set(store.likely.prefix(2).map(\.state))
        return (vocab?.states ?? []).filter { !shown.contains($0.key) } + (vocab?.causes ?? [])
    }

    private func label(_ key: String) -> String {
        let vocab = store.page?.vocabulary
        let all = (vocab?.states ?? []) + (vocab?.causes ?? []) + (vocab?.symptoms ?? [])
        return all.first { $0.key == key }?.label ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func likelihood(_ p: Double) -> String {
        p >= 0.85 ? "very likely" : p >= 0.6 ? "likely" : "maybe"
    }

    private func toggle(_ key: String) {
        touched = true
        if tags.contains(key) {
            tags.remove(key)
        } else {
            tags.insert(key)
            rejected.remove(key)
        }
    }

    private func set(_ state: String, _ yes: Bool) {
        touched = true
        if yes {
            tags.insert(state); rejected.remove(state)
        } else {
            rejected.insert(state); tags.remove(state)
        }
    }

    /// Starts from the saved answer, or else from the guess.
    private func reset() {
        if let saved {
            energy = saved.energy
            tags = Set(saved.tags)
            rejected = Set(saved.rejected)
            note = saved.note ?? ""
            showingMore = !(saved.note ?? "").isEmpty
        } else {
            energy = guessedEnergy
            tags = []
            rejected = []
            note = ""
        }
        touched = false
    }

    /// "Looks right" accepts every guessed state; after a change, unanswered guesses count as no.
    private func save() async {
        var tags = tags
        var rejected = rejected
        for state in store.likely.prefix(2).map(\.state) where !tags.contains(state) && !rejected.contains(state) {
            if touched { rejected.insert(state) } else { tags.insert(state) }
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let checkin = Checkin(day: day, energy: energy, mood: nil, soreness: nil, tags: tags.sorted(), rejected: rejected.sorted(),
                              note: trimmed.isEmpty ? nil : trimmed)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        editing = false
        await store.save(checkin, api: session.api)
    }
}

enum CheckinRoute: Hashable {
    case detail
}

// MARK: Past stretches

/// "Were you sick around July 15–17?": one past stretch at a time, so a year
/// of watch data gets labels without anyone remembering dates.
struct PastQuestion: View {
    @Environment(AppSession.self) private var session
    var store: CheckinStore
    @State private var skipped: Set<String> = []

    var body: some View {
        if let stretch = store.suggestions.first(where: { !skipped.contains($0.id) }) {
            FitSection(title: "Help the hub learn", trailing: "\(store.suggestions.count - skipped.count) to go") {
                Text("Were you \(stretch.label.lowercased()) around \(Self.range(stretch))?")
                    .font(Fit.value).fixedSize(horizontal: false, vertical: true)
                Takeaway(text: "Your watch data looked like it then. Answering once teaches the hub what it looks like for you.")
                HStack(spacing: 8) {
                    AnswerButton(title: "Yes", selected: false, tint: Fit.positive) { answer(stretch, true) }
                    AnswerButton(title: "No", selected: false, tint: Fit.attention) { answer(stretch, false) }
                    AnswerButton(title: "Don't remember", selected: false, tint: Fit.muted) {
                        withAnimation(.smooth) { _ = skipped.insert(stretch.id) }
                    }
                }
            }
            .transition(.opacity)
            .animation(.smooth, value: store.suggestions.count)
        }
    }

    private func answer(_ stretch: PastStretch, _ yes: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await store.answer(stretch, yes: yes, api: session.api) }
    }

    static func range(_ s: PastStretch) -> String {
        guard let from = Self.date(s.from), let to = Self.date(s.to) else { return s.from }
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

// MARK: Why we think this

/// Every number behind the morning's guess against the person's usual, how
/// sure the hub is about each state, and how much it has learned from them.
struct CheckinDetailPage: View {
    @Environment(AppSession.self) private var session
    var store: CheckinStore

    var body: some View {
        FitPage(title: "Check-in") {
            if let guess = store.guess {
                FitSection(title: "Last night against your usual", divider: false) {
                    if !guess.calibrated {
                        Takeaway(text: "Still learning your usual. Guesses sharpen after a couple of weeks of nights.")
                    }
                    ForEach(guess.metrics) { m in
                        DivergingRow(title: m.label, value: -m.z * direction(m.metric), scale: 3, detail: "\(m.value) · usual \(m.usual)")
                    }
                }
                FitSection(title: "What it could be") {
                    ForEach(guess.states) { s in
                        HStack {
                            Text(s.label).font(.subheadline)
                            Spacer()
                            Text("\(Int((s.probability * 100).rounded()))%").font(.subheadline).monospacedDigit().foregroundStyle(Fit.muted)
                        }
                        ProgressView(value: s.probability).tint(s.probability >= CheckinStore.threshold ? Fit.fair : Fit.faint)
                    }
                    Takeaway(text: "Energy guess: \(String(format: "%.1f", guess.energy)) of 5.")
                }
            }
            if let learning = store.page?.learning {
                FitSection(title: "What it has learned", trailing: "\(learning.labelledDays) days answered") {
                    ForEach(learning.states) { s in
                        HStack {
                            Text(s.label).font(.subheadline)
                            Spacer()
                            Text("\(s.yes) yes · \(s.no) no").font(.caption).foregroundStyle(Fit.muted).monospacedDigit()
                            Text(s.personal > 0 ? "\(Int(s.personal * 100))% yours" : "rules only")
                                .font(.caption).foregroundStyle(s.personal > 0 ? Fit.readiness : Fit.faint)
                                .frame(width: 76, alignment: .trailing)
                        }
                    }
                    if learning.energy.ratings < 10 {
                        Takeaway(text: "Energy: \(learning.energy.ratings) of 10 ratings before the hub fits its own energy model to you.")
                    } else if let error = learning.energy.error {
                        Takeaway(text: "Energy model from \(learning.energy.ratings) ratings, off by \(String(format: "%.1f", error)) on average.")
                    }
                    ForEach(learning.energy.drivers) { d in
                        DivergingRow(title: Self.driverName(d.input), value: d.effect, scale: 1,
                                     detail: String(format: "%+.1f energy", d.effect))
                    }
                    Takeaway(text: "Built from \(learning.daysOfData) days of watch data, including your Garmin Connect history.")
                }
            }
            if let recent = store.page?.recent, !recent.isEmpty {
                FitSection(title: "Last two weeks") {
                    ForEach(recent, id: \.day) { c in
                        HStack {
                            Text(PastQuestion.date(c.day)?.formatted(.dateTime.weekday(.abbreviated).month().day()) ?? c.day).font(.subheadline)
                            Spacer()
                            Text(([c.energy.map { "Energy \($0)" }] + c.tags.map { Optional($0.replacingOccurrences(of: "_", with: " ")) })
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Fit.muted).lineLimit(1)
                        }
                    }
                }
            }
            PastQuestion(store: store)
        }
        .refreshable { await store.load(api: session.api) }
    }

    /// +1 when higher is better, so bars point green for good.
    private func direction(_ metric: String) -> Double {
        ["hrv", "sleepHours", "sleepScore", "bodyBatteryWake", "readiness", "spo2"].contains(metric) ? -1 : 1
    }

    static func driverName(_ input: String) -> String {
        [
            "rhrUp": "Resting HR up", "hrvDown": "HRV down", "respUp": "Breathing up", "sleepHrUp": "Sleeping HR up",
            "sleepStressUp": "Restless sleep", "lateBed": "Late bedtime", "shortSleep": "Short sleep", "lowBattery": "Low Body Battery",
            "lowReadiness": "Low readiness", "stressUp": "Stressful day before", "loadUp": "Hard training day before",
            "persist": "Several off nights", "weekendNight": "Weekend", "wellness": "Good numbers overall",
        ][input] ?? input
    }
}

// MARK: Sessions

/// "How did it feel?" for a logged workout or a watch activity, prefilled
/// with the hub's guess (effort from Training Effect or set RPE, feel from
/// the morning).
struct SessionFeedbackSection: View {
    @Environment(AppSession.self) private var session
    var kind: String
    var id: String
    var onSaved: (() -> Void)? = nil
    @State private var store = CheckinStore.shared
    @State private var guess: SessionGuess?
    @State private var saved: SessionFeedback?
    @State private var feel: Int?
    @State private var effort: Int?
    @State private var vsExpected: Int?
    @State private var tags: Set<String> = []
    @State private var note = ""
    @State private var editing = false
    @State private var loaded = false

    static let feelWords = ["Awful", "Rough", "OK", "Good", "Great"]
    static let quickTags: [Tag] = [
        .init(key: "strong", label: "Strong"), .init(key: "weak", label: "Weak"), .init(key: "low_energy", label: "Low energy"),
        .init(key: "pumped", label: "Pumped"), .init(key: "pain", label: "Pain"), .init(key: "sore", label: "Sore going in"),
        .init(key: "distracted", label: "Distracted"), .init(key: "pr", label: "PR"),
    ]

    var body: some View {
        FitSection(title: "How did it feel?", trailing: saved == nil && guess?.feel != nil ? "Our guess" : nil) {
            if let saved, !editing {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text([saved.feel.map { Self.feelWords[$0 - 1] }, saved.effort.map { "effort \($0)/10" }].compactMap { $0 }.joined(separator: " · "))
                            .font(Fit.value)
                        let extra = [saved.vsExpected.map { $0 > 0 ? "Easier than expected" : $0 < 0 ? "Harder than expected" : "As expected" }]
                            .compactMap { $0 } + saved.tags.map { t in Self.quickTags.first { $0.key == t }?.label ?? t }
                        if !extra.isEmpty { Text(extra.joined(separator: ", ")).font(.subheadline).foregroundStyle(Fit.muted) }
                    }
                    Spacer()
                    Button("Edit") { editing = true }.font(.subheadline)
                }
            } else if loaded {
                form
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: id) { await load() }
    }

    @ViewBuilder private var form: some View {
        if let reasons = guess?.reasons, !reasons.isEmpty {
            Takeaway(text: reasons.joined(separator: ". ") + ".")
        }
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { value in
                Chip(title: Self.feelWords[value - 1], selected: feel == value, tint: Fit.energy) { feel = value }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Effort").font(.subheadline)
                Spacer()
                Text(effort.map { "\($0) of 10" } ?? "–").font(.subheadline).monospacedDigit().foregroundStyle(Fit.muted)
            }
            HStack(spacing: 4) {
                ForEach(1...10, id: \.self) { value in
                    Button { effort = value } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(value <= (effort ?? 0) ? Fit.activity.opacity(0.35 + Double(value) * 0.065) : Fit.track)
                            .frame(height: 28)
                            .overlay { Text("\(value)").font(.caption2).foregroundStyle(value <= (effort ?? 0) ? Color.primary : Fit.muted) }
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: effort == value)
                }
            }
        }
        HStack(spacing: 8) {
            Chip(title: "Harder", selected: vsExpected == -1, tint: Fit.attention) { vsExpected = vsExpected == -1 ? nil : -1 }
            Chip(title: "As expected", selected: vsExpected == 0, tint: Fit.muted) { vsExpected = vsExpected == 0 ? nil : 0 }
            Chip(title: "Easier", selected: vsExpected == 1, tint: Fit.positive) { vsExpected = vsExpected == 1 ? nil : 1 }
        }
        TagCloud(tags: Self.quickTags, selected: tags) { key in
            if tags.contains(key) { tags.remove(key) } else { tags.insert(key) }
        }
        TextField("Note", text: $note, axis: .vertical).font(.subheadline).lineLimit(1...3)
            .padding(10).background(Fit.track.opacity(0.5), in: .rect(cornerRadius: 10))
        Button {
            Task { await save() }
        } label: { Text("Save").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).tint(Fit.readiness).controlSize(.large)
            .disabled(feel == nil && effort == nil && vsExpected == nil && tags.isEmpty)
    }

    private func load() async {
        let result = await store.session(kind: kind, id: id, api: session.api)
        guess = result.guess
        saved = result.feedback
        let source = result.feedback
        feel = source?.feel ?? result.guess?.feel
        effort = source?.effort ?? result.guess?.effort
        vsExpected = source?.vsExpected
        tags = Set(source?.tags ?? [])
        note = source?.note ?? ""
        loaded = true
    }

    private func save() async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let feedback = SessionFeedback(kind: kind, refId: id, feel: feel, effort: effort, vsExpected: vsExpected, tags: tags.sorted(),
                                       note: trimmed.isEmpty ? nil : trimmed)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        saved = feedback
        editing = false
        onSaved?()
        await store.save(feedback, api: session.api)
    }
}

/// Right after a workout: the same question in a sheet, dismissed by saving or skipping.
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
                        try? await Task.sleep(for: .milliseconds(500))
                        dismiss()
                    }
                }
                .padding(.horizontal, Fit.gutter)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: Pieces

struct AnswerButton: View {
    var title: String
    var selected: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).frame(minHeight: 36)
                .foregroundStyle(selected ? Color.white : tint)
                .background(selected ? tint : tint.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct Chip: View {
    var title: String
    var selected: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(selected ? tint : Color.primary)
                .background(selected ? tint.opacity(0.15) : Fit.track.opacity(0.5), in: .capsule)
                .overlay { Capsule().strokeBorder(selected ? tint : .clear, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// Tags that wrap onto as many lines as they need.
struct TagCloud: View {
    var tags: [Tag]
    var selected: Set<String>
    var toggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags) { tag in
                let on = selected.contains(tag.key)
                Button { toggle(tag.key) } label: {
                    Text(tag.label).font(.footnote.weight(on ? .semibold : .regular))
                        .padding(.horizontal, 12).frame(minHeight: 32)
                        .foregroundStyle(on ? Fit.health : Color.primary)
                        .background(on ? Fit.health.opacity(0.15) : Fit.track.opacity(0.5), in: .capsule)
                        .overlay { Capsule().strokeBorder(on ? Fit.health : .clear, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: on)
            }
        }
    }
}
