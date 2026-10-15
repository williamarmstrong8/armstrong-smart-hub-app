import Foundation
import Observation
import UIKit

/// The Food tab's data: the day's meals and the grocery list, from
/// /api/mobile/food. Snapping or scanning returns something to show; logging
/// it saves a meal.
@MainActor
@Observable
final class FoodStore {
    private(set) var entries: [FoodEntry] = []
    private(set) var groceries: [GroceryItem] = []
    private(set) var loaded = false
    private(set) var error: String?
    /// Something slow (reading a photo) is in progress, with what to say about it.
    private(set) var working: String?

    func meals(on day: Date) -> [FoodEntry] {
        entries
            .filter { $0.date.map { Calendar.current.isDate($0, inSameDayAs: day) } == true }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func load(api: APIClient) async {
        do {
            let snapshot: FoodSnapshot = try await api.get("/api/mobile/food")
            entries = snapshot.entries
            groceries = snapshot.groceries
            error = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func log(_ meal: MealInput, api: APIClient, toast: Toast) async -> Bool {
        do {
            let _: Empty = try await api.post("/api/mobile/food", body: meal)
            await load(api: api)
            return true
        } catch {
            toast.error(error)
            return false
        }
    }

    func delete(_ entry: FoodEntry, api: APIClient, toast: Toast) async {
        entries.removeAll { $0.id == entry.id }
        do {
            let _: Empty = try await api.send(api.request("/api/mobile/food?id=\(entry.id)", method: "DELETE"))
        } catch {
            toast.error(error)
            await load(api: api)
        }
    }

    /// Reads a meal photo against the grocery list. Nothing is saved until it's logged.
    func estimate(_ image: UIImage, api: APIClient, toast: Toast) async -> MealEstimate? {
        guard let photo = PhotoUpload(image) else { toast.show("Couldn't read that photo.", error: true); return nil }
        working = "Reading your meal…"
        defer { working = nil }
        struct Body: Encodable { let photo: PhotoUpload }
        struct Reply: Decodable { let meal: MealEstimate?; let error: String? }
        do {
            let reply: Reply = try await api.send(api.request("/api/mobile/food/photo", method: "POST", body: Body(photo: photo), timeout: 90))
            guard let meal = reply.meal else { toast.show(reply.error ?? "Couldn't read that photo.", error: true); return nil }
            return meal
        } catch {
            toast.error(error)
            return nil
        }
    }

    /// Looks a barcode up in Open Food Facts (through the hub). nil means not found.
    func lookup(_ barcode: String, api: APIClient, toast: Toast) async -> FoodProduct? {
        working = "Looking it up…"
        defer { working = nil }
        struct Reply: Decodable { let product: FoodProduct?; let error: String? }
        do {
            let reply: Reply = try await api.get("/api/food/product?barcode=\(barcode)")
            if let error = reply.error { toast.show(error, error: true); return nil }
            if reply.product == nil { toast.show("That product isn't in Open Food Facts yet.") }
            return reply.product
        } catch {
            toast.error(error)
            return nil
        }
    }

    // MARK: Groceries

    /// Adds groceries from a receipt or list photo, or a scanned barcode. False if nothing could be added.
    @discardableResult
    func addGroceries(photo image: UIImage? = nil, barcode: String? = nil, api: APIClient, toast: Toast) async -> Bool {
        let photo = image.flatMap(PhotoUpload.init)
        if image != nil, photo == nil { toast.show("Couldn't read that photo.", error: true); return false }
        working = barcode == nil ? "Reading your groceries…" : "Adding to groceries…"
        defer { working = nil }
        struct Body: Encodable { let photo: PhotoUpload?; let barcode: String? }
        struct Reply: Decodable { let found: Int?; let added: Int?; let groceries: [GroceryItem]?; let error: String? }
        do {
            let reply: Reply = try await api.send(api.request("/api/mobile/food/groceries", method: "POST", body: Body(photo: photo, barcode: barcode), timeout: 90))
            guard let groceries = reply.groceries, let added = reply.added, let found = reply.found else {
                toast.show(reply.error ?? "Couldn't add that.", error: true)
                return false
            }
            self.groceries = groceries
            if barcode != nil {
                toast.show(added > 0 ? "Added to groceries" : "Already in your groceries")
            } else {
                toast.show(added == found ? "Added \(added) item\(added == 1 ? "" : "s")" : "Added \(added) new of \(found)")
            }
            return true
        } catch {
            toast.error(error)
            return false
        }
    }

    /// Usuals and products for the search sheet. Empty text lists the store's usuals.
    func searchGroceries(_ text: String, store: String?, api: APIClient) async throws -> GrocerySearchResult {
        var components = URLComponents()
        components.path = "/api/mobile/food/groceries/search"
        components.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "store", value: store ?? "")]
        return try await api.get(components.string ?? components.path)
    }

    /// Adds a pick from the search sheet, remembering the store and what was searched. True if it went on the list.
    func addGrocery(_ pick: GroceryPick, store: String?, query: String, api: APIClient, toast: Toast) async -> Bool {
        struct Body: Encodable { var barcode, again, name, store, query: String? }
        var body = Body(store: store, query: query.isEmpty ? nil : query)
        switch pick {
        case .product(let barcode): body.barcode = barcode
        case .again(let id): body.again = id
        case .named(let name): body.name = name
        }
        struct Reply: Decodable { let added: Int?; let groceries: [GroceryItem]?; let error: String? }
        do {
            let reply: Reply = try await api.send(api.request("/api/mobile/food/groceries", method: "POST", body: body, timeout: 90))
            guard let groceries = reply.groceries, let added = reply.added else {
                toast.show(reply.error ?? "Couldn't add that.", error: true)
                return false
            }
            self.groceries = groceries
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            toast.show(added > 0 ? "Added to groceries" : "Already on your list")
            return true
        } catch {
            toast.error(error)
            return false
        }
    }

    func deleteGrocery(_ item: GroceryItem, api: APIClient, toast: Toast) async {
        groceries.removeAll { $0.id == item.id }
        do {
            let _: Empty = try await api.send(api.request("/api/mobile/food/groceries?id=\(item.id)", method: "DELETE"))
        } catch {
            toast.error(error)
            await load(api: api)
        }
    }

    func clearGroceries(api: APIClient, toast: Toast) async {
        groceries = []
        do {
            let _: Empty = try await api.send(api.request("/api/mobile/food/groceries?all=1", method: "DELETE"))
        } catch {
            toast.error(error)
            await load(api: api)
        }
    }
}

extension PhotoUpload {
    /// Shrinks to at most 1600 px on the long side and encodes as JPEG, which
    /// keeps uploads small and drops location metadata.
    init?(_ image: UIImage) {
        guard let jpeg = image.resized(longest: 1600).jpegData(compressionQuality: 0.8) else { return nil }
        self.init(data: jpeg.base64EncodedString())
    }
}

extension UIImage {
    func resized(longest: CGFloat) -> UIImage {
        let scale = min(1, longest / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// A small JPEG to keep with a logged meal, as a data URL.
    var thumbnailDataURL: String? {
        resized(longest: 360).jpegData(compressionQuality: 0.6).map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
    }
}
