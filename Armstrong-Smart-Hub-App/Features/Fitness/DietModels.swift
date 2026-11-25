import Foundation
import SwiftUI

// MARK: FODMAPs

/// How a food sits on the low-FODMAP diet at an everyday serving.
enum FodmapLevel: String, Codable, CaseIterable, Identifiable {
    /// Fine at normal servings.
    case low
    /// Low only in a small serving, or depends on the recipe.
    case moderate
    /// Leave out during elimination.
    case high
    /// A food of his own that isn't rated.
    case unknown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "Low FODMAP"
        case .moderate: "Watch the portion"
        case .high: "High FODMAP"
        case .unknown: "Not rated"
        }
    }
    var short: String {
        switch self {
        case .low: "Low"
        case .moderate: "Watch"
        case .high: "High"
        case .unknown: "Not rated"
        }
    }
    var color: Color {
        switch self {
        case .low: Fit.positive
        case .moderate: Fit.fair
        case .high: Fit.attention
        case .unknown: Fit.muted
        }
    }
}

/// The fermentable carbs the diet is named for. Sorbitol and mannitol are the polyols.
enum FodmapGroup: String, Codable, CaseIterable, Identifiable {
    case fructans, gos, lactose, fructose, sorbitol, mannitol

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fructans: "Fructans"
        case .gos: "GOS"
        case .lactose: "Lactose"
        case .fructose: "Fructose"
        case .sorbitol: "Sorbitol"
        case .mannitol: "Mannitol"
        }
    }
    /// Where it turns up, for the guide and the reintroduction tests.
    var examples: String {
        switch self {
        case .fructans: "Wheat, garlic, onion, rye, inulin"
        case .gos: "Beans, lentils, chickpeas, cashews"
        case .lactose: "Milk, soft cheese, yogurt, ice cream"
        case .fructose: "Honey, apples, mango, agave"
        case .sorbitol: "Apples, pears, stone fruit, sugar-free gum"
        case .mannitol: "Mushrooms, cauliflower, sweet potato"
        }
    }
}

// MARK: The food guide

enum FoodCategory: String, CaseIterable, Identifiable {
    case vegetables, fruit, grains, protein, dairy, nuts, legumes, condiments, sweets, drinks, meals

    var id: String { rawValue }
    var title: String {
        switch self {
        case .vegetables: "Vegetables"
        case .fruit: "Fruit"
        case .grains: "Grains & starches"
        case .protein: "Meat, fish & eggs"
        case .dairy: "Dairy & alternatives"
        case .nuts: "Nuts & seeds"
        case .legumes: "Beans & legumes"
        case .condiments: "Sauces, oils & seasoning"
        case .sweets: "Sweets & sweeteners"
        case .drinks: "Drinks"
        case .meals: "Meals & takeout"
        }
    }
}

/// A food in the guide, or one he added himself.
struct DietFood: Identifiable, Hashable {
    /// The guide's key, or "custom:<name>" for one of his own.
    var id: String
    var name: String
    var category: FoodCategory?
    var level: FodmapLevel
    var groups: [FodmapGroup] = []
    /// The serving that keeps it low, or what to swap it for.
    var tip: String?
    /// Other names to find it by.
    var aliases: [String] = []

    /// True when the name or another name holds what he typed, or every word he typed
    /// starts a word of it: "pickled onion" finds "Pickled onions", "chick rice" finds "Chicken and rice".
    func matches(_ query: String) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let q = fold(query)
        let names = [name] + aliases
        if names.contains(where: { fold($0).contains(q) }) { return true }
        let typed = ReceiptReader.tokens(q)
        guard !typed.isEmpty else { return false }
        return names.contains { phrase in
            let words = ReceiptReader.tokens(fold(phrase))
            return typed.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }
    }

    /// True when he typed exactly its name or another name, plurals aside.
    func isNamed(_ text: String) -> Bool {
        let typed = ReceiptReader.tokens(text)
        return !typed.isEmpty && ([name] + aliases).contains { ReceiptReader.tokens($0) == typed }
    }
}

/// A diet the log can be kept against. Low FODMAP is the one there is so far.
enum DietPlan: String, CaseIterable, Identifiable {
    case lowFodmap

    var id: String { rawValue }
    var title: String { "Low FODMAP" }
    var foods: [DietFood] { LowFodmap.foods }
    var phases: [DietPhase] { DietPhase.allCases }
}

/// The low-FODMAP diet's three steps.
enum DietPhase: String, CaseIterable, Identifiable {
    case elimination, reintroduction, personalization

    var id: String { rawValue }
    var title: String {
        switch self {
        case .elimination: "Elimination"
        case .reintroduction: "Reintroduction"
        case .personalization: "Personalization"
        }
    }
    var step: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    /// What to do in it, in a sentence or two.
    var guidance: String {
        switch self {
        case .elimination:
            "Swap high-FODMAP foods for low ones for 2 to 6 weeks, until symptoms settle. Log every meal and how you feel after, so there's a baseline to test against."
        case .reintroduction:
            "Test one FODMAP group at a time: a small serving of one test food on day 1, more on day 2, a normal serving on day 3, then a few days back on low FODMAP before the next. Log how you feel after each."
        case .personalization:
            "Bring back the groups you handled, and keep limiting the ones that brought symptoms on. Keep logging when something new seems to bother you."
        }
    }
    /// About how long it lasts, for the day counter.
    var typicalDays: ClosedRange<Int>? {
        switch self {
        case .elimination: 14...42
        case .reintroduction: 42...70
        case .personalization: nil
        }
    }
}

/// The low-FODMAP food list, from the published Monash University and dietitian
/// guidance, rated at an everyday serving. Portions matter: many "Watch" foods are
/// low in the serving the tip gives. It's a guide, not a substitute for the Monash
/// app or a dietitian.
enum LowFodmap {
    private static func f(_ id: String, _ name: String, _ category: FoodCategory, _ level: FodmapLevel,
                          _ groups: [FodmapGroup] = [], tip: String? = nil, aka: [String] = []) -> DietFood {
        DietFood(id: id, name: name, category: category, level: level, groups: groups, tip: tip, aliases: aka)
    }

    static let foods: [DietFood] = [
        // Vegetables
        f("carrot", "Carrots", .vegetables, .low),
        f("cucumber", "Cucumber", .vegetables, .low),
        f("lettuce", "Lettuce", .vegetables, .low, aka: ["romaine", "iceberg", "salad greens", "mixed greens"]),
        f("spinach", "Spinach", .vegetables, .low),
        f("arugula", "Arugula", .vegetables, .low, aka: ["rocket"]),
        f("kale", "Kale", .vegetables, .low),
        f("tomato", "Tomatoes", .vegetables, .low, tip: "Fresh and canned are low; sun-dried tomatoes are not.", aka: ["cherry tomatoes"]),
        f("bell-pepper", "Bell pepper", .vegetables, .low, aka: ["capsicum", "red pepper", "green pepper"]),
        f("eggplant", "Eggplant", .vegetables, .low, aka: ["aubergine"]),
        f("green-beans", "Green beans", .vegetables, .low, tip: "Low at about 15 beans; more adds sorbitol."),
        f("bok-choy", "Bok choy", .vegetables, .low, aka: ["pak choi"]),
        f("potato", "Potatoes", .vegetables, .low, aka: ["fries", "hash browns", "mashed potatoes"]),
        f("bean-sprouts", "Bean sprouts", .vegetables, .low),
        f("radish", "Radish", .vegetables, .low),
        f("parsnip", "Parsnip", .vegetables, .low),
        f("turnip", "Turnip", .vegetables, .low),
        f("kabocha", "Kabocha squash", .vegetables, .low, aka: ["japanese pumpkin", "pumpkin"]),
        f("spaghetti-squash", "Spaghetti squash", .vegetables, .low),
        f("swiss-chard", "Swiss chard", .vegetables, .low, aka: ["silverbeet"]),
        f("cabbage", "Cabbage", .vegetables, .low, tip: "Green and red cabbage are low at about ¾ cup. Savoy is higher in fructans.", aka: ["coleslaw"]),
        f("olives", "Olives", .vegetables, .low),
        f("chives", "Chives", .vegetables, .low, tip: "A good stand-in for onion."),
        f("scallion-greens", "Spring onion, green part", .vegetables, .low, tip: "Only the green tops; the white bulb is high.", aka: ["scallion", "green onion"]),
        f("ginger", "Ginger", .vegetables, .low),
        f("herbs", "Fresh herbs", .vegetables, .low, aka: ["basil", "cilantro", "coriander", "parsley", "mint", "rosemary", "thyme", "dill"]),
        f("oyster-mushroom", "Oyster mushrooms", .vegetables, .low, tip: "The one mushroom that's low; canned champignons are too."),
        f("seaweed", "Seaweed", .vegetables, .low, aka: ["nori"]),
        f("broccoli", "Broccoli", .vegetables, .moderate, [.fructose], tip: "Florets are low at about ¾ cup; stalks are higher in fructose."),
        f("zucchini", "Zucchini", .vegetables, .moderate, [.fructans], tip: "Low at about ⅓ cup; larger servings add fructans.", aka: ["courgette", "zoodles"]),
        f("sweet-potato", "Sweet potato", .vegetables, .moderate, [.mannitol], tip: "Low at about ½ cup; more adds mannitol.", aka: ["yam"]),
        f("corn", "Sweet corn", .vegetables, .moderate, [.sorbitol], tip: "Low at about half a cob; more adds sorbitol.", aka: ["corn on the cob"]),
        f("celery", "Celery", .vegetables, .moderate, [.mannitol], tip: "Low under a quarter of a stalk; more adds mannitol."),
        f("butternut", "Butternut squash", .vegetables, .moderate, [.mannitol, .gos], tip: "Low in small servings, about ¼ cup."),
        f("brussels", "Brussels sprouts", .vegetables, .moderate, [.fructans], tip: "Low at about 2 sprouts."),
        f("beetroot", "Beets", .vegetables, .moderate, [.fructans, .gos], tip: "Low at about 2 slices.", aka: ["beetroot"]),
        f("snow-peas", "Snow peas", .vegetables, .moderate, [.fructans, .mannitol], tip: "Low at about 5 pods."),
        f("green-peas", "Green peas", .vegetables, .moderate, [.gos, .fructans], tip: "Only a spoonful or so is low."),
        f("garlic", "Garlic", .vegetables, .high, [.fructans], tip: "Garlic-infused oil is fine: fructans don't go into the oil.", aka: ["garlic powder"]),
        f("onion", "Onion", .vegetables, .high, [.fructans], tip: "Every kind, and onion powder. Use chives or spring onion greens instead.", aka: ["shallot", "red onion", "onion powder", "fried onions", "crispy onions", "caramelized onions"]),
        f("leek", "Leek", .vegetables, .high, [.fructans], tip: "The dark green leaves are low; the white bulb is high."),
        f("cauliflower", "Cauliflower", .vegetables, .high, [.mannitol], aka: ["cauliflower rice"]),
        f("mushrooms", "Mushrooms", .vegetables, .high, [.mannitol], tip: "Button, portobello and shiitake. Oyster mushrooms are low.", aka: ["portobello", "shiitake", "button mushrooms"]),
        f("asparagus", "Asparagus", .vegetables, .high, [.fructose, .fructans]),
        f("artichoke", "Artichoke", .vegetables, .high, [.fructans]),
        f("sugar-snap", "Sugar snap peas", .vegetables, .high, [.fructose, .mannitol]),

        // Fruit
        f("banana-firm", "Banana, firm", .fruit, .low, tip: "Slightly green, firm bananas are low.", aka: ["banana"]),
        f("banana-ripe", "Banana, ripe", .fruit, .moderate, [.fructans], tip: "Spotty, ripe bananas are low at about a third of one."),
        f("blueberries", "Blueberries", .fruit, .low),
        f("strawberries", "Strawberries", .fruit, .low, tip: "Low at about 5 berries."),
        f("raspberries", "Raspberries", .fruit, .low),
        f("grapes", "Grapes", .fruit, .low),
        f("kiwi", "Kiwi", .fruit, .low),
        f("orange", "Orange", .fruit, .low, aka: ["mandarin", "clementine", "tangerine"]),
        f("pineapple", "Pineapple", .fruit, .low),
        f("cantaloupe", "Cantaloupe", .fruit, .low, aka: ["rockmelon", "melon"]),
        f("papaya", "Papaya", .fruit, .low),
        f("passionfruit", "Passionfruit", .fruit, .low),
        f("lemon-lime", "Lemon or lime", .fruit, .low, aka: ["lemon", "lime"]),
        f("dragon-fruit", "Dragon fruit", .fruit, .low),
        f("rhubarb", "Rhubarb", .fruit, .low),
        f("honeydew", "Honeydew melon", .fruit, .moderate, [.fructans], tip: "Low at about ½ cup."),
        f("avocado", "Avocado", .fruit, .moderate, [.sorbitol], tip: "Low at about ⅛ of an avocado; more adds sorbitol."),
        f("apple", "Apple", .fruit, .high, [.fructose, .sorbitol], aka: ["applesauce"]),
        f("pear", "Pear", .fruit, .high, [.fructose, .sorbitol]),
        f("mango", "Mango", .fruit, .high, [.fructose]),
        f("watermelon", "Watermelon", .fruit, .high, [.fructose, .fructans, .mannitol]),
        f("cherries", "Cherries", .fruit, .high, [.fructose, .sorbitol]),
        f("stone-fruit", "Peach, nectarine or plum", .fruit, .high, [.sorbitol, .fructans], aka: ["peach", "nectarine", "plum", "apricot"]),
        f("blackberries", "Blackberries", .fruit, .high, [.sorbitol]),
        f("figs", "Figs", .fruit, .high, [.fructans]),
        f("dried-fruit", "Dried fruit", .fruit, .high, [.fructans, .fructose, .sorbitol], aka: ["raisins", "dates", "prunes", "craisins"]),

        // Grains & starches
        f("rice", "Rice", .grains, .low, aka: ["white rice", "brown rice", "jasmine", "basmati", "sushi rice"]),
        f("quinoa", "Quinoa", .grains, .low),
        f("gf-bread", "Gluten-free bread", .grains, .low, tip: "Check the label for inulin, chicory root, apple or honey."),
        f("gf-pasta", "Gluten-free pasta", .grains, .low, aka: ["rice pasta", "corn pasta"]),
        f("rice-noodles", "Rice noodles", .grains, .low, aka: ["vermicelli", "pad thai noodles"]),
        f("corn-tortilla", "Corn tortillas", .grains, .low, aka: ["tortilla chips", "taco shells"]),
        f("polenta", "Polenta", .grains, .low, aka: ["cornmeal", "grits"]),
        f("popcorn", "Popcorn", .grains, .low),
        f("rice-cakes", "Rice cakes or crackers", .grains, .low, aka: ["rice crackers"]),
        f("buckwheat", "Buckwheat", .grains, .low),
        f("millet", "Millet", .grains, .low),
        f("oats", "Oats", .grains, .moderate, [.fructans, .gos], tip: "Low at about ½ cup uncooked; more adds fructans and GOS.", aka: ["oatmeal", "porridge", "overnight oats"]),
        f("sourdough", "Sourdough bread", .grains, .moderate, [.fructans], tip: "Traditional, slow-fermented white wheat or spelt sourdough is low at 2 slices."),
        f("wheat-bread", "Wheat bread", .grains, .high, [.fructans], tip: "A single slice of white bread is sometimes tolerated. Sourdough or gluten-free is the swap.", aka: ["bread", "toast", "sandwich bread", "whole wheat bread", "bun"]),
        f("wheat-pasta", "Pasta", .grains, .high, [.fructans], tip: "Gluten-free, rice or corn pasta are the swap.", aka: ["spaghetti", "penne", "macaroni", "wheat pasta"]),
        f("flour-tortilla", "Flour tortilla", .grains, .high, [.fructans], tip: "Corn tortillas are the swap.", aka: ["wrap"]),
        f("bagel", "Bagel", .grains, .high, [.fructans]),
        f("wheat-noodles", "Wheat noodles", .grains, .high, [.fructans], aka: ["ramen", "udon", "egg noodles", "lo mein"]),
        f("couscous", "Couscous", .grains, .high, [.fructans]),
        f("barley-rye", "Barley or rye", .grains, .high, [.fructans], aka: ["rye bread", "barley", "pumpernickel"]),
        f("pastry", "Pastry, muffin or cake", .grains, .high, [.fructans], aka: ["croissant", "muffin", "donut", "cookie", "cake"]),
        f("granola", "Granola", .grains, .high, [.fructans, .fructose], tip: "Usually has honey, dried fruit or wheat."),
        f("wheat-crackers", "Wheat crackers", .grains, .high, [.fructans], aka: ["crackers", "pretzels"]),

        // Meat, fish & eggs
        f("chicken", "Chicken", .protein, .low, tip: "Plain: marinades often have garlic or onion."),
        f("beef", "Beef", .protein, .low, aka: ["steak", "ground beef"]),
        f("pork", "Pork", .protein, .low, aka: ["ham", "pork chop"]),
        f("lamb", "Lamb", .protein, .low),
        f("turkey", "Turkey", .protein, .low),
        f("fish", "Fish", .protein, .low, aka: ["salmon", "tuna", "cod", "tilapia"]),
        f("shellfish", "Shrimp and shellfish", .protein, .low, aka: ["shrimp", "prawns", "crab", "lobster", "scallops"]),
        f("eggs", "Eggs", .protein, .low, aka: ["egg", "omelette", "scrambled eggs"]),
        f("bacon", "Bacon", .protein, .low),
        f("tofu-firm", "Firm tofu", .protein, .low, tip: "Firm tofu is low; silken tofu is high in GOS.", aka: ["tofu"]),
        f("tempeh", "Tempeh", .protein, .low),
        f("tofu-silken", "Silken tofu", .protein, .high, [.gos]),
        f("sausage", "Sausage or deli meat", .protein, .moderate, [.fructans], tip: "Depends on the recipe: many have garlic, onion or wheat.", aka: ["sausage", "hot dog", "salami", "chorizo"]),

        // Dairy & alternatives
        f("lf-milk", "Lactose-free milk", .dairy, .low),
        f("almond-milk", "Almond milk", .dairy, .low),
        f("rice-milk", "Rice milk", .dairy, .low),
        f("hard-cheese", "Hard cheese", .dairy, .low, aka: ["cheese", "cheddar", "parmesan", "swiss", "mozzarella", "provolone", "gouda"]),
        f("brie", "Brie or camembert", .dairy, .low),
        f("feta", "Feta", .dairy, .low),
        f("butter", "Butter", .dairy, .low),
        f("lf-yogurt", "Lactose-free yogurt", .dairy, .low),
        f("whey-isolate", "Whey protein isolate", .dairy, .low, tip: "Isolate has most of the lactose removed.", aka: ["protein shake", "protein powder"]),
        f("oat-milk", "Oat milk", .dairy, .moderate, [.fructans, .gos], tip: "Low in small servings."),
        f("soy-milk", "Soy milk", .dairy, .moderate, [.gos], tip: "Made from soy protein: low. Made from whole soybeans: high in GOS."),
        f("coconut-milk", "Coconut milk", .dairy, .moderate, [.sorbitol], tip: "Low in modest servings."),
        f("greek-yogurt", "Greek yogurt", .dairy, .moderate, [.lactose], tip: "Lower in lactose than regular yogurt; small servings are often fine."),
        f("soft-cheese", "Ricotta or cottage cheese", .dairy, .moderate, [.lactose], tip: "Low at about 2 tablespoons.", aka: ["ricotta", "cottage cheese"]),
        f("cream-cheese", "Cream cheese", .dairy, .moderate, [.lactose], tip: "Low at about 2 tablespoons."),
        f("cream", "Cream or sour cream", .dairy, .moderate, [.lactose], tip: "A splash is low.", aka: ["sour cream", "half and half", "creamer"]),
        f("milk", "Milk", .dairy, .high, [.lactose], tip: "Lactose-free milk is the swap.", aka: ["whole milk", "skim milk", "latte"]),
        f("yogurt", "Yogurt", .dairy, .high, [.lactose]),
        f("ice-cream", "Ice cream", .dairy, .high, [.lactose]),
        f("whey-concentrate", "Whey protein concentrate", .dairy, .high, [.lactose], tip: "Isolate is the swap."),

        // Nuts & seeds
        f("peanuts", "Peanuts and peanut butter", .nuts, .low, aka: ["peanut butter", "pb"]),
        f("walnuts", "Walnuts", .nuts, .low),
        f("macadamia", "Macadamias", .nuts, .low),
        f("pecans", "Pecans", .nuts, .low),
        f("pine-nuts", "Pine nuts", .nuts, .low),
        f("chia", "Chia seeds", .nuts, .low),
        f("pumpkin-seeds", "Pumpkin seeds", .nuts, .low, aka: ["pepitas"]),
        f("sunflower", "Sunflower seeds", .nuts, .low),
        f("sesame", "Sesame and tahini", .nuts, .low, aka: ["tahini"]),
        f("flax", "Flaxseed", .nuts, .low, aka: ["linseed"]),
        f("almonds", "Almonds", .nuts, .moderate, [.gos], tip: "Low at about 10 almonds; more adds GOS.", aka: ["almond butter"]),
        f("hazelnuts", "Hazelnuts", .nuts, .moderate, [.gos], tip: "Low at about 10."),
        f("cashews", "Cashews", .nuts, .high, [.gos, .fructans]),
        f("pistachios", "Pistachios", .nuts, .high, [.gos, .fructans]),

        // Beans & legumes
        f("edamame", "Edamame", .legumes, .low),
        f("chickpeas", "Chickpeas", .legumes, .moderate, [.gos], tip: "Canned and rinsed, about ¼ cup is low."),
        f("lentils", "Lentils", .legumes, .moderate, [.gos], tip: "Canned and rinsed lentils are low in small servings; boiled from dry are high."),
        f("beans", "Beans", .legumes, .high, [.gos], aka: ["black beans", "kidney beans", "pinto beans", "baked beans", "refried beans"]),
        f("hummus", "Hummus", .legumes, .high, [.gos, .fructans]),

        // Sauces, oils & seasoning
        f("olive-oil", "Olive oil and other oils", .condiments, .low, aka: ["oil", "avocado oil", "canola oil", "coconut oil", "sesame oil", "vegetable oil"]),
        f("garlic-oil", "Garlic-infused oil", .condiments, .low, tip: "Garlic flavor without the fructans.", aka: ["garlic oil"]),
        f("soy-sauce", "Soy sauce", .condiments, .low, aka: ["tamari"]),
        f("mayo", "Mayonnaise", .condiments, .low, aka: ["mayo"]),
        f("mustard", "Mustard", .condiments, .low),
        f("fish-sauce", "Fish or oyster sauce", .condiments, .low, aka: ["oyster sauce"]),
        f("vinegar", "Vinegar", .condiments, .low, aka: ["balsamic", "rice vinegar"]),
        f("salt-pepper", "Salt, pepper and spices", .condiments, .low, tip: "Plain spices are fine; blends often have garlic or onion powder.", aka: ["spices", "paprika", "cumin", "chili flakes"]),
        f("miso", "Miso", .condiments, .low),
        f("ketchup", "Ketchup", .condiments, .moderate, [.fructans, .fructose], tip: "About a tablespoon is low."),
        f("hot-sauce", "Hot sauce", .condiments, .moderate, [.fructans], tip: "Check for garlic; a teaspoon of sriracha is low.", aka: ["sriracha", "tabasco"]),
        f("dressing", "Salad dressing", .condiments, .moderate, [.fructans, .fructose], tip: "Check for garlic, onion and honey. Oil and vinegar is safe."),
        f("salsa", "Salsa", .condiments, .high, [.fructans], tip: "Unless it's made without onion and garlic.", aka: ["pico de gallo"]),
        f("bbq", "BBQ sauce", .condiments, .high, [.fructans, .fructose]),
        f("pesto", "Pesto", .condiments, .high, [.fructans]),
        f("pasta-sauce", "Jarred pasta sauce", .condiments, .high, [.fructans], tip: "Onion and garlic; look for a low-FODMAP certified one.", aka: ["marinara", "tomato sauce"]),
        f("stock", "Stock or broth", .condiments, .high, [.fructans], tip: "Regular stock has onion and garlic; use a low-FODMAP one.", aka: ["broth", "bouillon", "soup", "chicken broth", "bone broth", "vegetable broth", "chicken stock"]),
        f("gravy", "Gravy", .condiments, .high, [.fructans]),
        f("guacamole", "Guacamole", .condiments, .high, [.sorbitol, .fructans]),

        // Sweets & sweeteners
        f("sugar", "Sugar", .sweets, .low, aka: ["table sugar", "brown sugar"]),
        f("maple", "Maple syrup", .sweets, .low),
        f("dark-chocolate", "Dark chocolate", .sweets, .low, tip: "About 30 g."),
        f("stevia", "Stevia", .sweets, .low),
        f("jam", "Strawberry jam", .sweets, .low, aka: ["jelly"]),
        f("milk-chocolate", "Milk chocolate", .sweets, .moderate, [.lactose], tip: "Small servings."),
        f("protein-bar", "Protein bar", .sweets, .moderate, [.fructans, .sorbitol], tip: "Often has chicory root (inulin), sugar alcohols or honey. Check the label."),
        f("honey", "Honey", .sweets, .high, [.fructose]),
        f("agave", "Agave", .sweets, .high, [.fructose]),
        f("hfcs", "High-fructose corn syrup", .sweets, .high, [.fructose], aka: ["corn syrup"]),
        f("sugar-free", "Sugar-free gum or mints", .sweets, .high, [.sorbitol, .mannitol], tip: "Sorbitol, mannitol, xylitol and maltitol.", aka: ["gum", "xylitol", "sugar alcohol"]),

        // Drinks
        f("water", "Water", .drinks, .low, aka: ["sparkling water", "seltzer"]),
        f("coffee", "Coffee", .drinks, .low, tip: "Black, or with lactose-free milk. Coffee can upset the gut on its own.", aka: ["espresso", "cold brew"]),
        f("green-tea", "Green or black tea", .drinks, .low, tip: "Weak black tea is low; strong brews are higher.", aka: ["black tea", "tea"]),
        f("peppermint-tea", "Peppermint tea", .drinks, .low),
        f("beer", "Beer", .drinks, .low, tip: "About one can. Bubbles and alcohol can still bother the gut."),
        f("wine", "Wine", .drinks, .low, tip: "About one glass."),
        f("spirits", "Vodka, gin or whiskey", .drinks, .low, aka: ["vodka", "gin", "whiskey", "tequila"]),
        f("diet-soda", "Diet soda", .drinks, .low, aka: ["diet coke", "coke zero"]),
        f("orange-juice", "Orange juice", .drinks, .moderate, [.fructose], tip: "About ½ cup."),
        f("coconut-water", "Coconut water", .drinks, .moderate, [.sorbitol], tip: "About ½ cup."),
        f("kombucha", "Kombucha", .drinks, .moderate, [.fructans], tip: "Small servings."),
        f("chamomile", "Chamomile or fennel tea", .drinks, .high, [.fructans], aka: ["fennel tea", "chai"]),
        f("rum", "Rum", .drinks, .high, [.fructose]),
        f("soda", "Soda", .drinks, .high, [.fructose], tip: "Made with high-fructose corn syrup in the US.", aka: ["coke", "sprite", "pop"]),
        f("juice", "Apple or mango juice", .drinks, .high, [.fructose, .sorbitol], aka: ["apple juice", "juice"]),

        // Meals & takeout
        f("sushi", "Sushi", .meals, .low, tip: "Skip tempura, imitation crab and sweet sauces."),
        f("poke", "Poke bowl", .meals, .moderate, [.fructans], tip: "Skip the onion and creamy or garlic sauces.", aka: ["poke"]),
        f("pho", "Pho", .meals, .moderate, [.fructans], tip: "Rice noodles are fine, but the broth is usually made with onion."),
        f("stir-fry", "Stir-fry", .meals, .moderate, [.fructans], tip: "Fine without garlic and onion."),
        f("salad", "Salad", .meals, .moderate, [.fructans], tip: "Depends on the dressing and toppings."),
        f("pizza", "Pizza", .meals, .high, [.fructans, .lactose], tip: "Wheat crust, garlic and onion in the sauce."),
        f("burger", "Burger with bun", .meals, .high, [.fructans], tip: "The bun and onion. Lettuce wrap or gluten-free bun."),
        f("burrito", "Burrito", .meals, .high, [.fructans, .gos], tip: "Flour tortilla, beans, onion and salsa. A bowl with rice and meat is safer."),
        f("curry", "Curry", .meals, .high, [.fructans], tip: "Most are built on onion and garlic."),
        f("fried-rice", "Fried rice", .meals, .high, [.fructans], tip: "Usually garlic and onion."),
        f("mac-cheese", "Mac and cheese", .meals, .high, [.fructans, .lactose]),

        // More vegetables
        f("pickled-onion", "Pickled onions", .vegetables, .moderate, [.fructans], tip: "Large pickled onions, drained, are low in a modest serving (about 2). Fructans leach into the brine, so skip the liquid. Small cocktail onions are high.", aka: ["pickled onion", "pickled red onion", "pickled red onions"]),
        f("cocktail-onion", "Cocktail onions", .vegetables, .high, [.fructans], tip: "The small pickled onions have no low serving.", aka: ["pearl onions"]),
        f("pickles", "Pickles", .vegetables, .low, tip: "Gherkins in vinegar are low. Check the brine for garlic.", aka: ["gherkins", "dill pickles", "cornichons", "pickle"]),
        f("sauerkraut", "Sauerkraut", .vegetables, .moderate, [.mannitol], tip: "About a tablespoon of white-cabbage sauerkraut is low; red-cabbage kraut is higher."),
        f("kimchi", "Kimchi", .vegetables, .moderate, [.fructans], tip: "Most have garlic and spring onion. A tablespoon or two is usually fine."),
        f("pickled-ginger", "Pickled ginger", .vegetables, .low, aka: ["gari", "sushi ginger"]),
        f("jalapeno", "Chili peppers", .vegetables, .low, tip: "Spicy food can upset the gut on its own.", aka: ["jalapeno", "jalapenos", "chili", "chilli", "serrano", "habanero", "pickled jalapenos"]),
        f("sun-dried-tomato", "Sun-dried tomatoes", .vegetables, .moderate, [.fructose], tip: "About 2 pieces is low."),
        f("tomato-paste", "Tomato paste", .vegetables, .low, tip: "About 2 tablespoons."),
        f("fennel", "Fennel bulb", .vegetables, .moderate, [.fructans], tip: "Low at about ½ cup."),
        f("okra", "Okra", .vegetables, .moderate, [.fructans], tip: "Low at about 6 pods."),
        f("endive", "Endive", .vegetables, .low, aka: ["chicory leaves", "radicchio"]),
        f("summer-squash", "Yellow squash", .vegetables, .low, aka: ["summer squash", "pattypan"]),
        f("acorn-squash", "Acorn squash", .vegetables, .moderate, [.gos], tip: "Low at about ½ cup."),
        f("water-chestnut", "Water chestnuts", .vegetables, .low),
        f("bamboo", "Bamboo shoots", .vegetables, .low),
        f("collards", "Collard greens", .vegetables, .low, aka: ["collards", "mustard greens", "watercress", "microgreens"]),
        f("alfalfa", "Alfalfa sprouts", .vegetables, .low),
        f("capers", "Capers", .vegetables, .low),
        f("lemongrass", "Lemongrass", .vegetables, .low),
        f("cassava", "Cassava", .vegetables, .low, aka: ["yuca", "tapioca"]),
        f("plantain", "Plantain", .vegetables, .low),
        f("artichoke-hearts", "Artichoke hearts, canned", .vegetables, .moderate, [.fructans], tip: "Low at about ⅛ cup."),
        f("mixed-veg", "Mixed vegetables", .vegetables, .moderate, [.gos, .fructans], tip: "Frozen mixes often have peas, onion or cauliflower. Check what's in it."),
        f("garlic-scapes", "Garlic scapes", .vegetables, .high, [.fructans]),

        // More fruit
        f("grapefruit", "Grapefruit", .fruit, .moderate, [.fructans], tip: "Low at about half a small grapefruit."),
        f("pomegranate", "Pomegranate", .fruit, .moderate, [.fructans], tip: "Low at about ¼ cup of seeds."),
        f("coconut", "Coconut", .fruit, .low, tip: "Shredded or fresh, about ¼ cup.", aka: ["shredded coconut", "coconut flakes"]),
        f("guava", "Guava, ripe", .fruit, .low),
        f("starfruit", "Starfruit", .fruit, .low),
        f("lychee", "Lychee", .fruit, .high, [.sorbitol]),
        f("persimmon", "Persimmon", .fruit, .high, [.fructose]),
        f("boysenberry", "Boysenberries", .fruit, .high, [.fructose]),
        f("dried-cranberries", "Dried cranberries", .fruit, .moderate, [.fructans], tip: "About a tablespoon is low."),
        f("fruit-salad", "Fruit salad", .fruit, .moderate, [.fructose, .sorbitol], tip: "Depends on the fruit: apple, pear, mango and watermelon are high."),
        f("smoothie", "Smoothie", .drinks, .moderate, [.fructose, .lactose], tip: "Fine with firm banana, berries and lactose-free milk; mango, apple, honey or regular yogurt make it high."),

        // More grains & starches
        f("potato-chips", "Potato chips", .grains, .low, tip: "Plain or salted. Flavored chips often have onion or garlic powder.", aka: ["chips", "crisps", "kettle chips"]),
        f("corn-chips", "Corn chips", .grains, .low, aka: ["fritos"]),
        f("rice-cereal", "Rice or corn cereal", .grains, .low, tip: "Check for malt, honey or inulin.", aka: ["rice krispies", "rice puffs", "cornflakes", "corn flakes"]),
        f("cereal", "Cereal", .grains, .moderate, [.fructans], tip: "Rice and corn cereals are low; wheat, bran and granola ones aren't.", aka: ["cheerios"]),
        f("bran", "Bran cereal", .grains, .high, [.fructans], aka: ["all bran", "raisin bran", "shredded wheat", "weetabix"]),
        f("gf-crackers", "Gluten-free crackers", .grains, .low),
        f("rice-paper", "Rice paper", .grains, .low),
        f("sorghum", "Sorghum", .grains, .low, aka: ["teff", "amaranth"]),
        f("cornstarch", "Cornstarch", .grains, .low, aka: ["corn flour", "potato starch", "rice flour"]),
        f("glass-noodles", "Glass noodles", .grains, .low, aka: ["cellophane noodles", "mung bean noodles"]),
        f("soba", "Soba noodles", .grains, .moderate, [.fructans], tip: "100% buckwheat soba is low; most mix in wheat."),
        f("spelt", "Spelt", .grains, .moderate, [.fructans], tip: "Spelt sourdough is low; other spelt bread isn't."),
        f("almond-flour", "Almond flour", .grains, .moderate, [.gos], tip: "Low at about ¼ cup.", aka: ["almond meal"]),
        f("gf-flour", "Gluten-free flour", .grains, .low, tip: "Check it isn't made with bean flour."),
        f("wheat-flour", "Wheat flour", .grains, .high, [.fructans], aka: ["flour", "all purpose flour"]),
        f("pancakes", "Pancakes or waffles", .grains, .high, [.fructans, .lactose], tip: "Made with gluten-free flour and lactose-free milk they're low.", aka: ["pancake", "waffle", "waffles", "french toast", "crepes"]),
        f("pita", "Pita or naan", .grains, .high, [.fructans], aka: ["naan", "flatbread", "pita bread"]),
        f("english-muffin", "English muffin", .grains, .high, [.fructans]),
        f("breadcrumbs", "Breadcrumbs", .grains, .high, [.fructans], aka: ["panko", "croutons", "breaded"]),
        f("gnocchi", "Gnocchi", .grains, .high, [.fructans], tip: "Made with wheat flour."),
        f("tater-tots", "Tater tots", .grains, .moderate, [.fructans], tip: "Some have onion or wheat; plain ones are low."),
        f("oatcakes", "Oatcakes", .grains, .moderate, [.fructans], tip: "About 2 is low."),

        // More meat, fish & eggs
        f("duck", "Duck", .protein, .low, aka: ["venison", "bison", "goat"]),
        f("sardines", "Sardines", .protein, .low, aka: ["anchovies", "mackerel", "canned tuna", "trout", "halibut"]),
        f("smoked-salmon", "Smoked salmon", .protein, .low, aka: ["lox"]),
        f("prosciutto", "Prosciutto", .protein, .low, tip: "Plain cured meats are low; check salami and sausage for garlic.", aka: ["pancetta"]),
        f("rotisserie", "Rotisserie chicken", .protein, .moderate, [.fructans], tip: "The rub often has garlic or onion. The skin holds most of it."),
        f("jerky", "Jerky", .protein, .moderate, [.fructans], tip: "Most have garlic, onion or honey. Look for plain or low-FODMAP certified."),
        f("pepperoni", "Pepperoni", .protein, .moderate, [.fructans], tip: "Usually garlic powder. A few slices is likely fine."),
        f("meatballs", "Meatballs", .protein, .high, [.fructans], tip: "Onion, garlic and breadcrumbs."),
        f("nuggets", "Chicken nuggets or tenders", .protein, .high, [.fructans], tip: "Wheat breading and often onion powder.", aka: ["chicken tenders", "chicken fingers", "fried chicken", "schnitzel"]),
        f("imitation-crab", "Imitation crab", .protein, .high, [.sorbitol, .fructans], aka: ["surimi", "crab sticks"]),
        f("veggie-burger", "Veggie burger", .protein, .high, [.gos, .fructans], tip: "Usually beans, onion and garlic.", aka: ["black bean burger", "plant based burger", "impossible burger", "beyond burger"]),
        f("egg-whites", "Egg whites", .protein, .low, aka: ["egg white"]),

        // More dairy & alternatives
        f("lf-ice-cream", "Lactose-free ice cream", .dairy, .low),
        f("lf-cottage", "Lactose-free cottage cheese", .dairy, .low),
        f("goat-cheese", "Goat cheese", .dairy, .low, tip: "About 40 g.", aka: ["chevre"]),
        f("halloumi", "Halloumi", .dairy, .low, tip: "About 40 g."),
        f("mascarpone", "Mascarpone", .dairy, .moderate, [.lactose], tip: "About 2 tablespoons."),
        f("ghee", "Ghee", .dairy, .low),
        f("coconut-yogurt", "Coconut yogurt", .dairy, .moderate, [.sorbitol], tip: "Check for inulin."),
        f("hemp-milk", "Hemp or macadamia milk", .dairy, .low, aka: ["hemp milk", "macadamia milk"]),
        f("whipped-cream", "Whipped cream", .dairy, .moderate, [.lactose], tip: "A dollop is low."),
        f("buttermilk", "Buttermilk", .dairy, .high, [.lactose]),
        f("kefir", "Kefir", .dairy, .high, [.lactose], tip: "Lactose-free kefir is the swap."),
        f("goat-milk", "Goat milk", .dairy, .high, [.lactose]),
        f("condensed-milk", "Condensed or evaporated milk", .dairy, .high, [.lactose], aka: ["condensed milk", "evaporated milk"]),
        f("custard", "Custard or pudding", .dairy, .high, [.lactose], aka: ["pudding", "flan"]),
        f("frozen-yogurt", "Frozen yogurt", .dairy, .high, [.lactose], aka: ["froyo"]),

        // More nuts & seeds
        f("brazil-nuts", "Brazil nuts", .nuts, .low),
        f("hemp-seeds", "Hemp seeds", .nuts, .low, aka: ["hemp hearts"]),
        f("sunbutter", "Sunflower seed butter", .nuts, .low, aka: ["sunbutter"]),
        f("mixed-nuts", "Mixed nuts", .nuts, .high, [.gos, .fructans], tip: "Usually cashews and pistachios.", aka: ["trail mix"]),
        f("nutella", "Chocolate hazelnut spread", .nuts, .moderate, [.gos, .lactose], tip: "About 2 tablespoons.", aka: ["nutella"]),

        // More beans & legumes
        f("falafel", "Falafel", .legumes, .high, [.gos, .fructans]),
        f("dal", "Dal", .legumes, .high, [.gos, .fructans], aka: ["dhal", "daal", "lentil soup"]),
        f("split-peas", "Split peas", .legumes, .high, [.gos], aka: ["black eyed peas", "lima beans", "butter beans", "soybeans", "navy beans", "cannellini"]),

        // More sauces & seasoning
        f("worcestershire", "Worcestershire sauce", .condiments, .low, tip: "About 2 tablespoons."),
        f("ponzu", "Ponzu or mirin", .condiments, .low, aka: ["mirin", "rice wine"]),
        f("wasabi", "Wasabi or horseradish", .condiments, .low, aka: ["wasabi", "horseradish"]),
        f("nutritional-yeast", "Nutritional yeast", .condiments, .low),
        f("cocoa", "Cocoa powder", .condiments, .low, aka: ["cacao"]),
        f("vanilla", "Vanilla", .condiments, .low),
        f("teriyaki", "Teriyaki sauce", .condiments, .moderate, [.fructans, .fructose], tip: "Usually garlic and honey; a tablespoon is likely fine."),
        f("hoisin", "Hoisin sauce", .condiments, .moderate, [.fructans], tip: "About ½ tablespoon."),
        f("sweet-chili", "Sweet chili sauce", .condiments, .moderate, [.fructans], tip: "About a tablespoon; check for garlic."),
        f("satay", "Peanut sauce", .condiments, .moderate, [.fructans], tip: "Peanuts are fine; the garlic and onion aren't.", aka: ["satay"]),
        f("gochujang", "Gochujang", .condiments, .moderate, [.fructans], tip: "About a tablespoon."),
        f("relish", "Relish", .condiments, .moderate, [.fructans, .fructose], tip: "Often onion and corn syrup."),
        f("harissa", "Harissa", .condiments, .moderate, [.fructans], tip: "Usually garlic; a teaspoon is likely fine."),
        f("ranch", "Ranch dressing", .condiments, .high, [.fructans, .lactose], tip: "Garlic and onion powder, plus buttermilk."),
        f("caesar", "Caesar dressing", .condiments, .high, [.fructans], tip: "Garlic.", aka: ["caesar"]),
        f("tzatziki", "Tzatziki", .condiments, .high, [.fructans, .lactose], tip: "Garlic and yogurt."),
        f("aioli", "Aioli or garlic mayo", .condiments, .high, [.fructans], aka: ["garlic mayo"]),
        f("chimichurri", "Chimichurri", .condiments, .high, [.fructans], aka: ["salsa verde"]),
        f("curry-paste", "Curry paste", .condiments, .high, [.fructans], aka: ["curry powder"]),
        f("taco-seasoning", "Taco seasoning", .condiments, .high, [.fructans], tip: "Onion and garlic powder. Mix your own with cumin, paprika and chili.", aka: ["fajita seasoning", "seasoning mix", "garlic salt", "onion salt"]),
        f("chutney", "Chutney", .condiments, .high, [.fructose, .fructans]),
        f("tahini-sauce", "Tahini sauce", .condiments, .moderate, [.fructans], tip: "Tahini is low; the garlic often in the sauce isn't."),

        // More sweets
        f("marmalade", "Marmalade", .sweets, .low),
        f("marshmallows", "Marshmallows", .sweets, .low),
        f("candy", "Candy", .sweets, .moderate, [.fructose], tip: "Hard candy and jelly beans made with sugar are low; ones with corn syrup or sugar alcohols aren't.", aka: ["jelly beans", "gummies", "gummy bears", "lollipop"]),
        f("white-chocolate", "White chocolate", .sweets, .moderate, [.lactose], tip: "A small serving."),
        f("sorbet", "Sorbet", .sweets, .moderate, [.fructose], tip: "Lemon, raspberry and strawberry are low; mango isn't."),
        f("cheesecake", "Cheesecake", .sweets, .high, [.lactose, .fructans]),
        f("pie", "Pie", .sweets, .high, [.fructans, .fructose], aka: ["apple pie", "tart"]),
        f("brownie", "Brownie", .sweets, .high, [.fructans], aka: ["brownies", "cookies", "biscuits"]),
        f("golden-syrup", "Golden syrup or rice malt syrup", .sweets, .low, aka: ["rice malt syrup", "golden syrup"]),
        f("molasses", "Molasses", .sweets, .moderate, [.fructans], tip: "About a teaspoon."),
        f("coconut-sugar", "Coconut sugar", .sweets, .moderate, [.fructans], tip: "About a teaspoon."),

        // More drinks
        f("matcha", "Matcha", .drinks, .low, tip: "About a teaspoon of powder; with lactose-free milk for a latte."),
        f("ginger-tea", "Ginger tea", .drinks, .low, aka: ["rooibos"]),
        f("cranberry-juice", "Cranberry juice", .drinks, .low),
        f("tomato-juice", "Tomato juice", .drinks, .moderate, [.fructose], tip: "About a cup."),
        f("lemonade", "Lemonade", .drinks, .moderate, [.fructose], tip: "Fine made with sugar; most bottled is corn syrup."),
        f("sports-drink", "Sports drink", .drinks, .moderate, [.fructose], tip: "Check for high-fructose corn syrup.", aka: ["gatorade", "powerade", "electrolyte drink"]),
        f("energy-drink", "Energy drink", .drinks, .moderate, [.fructose], tip: "Caffeine and fizz can upset the gut; sugar-free ones may have sugar alcohols.", aka: ["red bull", "celsius", "monster"]),
        f("hot-chocolate", "Hot chocolate", .drinks, .high, [.lactose], tip: "Make it with lactose-free milk.", aka: ["hot cocoa"]),
        f("oolong", "Oolong or strong black tea", .drinks, .high, [.fructans], aka: ["oolong", "dandelion tea"]),
        f("sparkling-wine", "Sparkling wine", .drinks, .low, tip: "About one glass.", aka: ["prosecco", "champagne", "cava"]),
        f("sake", "Sake", .drinks, .low),
        f("cider", "Cider", .drinks, .high, [.fructose, .sorbitol], aka: ["hard cider", "apple cider"]),
        f("port", "Port or dessert wine", .drinks, .high, [.fructose], aka: ["dessert wine", "sherry"]),
        f("cocktail", "Cocktail", .drinks, .moderate, [.fructose], tip: "Spirits are low; juice, syrups and mixers often aren't.", aka: ["margarita", "mojito", "mixed drink"]),

        // More meals & takeout
        f("sandwich", "Sandwich", .meals, .high, [.fructans], tip: "The bread. Sourdough or gluten-free bread makes it low.", aka: ["sub", "hoagie", "panini", "blt"]),
        f("tacos", "Tacos", .meals, .moderate, [.fructans], tip: "Corn tortillas are fine; skip onion, salsa and taco seasoning.", aka: ["taco"]),
        f("quesadilla", "Quesadilla", .meals, .high, [.fructans], tip: "Flour tortilla. A corn tortilla with hard cheese is low."),
        f("nachos", "Nachos", .meals, .moderate, [.fructans, .gos], tip: "Chips and cheese are fine; beans, salsa and onion aren't."),
        f("fajitas", "Fajitas", .meals, .high, [.fructans], tip: "Onion and seasoning."),
        f("chili-con-carne", "Chili", .meals, .high, [.gos, .fructans], tip: "Beans, onion and garlic.", aka: ["chili con carne"]),
        f("lasagna", "Lasagna", .meals, .high, [.fructans, .lactose]),
        f("ramen-bowl", "Ramen", .meals, .high, [.fructans], tip: "Wheat noodles and a broth made with garlic and onion.", aka: ["ramen bowl", "tonkotsu"]),
        f("pad-thai", "Pad thai", .meals, .moderate, [.fructans], tip: "Rice noodles are fine; ask for no garlic or shallots."),
        f("dumplings", "Dumplings", .meals, .high, [.fructans], aka: ["gyoza", "potstickers", "dim sum", "bao"]),
        f("spring-rolls", "Spring rolls", .meals, .moderate, [.fructans], tip: "Fresh rice-paper rolls are usually fine; fried ones use wheat wrappers.", aka: ["summer rolls"]),
        f("wings", "Chicken wings", .meals, .moderate, [.fructans], tip: "Plain or salt-and-pepper wings are low; buffalo and BBQ sauces have garlic.", aka: ["buffalo wings"]),
        f("kebab", "Kebab or gyro", .meals, .high, [.fructans], tip: "Pita, onion and garlic sauce.", aka: ["gyro", "shawarma", "doner"]),
        f("bowl", "Grain bowl", .meals, .moderate, [.fructans], tip: "Rice or quinoa with plain protein is low; watch the dressing.", aka: ["rice bowl", "burrito bowl", "chipotle bowl", "sweetgreen", "cava bowl"]),
        f("bibimbap", "Bibimbap", .meals, .moderate, [.fructans], tip: "The gochujang and any garlic."),
        f("risotto", "Risotto", .meals, .moderate, [.fructans], tip: "Usually onion and regular stock."),
        f("paella", "Paella", .meals, .moderate, [.fructans], tip: "Usually onion and garlic."),
        f("quiche", "Quiche", .meals, .high, [.fructans, .lactose]),
        f("eggs-benedict", "Eggs benedict", .meals, .high, [.fructans], tip: "The English muffin."),
        f("fish-chips", "Fish and chips", .meals, .high, [.fructans], tip: "The wheat batter."),
        f("acai", "Açaí bowl", .meals, .moderate, [.fructose, .fructans], tip: "Granola, honey and some fruit add up.", aka: ["acai bowl", "smoothie bowl"]),
        f("chicken-rice", "Chicken and rice", .meals, .low, tip: "Plain: watch for garlic in the seasoning."),
        f("steak-potatoes", "Steak and potatoes", .meals, .low),
        f("omelette-meal", "Breakfast plate", .meals, .moderate, [.fructans], tip: "Eggs, bacon and potatoes are low; toast and sausage aren't.", aka: ["eggs and bacon", "full breakfast", "diner breakfast"]),
    ]

    static let byID: [String: DietFood] = Dictionary(foods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// The guide foods named inside a food that isn't in the guide, most specific
    /// first: "garlic bread" is garlic and wheat bread, "garlic-infused oil" only the oil.
    static func ingredients(of text: String) -> [DietFood] {
        let words = ReceiptReader.tokens(text)
        guard !words.isEmpty else { return [] }
        var found: [(food: DietFood, words: Set<String>)] = []
        for food in foods {
            let phrases = ([food.name] + food.aliases).map { Set(ReceiptReader.tokens($0)) }
                .filter { !$0.isEmpty && $0.isSubset(of: words) }
            if let best = phrases.max(by: { $0.count < $1.count }) { found.append((food, best)) }
        }
        // A match inside a bigger one is the same words read twice ("oil" in "garlic oil").
        let kept = found.filter { a in !found.contains { b in b.food.id != a.food.id && a.words.isStrictSubset(of: b.words) } }
        return kept.sorted { $0.words.count > $1.words.count }.map(\.food)
    }

    /// A rating for a food that isn't in the guide, from the guide foods in its name:
    /// the worst of them, since one high ingredient makes the dish high.
    static func estimate(_ name: String) -> DietFood? {
        let parts = ingredients(of: name)
        guard !parts.isEmpty else { return nil }
        let order: [FodmapLevel] = [.high, .moderate, .low]
        let level = order.first { l in parts.contains { $0.level == l } } ?? .low
        let groups = FodmapGroup.allCases.filter { g in parts.contains { $0.level != .low && $0.groups.contains(g) } }
        let names = parts.filter { $0.level == level }.map { $0.name.lowercased() }.joined(separator: ", ")
        let tip = switch level {
        case .high: "Rated from what's in it. High: \(names)."
        case .moderate: "Rated from what's in it. Watch the portion: \(names)."
        default: "Rated from what's in it: \(names)."
        }
        return DietFood(id: "", name: name, category: nil, level: level, groups: groups, tip: tip)
    }
}

// MARK: Meals

enum MealSlot: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }
    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snack"
        }
    }
    var symbol: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon"
        case .snack: "carrot"
        }
    }

    /// The meal a clock time most likely is.
    static func of(_ date: Date) -> MealSlot {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        switch minutes {
        case 5 * 60..<(10 * 60 + 30): return .breakfast
        case (11 * 60)..<(14 * 60 + 30): return .lunch
        case (17 * 60)..<(21 * 60 + 30): return .dinner
        default: return .snack
        }
    }
}

/// A food as it was logged: its rating then, so the history keeps its meaning if the guide changes.
struct MealFood: Hashable, Identifiable {
    var foodID: String?
    var name: String
    var level: FodmapLevel
    var groups: [FodmapGroup]

    var id: String { foodID ?? "custom:\(name.lowercased())" }

    init(_ food: DietFood) {
        foodID = food.id
        name = food.name
        level = food.level
        groups = food.groups
    }

    init(foodID: String?, name: String, level: FodmapLevel, groups: [FodmapGroup]) {
        self.foodID = foodID
        self.name = name
        self.level = level
        self.groups = groups
    }
}

struct Meal: Identifiable, Equatable {
    var id: String
    var at: Date
    var slot: MealSlot
    var foods: [MealFood]
    var note: String?

    /// The worst rating among its foods.
    var level: FodmapLevel {
        let levels = Set(foods.map(\.level))
        if levels.contains(.high) { return .high }
        if levels.contains(.moderate) { return .moderate }
        if levels.contains(.unknown) { return .unknown }
        return .low
    }

    /// The groups that came from foods that aren't low.
    var groups: Set<FodmapGroup> { Set(foods.filter { $0.level == .high || $0.level == .moderate }.flatMap(\.groups)) }

    /// "Chicken, rice, carrots".
    var summary: String {
        let names = foods.map(\.name)
        guard let first = names.first else { return note ?? "No foods listed" }
        return ([first] + names.dropFirst().map { $0.lowercased() }).joined(separator: ", ")
    }
}

// MARK: How he felt

enum Symptom: String, Codable, CaseIterable, Identifiable {
    case gutPain, gas, bloating, nausea, cramps, diarrhea, constipation, reflux, urgency, fatigue

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gutPain: "Gut pain"
        case .gas: "Gassy"
        case .bloating: "Bloated"
        case .nausea: "Nauseous"
        case .cramps: "Cramps"
        case .diarrhea: "Diarrhea"
        case .constipation: "Constipated"
        case .reflux: "Heartburn"
        case .urgency: "Urgency"
        case .fatigue: "Tired"
        }
    }
    var emoji: String {
        switch self {
        case .gutPain: "😣"
        case .gas: "💨"
        case .bloating: "🎈"
        case .nausea: "🤢"
        case .cramps: "🌀"
        case .diarrhea: "🚽"
        case .constipation: "🧱"
        case .reflux: "🔥"
        case .urgency: "⏱️"
        case .fatigue: "😴"
        }
    }
    var symbol: String {
        switch self {
        case .gutPain: "bolt.heart"
        case .gas: "wind"
        case .bloating: "circle.dashed"
        case .nausea: "face.dashed"
        case .cramps: "tornado"
        case .diarrhea: "drop"
        case .constipation: "stop.circle"
        case .reflux: "flame"
        case .urgency: "timer"
        case .fatigue: "zzz"
        }
    }
}

enum Severity: Int, Codable, CaseIterable, Identifiable, Comparable {
    case mild = 1, moderate = 2, severe = 3

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .mild: "Mild"
        case .moderate: "Moderate"
        case .severe: "Severe"
        }
    }
    var color: Color {
        switch self {
        case .mild: Fit.fair
        case .moderate: Fit.activity
        case .severe: Fit.attention
        }
    }
    /// Off, then mild, moderate, severe, then off again.
    var next: Severity? { Severity(rawValue: rawValue + 1) }

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

/// How he felt at a moment, usually after a meal. No symptoms means he felt fine.
struct GutCheck: Identifiable, Equatable {
    var id: String
    var at: Date
    /// The meal it's about, when it's about one.
    var mealID: String?
    var symptoms: [Symptom: Severity]
    var note: String?

    var isFine: Bool { symptoms.isEmpty }
    var worst: Severity? { symptoms.values.max() }

    /// "Gassy, bloated (moderate)", or "Felt fine".
    var summary: String {
        guard !symptoms.isEmpty else { return "Felt fine" }
        let names = Symptom.allCases.compactMap { s in symptoms[s].map { _ in s.title } }
        let text = ([names[0]] + names.dropFirst().map { $0.lowercased() }).joined(separator: ", ")
        return worst.map { "\(text) (\($0.title.lowercased()))" } ?? text
    }
}
