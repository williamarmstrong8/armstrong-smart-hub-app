import AuthenticationServices
import SwiftUI

/// The next thing on the calendar as one Liquid Glass card in Home's hero: the calendar's
/// color, how soon, the name, and when and where. Holds its height while the agenda loads,
/// so the hero never jumps.
struct NextEventCard: View {
    let agenda: AgendaStore
    @Environment(\.openURL) private var openURL
    @Environment(AppSession.self) private var session
    @State private var connecting = false

    var body: some View {
        // Ticks each minute so "in 12 min" stays true.
        TimelineView(.everyMinute) { context in
            if let next = agenda.next {
                Button {
                    if let s = next.event.url, let url = URL(string: s) { openURL(url) }
                } label: {
                    card(next.event, start: next.start, now: context.date)
                }
                .buttonStyle(.plain)
                .accessibilityHint(next.event.url == nil ? "" : "Opens the event")
            } else if agenda.data == nil {
                card(Self.placeholder, start: .now.addingTimeInterval(3600), now: context.date)
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            } else if let status = agenda.data?.status, ["not_connected", "missing_scope"].contains(status) {
                reconnect(first: status == "not_connected")
            } else if agenda.hasAgenda {
                empty
            }
        }
    }

    private func card(_ event: CalendarEvent, start: Date, now: Date) -> some View {
        HStack(spacing: 14) {
            Capsule()
                .fill(Color(hexForWhiteText: event.color))
                .frame(width: 4)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                BrickCaps(text: Self.when(start, now: now)).foregroundStyle(BrickLook.soft)
                Text(event.title).font(.headline).foregroundStyle(HubDesign.ink).lineLimit(1)
                Text(detail(event, start: start))
                    .font(.subheadline).foregroundStyle(BrickLook.soft).lineLimit(1)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(BrickLook.soft)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .glassGlare(.regular.interactive(), in: .rect(cornerRadius: HubLayout.cardRadius))
        .contentShape(.rect(cornerRadius: HubLayout.cardRadius))
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar").font(.title3).foregroundStyle(BrickLook.soft)
            Text("Nothing else on your calendar").font(.subheadline).foregroundStyle(BrickLook.soft)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .glassGlare(.regular, in: .rect(cornerRadius: HubLayout.cardRadius))
    }

    /// Google's link has lapsed (or was never made): sign in again right here.
    private func reconnect(first: Bool) -> some View {
        Button {
            Task { await connectGoogle() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "calendar.badge.exclamationmark").font(.title3).foregroundStyle(BrickLook.soft)
                VStack(alignment: .leading, spacing: 3) {
                    Text(first ? "Connect Google Calendar" : "Reconnect Google Calendar")
                        .font(.headline).foregroundStyle(HubDesign.ink)
                    Text(agenda.connectError ?? (first ? "Sign in once to see what's next" : "Google's sign-in expired"))
                        .font(.subheadline).foregroundStyle(BrickLook.soft).lineLimit(1)
                }
                Spacer(minLength: 8)
                if connecting {
                    ProgressView()
                } else {
                    Text(first ? "Connect" : "Reconnect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HubDesign.ink)
                        .padding(.horizontal, 14).frame(height: 34)
                        .glassGlare(.regular.tint(HubDesign.action.opacity(0.35)), in: .capsule)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
            .glassGlare(.regular.interactive(), in: .rect(cornerRadius: HubLayout.cardRadius))
            .contentShape(.rect(cornerRadius: HubLayout.cardRadius))
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }

    /// Google's sign-in sheet; the hub keeps the tokens and the agenda reloads.
    private func connectGoogle() async {
        connecting = true
        defer { connecting = false }
        agenda.connectError = nil
        do {
            _ = try await GoogleSignIn.connect(api: session.api)
            await agenda.load(api: session.api, refresh: true)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
        } catch {
            agenda.connectError = error.localizedDescription
        }
    }

    static let height: CGFloat = 84

    /// "3 PM – 4 PM · Office", in the calendar's time zone.
    private func detail(_ event: CalendarEvent, start: Date) -> String {
        let tz = agenda.data.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
        func short(_ d: Date) -> String {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            var style = Date.FormatStyle.dateTime.hour()
            if cal.component(.minute, from: d) != 0 { style = style.minute() }
            style.timeZone = tz
            return d.formatted(style)
        }
        var time = short(start)
        if let end = ISO.parse(event.end) { time += " – \(short(end))" }
        if let place = event.location?.split(separator: ",").first.map(String.init), !place.isEmpty {
            return "\(time) · \(place)"
        }
        return time
    }

    /// "Now", "In 40 min", "Today", "Tomorrow" or the weekday.
    static func when(_ start: Date, now: Date) -> String {
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "In \(minutes) min" }
        let cal = Calendar.current
        if cal.isDate(start, inSameDayAs: now) {
            let hours = minutes / 60
            return hours < 6 ? "In \(hours) hr" : "Later today"
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(start, inSameDayAs: tomorrow) { return "Tomorrow" }
        return start.formatted(.dateTime.weekday(.wide))
    }

    private static let placeholder: CalendarEvent = {
        let json = ##"{"id":"p","title":"Something coming up","start":"2026-01-01T15:00:00Z","end":"2026-01-01T16:00:00Z","allDay":false,"calendar":"p","color":"#6b7280"}"##
        return try! APIClient.decoder.decode(CalendarEvent.self, from: Data(json.utf8))
    }()
}
