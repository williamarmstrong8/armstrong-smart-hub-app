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
    /// Imports and photo estimates wait for review before they count.
    let confirmed: Bool
    let items: [MealItem]?

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
}

/// Per 100 g, from Open Food Facts.
struct FoodProduct: Decodable, Hashable, Sendable {
    let barcode: String
    let name: String
    let brand: String
    let serving: String
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

struct FoodSnapshot: Decodable, Sendable {
    let entries: [FoodEntry]
    let groceries: [GroceryItem]
    /// connected, missing_scope or unconfigured.
    let gmail: String
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
    }

    private enum CodingKeys: String, CodingKey { case id, name, eatenAt, grams, calories, protein, carbs, fat, barcode }
}

/// A photo for the hub to read: JPEG bytes as base64.
struct PhotoUpload: Encodable, Sendable {
    let data: String
    let mediaType = "image/jpeg"
}
