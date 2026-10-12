import SwiftUI

/// Calendar events as Google Calendar–style chips that slide in one after
/// another. A newly added (or moved) event drops in last, into its place in the
/// day, and the chips after it slide down to make room. A deleted event shows
/// briefly, then slides out and the rest close the gap.
struct CalendarCard: View {
    let data: CalendarCardData

    var body: some View {
        let zone = TimeZone(identifier: data.timeZone) ?? .current
        VStack(alignment: .leading, spacing: 40) {
            CardHeader(title: data.title, detail: detail)
            if data.days.count == 1, let day = data.days.first {
                DayAgenda(day: day, zone: zone, addedId: data.addedId, removedId: data.removedId, wide: true)
            } else {
                HStack(alignment: .top, spacing: 36) {
                    ForEach(data.days) { day in
                        DayAgenda(day: day, zone: zone, addedId: data.addedId, removedId: data.removedId, wide: false)
                    }
                }
            }
        }
    }

    private var detail: String {
        let count = data.days.reduce(0) { $0 + $1.events.count }
        if data.removedId != nil { return "Removed from your calendar" }
        if data.addedId != nil { return "Updated your calendar" }
        return count == 0 ? "Nothing planned" : "\(count) event\(count == 1 ? "" : "s")"
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
        HStack(alignment: .top, spacing: wide ? 40 : 18) {
            DateBadge(day: day.day, zone: zone, large: wide)

            VStack(alignment: .leading, spacing: wide ? 14 : 10) {
                if day.events.isEmpty {
                    Text("Nothing planned")
                        .font(wide ? .title : .title3)
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                }
                ForEach(events) { event in
                    let isNew = event.id == addedId
                    let shown = isNew || revealed.contains(event.id)
                    EventChip(event: event, zone: zone, isNew: isNew, large: wide)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The one being deleted fades back before it leaves.
                        .opacity(event.id == removedId ? 0.45 : 1)
                        .scaleEffect(event.id == removedId ? 0.97 : 1)
                        .opacity(shown ? 1 : 0)
                        .offset(x: shown ? 0 : 60)
                        // The day opens a gap and the new chip grows into it.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
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
        VStack(spacing: 6) {
            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated)).uppercased())
                .font(large ? .title3.weight(.semibold) : .footnote.weight(.semibold))
                .foregroundStyle(today ? Color.googleBlue : .secondary)
            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).day()))
                .font(.system(size: large ? 40 : 26, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(today ? .white : .primary)
                .frame(width: large ? 80 : 52, height: large ? 80 : 52)
                .background(today ? Color.googleBlue : .clear, in: .circle)
        }
        .frame(width: large ? 90 : 60)
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
        let color = Color(hex: event.color)
        VStack(alignment: .leading, spacing: 3) {
            Text(event.title)
                .font(.system(size: (event.allDay ? 17 : 19) * (large ? 1.4 : 1), weight: .semibold))
                .lineLimit(1)
            if !event.allDay {
                Text(timeText)
                    .font(.system(size: large ? 21 : 15, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.85)
            }
            if let location = event.location, !event.allDay {
                Text(location).font(.system(size: large ? 19 : 14)).opacity(0.75).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, large ? 24 : 16)
        .padding(.vertical, (event.allDay ? 9 : 13) * (large ? 1.5 : 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color, in: .rect(cornerRadius: large ? 16 : 12))
        .shadow(color: color.opacity(isNew ? 0.6 : 0.25), radius: isNew ? 22 : 10, y: 6)
        .overlay {
            if isNew {
                RoundedRectangle(cornerRadius: large ? 16 : 12)
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
