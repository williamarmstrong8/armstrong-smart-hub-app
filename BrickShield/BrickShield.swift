import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The screen iOS shows over a blocked app or site: black and white, today's Brick time,
/// and a different line about what these apps cost each time it appears.
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
            subtitle: ShieldConfiguration.Label(text: Self.lines.randomElement() ?? "", color: UIColor(white: 0.7, alpha: 1)),
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

    /// A different one each time. Two are real, attributed quotes; the rest are plain statements.
    private static let lines = [
        "\u{201C}The short-term, dopamine-driven feedback loops that we have created are destroying how society works.\u{201D} \u{2014} Chamath Palihapitiya, former Facebook VP of user growth",
        "\u{201C}God only knows what it's doing to our children's brains.\u{201D} \u{2014} Sean Parker, Facebook's first president",
        "This app was built by thousands of engineers to keep you scrolling. You're one person. Don't play their game.",
        "The feed never ends. That's the point. Your day does.",
        "You're not the customer here. Your attention is what's being sold.",
        "Every notification is a slot machine pull. The house always wins.",
        "Endless scrolling trains your brain to crave novelty and lose patience for anything that takes real focus.",
        "It takes a long time to get back into deep work after a single check. Is this worth that?",
        "Comparing your life to everyone's highlight reel is a reliable way to feel worse.",
        "Late-night scrolling costs you sleep, and poor sleep costs you tomorrow.",
        "The U.S. Surgeon General has warned that social media can pose a profound risk to young people's mental health.",
        "Nothing in there is urgent. If it were, someone would call.",
        "An hour a day of scrolling is more than two weeks a year. Spend it on something you'll remember.",
        "You opened this out of habit, not because you needed it.",
        "Boredom is where ideas start. Don't hand it to an algorithm.",
    ]
}
