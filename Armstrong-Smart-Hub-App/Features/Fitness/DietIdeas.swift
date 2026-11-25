import Foundation

/// A low-FODMAP meal to suggest: what it needs (each need met by any one of
/// several guide foods), what's nice to add, and when it suits.
struct MealIdea: Identifiable {
    var id: String
    var name: String
    var slots: Set<MealSlot>
    /// Each inner list is one ingredient, met by any of these guide foods.
    var needs: [[String]]
    /// Extras it's better with, if he has them.
    var extras: [String] = []
    var tip: String?
    /// Small enough for late at night.
    var light = false
}

/// An idea worked out against his kitchen and history.
struct IdeaPick: Identifiable {
    var idea: MealIdea
    /// The food chosen for each need: one he has when he can.
    var foods: [DietFood]
    /// Needs he doesn't have.
    var missing: [DietFood]
    /// Extras he has.
    var extras: [DietFood]
    /// Foods in it that have sat well with him.
    var agreeable: [DietFood]
    var score: Double

    var id: String { idea.id }
    var complete: Bool { missing.isEmpty }
    /// The "watch" foods in it, whose serving matters.
    var portions: [DietFood] { (foods + extras).filter { $0.level == .moderate } }
}

/// Meal ideas for the time of day: the upcoming meal's ideas, ranked by how much
/// of each he has in his kitchen, nudged toward foods that have sat well and away
/// from what he just ate. Ideas using a food that keeps coming before his
/// symptoms are left out. Every idea is built from low or "watch" foods only.
@MainActor
enum DietIdeas {
    // MARK: When

    /// The meal coming up: the one it's time for, or the next if that one's already logged today.
    static func upcoming(_ store: DietStore, now: Date = .now) -> MealSlot {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let slot: MealSlot = switch minutes {
        case 240..<630: .breakfast
        case 630..<870: .lunch
        case 870..<1020: .snack
        case 1020..<1290: .dinner
        default: .snack
        }
        let logged = Set(store.meals(on: localDay(now)).map(\.slot))
        guard logged.contains(slot) else { return slot }
        switch slot {
        case .breakfast: return minutes >= 540 ? .lunch : .snack
        case .lunch: return .snack
        case .dinner: return .snack
        case .snack: return minutes >= 870 && minutes < 1020 ? .dinner : .snack
        }
    }

    /// After 9:30 pm, or before 4 am.
    static func isLate(_ now: Date = .now) -> Bool {
        let h = Calendar.current.component(.hour, from: now), m = Calendar.current.component(.minute, from: now)
        return h * 60 + m >= 1290 || h < 4
    }

    /// A line of advice for the time of day.
    static func tip(for slot: MealSlot, now: Date = .now) -> String {
        if slot == .snack, isLate(now) {
            return "Late: keep it small and plain. Lying down soon after a big meal can bring on reflux."
        }
        switch slot {
        case .breakfast: return "Keep oats to about ½ cup, and go easy on coffee on an empty stomach: it gets the gut moving."
        case .lunch: return "Several \"watch\" foods in one meal add up. Have one at its low serving, not three."
        case .snack: return "Space snacks a few hours from meals, so FODMAPs from each don't stack."
        case .dinner: return "Finishing dinner two to three hours before bed gives your gut time before you lie down."
        }
    }

    // MARK: Ranking

    static func suggest(_ store: DietStore, slot: MealSlot, now: Date = .now, limit: Int = 6) -> [IdeaPick] {
        let have = store.inStock(now: now)
        let insights = DietInsights(store: store)
        let suspects = Set(insights.suspects.map(\.id))
        let agreeable = Set(insights.agreeable.map(\.id))
        let recent = Set(store.meals.filter { now.timeIntervalSince($0.at) < 20 * 3600 }.flatMap { $0.foods.compactMap(\.foodID) })
        let late = slot == .snack && isLate(now)
        let day = localDay(now)

        let picks: [IdeaPick] = all.compactMap { idea in
            guard idea.slots.contains(slot), !late || idea.light else { return nil }
            var foods: [DietFood] = [], missing: [DietFood] = []
            for need in idea.needs {
                // Leave out what keeps coming before his symptoms.
                let options = need.filter { !suspects.contains($0) }.compactMap { LowFodmap.byID[$0] }
                guard let first = options.first else { return nil }
                // One food per need: a food already used for another need doesn't count twice.
                let open = options.filter { option in !foods.contains { $0.id == option.id } }
                let owned = open.filter { have.contains($0.id) }
                let chosen = owned.first { agreeable.contains($0.id) } ?? owned.first
                if let chosen { foods.append(chosen) } else {
                    let fallback = open.first ?? first
                    foods.append(fallback)
                    missing.append(fallback)
                }
            }
            let extras = idea.extras.filter { id in have.contains(id) && !suspects.contains(id) && !foods.contains { $0.id == id } }
                .compactMap { LowFodmap.byID[$0] }
            let liked = (foods + extras).filter { agreeable.contains($0.id) }
            let met = Double(idea.needs.count - missing.count) / Double(max(idea.needs.count, 1))
            var score = met * 2 + (missing.isEmpty ? 1 : 0)
            score += Double(liked.count) * 0.15 + Double(extras.count) * 0.05
            // Something different from the last day's meals.
            if foods.allSatisfy({ recent.contains($0.id) }) { score -= 0.6 }
            // A little day-to-day variety among equals.
            score += Double(stableHash(idea.id + day) % 100) / 2000
            return IdeaPick(idea: idea, foods: foods, missing: missing, extras: extras, agreeable: liked, score: score)
        }
        return Array(picks.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// The same number for the same text on every launch (hashValue isn't).
    private static func stableHash(_ text: String) -> Int {
        text.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
    }

    /// The idea as a meal to log: its foods and the extras he has.
    static func draft(_ pick: IdeaPick, slot: MealSlot, at date: Date = .now) -> Meal {
        Meal(id: LocalDB.uuid(), at: date, slot: slot, foods: (pick.foods + pick.extras).map(MealFood.init), note: nil)
    }

    // MARK: The ideas

    private static let berries = ["blueberries", "strawberries", "raspberries", "kiwi", "pineapple"]
    private static let lowMilk = ["lf-milk", "almond-milk", "rice-milk"]
    private static let bread = ["sourdough", "gf-bread"]
    private static let greens = ["spinach", "kale", "arugula", "lettuce", "bok-choy", "swiss-chard"]
    private static let veg = ["carrot", "bell-pepper", "green-beans", "bok-choy", "zucchini", "spinach", "eggplant", "bean-sprouts", "kale"]
    private static let protein = ["chicken", "beef", "pork", "fish", "shellfish", "turkey", "tofu-firm", "eggs"]
    private static let cheese = ["hard-cheese", "feta", "brie"]
    private static let nuts = ["walnuts", "macadamia", "pecans", "peanuts", "pumpkin-seeds", "sunflower"]
    private static let fruit = ["orange", "kiwi", "grapes", "strawberries", "blueberries", "raspberries", "pineapple", "banana-firm", "cantaloupe", "papaya"]

    static let all: [MealIdea] = [
        // Breakfast
        MealIdea(id: "eggs-toast", name: "Scrambled eggs on toast", slots: [.breakfast], needs: [["eggs"], bread],
                 extras: ["spinach", "tomato", "chives", "hard-cheese", "butter"]),
        MealIdea(id: "overnight-oats", name: "Overnight oats with berries", slots: [.breakfast], needs: [["oats"], lowMilk, berries],
                 extras: ["chia", "maple", "peanuts", "walnuts"], tip: "About ½ cup of oats keeps it low."),
        MealIdea(id: "pb-banana-toast", name: "Peanut butter and banana toast", slots: [.breakfast, .snack], needs: [bread, ["peanuts"], ["banana-firm"]],
                 extras: ["chia"], tip: "A firm, slightly green banana."),
        MealIdea(id: "yogurt-bowl", name: "Yogurt bowl with fruit and seeds", slots: [.breakfast, .snack], needs: [["lf-yogurt"], berries, ["chia", "pumpkin-seeds", "walnuts", "pecans"]],
                 extras: ["maple"], light: true),
        MealIdea(id: "omelette", name: "Veggie omelette", slots: [.breakfast, .lunch], needs: [["eggs"], ["bell-pepper", "spinach", "tomato", "kale", "zucchini"], cheese],
                 extras: ["chives", "herbs", "oyster-mushroom"]),
        MealIdea(id: "smoothie", name: "Berry smoothie", slots: [.breakfast, .snack], needs: [["banana-firm", "pineapple"], berries, lowMilk + ["lf-yogurt"]],
                 extras: ["peanuts", "whey-isolate", "chia", "spinach"]),
        MealIdea(id: "potato-hash", name: "Potato hash with eggs", slots: [.breakfast, .lunch], needs: [["potato"], ["eggs"], ["bell-pepper", "spinach", "kale"]],
                 extras: ["bacon", "chives", "scallion-greens"]),
        MealIdea(id: "bacon-eggs", name: "Bacon and eggs with toast", slots: [.breakfast], needs: [["bacon"], ["eggs"], bread], extras: ["tomato"]),
        MealIdea(id: "breakfast-tacos", name: "Breakfast tacos", slots: [.breakfast, .lunch], needs: [["corn-tortilla"], ["eggs"], cheese + ["bell-pepper", "tomato"]],
                 extras: ["chives", "scallion-greens", "lettuce"], tip: "Skip the salsa: it's onion and garlic."),
        MealIdea(id: "quinoa-porridge", name: "Quinoa porridge", slots: [.breakfast], needs: [["quinoa"], lowMilk, berries + ["banana-firm"]],
                 extras: ["maple", "walnuts", "pecans"]),

        // Lunch
        MealIdea(id: "chicken-rice-bowl", name: "Chicken rice bowl", slots: [.lunch, .dinner], needs: [["chicken"], ["rice"], veg + ["cucumber"]],
                 extras: ["soy-sauce", "sesame", "scallion-greens", "ginger"]),
        MealIdea(id: "tuna-sandwich", name: "Tuna sandwich", slots: [.lunch], needs: [["fish"], ["mayo"], bread],
                 extras: ["lettuce", "cucumber", "chives", "tomato"]),
        MealIdea(id: "quinoa-salad", name: "Quinoa salad with feta", slots: [.lunch], needs: [["quinoa"], ["cucumber", "tomato", "bell-pepper", "spinach"], ["feta", "hard-cheese"]],
                 extras: ["olives", "olive-oil", "lemon-lime", "herbs"]),
        MealIdea(id: "turkey-sandwich", name: "Turkey sandwich", slots: [.lunch], needs: [["turkey"], bread, ["lettuce", "spinach", "tomato"]],
                 extras: ["hard-cheese", "mustard", "mayo"], tip: "Plain turkey: some deli meats have garlic or onion."),
        MealIdea(id: "egg-fried-rice", name: "Egg fried rice", slots: [.lunch, .dinner], needs: [["rice"], ["eggs"], ["carrot", "bok-choy", "bean-sprouts", "bell-pepper"]],
                 extras: ["scallion-greens", "soy-sauce", "garlic-oil", "ginger"],
                 tip: "Garlic-infused oil and spring onion greens instead of garlic and onion."),
        MealIdea(id: "chicken-tacos", name: "Chicken tacos", slots: [.lunch, .dinner], needs: [["chicken"], ["corn-tortilla"], ["lettuce", "bell-pepper", "tomato", "cabbage"]],
                 extras: ["hard-cheese", "lemon-lime", "herbs"]),
        MealIdea(id: "salmon-salad", name: "Salmon salad", slots: [.lunch], needs: [["fish"], greens, ["cucumber", "tomato", "carrot"]],
                 extras: ["olive-oil", "lemon-lime", "feta", "pumpkin-seeds"]),
        MealIdea(id: "noodle-salad", name: "Rice noodle salad", slots: [.lunch, .dinner], needs: [["rice-noodles"], ["carrot", "cucumber", "bean-sprouts"], ["chicken", "shellfish", "tofu-firm"]],
                 extras: ["herbs", "fish-sauce", "peanuts", "lemon-lime"]),
        MealIdea(id: "baked-potato", name: "Loaded baked potato", slots: [.lunch, .dinner], needs: [["potato"], cheese],
                 extras: ["chives", "scallion-greens", "bacon", "butter"]),
        MealIdea(id: "egg-salad", name: "Egg salad lettuce wraps", slots: [.lunch], needs: [["eggs"], ["mayo"], ["lettuce"]],
                 extras: ["chives", "mustard", "cucumber"], light: true),

        // Dinner
        MealIdea(id: "salmon-rice", name: "Salmon with rice and greens", slots: [.dinner], needs: [["fish"], ["rice", "quinoa", "potato"], ["green-beans", "bok-choy", "spinach", "kale", "carrot"]],
                 extras: ["lemon-lime", "olive-oil", "herbs", "butter"]),
        MealIdea(id: "steak-potatoes", name: "Steak, potatoes and carrots", slots: [.dinner], needs: [["beef"], ["potato"], ["carrot", "green-beans", "spinach", "kale"]],
                 extras: ["butter", "herbs"]),
        MealIdea(id: "stir-fry", name: "Stir-fry with rice", slots: [.dinner, .lunch], needs: [["chicken", "beef", "pork", "shellfish", "tofu-firm"], ["rice", "rice-noodles"], ["bok-choy", "bell-pepper", "carrot", "bean-sprouts", "green-beans"]],
                 extras: ["soy-sauce", "ginger", "garlic-oil", "scallion-greens", "sesame"],
                 tip: "Garlic-infused oil and ginger for flavor, no garlic or onion."),
        MealIdea(id: "shrimp-tacos", name: "Shrimp tacos", slots: [.dinner], needs: [["shellfish"], ["corn-tortilla"], ["cabbage", "lettuce", "bell-pepper"]],
                 extras: ["lemon-lime", "herbs", "hard-cheese"]),
        MealIdea(id: "gf-pasta", name: "Pasta with tomatoes and parmesan", slots: [.dinner, .lunch], needs: [["gf-pasta"], ["tomato"], ["hard-cheese"]],
                 extras: ["olive-oil", "garlic-oil", "herbs", "spinach", "chicken"],
                 tip: "Fresh or canned tomatoes, not jarred sauce: that's usually onion and garlic."),
        MealIdea(id: "pork-chops", name: "Pork chops with potatoes and green beans", slots: [.dinner], needs: [["pork"], ["potato", "rice"], ["green-beans", "carrot", "zucchini"]],
                 extras: ["butter", "herbs", "mustard"]),
        MealIdea(id: "tofu-bowl", name: "Tofu rice bowl", slots: [.dinner, .lunch], needs: [["tofu-firm", "tempeh"], ["rice", "quinoa"], ["bok-choy", "carrot", "bell-pepper", "spinach"]],
                 extras: ["soy-sauce", "sesame", "ginger", "scallion-greens"], tip: "Firm tofu, not silken."),
        MealIdea(id: "burger-bowl", name: "Burger bowl", slots: [.dinner, .lunch], needs: [["beef", "turkey"], ["lettuce"], ["tomato", "cucumber"], ["potato", "rice"]],
                 extras: ["hard-cheese", "mustard", "bacon"], tip: "A plain patty, no bun or onion."),
        MealIdea(id: "stuffed-peppers", name: "Stuffed peppers", slots: [.dinner], needs: [["bell-pepper"], ["turkey", "beef"], ["rice", "quinoa"]],
                 extras: ["hard-cheese", "tomato", "herbs"]),
        MealIdea(id: "roast-chicken", name: "Roast chicken and vegetables", slots: [.dinner], needs: [["chicken"], ["kabocha", "potato", "parsnip", "carrot"], ["kale", "spinach", "green-beans"]],
                 extras: ["olive-oil", "herbs", "lemon-lime"]),
        MealIdea(id: "fish-polenta", name: "Fish with polenta and spinach", slots: [.dinner], needs: [["fish"], ["polenta"], ["spinach", "kale", "tomato"]],
                 extras: ["butter", "lemon-lime", "hard-cheese"]),
        MealIdea(id: "lamb-rice", name: "Lamb with rice and roast carrots", slots: [.dinner], needs: [["lamb"], ["rice", "potato"], ["carrot", "parsnip"]],
                 extras: ["herbs", "lemon-lime"]),

        // Snacks
        MealIdea(id: "pb-rice-cakes", name: "Peanut butter rice cakes", slots: [.snack], needs: [["rice-cakes"], ["peanuts"]], extras: ["banana-firm"], light: true),
        MealIdea(id: "cheese-crackers", name: "Cheese and rice crackers", slots: [.snack], needs: [["rice-cakes"], cheese], extras: ["grapes", "cucumber"], light: true),
        MealIdea(id: "fruit", name: "A piece of fruit", slots: [.snack, .breakfast], needs: [fruit], light: true),
        MealIdea(id: "nuts", name: "A small handful of nuts", slots: [.snack], needs: [nuts], tip: "About a small handful.", light: true),
        MealIdea(id: "yogurt-berries", name: "Yogurt and berries", slots: [.snack], needs: [["lf-yogurt"], berries], light: true),
        MealIdea(id: "boiled-eggs", name: "Hard-boiled eggs", slots: [.snack], needs: [["eggs"]], light: true),
        MealIdea(id: "veg-sticks", name: "Carrot and cucumber sticks", slots: [.snack], needs: [["carrot", "cucumber", "bell-pepper"]],
                 extras: ["peanuts", "hard-cheese"], light: true),
        MealIdea(id: "popcorn", name: "Popcorn", slots: [.snack], needs: [["popcorn"]], light: true),
        MealIdea(id: "chocolate-strawberries", name: "Dark chocolate and strawberries", slots: [.snack], needs: [["dark-chocolate"], ["strawberries", "raspberries"]],
                 tip: "A couple of squares.", light: true),
        MealIdea(id: "cheese-grapes", name: "Cheese and grapes", slots: [.snack], needs: [cheese, ["grapes"]], light: true),
        MealIdea(id: "edamame", name: "Edamame", slots: [.snack], needs: [["edamame"]]),
        MealIdea(id: "banana-pb", name: "Banana with peanut butter", slots: [.snack], needs: [["banana-firm"], ["peanuts"]], light: true),
        MealIdea(id: "toast-snack", name: "Toast with butter or jam", slots: [.snack], needs: [bread, ["butter", "jam", "peanuts"]], light: true),
    ]
}
