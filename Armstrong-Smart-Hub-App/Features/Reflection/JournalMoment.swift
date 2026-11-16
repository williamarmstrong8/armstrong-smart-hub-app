import Foundation
import HealthKit
import JournalingSuggestions

/// A moment picked from Apple's Journaling Suggestions, written out as the
/// start of a journal entry (markdown): its title and date, then a line for
/// each thing in it (a workout, a place, a song, a person, a prompt), and room
/// to write underneath. Photos stay in Photos; the entry says how many.
enum JournalMoment {
    static func draft(from suggestion: JournalingSuggestion) async -> String {
        var lines: [String] = ["## \(suggestion.title)"]
        if let date = suggestion.date {
            lines.append("_\(date.start.formatted(date: .complete, time: .omitted))_")
        }
        var details: [String] = []
        var prompts: [String] = []
        var photos = 0

        for item in suggestion.items {
            if let w = await first(item, JournalingSuggestion.Workout.self) {
                details.append(workout(w))
            } else if let g = await first(item, JournalingSuggestion.WorkoutGroup.self) {
                details.append(contentsOf: g.workouts.map(workout))
            } else if let l = await first(item, JournalingSuggestion.Location.self) {
                if let line = place(l) { details.append(line) }
            } else if let g = await first(item, JournalingSuggestion.LocationGroup.self) {
                details.append(contentsOf: g.locations.compactMap(place))
            } else if let s = await first(item, JournalingSuggestion.Song.self) {
                let song = [s.song, s.artist].compactMap { $0 }.joined(separator: " – ")
                if !song.isEmpty { details.append("- Listened to \(song)") }
            } else if let p = await first(item, JournalingSuggestion.Podcast.self) {
                let episode = [p.episode, p.show].compactMap { $0 }.joined(separator: ", ")
                if !episode.isEmpty { details.append("- Podcast: \(episode)") }
            } else if let m = await first(item, JournalingSuggestion.GenericMedia.self) {
                let media = [m.title, m.artist].compactMap { $0 }.joined(separator: " – ")
                if !media.isEmpty { details.append("- \(media)") }
            } else if let c = await first(item, JournalingSuggestion.Contact.self) {
                details.append("- With \(c.name)")
            } else if let m = await first(item, JournalingSuggestion.MotionActivity.self) {
                details.append("- \(m.steps.formatted()) steps")
            } else if let s = await first(item, JournalingSuggestion.StateOfMind.self) {
                details.append("- Felt \(mood(s.state))")
            } else if let r = await first(item, JournalingSuggestion.Reflection.self) {
                prompts.append("> \(r.prompt)")
            } else if let e = await first(item, JournalingSuggestion.EventPoster.self) {
                let place = e.placeName.map { " at \($0)" } ?? ""
                details.append("- \(String(e.title.characters))\(place)")
            } else if item.hasContent(ofType: JournalingSuggestion.Photo.self)
                        || item.hasContent(ofType: JournalingSuggestion.LivePhoto.self)
                        || item.hasContent(ofType: JournalingSuggestion.Video.self) {
                photos += 1
            }
        }
        if photos > 0 { details.append("- \(photos) photo\(photos == 1 ? "" : "s") in Photos") }

        var seen = Set<String>()
        details = details.filter { seen.insert($0).inserted }
        if !details.isEmpty { lines.append(""); lines.append(contentsOf: details) }
        if !prompts.isEmpty { lines.append(""); lines.append(contentsOf: prompts) }
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The item's content of one kind, when it has that kind (an item can offer several).
    private static func first<T: JournalingSuggestionAsset>(_ item: JournalingSuggestion.ItemContent, _ type: T.Type) async -> T? {
        guard item.hasContent(ofType: type) else { return nil }
        let all: [T] = await item.content(forType: type)
        return all.first
    }

    private static func workout(_ w: JournalingSuggestion.Workout) -> String {
        var parts: [String] = []
        let d = w.details
        parts.append(d?.localizedName ?? "Workout")
        if let interval = d?.date { parts.append(FitnessFormat.duration(interval.duration)) }
        if let distance = d?.distance { parts.append(FitnessFormat.distance(distance.doubleValue(for: .meter()))) }
        if let kcal = d?.activeEnergyBurned { parts.append("\(Int(kcal.doubleValue(for: .kilocalorie()).rounded())) kcal") }
        if let hr = d?.averageHeartRate { parts.append("avg \(Int(hr.doubleValue(for: .count().unitDivided(by: .minute())).rounded())) bpm") }
        return "- " + parts.joined(separator: " · ")
    }

    private static func place(_ l: JournalingSuggestion.Location) -> String? {
        let name = [l.place, l.city].compactMap { $0 }.filter { !$0.isEmpty }
        guard !name.isEmpty else { return nil }
        return "- At " + name.joined(separator: ", ")
    }

    /// Health's mood as a word, from how pleasant it was.
    private static func mood(_ s: HKStateOfMind) -> String {
        switch s.valence {
        case ..<(-0.6): "very unpleasant"
        case ..<(-0.2): "unpleasant"
        case ..<0.2: "neutral"
        case ..<0.6: "pleasant"
        default: "very pleasant"
        }
    }
}
