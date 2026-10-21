import SwiftUI

// MARK: Morning check-in

/// One question a morning: sick or not. The hub's guess is said first and
/// its answer is the filled button; the other is right beside it, so a wrong
/// guess is one tap to correct. Once answered: one line, a past day to
/// confirm if there is one, and a way to log sick days the hub missed.
/// Every answer is a label the hub learns from (checkin-engine.ts).
struct MorningCheckin: View {
    @Environment(AppSession.self) private var session
    var store: CheckinStore
    @State private var changing = false
    @State private var logging = false

    private var day: String { store.day }
    /// The hub thinks today looks like being sick.
    private var guessedSick: Bool { store.likely.contains { $0.state == "sick" } }

    var body: some View {
        FitSection {
            VStack(alignment: .leading, spacing: 0) {
                if let sick = store.entry(for: day).flatMap(Self.sick), !changing {
                    answered(sick)
                    if let stretch = store.suggestions.first {
                        divider
                        past(stretch)
                    }
                } else {
                    asking
                }
                divider
                Button { logging = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.caption.weight(.semibold))
                        Text("Log sick days")
                    }
                    .font(.footnote).foregroundStyle(BrickLook.soft)
                }
                .buttonStyle(.plain)
            }
            .animation(.smooth, value: changing)
        }
        .sheet(isPresented: $logging) { SickDaysSheet(store: store) }
    }

    private var divider: some View {
        Rectangle().fill(BrickLook.line).frame(height: 1).padding(.vertical, 16)
    }

    /// "Looks like you might be sick", then the two answers, the guessed one filled.
    private var asking: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                BrickCaps(text: store.guess == nil ? "Check in" : "Our guess").foregroundStyle(BrickLook.soft)
                Text(store.guess == nil ? "How are you today?" : guessedSick ? "Looks like you might be sick" : "Looks like a normal day")
                    .font(.system(size: 22, weight: .regular)).foregroundStyle(BrickLook.ink)
            }
            HStack(spacing: 10) {
                CheckinButton(title: "I'm fine", filled: store.guess != nil && !guessedSick) { answer(false) }
                CheckinButton(title: "I'm sick", filled: guessedSick) { answer(true) }
            }
            if changing {
                Button("Cancel") { changing = false }.font(.footnote).foregroundStyle(BrickLook.soft).buttonStyle(.plain)
            }
        }
    }

    private func answered(_ sick: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sick ? "thermometer.medium" : "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(sick ? Fit.attention : Fit.positive)
                .frame(width: 34, height: 34)
                .background(BrickLook.pill, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(sick ? "Sick today" : "Feeling fine").font(.body).foregroundStyle(BrickLook.ink)
                BrickCaps(text: "Checked in").foregroundStyle(BrickLook.soft)
            }
            Spacer(minLength: 8)
            Button("Change") { changing = true }
                .font(.footnote.weight(.medium)).foregroundStyle(BrickLook.ink)
                .padding(.horizontal, 14).frame(height: 32)
                .background(BrickLook.pill, in: .capsule)
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

    /// Yes for sick, no for not, nil when the day's check-in didn't say.
    static func sick(_ c: Checkin) -> Bool? {
        c.tags.contains("sick") ? true : c.rejected.contains("sick") ? false : nil
    }

    private func answer(_ sick: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        changing = false
        Task { await store.answer(day: day, sick: sick, api: session.api) }
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

/// "I was sick from … to …": just the days.
struct SickDaysSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: CheckinStore
    @State private var from = Date.now
    @State private var to = Date.now

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $from, in: ...Date.now, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
            }
            .navigationTitle("Sick days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onChange(of: from) { if to < from { to = from } }
        }
        .presentationDetents([.height(260)])
    }

    private func save() {
        let first = Self.day(from), last = max(Self.day(to), Self.day(from))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { await store.log(from: first, to: last, tags: ["sick"], note: nil, api: session.api) }
        dismiss()
    }

    /// The local calendar day, as the hub keys check-ins.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
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
