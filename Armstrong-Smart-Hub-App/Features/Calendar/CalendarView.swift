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
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
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
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
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

/// Google's day marker: weekday over the date, filled blue for today.
private struct DateMarker: View {
    let day: String
    let isToday: Bool

    var body: some View {
        let date = DayFormat.parse(day) ?? .now
        VStack(spacing: 4) {
            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated)).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isToday ? Color.googleBlue : .secondary)
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
        .background(Color(hexForWhiteText: event.color), in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
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
