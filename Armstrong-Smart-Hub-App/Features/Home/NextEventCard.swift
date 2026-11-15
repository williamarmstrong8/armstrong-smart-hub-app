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

    /// One line: what, then when.
    private func card(_ event: CalendarEvent, start: Date, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(event.title)
                .font(.title3.weight(.medium))
                .foregroundStyle(HubDesign.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(when(start, now: now))
                .font(.title3)
                .foregroundStyle(BrickLook.soft)
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
        }
        .modifier(Shell())
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        Text("Nothing else on your calendar")
            .font(.title3)
            .foregroundStyle(BrickLook.soft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Shell(interactive: false))
    }

    /// The card's glass, shared so every state is the same height.
    private struct Shell: ViewModifier {
        var interactive = true
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: NextEventCard.height, alignment: .leading)
                .glassGlare(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: HubLayout.cardRadius))
                .contentShape(.rect(cornerRadius: HubLayout.cardRadius))
        }
    }

    /// Google's link has lapsed (or was never made): sign in again right here.
    private func reconnect(first: Bool) -> some View {
        Button {
            Task { await connectGoogle() }
        } label: {
            HStack(spacing: 12) {
                Text(agenda.connectError ?? (first ? "Connect Google Calendar" : "Reconnect Google Calendar"))
                    .font(.title3)
                    .foregroundStyle(agenda.connectError == nil ? HubDesign.ink : BrickLook.soft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if connecting {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)).foregroundStyle(BrickLook.soft)
                }
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

    /// "Now", "In 40 min", "3 PM", "Tomorrow 9 AM" or "Tue 9 AM", in the calendar's time zone.
    private func when(_ start: Date, now: Date) -> String {
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "In \(minutes) min" }
        let tz = agenda.data.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var style = Date.FormatStyle.dateTime.hour()
        if cal.component(.minute, from: start) != 0 { style = style.minute() }
        style.timeZone = tz
        let time = start.formatted(style)
        if cal.isDate(start, inSameDayAs: now) { return time }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(start, inSameDayAs: tomorrow) { return "Tomorrow \(time)" }
        var day = Date.FormatStyle.dateTime.weekday(.abbreviated)
        day.timeZone = tz
        return "\(start.formatted(day)) \(time)"
    }

    private static let placeholder: CalendarEvent = {
        let json = ##"{"id":"p","title":"Something coming up","start":"2026-01-01T15:00:00Z","end":"2026-01-01T16:00:00Z","allDay":false,"calendar":"p","color":"#6b7280"}"##
        return try! APIClient.decoder.decode(CalendarEvent.self, from: Data(json.utf8))
    }()
}
