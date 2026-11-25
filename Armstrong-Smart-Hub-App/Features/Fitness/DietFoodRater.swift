import Foundation
import FoundationModels

/// Rates a food that isn't in the guide and doesn't name anything in it (a dish,
/// a brand, a snack), with the on-device model, so every food he logs gets a rating.
/// It runs on the phone; nothing leaves it. Ratings lean cautious: when the usual
/// recipe has garlic, onion, wheat, honey, beans or milk it's high.
nonisolated enum DietFoodRater {
    @Generable
    struct Rating {
        @Guide(description: "low, moderate or high FODMAP at a normal serving. moderate means low only in a small serving. When unsure, moderate.",
               .anyOf(["low", "moderate", "high"]))
        var level: String
        @Guide(description: "The FODMAP groups that make it moderate or high, from: fructans, gos, lactose, fructose, sorbitol, mannitol. Empty when low.")
        var groups: [String]
        @Guide(description: "One short sentence saying why, naming the ingredients that matter or the serving that keeps it low, e.g. 'Usually made with garlic and onion.'")
        var tip: String
    }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// The level and groups come back as their raw values ("high", "fructans").
    static func rate(_ name: String) async -> (level: String, groups: [String], tip: String)? {
        guard isAvailable else { return nil }
        let instructions = """
        You rate foods for someone on the Monash University low-FODMAP diet, at a normal serving. \
        Think about what the food is usually made with. Garlic, onion, wheat, rye, barley, honey, agave, \
        apple, pear, mango, beans, lentils, cashews, pistachios, mushrooms, cauliflower, milk, soft cheese \
        and yogurt make a food high. Meat, fish, eggs, rice, potatoes, oats in small servings, most hard \
        cheese, carrots, spinach, berries, citrus, peanuts and plain oils are low. Be cautious: if a usual \
        recipe has a high ingredient, say high.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "Rate this food: \(name)", generating: Rating.self)
            let r = response.content
            let level = r.level.lowercased()
            guard ["low", "moderate", "high"].contains(level) else { return nil }
            let tip = r.tip.trimmingCharacters(in: .whitespacesAndNewlines)
            return (level, level == "low" ? [] : r.groups.map { $0.lowercased() },
                    (tip.isEmpty ? "" : tip + " ") + "Estimated on your phone, so check the label.")
        } catch {
            return nil
        }
    }
}
