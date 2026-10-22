import AppIntents
import SwiftUI
import WidgetKit

// Today's habits: check them off from the home screen, see the count on the
// lock screen. The check buttons call the hub from here.

struct ToggleHabitIntent: AppIntent {
    static let title: LocalizedStringResource = "Check off a habit"
    static let isDiscoverable = false

    @Parameter(title: "Habit") var habitId: String
    @Parameter(title: "Done") var done: Bool

    init() {}
    init(id: String, done: Bool) {
        habitId = id
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        guard let hub = HubCall.current else { throw HubCallError(message: "Open the app and sign in first.") }
        let today = SharedDay.string()
        let _: HubNothing? = try await hub.run("setCompletion", [.string(habitId), .string(today), .bool(done)])
        if var snapshot = HabitsSnapshot.read(), snapshot.day == today, let i = snapshot.habits.firstIndex(where: { $0.id == habitId }) {
            if snapshot.habits[i].done != done { snapshot.habits[i].streak = max(0, snapshot.habits[i].streak + (done ? 1 : -1)) }
            snapshot.habits[i].done = done
            snapshot.touchedAt = .now
            snapshot.write()
        }
        return .result()
    }
}

struct HabitsEntry: TimelineEntry {
    var date: Date
    var snapshot: HabitsSnapshot?
    var signedIn: Bool
}

struct HabitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.habits, provider: HabitsProvider()) { entry in
            HabitsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "armstronghub://home"))
        }
        .configurationDisplayName("Habits")
        .description("Check off today's habits.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct HabitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> HabitsEntry {
        HabitsEntry(date: .now, snapshot: HabitsSnapshot(day: SharedDay.string(), habits: [
            HabitItem(id: "a", name: "Read", color: "#52A8FF", icon: "📚", done: true, streak: 4),
            HabitItem(id: "b", name: "Stretch", color: "#62C073", icon: "🧘", done: false, streak: 0),
            HabitItem(id: "c", name: "Water", color: "#FF9F0A", icon: "💧", done: true, streak: 12),
        ]), signedIn: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (HabitsEntry) -> Void) {
        if context.isPreview && HabitsSnapshot.read() == nil { return completion(placeholder(in: context)) }
        completion(HabitsEntry(date: .now, snapshot: HabitsSnapshot.read(), signedIn: HubCall.current != nil))
    }

    /// Fresh from the hub when it answers. A new entry at midnight starts the next day unchecked.
    func getTimeline(in context: Context, completion: @escaping (Timeline<HabitsEntry>) -> Void) {
        Task {
            var snapshot = HabitsSnapshot.read()
            if !(snapshot?.recentlyTouched ?? false), let hub = HubCall.current,
               let payload: WidgetHabitsPayload = try? await hub.get("/api/mobile/habits") {
                snapshot = payload.snapshot
                snapshot?.write()
            }
            let signedIn = HubCall.current != nil
            let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
            let today = snapshot.map { $0.day == SharedDay.string() ? $0 : Self.rolled($0, to: SharedDay.string()) }
            let entries = [
                HabitsEntry(date: .now, snapshot: today, signedIn: signedIn),
                HabitsEntry(date: midnight, snapshot: today.map { Self.rolled($0, to: SharedDay.string(midnight)) }, signedIn: signedIn),
            ]
            completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(30 * 60))))
        }
    }

    /// The board on a later day: nothing checked yet, and only streaks ticked the day before live on.
    private static func rolled(_ s: HabitsSnapshot, to day: String) -> HabitsSnapshot {
        let keepStreaks = SharedDay.shift(day, -1) == s.day
        return HabitsSnapshot(day: day, habits: s.habits.map { h in
            var h = h
            if !(keepStreaks && h.done) { h.streak = 0 }
            h.done = false
            return h
        })
    }
}

private struct HabitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: HabitsEntry

    private var habits: [HabitItem] { entry.snapshot?.habits ?? [] }
    private var done: Int { habits.filter(\.done).count }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(done)/\(habits.count) habits", systemImage: "checkmark.circle")
        case .accessoryCircular:
            Gauge(value: Double(done), in: 0...Double(max(habits.count, 1))) {
                Image(systemName: "checkmark")
            } currentValueLabel: {
                Text("\(done)/\(habits.count)").monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Habits", systemImage: "checkmark.circle.fill").font(.headline).widgetAccentable()
                Text(done == habits.count && !habits.isEmpty ? "All done today" : "\(done) of \(habits.count) done")
                Text(habits.filter { !$0.done }.map(\.name).joined(separator: ", "))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            board
        }
    }

    private var limit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 6
        default: return 14
        }
    }

    @ViewBuilder private var board: some View {
        if !entry.signedIn {
            WidgetMessage(symbol: "checkmark.circle", title: "Habits", detail: "Open the app to sign in")
        } else if habits.isEmpty {
            WidgetMessage(symbol: "checkmark.circle", title: "No habits yet", detail: "Add some on Home")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Habits").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(done)/\(habits.count)").font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(done == habits.count ? WidgetColor.green : .secondary)
                }
                let shown = Array(habits.prefix(limit))
                if family == .systemSmall {
                    ForEach(shown) { HabitRow(habit: $0, compact: true) }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
                        ForEach(shown) { HabitRow(habit: $0, compact: false) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct HabitRow: View {
    var habit: HabitItem
    var compact: Bool

    var body: some View {
        let color = Color(widgetHex: habit.color)
        Button(intent: ToggleHabitIntent(id: habit.id, done: !habit.done)) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().strokeBorder(color, lineWidth: 2)
                    if habit.done {
                        Circle().fill(color)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text([habit.icon, habit.name].compactMap { $0 }.joined(separator: " "))
                        .font(.caption.weight(.semibold)).lineLimit(1)
                    if !compact, habit.streak > 1 {
                        Text("\(habit.streak) day streak").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, compact ? 1 : 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .invalidatableContent()
    }
}

extension Color {
    /// "#RRGGBB", like the app's Color(hex:).
    init(widgetHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
