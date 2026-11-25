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

    func matches(_ query: String) -> Bool {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return fold(name).contains(q) || aliases.contains { fold($0).contains(q) }
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
        f("zucchini", "Zucchini", .vegetables, .moderate, [.fructans], tip: "Low at about ⅓ cup; larger servings add fructans.", aka: ["courgette"]),
        f("sweet-potato", "Sweet potato", .vegetables, .moderate, [.mannitol], tip: "Low at about ½ cup; more adds mannitol.", aka: ["yam"]),
        f("corn", "Sweet corn", .vegetables, .moderate, [.sorbitol], tip: "Low at about half a cob; more adds sorbitol.", aka: ["corn on the cob"]),
        f("celery", "Celery", .vegetables, .moderate, [.mannitol], tip: "Low under a quarter of a stalk; more adds mannitol."),
        f("butternut", "Butternut squash", .vegetables, .moderate, [.mannitol, .gos], tip: "Low in small servings, about ¼ cup."),
        f("brussels", "Brussels sprouts", .vegetables, .moderate, [.fructans], tip: "Low at about 2 sprouts."),
        f("beetroot", "Beets", .vegetables, .moderate, [.fructans, .gos], tip: "Low at about 2 slices.", aka: ["beetroot"]),
        f("snow-peas", "Snow peas", .vegetables, .moderate, [.fructans, .mannitol], tip: "Low at about 5 pods."),
        f("green-peas", "Green peas", .vegetables, .moderate, [.gos, .fructans], tip: "Only a spoonful or so is low."),
        f("garlic", "Garlic", .vegetables, .high, [.fructans], tip: "Garlic-infused oil is fine: fructans don't go into the oil.", aka: ["garlic powder"]),
        f("onion", "Onion", .vegetables, .high, [.fructans], tip: "Every kind, and onion powder. Use chives or spring onion greens instead.", aka: ["shallot", "red onion", "onion powder"]),
        f("leek", "Leek", .vegetables, .high, [.fructans], tip: "The dark green leaves are low; the white bulb is high."),
        f("cauliflower", "Cauliflower", .vegetables, .high, [.mannitol]),
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
        f("corn-tortilla", "Corn tortillas", .grains, .low, aka: ["tacos", "tortilla chips"]),
        f("polenta", "Polenta", .grains, .low, aka: ["cornmeal", "grits"]),
        f("popcorn", "Popcorn", .grains, .low),
        f("rice-cakes", "Rice cakes or crackers", .grains, .low, aka: ["rice crackers"]),
        f("buckwheat", "Buckwheat", .grains, .low),
        f("millet", "Millet", .grains, .low),
        f("oats", "Oats", .grains, .moderate, [.fructans, .gos], tip: "Low at about ½ cup uncooked; more adds fructans and GOS.", aka: ["oatmeal", "porridge", "overnight oats"]),
        f("sourdough", "Sourdough bread", .grains, .moderate, [.fructans], tip: "Traditional, slow-fermented white wheat or spelt sourdough is low at 2 slices."),
        f("wheat-bread", "Wheat bread", .grains, .high, [.fructans], tip: "A single slice of white bread is sometimes tolerated. Sourdough or gluten-free is the swap.", aka: ["toast", "sandwich bread", "whole wheat bread", "bun"]),
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
        f("sausage", "Sausage or deli meat", .protein, .moderate, [.fructans], tip: "Depends on the recipe: many have garlic, onion or wheat.", aka: ["hot dog", "salami", "chorizo"]),

        // Dairy & alternatives
        f("lf-milk", "Lactose-free milk", .dairy, .low),
        f("almond-milk", "Almond milk", .dairy, .low),
        f("rice-milk", "Rice milk", .dairy, .low),
        f("hard-cheese", "Hard cheese", .dairy, .low, aka: ["cheddar", "parmesan", "swiss", "mozzarella", "provolone", "gouda"]),
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
        f("olive-oil", "Olive oil and other oils", .condiments, .low, aka: ["oil", "avocado oil", "canola oil"]),
        f("garlic-oil", "Garlic-infused oil", .condiments, .low, tip: "Garlic flavor without the fructans."),
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
        f("stock", "Stock or broth", .condiments, .high, [.fructans], tip: "Regular stock has onion and garlic; use a low-FODMAP one.", aka: ["broth", "bouillon", "soup"]),
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
        f("poke", "Poke bowl", .meals, .moderate, [.fructans], tip: "Skip the onion and creamy or garlic sauces."),
        f("pho", "Pho", .meals, .moderate, [.fructans], tip: "Rice noodles are fine, but the broth is usually made with onion."),
        f("stir-fry", "Stir-fry", .meals, .moderate, [.fructans], tip: "Fine without garlic and onion."),
        f("salad", "Salad", .meals, .moderate, [.fructans], tip: "Depends on the dressing and toppings."),
        f("pizza", "Pizza", .meals, .high, [.fructans, .lactose], tip: "Wheat crust, garlic and onion in the sauce."),
        f("burger", "Burger with bun", .meals, .high, [.fructans], tip: "The bun and onion. Lettuce wrap or gluten-free bun."),
        f("burrito", "Burrito", .meals, .high, [.fructans, .gos], tip: "Flour tortilla, beans, onion and salsa. A bowl with rice and meat is safer."),
        f("curry", "Curry", .meals, .high, [.fructans], tip: "Most are built on onion and garlic."),
        f("fried-rice", "Fried rice", .meals, .high, [.fructans], tip: "Usually garlic and onion."),
        f("mac-cheese", "Mac and cheese", .meals, .high, [.fructans, .lactose]),
    ]

    static let byID: [String: DietFood] = Dictionary(foods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
