import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The screen iOS shows over a blocked app or site: black and white, today's Brick time,
/// and a different hard line about what these apps cost you each time it appears.
/// iOS only lets this pick colors, an icon and text; it can't draw its own views.
class BrickShield: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration { screen() }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        screen()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { screen() }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        screen()
    }

    private func screen() -> ShieldConfiguration {
        let icon = UIImage(systemName: "iphone.slash",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .light))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: .black,
            icon: icon,
            title: ShieldConfiguration.Label(text: headline(), color: .white),
            // iOS sets the spacing and alignment itself; a blank line is the only way to push the quote down.
            subtitle: ShieldConfiguration.Label(text: "\n" + (Self.lines.randomElement() ?? ""), color: UIColor(white: 0.75, alpha: 1)),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Close", color: .black),
            primaryButtonBackgroundColor: .white)
    }

    /// Today's Brick time, the running session included. Lockdowns don't count as Brick time,
    /// so during only a lockdown this says so instead of a number.
    private func headline() -> String {
        let start = Calendar.current.startOfDay(for: Date())
        let seconds = BrickEngine.sessions.reduce(0.0) { total, s in
            let end = s.end ?? Date()
            guard end > start else { return total }
            return total + end.timeIntervalSince(max(s.start, start))
        }
        if seconds < 60 && BrickEngine.blockingProfileID == nil { return "Locked down" }
        let minutes = Int(seconds / 60)
        let text = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return "\(text) saved today"
    }

    /// A different one each time. Harsh on purpose.
    private static let lines = [
        "The best version of you doesn't open this app. You know that.",
        "You're trading the person you could be for a feed that forgets you in a second.",
        "Comfort is killing you slowly. This is the most comfortable thing you do all day.",
        "Every scroll is a vote for staying exactly who you are right now.",
        "The people you love are getting the leftovers of your attention. This app gets the best of it.",
        "No one at the end of their life wishes they'd scrolled more.",
        "You keep saying you'll start tomorrow. This is why tomorrow never comes.",
        "This app is making your decisions for you. What you want, what you buy, how you feel. Take it back.",
        "Your relationships don't fade in one big moment. They fade one ignored conversation at a time, while you're on this.",
        "Someone with half your talent is outworking you right now because they put the phone down.",
        "You're not relaxing. You're numbing yourself so you don't have to face what you're avoiding.",
        "Hours of your life, gone, and you can't name a single thing you saw.",
        "The algorithm knows you better than your friends do now. That should scare you.",
        "Discipline is choosing what you want most over what you want now. This is what you want now.",
        "You are becoming what you consume. Look at what you consume.",
        "Every minute here is a minute you'll never get back. You're spending your life on this.",
        "Average is comfortable. This app is how you stay average.",
        "You'd be embarrassed if anyone saw how much of your life goes into this screen.",
        "Your value isn't likes and views. Stop letting an app tell you what you're worth.",
        "The work that changes your life is hard and boring. This is the escape from it. Don't escape.",
        "You already know what you should be doing. Go do it.",
        "Your phone is not your life. But it's becoming your life. Stop it here.",
        "Nobody is coming to make you better. You have to do it, and you can't do it from in here.",
        "You opened this without thinking. That's exactly the problem.",
        "Close it. Go be the person you keep promising yourself you'll become.",
    ]
}
