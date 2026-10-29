import SwiftUI

/// A month of habits on the Calendar page: each day shows a dot, in the habit's color, for every
/// habit checked off that day. Tap a day to see it and fix what was missed.
struct HabitMonth: View {
    let store: HabitsStore
    let onSelect: (String) -> Void

    /// The first of the month on screen, as "YYYY-MM-01".
    @State private var month = HabitMonth.firstOfMonth(localDay())

    /// Day strings are calendar dates with no time zone; do the month math in UTC like DayFormat.
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = Calendar.current.firstWeekday
        return c
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 14) {
                header
                weekdays
                grid
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { g in
            guard abs(g.translation.width) > abs(g.translation.height) else { return }
            step(g.translation.width < 0 ? 1 : -1)
        })
    }

    private var header: some View {
        HStack {
            Button("Previous month", systemImage: "chevron.left") { step(-1) }
                .disabled(!canStep(-1))
            Spacer()
            Text(monthDate.formatted(Date.FormatStyle(timeZone: .gmt).month(.wide).year()))
                .font(.system(size: 28, weight: .semibold))
                .contentTransition(.numericText())
            Spacer()
            Button("Next month", systemImage: "chevron.right") { step(1) }
                .disabled(!canStep(1))
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 22, weight: .medium))
    }

    private var weekdays: some View {
        let symbols = Self.utc.veryShortStandaloneWeekdaySymbols
        let first = Self.utc.firstWeekday - 1
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[(i + first) % 7])
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BrickLook.soft)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    DayCell(day: day, isToday: day == store.today, isFuture: day > store.today,
                            dots: store.habits.filter { store.isDone($0.id, day) }.map(\.color))
                        .onTapGesture { if day <= store.today { onSelect(day) } }
                } else {
                    Color.clear.frame(height: 48)
                }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: store.done)
    }

    // MARK: Month math

    private var monthDate: Date { DayFormat.parse(month) ?? .now }

    /// The month's days, with blanks before the 1st so it lands under its weekday.
    private var cells: [String?] {
        let date = monthDate
        let count = Self.utc.range(of: .day, in: .month, for: date)?.count ?? 30
        let weekday = Self.utc.component(.weekday, from: date)
        let lead = (weekday - Self.utc.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + (0..<count).map { addDays(month, $0) }
    }

    private static func firstOfMonth(_ day: String) -> String { String(day.prefix(8)) + "01" }

    private func shifted(_ delta: Int) -> String {
        guard let next = Self.utc.date(byAdding: .month, value: delta, to: monthDate) else { return month }
        return DayFormat.formatter.string(from: next)
    }

    /// Not past this month, and not before the history the hub keeps.
    private func canStep(_ delta: Int) -> Bool {
        let target = shifted(delta)
        if delta > 0 { return target <= Self.firstOfMonth(store.today) }
        return target >= Self.firstOfMonth(addDays(store.today, -store.historyDays))
    }

    private func step(_ delta: Int) {
        guard canStep(delta) else { return }
        withAnimation(.snappy) { month = shifted(delta) }
    }
}

/// One day: its number (filled for today) over a dot per habit done.
private struct DayCell: View {
    let day: String
    let isToday: Bool
    let isFuture: Bool
    let dots: [String]

    var body: some View {
        VStack(spacing: 4) {
            Text(String(Int(day.suffix(2)) ?? 0))
                .font(.subheadline.weight(isToday ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(isToday ? .white : isFuture ? BrickLook.soft : BrickLook.ink)
                .frame(width: 30, height: 30)
                .background(isToday ? Color.googleBlue : .clear, in: .circle)
            // Up to six dots in two rows of three; past that the count says the rest.
            VStack(spacing: 2) {
                ForEach(Array(stride(from: 0, to: min(dots.count, 6), by: 3)), id: \.self) { start in
                    HStack(spacing: 2) {
                        ForEach(start..<min(start + 3, dots.count, 6), id: \.self) { i in
                            Circle().fill(Color(hex: dots[i])).frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .frame(height: 12, alignment: .top)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day), \(dots.count) habits done")
    }
}

/// One day's habits, to look back at and fix: tap a circle to mark it done (or not) for that day.
struct HabitDaySheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let store: HabitsStore
    let day: String
    let toast: Toast

    var body: some View {
        let done = store.habits.filter { store.isDone($0.id, day) }
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text(store.habits.isEmpty ? "No habits yet" : "\(done.count) of \(store.habits.count) done")
                            .font(.title2.weight(.semibold))
                            .contentTransition(.numericText())
                        Text(day == store.today ? "Tap a habit to check it off." : "Did one but forgot to check it? Tap it to mark it done for this day.")
                            .font(.subheadline)
                            .foregroundStyle(BrickLook.soft)
                            .multilineTextAlignment(.center)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 20) {
                        ForEach(store.habits) { habit in
                            VStack(spacing: 6) {
                                HabitButton(habit: habit, done: store.isDone(habit.id, day), saving: store.isSaving(habit.id, day), size: 76) {
                                    Task { await store.toggle(habit, day, api: session.api, toast: toast) }
                                }
                                let streak = store.streakText(habit)
                                if day == store.today, !streak.isEmpty {
                                    Text(streak).font(.caption).foregroundStyle(BrickLook.soft)
                                }
                            }
                        }
                    }
                    .animation(.spring(duration: 0.4, bounce: 0.2), value: store.done)
                    .sensoryFeedback(.success, trigger: done.count) { old, new in new > old }
                }
                .padding(.horizontal, Fit.gutter).padding(.vertical, 20)
            }
            .background(BrickLook.page.ignoresSafeArea())
            .foregroundStyle(BrickLook.ink)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .toast(toast)
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        guard let date = DayFormat.parse(day) else { return day }
        if day == store.today { return "Today" }
        if day == addDays(store.today, -1) { return "Yesterday" }
        return date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.wide).month(.abbreviated).day())
    }
}

/// A day picked on the month, for `.sheet(item:)`.
struct PickedDay: Identifiable {
    let day: String
    var id: String { day }
}
