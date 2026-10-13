import Foundation

// MARK: Food (lib/food/types.ts)

struct MealItem: Decodable, Hashable, Sendable {
    let name: String
    let groceryId: String?
    let portion: String?
    let grams: Double?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

struct FoodEntry: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var eatenAt: String
    var grams: Double?
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    let barcode: String?
    /// manual, barcode, doordash or photo.
    let source: String
    let restaurant: String?
    let receiptId: String?
    let confirmed: Bool
    let items: [MealItem]?
    /// A product photo URL, or a "data:image/jpeg;base64," thumbnail.
    let image: String?

    var date: Date? { ISO.parse(eatenAt) }

    var sourceSymbol: String {
        switch source {
        case "doordash": "bicycle"
        case "photo": "camera"
        case "barcode": "barcode"
        default: "fork.knife"
        }
    }
}

struct GroceryItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let quantity: String?
    let serving: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let source: String
    let image: String?
}

/// Per 100 g, from Open Food Facts.
struct FoodProduct: Decodable, Hashable, Sendable {
    let barcode: String
    let name: String
    let brand: String
    let serving: String
    let servingGrams: Double?
    let image: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

struct FoodSnapshot: Decodable, Sendable {
    let entries: [FoodEntry]
    let groceries: [GroceryItem]
}

/// A meal photo, read but not logged yet.
struct MealEstimate: Decodable, Hashable, Sendable {
    let name: String
    let items: [MealItem]
    let grams: Double?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

/// What /api/mobile/food takes to add or save a meal.
struct MealInput: Encodable, Sendable {
    var id: String?
    var name: String
    var eatenAt: String
    var grams: Double?
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var barcode: String?
    var image: String?
    var items: [MealItemInput]?
    var source: String?

    // Explicit nulls: the hub's schema treats a missing value and null the same,
    // but sending null keeps "unknown" unambiguous.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(eatenAt, forKey: .eatenAt)
        try c.encode(grams, forKey: .grams)
        try c.encode(calories, forKey: .calories)
        try c.encode(protein, forKey: .protein)
        try c.encode(carbs, forKey: .carbs)
        try c.encode(fat, forKey: .fat)
        try c.encode(barcode, forKey: .barcode)
        try c.encode(image, forKey: .image)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(source, forKey: .source)
    }

    private enum CodingKeys: String, CodingKey { case id, name, eatenAt, grams, calories, protein, carbs, fat, barcode, image, items, source }
}

/// A photographed meal's part, sent back when the meal is logged.
struct MealItemInput: Encodable, Sendable {
    let name: String
    let groceryId: String?
    let portion: String?
    let grams: Double?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(groceryId, forKey: .groceryId)
        try c.encode(portion, forKey: .portion)
        try c.encode(grams, forKey: .grams)
        try c.encode(calories, forKey: .calories)
        try c.encode(protein, forKey: .protein)
        try c.encode(carbs, forKey: .carbs)
        try c.encode(fat, forKey: .fat)
    }

    private enum CodingKeys: String, CodingKey { case name, groceryId, portion, grams, calories, protein, carbs, fat }
}

/// A photo for the hub to read: JPEG bytes as base64.
struct PhotoUpload: Encodable, Sendable {
    let data: String
    let mediaType = "image/jpeg"
}

extension ISO {
    /// An instant as the ISO 8601 string the hub expects.
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
