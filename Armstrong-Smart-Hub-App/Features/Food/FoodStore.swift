import Foundation
import Observation
import UIKit

/// The Food tab's data: the journal, the review queue and the grocery list,
/// all from /api/mobile/food. Writes go to the hub and then reload.
@MainActor
@Observable
final class FoodStore {
    private(set) var entries: [FoodEntry] = []
    private(set) var groceries: [GroceryItem] = []
    private(set) var gmail = "unconfigured"
    private(set) var loaded = false
    private(set) var error: String?
    /// Something slow (reading a photo, syncing) is in progress, with what to say about it.
    private(set) var working: String?

    var review: [FoodEntry] { entries.filter { !$0.confirmed } }

    func meals(on day: Date) -> [FoodEntry] {
        entries
            .filter { $0.confirmed && $0.date.map { Calendar.current.isDate($0, inSameDayAs: day) } == true }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func load(api: APIClient) async {
        do {
            let snapshot: FoodSnapshot = try await api.get("/api/mobile/food")
            entries = snapshot.entries
            groceries = snapshot.groceries
            gmail = snapshot.gmail
            error = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(_ meal: MealInput, api: APIClient, toast: Toast) async -> Bool {
        do {
            let _: Empty = try await api.post("/api/mobile/food", body: meal)
            await load(api: api)
            return true
        } catch {
            toast.error(error)
            return false
        }
    }

    /// Accepts an estimate or import exactly as it is.
    func accept(_ entry: FoodEntry, api: APIClient, toast: Toast) async {
        let input = MealInput(id: entry.id, name: entry.name, eatenAt: entry.eatenAt, grams: entry.grams, calories: entry.calories,
                              protein: entry.protein, carbs: entry.carbs, fat: entry.fat, barcode: entry.barcode)
        if await save(input, api: api, toast: toast) { toast.show("Added to your day") }
    }

    func delete(_ entry: FoodEntry, api: APIClient, toast: Toast) async {
        do {
            let _: Empty = try await api.send(api.request("/api/mobile/food?id=\(entry.id)", method: "DELETE"))
            entries.removeAll { $0.id == entry.id }
        } catch {
            toast.error(error)
        }
    }

    /// Sends a meal photo to be read against the grocery list. It comes back in review.
    func logPhoto(_ image: UIImage, api: APIClient, toast: Toast) async -> FoodEntry? {
        guard let photo = PhotoUpload(image) else { toast.show("Couldn't read that photo.", error: true); return nil }
        working = "Reading your meal…"
        defer { working = nil }
        struct Body: Encodable { let photo: PhotoUpload }
        struct Reply: Decodable { let entry: FoodEntry?; let error: String? }
        do {
            let reply: Reply = try await api.send(api.request("/api/mobile/food/photo", method: "POST", body: Body(photo: photo), timeout: 90))
            guard let entry = reply.entry else { toast.show(reply.error ?? "Couldn't read that photo.", error: true); return nil }
            await load(api: api)
            return entry
        } catch {
            toast.error(error)
            return nil
        }
    }

    /// Adds groceries from a receipt or list photo, or typed text.
    func addGroceries(photo image: UIImage? = nil, text: String? = nil, api: APIClient, toast: Toast) async {
        let photo = image.flatMap(PhotoUpload.init)
        if image != nil, photo == nil { toast.show("Couldn't read that photo.", error: true); return }
        working = "Reading your list…"
        defer { working = nil }
        struct Body: Encodable { let photo: PhotoUpload?; let text: String? }
        struct Reply: Decodable { let found: Int?; let added: Int?; let groceries: [GroceryItem]?; let error: String? }
        do {
            let reply: Reply = try await api.send(api.request("/api/mobile/food/groceries", method: "POST", body: Body(photo: photo, text: text), timeout: 90))
            guard let groceries = reply.groceries, let added = reply.added, let found = reply.found else {
                toast.show(reply.error ?? "Couldn't read that list.", error: true)
                return
            }
            self.groceries = groceries
            toast.show(added == found ? "Added \(added) item\(added == 1 ? "" : "s")" : "Added \(added) new of \(found) found")
        } catch {
            toast.error(error)
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

    func syncDoorDash(api: APIClient, toast: Toast) async {
        working = "Checking Gmail…"
        defer { working = nil }
        struct Reply: Decodable { let imported: Int?; let more: Bool?; let error: String? }
        do {
            let reply: Reply = try await api.post("/api/mobile/food/sync")
            guard let imported = reply.imported else { toast.show(reply.error ?? "Couldn't sync receipts.", error: true); return }
            toast.show((imported == 0 ? "No new orders" : "Imported \(imported) order\(imported == 1 ? "" : "s")") + (reply.more == true ? ". More remain." : ""))
            await load(api: api)
        } catch {
            toast.error(error)
        }
    }

    /// Looks a barcode up in Open Food Facts (through the hub). nil means not found.
    func lookup(_ barcode: String, api: APIClient) async throws -> FoodProduct? {
        struct Reply: Decodable { let product: FoodProduct?; let error: String? }
        let reply: Reply = try await api.get("/api/food/product?barcode=\(barcode)")
        if let error = reply.error { throw APIError(message: error) }
        return reply.product
    }
}

extension PhotoUpload {
    /// Shrinks to at most 1600 px on the long side and encodes as JPEG, which
    /// keeps uploads small and drops location metadata.
    init?(_ image: UIImage) {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        self.init(data: jpeg.base64EncodedString())
    }
}
