import Foundation
import FoundationModels
import Observation
import UserNotifications

/// A short read of your health, written on the phone by Apple's on-device
/// model, twice a day as a notification:
/// - morning (once last night's sleep is in, 5 am – noon): sleep, HRV,
///   resting heart rate, readiness, Body Battery, last night's drinks and the
///   check-in guess;
/// - night (from 9:30 pm): steps, activity, workouts, stress, Body Battery,
///   tonight's drinks and time at work or the gym.
///
/// Nothing leaves the phone. Without Apple Intelligence it sends the same
/// facts as plain sentences. It runs whenever the app gets a chance: a watch
/// sync, a background refresh, or opening the app; each slot goes out once a
/// day.
@MainActor
@Observable
final class HealthBriefing {
    static let shared = HealthBriefing()

    enum Slot: String, CaseIterable {
        case morning, night
        var title: String { self == .morning ? "Morning briefing" : "Night briefing" }
    }

    var api: APIClient?
    var morningOn: Bool { didSet { UserDefaults.standard.set(morningOn, forKey: "briefing.morning.on") } }
    var nightOn: Bool { didSet { UserDefaults.standard.set(nightOn, forKey: "briefing.night.on") } }
    /// The newest briefing of each slot, for the card on Fitness.
    private(set) var briefs: [Slot: Brief] = [:]

    struct Brief: Codable, Equatable {
        var text: String
        var at: Date
    }
    private(set) var writing = false

    /// The hour (local) the night briefing goes out from.
    static let nightHour = 21
    static let nightMinute = 30

    @ObservationIgnored private let fitness = FitnessStore()

    init() {
        let d = UserDefaults.standard
        morningOn = d.object(forKey: "briefing.morning.on") as? Bool ?? true
        nightOn = d.object(forKey: "briefing.night.on") as? Bool ?? true
        for slot in Slot.allCases {
            if let data = d.data(forKey: "briefing.\(slot.rawValue).brief"), let brief = try? JSONDecoder().decode(Brief.self, from: data) {
                briefs[slot] = brief
            }
        }
    }

    var modelAvailable: Bool { SystemLanguageModel.default.isAvailable }

    // MARK: When

    /// The slot that should go out now, if any, and the day it's for.
    func due(now: Date = .now) -> (Slot, String)? {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minutes = hour * 60 + calendar.component(.minute, from: now)
        if morningOn, (5..<12).contains(hour) {
            let day = localDay(now)
            if !sent(.morning, day) {
                // Wait for last night's sleep (a sync after waking), or 9 am at the latest.
                let woke = fitness.lastNight?.endDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false
                if woke || hour >= 9 { return (.morning, day) }
            }
        }
        if nightOn, minutes >= Self.nightHour * 60 + Self.nightMinute || hour < 3 {
            // After midnight it's still the evening before.
            let day = localDay(now.addingTimeInterval(-3 * 3600))
            if !sent(.night, day) { return (.night, day) }
        }
        return nil
    }

    /// The next moment a slot could go out, for the background refresh to aim at.
    func nextTime(after now: Date = .now) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let candidates: [Date] = (0...1).flatMap { offset -> [Date] in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return [] }
            return [
                calendar.date(bySettingHour: 7, minute: 30, second: 0, of: day),
                calendar.date(bySettingHour: Self.nightHour, minute: Self.nightMinute, second: 0, of: day),
            ].compactMap { $0 }
        }
        return candidates.filter { $0 > now }.min() ?? now.addingTimeInterval(6 * 3600)
    }

    private func sent(_ slot: Slot, _ day: String) -> Bool {
        UserDefaults.standard.string(forKey: "briefing.\(slot.rawValue).sent") == day
    }

    // MARK: Writing

    /// Sends the slot that's due, if any. Safe to call often.
    func runIfDue() async {
        guard !Demo.isOn, !writing else { return }
        if let api { await fitness.load(api: api) }
        guard let (slot, day) = due() else { return }
        writing = true
        defer { writing = false }
        let facts = facts(slot)
        guard !facts.isEmpty else { return }
        let text = await write(slot, facts: facts)
        UserDefaults.standard.set(day, forKey: "briefing.\(slot.rawValue).sent")
        keep(slot, text)
        await notify(slot, text)
    }

    /// The slot for right now: morning until 3 pm, then night.
    nonisolated static var currentSlot: Slot { Calendar.current.component(.hour, from: .now) < 15 ? .morning : .night }

    /// Writes a briefing now, whatever the time, without a notification (the card's refresh).
    func writeNow(_ slot: Slot = currentSlot) async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        if let api { await fitness.load(api: api) }
        let facts = facts(slot)
        guard !facts.isEmpty else { return }
        keep(slot, await write(slot, facts: facts))
    }

    /// Account › Test features: writes the slot now and sends it as the real notification would look.
    func sendTest(_ slot: Slot, after seconds: TimeInterval = 5) async -> String {
        await writeNow(slot)
        guard isCurrent(slot), let brief = briefs[slot] else { return "No health data on the phone to write from yet." }
        await notify(slot, brief.text, after: seconds)
        return modelAvailable ? "Written by Apple Intelligence." : "Apple Intelligence is off, so this is the plain version."
    }

    /// Account › Test features: loads the newest snapshot and writes it to Apple Health now.
    func syncHealthNow() async -> String {
        let health = HealthSync.shared
        guard health.enabled else { return "Turn on Write to Apple Health first." }
        if let api { await fitness.load(api: api) }
        await health.sync(fitness.snapshot, drinks: AlcoholStore.shared.entries)
        if let error = health.lastError { return "Health said: \(error)" }
        return "Done. \(health.writtenCount) items written so far; open Health › Browse to see them."
    }

    /// Whether a slot's brief is from today (the night one counts until 3 am).
    func isCurrent(_ slot: Slot) -> Bool {
        guard let at = briefs[slot]?.at else { return false }
        return localDay(at.addingTimeInterval(-3 * 3600)) == localDay(Date.now.addingTimeInterval(-3 * 3600))
    }

    private func keep(_ slot: Slot, _ text: String) {
        let brief = Brief(text: text, at: .now)
        briefs[slot] = brief
        if let data = try? JSONEncoder().encode(brief) { UserDefaults.standard.set(data, forKey: "briefing.\(slot.rawValue).brief") }
    }

    private func write(_ slot: Slot, facts: [String]) async -> String {
        guard modelAvailable else { return Self.plain(facts) }
        let instructions = """
        You write a short \(slot == .morning ? "morning" : "end-of-day") health briefing for one person, from their \
        watch and app data. Two to four short sentences, second person, warm and direct, plain text: no lists, \
        headings or emoji. Use only the facts given and never invent numbers. Lead with what matters most \
        \(slot == .morning ? "for today" : "about today"), compare with their usual where a fact says what usual is, \
        and end with one practical suggestion. No diagnoses or medical advice.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "Facts:\n" + facts.map { "- \($0)" }.joined(separator: "\n"))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? Self.plain(facts) : text
        } catch {
            return Self.plain(facts)
        }
    }

    /// No model: the first few facts as they are.
    private static func plain(_ facts: [String]) -> String {
        facts.prefix(4).map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    private func notify(_ slot: Slot, _ text: String, after seconds: TimeInterval = 0) async {
        let content = UNMutableNotificationContent()
        content.title = slot.title
        content.body = text
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = Self.category
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "briefing.\(slot.rawValue)", content: content, trigger: seconds > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false) : nil))
    }

    nonisolated static let category = "briefing"
    nonisolated static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: [], intentIdentifiers: [])
    }

    // MARK: Facts

    private func facts(_ slot: Slot) -> [String] {
        slot == .morning ? morningFacts() : nightFacts()
    }

    private func morningFacts() -> [String] {
        var out: [String] = []
        let calendar = Calendar.current
        if let night = fitness.lastNight, let end = night.endDate, end.timeIntervalSinceNow > -18 * 3600 {
            var line = "Slept \(FitnessFormat.duration(Double(night.asleepSeconds)))"
            let usual = fitness.nights.dropFirst().prefix(14).map(\.asleepSeconds).filter { $0 > 0 }
            if !usual.isEmpty { line += " (usually \(FitnessFormat.duration(Double(usual.reduce(0, +) / usual.count))))" }
            line += ": deep \(FitnessFormat.duration(Double(night.seconds(.deep)))), REM \(FitnessFormat.duration(Double(night.seconds(.rem)))), awake \(FitnessFormat.duration(Double(night.seconds(.awake))))"
            if let score = night.score { line += ", sleep score \(score)" }
            out.append(line)
        }
        if let h = fitness.snapshot?.hrv?.first, let value = h.lastNightAverage {
            var line = "Overnight HRV \(Int(value.rounded())) ms"
            if let week = h.weeklyAverage { line += " (7-day average \(Int(week.rounded())) ms)" }
            if let status = h.status { line += ", status \(status.lowercased())" }
            out.append(line)
        }
        let rhr = fitness.days.compactMap(\.restingHr)
        if let now = rhr.first {
            let usual = rhr.dropFirst().prefix(7)
            out.append("Resting heart rate \(now) bpm" + (usual.isEmpty ? "" : " (usually \(usual.reduce(0, +) / usual.count))"))
        }
        if let r = fitness.snapshot?.metrics?.readiness, let score = r.score {
            out.append("Readiness \(score)/100" + (r.level.map { ", \($0.lowercased())" } ?? ""))
        }
        if let battery = fitness.series(.bodyBattery).last, battery.date.timeIntervalSinceNow > -6 * 3600 {
            out.append("Body Battery \(battery.value)")
        }
        let lastNight = AlcoholStore.night(of: Date.now.addingTimeInterval(-12 * 3600))
        let drinks = AlcoholStore.shared.drinks(on: lastNight)
        if drinks > 0 { out.append("\(drinks) drink\(drinks == 1 ? "" : "s") last night") }
        else if AlcoholStore.shared.isAnswered(lastNight) { out.append("No drinks last night") }
        let store = CheckinStore.shared
        if let top = store.likely.first { out.append("The hub's guess this morning: \(top.label.lowercased()) (\(Int(top.probability * 100))% likely)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: .now) {
            let done = fitness.activities.filter { $0.start.map { calendar.isDate($0, inSameDayAs: yesterday) } ?? false }
            if !done.isEmpty { out.append("Yesterday: " + done.map { "\($0.title) \(FitnessFormat.duration($0.duration))" }.joined(separator: ", ")) }
        }
        return out
    }

    private func nightFacts() -> [String] {
        var out: [String] = []
        let calendar = Calendar.current
        let now = Date.now.addingTimeInterval(-3 * 3600)
        if let day = fitness.days.first(where: { $0.day == localDay(now) }) {
            if let steps = day.steps {
                out.append("\(steps.formatted()) steps" + (day.stepGoal.map { " of a \($0.formatted()) goal" } ?? ""))
            }
            if let kcal = day.activeKcal { out.append("\(kcal) active calories") }
            if let minutes = day.intensityMinutes, minutes > 0 { out.append("\(minutes) intensity minutes") }
        }
        let today = fitness.activities.filter { $0.start.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        for a in today {
            var line = "\(a.title), \(FitnessFormat.duration(a.duration))"
            if a.hasDistance { line += ", \(FitnessFormat.distance(a.distanceMeters))" }
            if let hr = a.avgHr { line += ", average heart rate \(hr)" }
            out.append(line)
        }
        let stress = fitness.series(.stress).filter { calendar.isDate($0.date, inSameDayAs: now) }.map(\.value).filter { $0 >= 0 }
        if !stress.isEmpty {
            let average = stress.reduce(0, +) / stress.count
            let high = stress.filter { $0 >= 60 }.count * 5
            out.append("Average stress \(average)/100" + (high >= 30 ? ", about \(FitnessFormat.duration(Double(high * 60))) high" : ""))
        }
        if let battery = fitness.series(.bodyBattery).last, battery.date.timeIntervalSinceNow > -3 * 3600 {
            out.append("Body Battery now \(battery.value)")
        }
        let tonight = AlcoholStore.shared.tonight
        let drinks = AlcoholStore.shared.drinks(on: tonight)
        if drinks > 0 { out.append("\(drinks) drink\(drinks == 1 ? "" : "s") so far tonight") }
        for kind in [PlaceMonitor.Kind.work, .gym] {
            let seconds = PlaceMonitor.shared.seconds(at: kind, on: now)
            if seconds >= 15 * 60 { out.append("\(FitnessFormat.duration(seconds)) at \(kind.title.lowercased())") }
        }
        let checkin = CheckinStore.shared.entry(for: localDay(now))
        if let feeling = checkin.flatMap(Feeling.of) { out.append("Checked in feeling \(Feeling.label(feeling).lowercased()) today") }
        return out
    }
}
