import SwiftUI

/// Someone's birthday, from Google Calendar, at the top of Home: from 8 PM the evening before
/// through the whole day. The X hides that one birthday for good.
struct BirthdayCards: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    /// Shares the Calendar page's copy, so it shows at once on launch.
    @State private var data: CalendarResponse? = DiskCache.read(calendarCacheName)
    /// Event ids of birthdays already closed, one per line.
    @AppStorage("dismissedBirthdays") private var dismissed = ""

    /// The evening before, from this hour.
    private static let eveningHour = 20

    var body: some View {
        // Re-checked every minute, so 8 PM and midnight bring it in and out without a reload.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let items = showing(at: context.date)
            VStack(spacing: 12) {
                ForEach(items) { item in
                    BirthdayCard(event: item.event, isToday: item.isToday) {
                        withAnimation(.smooth) { dismiss(item.event.id) }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.bottom, items.isEmpty ? 0 : 28)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await load()
        }
    }

    private struct Item: Identifiable {
        let event: CalendarEvent
        let isToday: Bool
        var id: String { event.id }
    }

    private func showing(at now: Date) -> [Item] {
        guard let data else { return [] }
        let today = localDay(now)
        let tomorrow = addDays(today, 1)
        let evening = Calendar.current.component(.hour, from: now) >= Self.eveningHour
        let closed = Set(dismissed.split(separator: "\n").map(String.init))
        var seen = Set<String>()
        return data.days.flatMap(\.events)
            .filter { $0.birthday == true && !closed.contains($0.id) && seen.insert($0.id).inserted }
            .compactMap { e -> Item? in
                let day = String(e.start.prefix(10))
                if day == today { return Item(event: e, isToday: true) }
                if day == tomorrow, evening { return Item(event: e, isToday: false) }
                return nil
            }
    }

    private func dismiss(_ id: String) {
        // Keep the list short: last year's ids can't come back.
        let kept = dismissed.split(separator: "\n").suffix(50).map(String.init)
        dismissed = (kept + [id]).joined(separator: "\n")
    }

    private func load() async {
        do {
            let api = session.api
            let raw = try await api.data(api.request("/api/mobile/calendar"))
            let fresh = try APIClient.decoder.decode(CalendarResponse.self, from: raw)
            withAnimation(.smooth) { data = fresh }
            DiskCache.write(raw, calendarCacheName)
        } catch {
            // Keep the last copy; a birthday card is never worth an error on Home.
        }
    }
}

private struct BirthdayCard: View {
    let event: CalendarEvent
    let isToday: Bool
    let onClose: () -> Void

    var body: some View {
        BrickCard(padding: 18) {
            HStack(spacing: 16) {
                Text("🎂").font(.system(size: 38))
                VStack(alignment: .leading, spacing: 3) {
                    BrickCaps(text: isToday ? "Today" : "Tomorrow").foregroundStyle(BrickLook.soft)
                    Text(event.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(BrickLook.ink)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrickLook.soft)
                    .frame(width: 34, height: 34)
                    .background(BrickLook.pill, in: .circle)
                    .buttonStyle(.plain)
            }
        }
    }
}
