import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import PDFKit
import UIKit
import Vision

/// One line read off a receipt, and what it seems to be.
nonisolated struct ReceiptItem: Identifiable, Equatable {
    var id = UUID()
    /// As printed, without the price.
    var line: String
    /// What to call it.
    var name: String
    /// The guide food it matched.
    var foodID: String?
    /// Whether it seems to be food at all.
    var isFood: Bool
    /// Ticked to add.
    var include: Bool
}

/// What a receipt holds.
nonisolated struct ReceiptRead {
    var items: [ReceiptItem]
    var store: String?
    var purchasedAt: Date?
}

/// Reads grocery receipts: a scan or photo (Vision's text recognition, rows
/// rebuilt from where the words sit), a PDF, or pasted text. Lines are cleaned
/// of prices, weights and totals, Whole Foods' abbreviations are spelled out, and
/// each is matched to the low-FODMAP guide. Lines that still don't match go to the
/// on-device language model, when there is one, which says what food each is.
/// Nothing leaves the phone.
nonisolated enum ReceiptReader {
    // MARK: Text

    /// The receipt's rows, top to bottom, from a photo or scan.
    static func rows(in image: CGImage, orientation: CGImagePropertyOrientation = .up) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Receipts are abbreviations; "correcting" them makes them worse.
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        guard (try? handler.perform([request])) != nil else { return [] }

        struct Piece { var text: String; var minX: CGFloat; var midY: CGFloat; var height: CGFloat }
        let pieces: [Piece] = (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first, top.confidence >= 0.25 else { return nil }
            let b = obs.boundingBox
            return Piece(text: top.string, minX: b.minX, midY: b.midY, height: b.height)
        }
        // Words on the same printed row (name on the left, price on the right) join up.
        var rows: [[Piece]] = []
        for piece in pieces.sorted(by: { $0.midY > $1.midY }) {
            if let i = rows.indices.last, let ref = rows[i].first,
               abs(ref.midY - piece.midY) < 0.5 * max(ref.height, piece.height) {
                rows[i].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { $0.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: "  ") }
    }

    /// A PDF's rows: its text when it has some, else each page read like a photo.
    static func rows(inPDF url: URL) -> [String] {
        guard let doc = PDFDocument(url: url) else { return [] }
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
            return text.components(separatedBy: .newlines)
        }
        var rows: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1800 / max(bounds.width, 1)
            let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            if let cg = image.cgImage { rows += Self.rows(in: cg) }
        }
        return rows
    }

    // MARK: Reading

    /// Turns a receipt's rows into items, matched to the guide.
    static func read(_ rows: [String], foods: [DietFood], useModel: Bool = true) async -> ReceiptRead {
        let all = rows.map(clean).filter { !$0.isEmpty }
        let text = all.joined(separator: "\n").uppercased()
        let store: String? = text.contains("WHOLE FOODS") || text.contains("WFM") ? "Whole Foods" : nil
        let lines = itemLines(all)

        var items: [ReceiptItem] = lines.map { line in
            let plain = expand(line)
            if let food = match(plain, in: foods) {
                return ReceiptItem(line: line, name: food.name, foodID: food.id, isFood: true, include: true)
            }
            return ReceiptItem(line: line, name: titled(plain), foodID: nil, isFood: false, include: false)
        }

        // Lines that didn't match: ask the on-device model what food each is.
        let unmatched = items.indices.filter { items[$0].foodID == nil }
        if useModel, !unmatched.isEmpty, SystemLanguageModel.default.isAvailable {
            for chunk in stride(from: 0, to: unmatched.count, by: 30).map({ Array(unmatched[$0..<min($0 + 30, unmatched.count)]) }) {
                let guesses = await guess(chunk.map { items[$0].line })
                for (n, index) in chunk.enumerated() {
                    guard let g = guesses[n + 1] else { continue }
                    if !g.isFood {
                        items[index].isFood = false
                        items[index].include = false
                        continue
                    }
                    let plain = g.food.trimmingCharacters(in: .whitespacesAndNewlines)
                    items[index].isFood = true
                    items[index].include = true
                    if let food = match(plain, in: foods) ?? match(expand(items[index].line) + " " + plain, in: foods) {
                        items[index].name = food.name
                        items[index].foodID = food.id
                    } else if !plain.isEmpty {
                        items[index].name = titled(plain)
                    }
                }
            }
        }
        return ReceiptRead(items: items, store: store, purchasedAt: date(in: all))
    }

    // MARK: Lines

    /// Whitespace squeezed, stray symbols dropped.
    static func clean(_ row: String) -> String {
        row.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The rows that look like items: before the subtotal, with words in them, and not
    /// store details, weights, totals or payment.
    static func itemLines(_ rows: [String]) -> [String] {
        var rows = rows
        if let end = rows.firstIndex(where: { $0.range(of: #"\bSUB\s?TOTAL\b"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
            rows = Array(rows[..<end])
        }
        return rows.compactMap { row in
            var line = row
            // A trailing price and tax flag: "3.99 F", "$12.49", "-1.00 T".
            line = line.replacingOccurrences(of: #"\s*-?\$?\d{1,4}[.,]\d{2}\s*[A-Z]{0,2}\s*$"#, with: "", options: .regularExpression)
            // Leading item codes and quantities: "4011 ", "2 X ", "1 @ ".
            line = line.replacingOccurrences(of: #"^(\d{4,14}\s+|\d+\s*[X@]\s+)"#, with: "", options: [.regularExpression, .caseInsensitive])
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " -*•.:#"))
            let letters = line.filter(\.isLetter).count
            guard letters >= 3, line.count <= 90 else { return nil }
            // A weight line under a produce item: "1.23 lb @ 0.79 /lb".
            if line.range(of: #"\d\s*(lb|lbs|oz|kg|g)\b.*@"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
            if line.range(of: #"@\s*\$?\d"#, options: .regularExpression) != nil, letters < 6 { return nil }
            let upper = stripBrands(line).uppercased()
            // Only the store's name was on it.
            guard upper.filter(\.isLetter).count >= 3 else { return nil }
            // "TOTAL" starts a total line; inside a name it's a brand (Fage Total).
            if upper.range(of: #"^\s*(SUB\s?)?TOTAL\b|\bTOTAL\s*(DUE|:)"#, options: .regularExpression) != nil { return nil }
            if junk.contains(where: { upper.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) { return nil }
            // Phone numbers, card numbers, dates and times.
            if line.range(of: #"\d{3}[-.) ]+\d{3}[-. ]\d{4}|X{4,}|\*{4,}|\d{1,2}[/:]\d{2}([/:]\d{2,4})?"#, options: .regularExpression) != nil,
               letters < 12 { return nil }
            return line
        }
    }

    /// Words that mark a row as something other than an item.
    private static let junk = [
        "SUBTOTAL", "TAX", "TAXES", "VISA", "MASTERCARD", "AMEX", "DISCOVER", "DEBIT", "CREDIT", "CHANGE", "CASH",
        "BALANCE", "SAVINGS", "SAVED", "YOU SAVED", "PRIME MEMBER", "MEMBER DEAL", "DISCOUNT", "COUPON", "REFUND", "BAG", "BAGS",
        "RECEIPT", "THANK", "THANKS", "CASHIER", "AUTH", "APPROVED", "ITEMS SOLD", "ITEM COUNT", "CARD", "ACCOUNT", "REWARDS",
        "VOID", "TEL", "PHONE", "WWW", "HTTP", "HTTPS", "COM", "ORDER", "DELIVERY", "TIP", "FEE", "FEES", "SERVICE", "SHIPPING",
        "STORE", "TRAN", "TRANS", "TERMINAL", "SURVEY", "FEEDBACK", "WHOLE FOODS MARKET", "AMAZON", "PAYMENT", "AMOUNT",
        "QTY", "PRICE", "SUBSTITUTED", "REFUNDED", "RETURN", "MANAGER", "OPEN DAILY", "HOURS", "AVE", "STREET", "BLVD", "SUITE",
        "BOTTLE DEPOSIT", "DEPOSIT", "CRV", "GIFT",
    ]

    /// The purchase date, when a row has one ("11/24/26", "11/24/2026", "Nov 24, 2026").
    static func date(in rows: [String]) -> Date? {
        let formats = ["MM/dd/yy", "MM/dd/yyyy", "MMM d, yyyy", "MMMM d, yyyy", "yyyy-MM-dd"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let pattern = #"\b(\d{1,2}/\d{1,2}/\d{2,4}|[A-Z][a-z]{2,8} \d{1,2}, \d{4}|\d{4}-\d{2}-\d{2})\b"#
        for row in rows {
            guard let range = row.range(of: pattern, options: .regularExpression) else { continue }
            let text = String(row[range])
            for format in formats {
                f.dateFormat = format
                if let d = f.date(from: text) { return d }
            }
        }
        return nil
    }

    // MARK: Words

    /// Spells out receipt shorthand and drops brands and labels: "365 ORG BBY SPNCH 5OZ" is "baby spinach".
    static func expand(_ line: String) -> String {
        var text = stripBrands(line)
        // Sizes and counts: "5oz", "16 fl oz", "1 lb", "12ct", "2 pk".
        text = text.replacingOccurrences(of: #"\b\d+(\.\d+)?\s*(fl\s*)?(oz|lb|lbs|ct|pk|pack|g|kg|ml|l|ea|each|count)\b"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
        let words = text.split(separator: " ").flatMap { word -> [String] in
            let w = String(word)
            if dropWords.contains(w) { return [] }
            return (abbreviations[w] ?? w).split(separator: " ").map(String.init)
        }
        return words.joined(separator: " ")
    }

    private static let brandPhrases = ["365 by whole foods market", "whole foods market", "365 everyday value", "by whole foods",
                                       "amazon fresh", "amazon grocery", "happy belly"]

    /// Lowercased, without the store's own brand names.
    static func stripBrands(_ line: String) -> String {
        var text = " " + line.lowercased() + " "
        for phrase in brandPhrases { text = text.replacingOccurrences(of: phrase, with: " ") }
        return text
    }

    private static let dropWords: Set<String> = [
        "org", "og", "organic", "wfm", "wf", "prm", "premium", "fresh", "frsh", "natural", "nat", "lg", "large", "sm", "small",
        "med", "medium", "xl", "jumbo", "value", "pack", "family", "size", "the", "and", "with", "w", "of", "by", "a", "s",
        "rw", "raw", "uncured", "grassfed", "pasture", "raised", "range", "wild", "caught", "farmed", "local",
        "unswt", "unsweetened", "sweetened", "plain",
        // "LF" is usually low-fat; reading it as lactose-free would rate regular milk as low.
        "lf", "lowfat", "nonfat", "fat", "reduced", "skim", "orig", "original", "classic", "ea", "lb", "oz",
    ]

    private static let abbreviations: [String: String] = [
        // Meat and fish
        "chkn": "chicken", "chk": "chicken", "chix": "chicken", "brst": "breast", "bst": "breast", "thgh": "thigh", "thghs": "thigh",
        "bnls": "boneless", "sknls": "skinless", "grnd": "ground", "grd": "ground", "bf": "beef", "trky": "turkey", "tky": "turkey",
        "slmn": "salmon", "salm": "salmon", "shrmp": "shrimp", "prk": "pork", "bcn": "bacon", "stk": "steak", "sirln": "steak",
        "ribeye": "steak", "sausg": "sausage", "saus": "sausage", "tuna": "tuna",
        // Produce
        "spnch": "spinach", "spin": "spinach", "bby": "baby", "lttc": "lettuce", "lett": "lettuce", "ltc": "lettuce", "rom": "romaine",
        "tom": "tomato", "toms": "tomato", "tmto": "tomato", "cuc": "cucumber", "cuke": "cucumber", "cukes": "cucumber",
        "crt": "carrot", "carr": "carrot", "crrt": "carrot", "pep": "pepper", "ppr": "pepper", "pepr": "pepper", "broc": "broccoli",
        "brocc": "broccoli", "zuc": "zucchini", "zucch": "zucchini", "pot": "potato", "pots": "potato", "pto": "potato",
        "swt": "sweet", "mush": "mushrooms", "mshrm": "mushrooms", "oni": "onion", "onn": "onion", "onio": "onion",
        "yel": "yellow", "grlc": "garlic", "avo": "avocado", "avoc": "avocado", "avcdo": "avocado", "bnna": "banana",
        "ban": "banana", "banan": "banana", "bananas": "banana", "strwb": "strawberries", "strawb": "strawberries",
        "blueb": "blueberries", "blbry": "blueberries", "rasp": "raspberries", "grp": "grapes", "grps": "grapes",
        "appl": "apple", "mngo": "mango", "pnapl": "pineapple", "lmn": "lemon", "clem": "clementine", "mand": "mandarin",
        "kale": "kale", "cilan": "cilantro", "parsl": "parsley", "grn": "green", "scal": "scallion", "scln": "scallion",
        "celry": "celery", "caul": "cauliflower", "cauli": "cauliflower", "aspar": "asparagus", "brus": "brussels",
        "eggplt": "eggplant", "cabb": "cabbage", "jalp": "jalapeno", "berr": "berries",
        // Dairy
        "mlk": "milk", "lact": "lactose", "lactfr": "lactose free", "alm": "almond", "almd": "almond",
        "ygrt": "yogurt", "yog": "yogurt", "ygt": "yogurt", "yogt": "yogurt", "grk": "greek", "chs": "cheese", "chse": "cheese",
        "ched": "cheddar", "chdr": "cheddar", "parm": "parmesan", "mozz": "mozzarella", "btr": "butter", "crm": "cream",
        "shrd": "shredded", "shred": "shredded", "ricot": "ricotta", "cott": "cottage", "hlf": "half",
        // Grains
        "brd": "bread", "srdgh": "sourdough", "sourdh": "sourdough", "srdo": "sourdough", "gf": "gluten free", "glutfr": "gluten free",
        "psta": "pasta", "spag": "spaghetti", "rce": "rice", "jasm": "jasmine", "basm": "basmati", "quin": "quinoa",
        "qnoa": "quinoa", "rld": "rolled", "tort": "tortilla", "tortl": "tortilla", "trtla": "tortilla", "crn": "corn",
        "flr": "flour", "bagl": "bagel", "crkr": "crackers", "crckr": "crackers", "ndl": "noodles", "ndls": "noodles",
        "gran": "granola", "cerl": "cereal",
        // Nuts, legumes
        "pnt": "peanut", "pnut": "peanut", "pb": "peanut butter", "wlnt": "walnuts", "almnd": "almonds", "pecn": "pecans",
        "pstch": "pistachios", "cshw": "cashews", "cashw": "cashews", "hmms": "hummus", "humm": "hummus", "chkpea": "chickpeas",
        "garb": "chickpeas", "lntl": "lentils", "blk": "black", "bns": "beans", "bn": "beans",
        // Pantry, drinks
        "hny": "honey", "mpl": "maple", "syr": "syrup", "choc": "chocolate", "drk": "dark", "kmbch": "kombucha",
        "komb": "kombucha", "spkl": "sparkling", "sprk": "sparkling", "wtr": "water", "coff": "coffee", "cfe": "coffee",
        "jce": "juice", "oj": "orange juice", "slsa": "salsa", "sce": "sauce", "mstrd": "mustard", "ketch": "ketchup",
        "evoo": "olive oil", "olv": "olive", "brth": "broth", "stck": "stock", "vinegr": "vinegar",
        "mayo": "mayonnaise", "srir": "sriracha", "tofu": "tofu", "frm": "firm", "xfrm": "firm", "tmph": "tempeh",
    ]

    /// "chicken breast" becomes "Chicken breast".
    static func titled(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: Matching

    /// The guide food a plain name is: the one whose name or other name has the most
    /// words in it, then the one named last (the head noun: "chicken broth" is broth).
    static func match(_ plain: String, in foods: [DietFood]) -> DietFood? {
        let words = tokens(plain)
        guard !words.isEmpty else { return nil }
        var best: (food: DietFood, size: Int, last: Int)?
        for food in foods {
            for phrase in [food.name] + food.aliases {
                let p = Array(Set(tokens(phrase)))
                guard !p.isEmpty, p.allSatisfy(words.contains) else { continue }
                let last = p.compactMap { words.lastIndex(of: $0) }.max() ?? 0
                if best == nil || p.count > best!.size || (p.count == best!.size && last > best!.last) {
                    best = (food, p.count, last)
                }
            }
        }
        return best?.food
    }

    /// Lowercase words, without "and" or "or", plurals made singular.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { !["and", "or", "of", "the", "a", "other"].contains($0) }
            .map(stem)
    }

    static func stem(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("oes") || w.hasSuffix("ches") || w.hasSuffix("shes") || w.hasSuffix("sses") { return String(w.dropLast(2)) }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us") { return String(w.dropLast()) }
        return w
    }

    // MARK: The model

    @Generable
    struct Guess {
        @Guide(description: "The line's number, as given")
        var line: Int
        @Guide(description: "The plain food in lowercase English, without brand, size or words like organic, e.g. 'chicken breast', 'baby spinach', 'sourdough bread'. Empty when it isn't food.")
        var food: String
        @Guide(description: "False for bags, household and personal care goods, flowers, discounts, totals, payment and store details")
        var isFood: Bool
    }

    @Generable
    struct Guesses {
        @Guide(description: "One entry per numbered line")
        var items: [Guess]
    }

    /// What the on-device model makes of each line, by line number (from 1).
    static func guess(_ lines: [String]) async -> [Int: Guess] {
        let instructions = """
        You read lines from a grocery store receipt. Item names are often abbreviated and in capitals, \
        for example "PRM CHKN BRST BNLS" is chicken breast and "365 OG BBY SPNCH" is baby spinach. \
        For each numbered line, say what food it is in plain words, or that it isn't food.
        """
        let prompt = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: Guesses.self)
            return Dictionary(response.content.items.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            return [:]
        }
    }
}
