import AuthenticationServices
import SwiftUI

let calendarCacheName = "calendar"
let todoCacheName = "todos"

/// What Home shows of the calendar: the Google agenda and the to-do list, loaded together.
@MainActor
@Observable
final class AgendaStore {
    /// The last agenda and list on the phone show until the hub answers.
    var data: CalendarResponse? = DiskCache.read(calendarCacheName)
    var todos: [TodoItem]? = DiskCache.read(todoCacheName)
    var error: String?
    var connectError: String?

    var hasAgenda: Bool {
        guard let data else { return false }
        return !["unconfigured", "not_connected", "missing_scope"].contains(data.status) && data.error == nil && !data.days.isEmpty
    }

    /// The event coming up next: later today, else the first one after.
    var next: (event: CalendarEvent, start: Date)? {
        guard hasAgenda, let data else { return nil }
        let now = Date()
        let upcoming = data.days.lazy.flatMap(\.events).compactMap { e -> (CalendarEvent, Date)? in
            guard !e.allDay, let start = e.startDate, start > now else { return nil }
            return (e, start)
        }
        return upcoming.first.map { (event: $0.0, start: $0.1) }
    }

    /// `refresh` makes the hub drop its cached events, so a calendar connected in the browser
    /// (or an event added elsewhere) shows right away.
    func load(api: APIClient, refresh: Bool = false) async {
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
        if let items = await list?.items { todos = items; DiskCache.write(items, todoCacheName) } else if todos == nil { todos = [] }
    }
}

/// The to-do list, a month of habits and the next two weeks, as sections of the Home page.
struct AgendaSections: View {
    @Environment(AppSession.self) private var session
    @Bindable var agenda: AgendaStore
    var habits: HabitsStore
    var onPickDay: (String) -> Void

    var body: some View {
        TodoSection(items: $agenda.todos)
        if habits.loaded, !habits.habits.isEmpty {
            HabitMonth(store: habits) { onPickDay($0) }
        }
        calendar
    }

    @ViewBuilder
    private var calendar: some View {
        if let data = agenda.data {
            agendaDays(data)
        } else if let error = agenda.error {
            MessageView(title: "Couldn't load your calendar", systemImage: "calendar.badge.exclamationmark", message: error,
                        actionTitle: "Try again") { Task { await agenda.load(api: session.api, refresh: true) } }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    @ViewBuilder
    private func agendaDays(_ data: CalendarResponse) -> some View {
        switch data.status {
        case "unconfigured":
            MessageView(title: "Google isn't set up", systemImage: "calendar",
                        message: "Add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET to the hub, then restart it.")
        case "not_connected", "missing_scope":
            MessageView(title: data.status == "missing_scope" ? "Reconnect Google Calendar" : "Connect Google Calendar",
                        systemImage: "calendar.badge.plus",
                        message: agenda.connectError ?? "Sign in with Google right here. You only do this once.",
                        actionTitle: "Connect Google") {
                Task { await connectGoogle() }
            }
        default:
            if let error = data.error {
                MessageView(title: "Couldn't load your calendar", systemImage: "exclamationmark.triangle", message: error)
            } else if data.days.isEmpty {
                MessageView(title: "Nothing coming up", systemImage: "calendar",
                            message: "Nothing on your calendar for the next \(data.upcomingDays) days.")
            } else {
                ForEach(data.days) { day in
                    HStack(alignment: .top, spacing: 14) {
                        DateMarker(day: day.day, isToday: day.day == data.today)
                        VStack(spacing: 8) {
                            ForEach(day.events) { event in
                                if let s = event.url, let url = URL(string: s) {
                                    Link(destination: url) {
                                        EventCard(event: event, zone: data.timeZone)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    EventCard(event: event, zone: data.timeZone)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Google's sign-in sheet, then the hub keeps the tokens and the agenda reloads.
    private func connectGoogle() async {
        agenda.connectError = nil
        do {
            _ = try await GoogleSignIn.connect(api: session.api)
            await agenda.load(api: session.api, refresh: true)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            agenda.connectError = error.localizedDescription
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
                .foregroundStyle(isToday ? Color.googleBlue : HubDesign.secondary)
            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).day()))
                .font(.title3.weight(.medium)).monospacedDigit()
                .foregroundStyle(isToday ? .white : HubDesign.ink)
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
        .padding(HubLayout.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(Color(hexForWhiteText: event.color), in: .rect(cornerRadius: HubLayout.cardRadius))
        .contentShape(.rect(cornerRadius: HubLayout.cardRadius))
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
