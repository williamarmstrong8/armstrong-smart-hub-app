import SwiftUI

/// The Google Calendar agenda from the Calendar page, next 14 days.
struct CalendarView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    /// The last agenda on the phone shows until the hub answers.
    @State private var data: CalendarResponse? = DiskCache.read(calendarCacheName)
    @State private var fetched = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The agenda scrolls its own top bar away, like every other tab; the other states keep it here.
                if !showsAgenda {
                    topBar.padding(.horizontal, Fit.gutter).padding(.top, 12).padding(.bottom, 8)
                }
                Group {
                    if let data {
                        agenda(data)
                    } else if let error {
                        MessageView(title: "Couldn't load your calendar", systemImage: "calendar.badge.exclamationmark", message: error,
                                    actionTitle: "Try again") { Task { await load() } }
                    } else {
                        ProgressView().frame(maxHeight: .infinity)
                    }
                }
            }
            .background(BrickLook.page.ignoresSafeArea())
            .foregroundStyle(BrickLook.ink)
            .tint(BrickLook.ink)
            .toolbar(.hidden, for: .navigationBar)
            .task { if !fetched { await load() } }
            .refreshable { await load(refresh: true) }
        }
    }

    private var showsAgenda: Bool {
        guard let data, !["unconfigured", "not_connected", "missing_scope"].contains(data.status) else { return false }
        return data.error == nil && !data.days.isEmpty
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
                        topBar.padding(.bottom, -14)
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
                    .padding(.horizontal, Fit.gutter).padding(.top, 12).padding(.bottom, 16)
                }
            }
        }
    }

    private func load(refresh: Bool = false) async {
        do {
            let api = session.api
            let raw = try await api.data(api.request("/api/mobile/calendar\(refresh ? "?refresh=1" : "")"))
            data = try APIClient.decoder.decode(CalendarResponse.self, from: raw)
            fetched = true
            error = nil
            DiskCache.write(raw, calendarCacheName)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
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
