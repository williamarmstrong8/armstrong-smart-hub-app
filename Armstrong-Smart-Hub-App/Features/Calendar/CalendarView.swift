import SwiftUI

/// The Google Calendar agenda from the Calendar page, next 14 days, with the to-do list on top.
struct CalendarView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// The last agenda on the phone shows until the hub answers.
    @State private var data: CalendarResponse? = DiskCache.read(calendarCacheName)
    @State private var todos: [TodoItem]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            // One scroll view for every state, so pulling down always reloads: also the
            // "Connect Google Calendar" message, once it's connected in the browser.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    topBar.padding(.bottom, -14)
                    TodoSection(items: $todos)
                    calendar
                }
                .padding(.horizontal, Fit.gutter).padding(.top, 12).padding(.bottom, 16)
            }
            .background(BrickLook.page.ignoresSafeArea())
            .foregroundStyle(BrickLook.ink)
            .tint(BrickLook.ink)
            .toolbar(.hidden, for: .navigationBar)
            // On first show and every time the app comes back to the front.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await load(refresh: true)
            }
            .refreshable { await load(refresh: true) }
        }
    }

    private var topBar: some View {
        BrickTopBar {
            Button("Open Google Calendar", systemImage: "arrow.up.forward.app") {
                openURL(URL(string: "https://calendar.google.com")!)
            }
            .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private var calendar: some View {
        if let data {
            agenda(data)
        } else if let error {
            MessageView(title: "Couldn't load your calendar", systemImage: "calendar.badge.exclamationmark", message: error,
                        actionTitle: "Try again") { Task { await load(refresh: true) } }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    @ViewBuilder
    private func agenda(_ data: CalendarResponse) -> some View {
        switch data.status {
        case "unconfigured":
            MessageView(title: "Google isn't set up", systemImage: "calendar",
                        message: "Add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET to the hub, then restart it.")
        case "not_connected", "missing_scope":
            MessageView(title: data.status == "missing_scope" ? "Reconnect Google Calendar" : "Connect Google Calendar",
                        systemImage: "calendar.badge.plus",
                        message: "Connecting Google happens in the browser. Open the hub's Calendar page, connect, then pull to refresh here.",
                        actionTitle: "Open in Safari") {
                if let url = session.webURL("/calendar") { openURL(url) }
            }
        default:
            if let error = data.error {
                MessageView(title: "Couldn't load your calendar", systemImage: "exclamationmark.triangle", message: error)
            } else if data.days.isEmpty {
                MessageView(title: "Nothing coming up", systemImage: "calendar",
                            message: "Nothing on your calendar for the next \(data.upcomingDays) days.")
            } else {
                CalendarHero(data: data)
                ForEach(data.days) { day in
                    HStack(alignment: .top, spacing: 14) {
                        DateMarker(day: day.day, isToday: day.day == data.today)
                        VStack(spacing: 8) {
                            ForEach(day.events) { event in
                                EventCard(event: event, zone: data.timeZone)
                                    .onTapGesture {
                                        if let s = event.url, let url = URL(string: s) { openURL(url) }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The agenda and the to-do list together. `refresh` makes the hub drop its cached events,
    /// so a calendar connected in the browser (or an event added elsewhere) shows right away.
    private func load(refresh: Bool = false) async {
        let api = session.api
        async let list: TodoList? = try? api.get("/api/mobile/todos")
        do {
            let raw = try await api.data(api.request("/api/mobile/calendar\(refresh ? "?refresh=1" : "")"))
            data = try APIClient.decoder.decode(CalendarResponse.self, from: raw)
            error = nil
            DiskCache.write(raw, calendarCacheName)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        // A list that won't load still shows (empty), so adding says what went wrong.
        if let items = await list?.items { todos = items } else if todos == nil { todos = [] }
    }
}

let calendarCacheName = "calendar"

/// The event coming up next, big.
private struct CalendarHero: View {
    let data: CalendarResponse

    var body: some View {
        let now = Date()
        let today = data.days.first { $0.day == data.today }?.events ?? []
        let next = today.first { !$0.allDay && ($0.startDate.map { $0 > now } ?? false) }
            ?? data.days.lazy.flatMap(\.events).first { !$0.allDay && ($0.startDate.map { $0 > now } ?? false) }
        if let next, let start = next.startDate {
            BrickHero(caption: "Next up", title: next.title,
                      subtitle: start.formatted(.dateTime.weekday(.wide).hour().minute())) {}
        } else {
            BrickHero(caption: "Today", title: today.isEmpty ? "Nothing today" : "Done for today") {}
        }
    }
}

/// Google's day marker: weekday over the date, filled blue for today.
private struct DateMarker: View {
    let day: String
    let isToday: Bool

    var body: some View {
        let date = DayFormat.parse(day) ?? .now
        VStack(spacing: 4) {
            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated)).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isToday ? Color.googleBlue : BrickLook.soft)
            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).day()))
                .font(.title3.weight(.medium)).monospacedDigit()
                .foregroundStyle(isToday ? .white : .primary)
                .frame(width: 40, height: 40)
                .background(isToday ? Color.googleBlue : .clear, in: .circle)
        }
        .frame(width: 44)
    }
}

/// One event as a solid card in its calendar's color: the name and the time.
private struct EventCard: View {
    let event: CalendarEvent
    let zone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title).font(.headline).lineLimit(2)
            Text(time).font(.subheadline.weight(.medium)).monospacedDigit().opacity(0.9)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(Color(hexForWhiteText: event.color), in: .rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))
    }

    /// "6 PM" or "6:30 PM – 8 PM", like Google Calendar.
    private var time: String {
        guard !event.allDay, let start = event.startDate else { return "All day" }
        let tz = TimeZone(identifier: zone) ?? .current
        func short(_ d: Date) -> String {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            var style = Date.FormatStyle.dateTime.hour()
            if cal.component(.minute, from: d) != 0 { style = style.minute() }
            style.timeZone = tz
            return d.formatted(style)
        }
        guard let end = ISO.parse(event.end) else { return short(start) }
        return "\(short(start)) – \(short(end))"
    }
}
