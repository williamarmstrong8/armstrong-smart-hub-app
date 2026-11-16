import AuthenticationServices
import SwiftUI

/// The next thing on the calendar as plain text under Home's greeting: the name, when, and
/// where. Holds its height while the agenda loads, so the hero never jumps.
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

    /// The name, when (how soon, then start to end), and where, all in full: lines wrap
    /// rather than cut off.
    private func card(_ event: CalendarEvent, start: Date, now: Date) -> some View {
        VStack(spacing: 4) {
            Text(event.title)
                .font(.title3.weight(.medium))
                .foregroundStyle(HubDesign.ink)
            Text(timeLine(event, start: start, now: now))
                .font(.body)
                .foregroundStyle(BrickLook.soft)
                .monospacedDigit()
            if let place = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                Text(place)
                    .font(.body)
                    .foregroundStyle(BrickLook.soft)
            }
        }
        .modifier(Shell())
        .accessibilityElement(children: .combine)
    }

    /// "In 40 min · 3 – 4 PM", "Tomorrow · 9 – 10:30 AM", or just "3 – 4 PM" later today.
    private func timeLine(_ event: CalendarEvent, start: Date, now: Date) -> String {
        var range = clock(start)
        if let end = ISO.parse(event.end) { range += " – \(clock(end))" }
        return [when(start, now: now), range].compactMap { $0 }.joined(separator: " · ")
    }

    private func clock(_ d: Date) -> String {
        let tz = agenda.data.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var style = Date.FormatStyle.dateTime.hour()
        if cal.component(.minute, from: d) != 0 { style = style.minute() }
        style.timeZone = tz
        return d.formatted(style)
    }

    private var empty: some View {
        Text("Nothing else on your calendar")
            .font(.title3)
            .foregroundStyle(BrickLook.soft)
            .modifier(Shell())
    }

    /// Plain text centred under the greeting, no glass; every state keeps the same minimum height.
    private struct Shell: ViewModifier {
        func body(content: Content) -> some View {
            content
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: NextEventCard.height)
                .contentShape(.rect)
        }
    }

    /// Google's link has lapsed (or was never made): sign in again right here.
    private func reconnect(first: Bool) -> some View {
        Button {
            Task { await connectGoogle() }
        } label: {
            VStack(spacing: 10) {
                Text(agenda.connectError ?? (first ? "Google Calendar isn't connected" : "Google Calendar needs reconnecting"))
                    .font(.title3)
                    .foregroundStyle(BrickLook.soft)
                Group {
                    if connecting {
                        ProgressView()
                    } else {
                        Text(first ? "Connect Google" : "Reconnect Google")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(HubDesign.ink)
                    }
                }
                .padding(.horizontal, 16).frame(height: 40)
                .glassGlare(.regular.tint(HubDesign.action.opacity(0.35)).interactive(), in: .capsule)
            }
            .modifier(Shell())
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

    static let height: CGFloat = 60

    /// "Now", "In 40 min", "Tomorrow" or "Tue"; nil later today (the time says it).
    private func when(_ start: Date, now: Date) -> String? {
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "In \(minutes) min" }
        let tz = agenda.data.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        if cal.isDate(start, inSameDayAs: now) { return nil }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(start, inSameDayAs: tomorrow) { return "Tomorrow" }
        var day = Date.FormatStyle.dateTime.weekday(.wide)
        day.timeZone = tz
        return start.formatted(day)
    }

    private static let placeholder: CalendarEvent = {
        let json = ##"{"id":"p","title":"Something coming up","start":"2026-01-01T15:00:00Z","end":"2026-01-01T16:00:00Z","allDay":false,"calendar":"p","color":"#6b7280"}"##
        return try! APIClient.decoder.decode(CalendarEvent.self, from: Data(json.utf8))
    }()
}
