import SwiftUI

/// The Google Calendar agenda from the Calendar page, next 14 days.
struct CalendarView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var data: CalendarResponse?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let data {
                    agenda(data)
                } else if let error {
                    MessageView(title: "Couldn't load your calendar", systemImage: "calendar.badge.exclamationmark", message: error,
                                actionTitle: "Try again") { Task { await load() } }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open Google Calendar", systemImage: "arrow.up.forward.app") {
                        openURL(URL(string: "https://calendar.google.com")!)
                    }
                }
            }
            .task { if data == nil { await load() } }
            .refreshable { await load(refresh: true) }
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
                List {
                    ForEach(data.days) { day in
                        Section(header: dayHeader(day.day, today: data.today, zone: data.timeZone)) {
                            ForEach(day.events) { event in
                                EventRow(event: event, zone: data.timeZone)
                                    .contentShape(.rect)
                                    .onTapGesture {
                                        if let s = event.url, let url = URL(string: s) { openURL(url) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func dayHeader(_ day: String, today: String?, zone: String) -> some View {
        let date = DayFormat.parse(day) ?? .now
        var utc = Date.FormatStyle.dateTime.weekday(.wide)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var short = Date.FormatStyle.dateTime.month(.abbreviated).day()
        short.timeZone = TimeZone(identifier: "UTC")!
        let label: String = {
            if day == today { return "Today" }
            if let today, day == addDays(today, 1) { return "Tomorrow" }
            return date.formatted(utc)
        }()
        return HStack(spacing: 6) {
            Text(label).foregroundStyle(.primary)
            Text(date.formatted(short))
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }

    private func load(refresh: Bool = false) async {
        do {
            data = try await session.api.get("/api/mobile/calendar\(refresh ? "?refresh=1" : "")")
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let zone: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: event.color)).frame(width: 4)
            Text(time).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 4) {
                    if let location = event.location {
                        Image(systemName: "mappin").imageScale(.small)
                        Text(location).lineLimit(1)
                        Text("·")
                    }
                    Text(event.calendar).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var time: String {
        guard !event.allDay, let date = event.startDate else { return "All day" }
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = TimeZone(identifier: zone) ?? .current
        return date.formatted(style)
    }
}
