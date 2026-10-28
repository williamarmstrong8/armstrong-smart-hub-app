import SwiftUI

/// Calendar events as Google Calendar–style chips that slide in one after
/// another. A newly added (or moved) event drops in last, into its place in the
/// day, and the chips after it slide down to make room. A deleted event shows
/// briefly, then slides out and the rest close the gap.
struct CalendarCard: View {
    let data: CalendarCardData

    /// Minimal and centered: the day's date big on top, its events under it. Several days sit
    /// side by side as centered columns, as many across as fit.
    var body: some View {
        let zone = TimeZone(identifier: data.timeZone) ?? .current
        VStack(spacing: 28) {
            if data.days.count == 1, let day = data.days.first {
                DayAgenda(day: day, zone: zone, addedId: data.addedId, removedId: data.removedId, wide: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    columns(3, zone)
                    columns(2, zone)
                    columns(1, zone)
                }
            }
            if let change {
                Text(change).font(.title2.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func columns(_ across: Int, _ zone: TimeZone) -> some View {
        let n = max(1, min(across, data.days.count))
        let rows = stride(from: 0, to: data.days.count, by: n).map { Array(data.days[$0..<min($0 + n, data.days.count)]) }
        return VStack(spacing: 44) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 36) {
                    ForEach(row) { day in
                        DayAgenda(day: day, zone: zone, addedId: data.addedId, removedId: data.removedId, wide: false)
                            .frame(width: 280)
                    }
                }
            }
        }
        .fixedSize()
    }

    /// Only when something changed: the date and the events say the rest.
    private var change: String? {
        if data.removedId != nil { return "Removed from your calendar" }
        if data.addedId != nil { return "Added to your calendar" }
        return nil
    }
}

private struct DayAgenda: View {
    let day: VoiceCalendarDay
    let zone: TimeZone
    let addedId: String?
    let removedId: String?
    let wide: Bool

    /// Chips that have slid in so far, by event (positions shift when one is inserted).
    @State private var revealed: Set<String> = []
    @State private var showAdded = false
    @State private var removedGone = false

    private var events: [CalendarEvent] {
        day.events.filter { ($0.id != addedId || showAdded) && !($0.id == removedId && removedGone) }
    }

    var body: some View {
        VStack(spacing: wide ? 32 : 20) {
            DateBadge(day: day.day, zone: zone, large: wide)

            VStack(spacing: wide ? 16 : 12) {
                if day.events.isEmpty {
                    Text("Nothing planned")
                        .font(.system(size: wide ? 40 : 26, weight: .light))
                        .foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    let isNew = event.id == addedId
                    let shown = isNew || revealed.contains(event.id)
                    EventChip(event: event, zone: zone, isNew: isNew, large: wide)
                        .frame(maxWidth: wide ? 640 : .infinity)
                        // The one being deleted fades back before it leaves.
                        .opacity(event.id == removedId ? 0.45 : 1)
                        .scaleEffect(event.id == removedId ? 0.97 : 1)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 24)
                        // The day opens a gap and the new chip grows into it.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .scale(scale: 0.85)).combined(with: .opacity)))
                }
            }
            .animation(.spring(duration: 0.7, bounce: 0.3), value: showAdded)
            .animation(.spring(duration: 0.6, bounce: 0.2), value: removedGone)
        }
        .onAppear { play(staggered: true) }
        // Same card, new data (Jev's preview, then the tool's result): keep the
        // chips already showing and animate only what changed.
        .onChange(of: day.events.map(\.id)) { play(staggered: false) }
        .onChange(of: addedId) { play(staggered: false) }
        .onChange(of: removedId) { play(staggered: false) }
    }

    private func play(staggered: Bool) {
        let existingEvents = day.events.filter { $0.id != addedId }
        // When updating in place, everything is already laid out: no stagger to wait for.
        let existing = staggered ? existingEvents.count : 0
        if !staggered {
            var instant = SwiftUI.Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                showAdded = false
                removedGone = false
            }
            withAnimation(.spring(duration: 0.5, bounce: 0.2)) { revealed.formUnion(existingEvents.map(\.id)) }
        }
        if removedId != nil {
            // Let the day settle, then the deleted event slides away.
            Task {
                try? await Task.sleep(for: .seconds(0.25 + 0.08 * Double(existing) + 0.6))
                removedGone = true
            }
        }
        for (i, event) in existingEvents.enumerated() where staggered {
            withAnimation(.spring(duration: 0.55, bounce: 0.2).delay(0.08 * Double(i) + 0.1)) { _ = revealed.insert(event.id) }
        }
        if addedId != nil {
            // After the day is laid out, the new event drops into its slot.
            Task {
                try? await Task.sleep(for: .seconds(0.25 + 0.08 * Double(existing) + 0.35))
                showAdded = true
            }
        }
    }
}

/// Google's day marker: weekday above a date, filled blue for today.
private struct DateBadge: View {
    let day: String
    let zone: TimeZone
    var large = false

    var body: some View {
        let date = DayFormat.parse(day) ?? .now
        let today = DayFormat.string(.now, zone: zone) == day
        VStack(spacing: large ? 10 : 6) {
            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(large ? .wide : .abbreviated)).uppercased())
                .font(.system(size: large ? 24 : 16, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(today ? Color.googleBlue : .secondary)
            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).day()))
                .font(.system(size: large ? 76 : 40, weight: .light))
                .monospacedDigit()
                .foregroundStyle(today ? .white : .primary)
                .frame(width: large ? 140 : 76, height: large ? 140 : 76)
                .background(today ? Color.googleBlue : .clear, in: .circle)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A solid, colored event chip like Google Calendar's.
private struct EventChip: View {
    let event: CalendarEvent
    let zone: TimeZone
    let isNew: Bool
    var large = false

    @State private var ring = false

    var body: some View {
        // Darkened where needed: Google's pastel calendar colors left white text unreadable.
        let color = Color(hexForWhiteText: event.color)
        VStack(spacing: 4) {
            Text(event.title)
                .font(.system(size: (event.allDay ? 18 : 21) * (large ? 1.6 : 1), weight: .semibold))
                .lineLimit(2)
            if !event.allDay {
                Text(timeText)
                    .font(.system(size: large ? 26 : 16, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.85)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(.horizontal, large ? 28 : 16)
        .padding(.vertical, (event.allDay ? 10 : 14) * (large ? 1.5 : 1))
        .frame(maxWidth: .infinity)
        .background(color, in: .rect(cornerRadius: large ? 22 : 14))
        .shadow(color: color.opacity(isNew ? 0.6 : 0.25), radius: isNew ? 22 : 10, y: 6)
        .overlay {
            if isNew {
                RoundedRectangle(cornerRadius: large ? 22 : 14)
                    .strokeBorder(color, lineWidth: 3)
                    .scaleEffect(ring ? 1.12 : 1)
                    .opacity(ring ? 0 : 1)
            }
        }
        .onAppear {
            guard isNew else { return }
            withAnimation(.easeOut(duration: 0.9).delay(0.5)) { ring = true }
        }
        .sensoryFeedback(.success, trigger: ring) { _, new in isNew && new }
    }

    private var timeText: String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        guard let s = ISO.parse(event.start) else { return "" }
        guard let e = ISO.parse(event.end) else { return s.formatted(style) }
        return "\(s.formatted(style)) – \(e.formatted(style))"
    }
}

extension Color {
    static let googleBlue = Color(red: 0.1, green: 0.45, blue: 0.91)
}

extension DayFormat {
    /// "YYYY-MM-DD" for an instant, in a given time zone.
    static func string(_ date: Date, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
