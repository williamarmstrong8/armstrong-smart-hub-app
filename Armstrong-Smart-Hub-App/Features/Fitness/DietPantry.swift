import Foundation

/// A food he has at home: from a receipt, or added by hand.
struct PantryItem: Identifiable, Equatable {
    enum Source: String { case receipt, manual }

    var id: String
    /// What to call it: the guide's name when matched, else the cleaned receipt name.
    var name: String
    /// The line as the receipt printed it.
    var line: String?
    /// The guide food it is, when it matched one.
    var foodID: String?
    var source: Source
    var receiptID: String?
    var addedAt: Date
    /// When he last said he still has it.
    var checkedAt: Date?

    /// What freshness counts from.
    var since: Date { max(addedAt, checkedAt ?? addedAt) }
}

/// One imported receipt.
struct DietReceipt: Identifiable, Equatable {
    var id: String
    var store: String?
    var purchasedAt: Date?
    var importedAt: Date
    var items: Int

    var title: String {
        let date = (purchasedAt ?? importedAt).formatted(.dateTime.month(.abbreviated).day())
        return "\(store ?? "Receipt") · \(date)"
    }
}

/// A food to add to the kitchen.
struct PantryAddition {
    var name: String
    var line: String?
    var foodID: String?
}

extension DietStore {
    // MARK: Reading

    func loadPantry() {
        guard let db else { return }
        pantry = db.query("""
            select id, name, line, food_id, source, receipt_id, added_at, checked_at from diet_pantry
            where gone_at is null order by added_at desc, name
            """).compactMap { r in
            guard let id = r["id"] as? String, let name = r["name"] as? String,
                  let added = LocalDB.date(r["added_at"] as? String) else { return nil }
            return PantryItem(id: id, name: name, line: r["line"] as? String, foodID: r["food_id"] as? String,
                              source: PantryItem.Source(rawValue: r["source"] as? String ?? "") ?? .manual,
                              receiptID: r["receipt_id"] as? String, addedAt: added,
                              checkedAt: LocalDB.date(r["checked_at"] as? String))
        }
        receipts = db.query("select id, store, purchased_at, imported_at, items from diet_receipts order by imported_at desc limit 20").compactMap { r in
            guard let id = r["id"] as? String, let imported = LocalDB.date(r["imported_at"] as? String) else { return nil }
            return DietReceipt(id: id, store: r["store"] as? String, purchasedAt: LocalDB.date(r["purchased_at"] as? String),
                               importedAt: imported, items: r["items"] as? Int ?? 0)
        }
    }

    // MARK: Freshness

    /// About how long a food keeps once bought, in days.
    static func shelfDays(_ food: DietFood?) -> Int {
        guard let food else { return 21 }
        switch food.id {
        case "eggs": return 35
        case "hard-cheese", "feta", "butter": return 45
        case "wheat-bread", "sourdough", "bagel", "pastry": return 7
        case "gf-bread": return 14
        case "potato", "kabocha", "spaghetti-squash", "onion", "garlic", "sweet-potato": return 30
        case "banana-firm", "banana-ripe", "strawberries", "raspberries", "blueberries": return 6
        case "lemon-lime", "orange", "carrot", "cabbage", "apple": return 21
        default: break
        }
        switch food.category {
        case .vegetables: return 10
        case .fruit: return 9
        case .protein: return 5
        case .dairy: return 14
        case .grains, .nuts, .legumes, .condiments, .sweets: return 120
        case .drinks: return 60
        case .meals: return 4
        case nil: return 21
        }
    }

    /// Whether it's likely still around: bought (or confirmed) within its shelf life.
    func isFresh(_ item: PantryItem, now: Date = .now) -> Bool {
        let days = Self.shelfDays(item.foodID.flatMap(food))
        return now.timeIntervalSince(item.since) < Double(days) * 86400
    }

    /// Guide foods he likely has right now.
    func inStock(now: Date = .now) -> Set<String> {
        Set(pantry.filter { isFresh($0, now: now) }.compactMap(\.foodID))
    }

    var freshPantry: [PantryItem] { pantry.filter { isFresh($0) } }
    var stalePantry: [PantryItem] { pantry.filter { !isFresh($0) } }

    // MARK: Changing it

    /// Adds foods, from a receipt or by hand. A food already in stock is refreshed rather than added twice.
    func addToPantry(_ additions: [PantryAddition], store storeName: String? = nil, purchasedAt: Date? = nil, source: PantryItem.Source) {
        guard !additions.isEmpty else { return }
        let now = Date.now
        // A receipt date that reads sensibly counts as when he bought it.
        let bought = purchasedAt.flatMap { $0 <= now && now.timeIntervalSince($0) < 60 * 86400 ? $0 : nil } ?? now
        var receiptID: String?
        if source == .receipt {
            let id = LocalDB.uuid()
            receiptID = id
            receipts.insert(DietReceipt(id: id, store: storeName, purchasedAt: purchasedAt, importedAt: now, items: additions.count), at: 0)
            db?.run("insert into diet_receipts (id, store, purchased_at, imported_at, items) values (?, ?, ?, ?, ?)",
                    [id, storeName, purchasedAt.map(LocalDB.iso), LocalDB.iso(now), additions.count])
        }
        db?.transaction { [db] in
            for add in additions {
                let index = pantry.firstIndex { item in
                    if let f = add.foodID { return item.foodID == f }
                    return item.foodID == nil && item.name.caseInsensitiveCompare(add.name) == .orderedSame
                }
                if let index {
                    pantry[index].addedAt = max(pantry[index].addedAt, bought)
                    pantry[index].checkedAt = nil
                    pantry[index].line = add.line ?? pantry[index].line
                    pantry[index].receiptID = receiptID ?? pantry[index].receiptID
                    let item = pantry[index]
                    db?.run("update diet_pantry set added_at = ?, checked_at = null, line = ?, receipt_id = ? where id = ?",
                            [LocalDB.iso(item.addedAt), item.line, item.receiptID, item.id])
                } else {
                    let item = PantryItem(id: LocalDB.uuid(), name: add.name, line: add.line, foodID: add.foodID, source: source,
                                          receiptID: receiptID, addedAt: bought, checkedAt: nil)
                    pantry.append(item)
                    db?.run("""
                        insert into diet_pantry (id, name, line, food_id, source, receipt_id, added_at) values (?, ?, ?, ?, ?, ?, ?)
                        """, [item.id, item.name, item.line, item.foodID, item.source.rawValue, item.receiptID, LocalDB.iso(item.addedAt)])
                }
            }
        }
        pantry.sort { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : $0.name < $1.name }
    }

    /// Adds one guide food (or one of his own) by hand.
    func addToPantry(_ food: DietFood) {
        addToPantry([PantryAddition(name: food.name, line: nil, foodID: food.id)], source: .manual)
    }

    /// Ran out of it.
    func markGone(_ item: PantryItem) {
        pantry.removeAll { $0.id == item.id }
        db?.run("update diet_pantry set gone_at = ? where id = ?", [LocalDB.iso(.now), item.id])
    }

    /// Still has it, so it counts as fresh again.
    func keep(_ item: PantryItem) {
        guard let index = pantry.firstIndex(where: { $0.id == item.id }) else { return }
        pantry[index].checkedAt = .now
        db?.run("update diet_pantry set checked_at = ? where id = ?", [LocalDB.iso(.now), item.id])
    }

    /// Clears everything that's probably used up.
    func clearStale() {
        for item in stalePantry { markGone(item) }
    }

    /// Points an item at a different guide food (or none).
    func setFood(_ item: PantryItem, _ food: DietFood?) {
        guard let index = pantry.firstIndex(where: { $0.id == item.id }) else { return }
        pantry[index].foodID = food?.id
        if let food { pantry[index].name = food.name }
        db?.run("update diet_pantry set food_id = ?, name = ? where id = ?", [food?.id, pantry[index].name, item.id])
    }
}
