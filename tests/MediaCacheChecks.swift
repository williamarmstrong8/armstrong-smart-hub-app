// Run: ./scripts/check-media-cache.sh
// The script injects the current production cache and load methods at the markers below.
// No SwiftUI, network, real app-cache access, or duplicated production implementation.
import Foundation
import Darwin

// EXTRACTED_MEDIA_CACHE

// Controlled network stand-in. Cancellation deliberately does NOT resolve a request:
// tests deliver a late successful response to exercise the production cancellation guards.
enum TestArgument: Sendable { case string(String), int(Int) }

@MainActor
final class APIClient {
    private var responses: [CheckedContinuation<Data, Never>] = []
    var pending: Int { responses.count }

    func run<T: Decodable>(_ action: String, _ arguments: [TestArgument]) async throws -> T? {
        let data = await withCheckedContinuation { responses.append($0) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func resolve(_ data: Data, at index: Int = 0) {
        responses.remove(at: index).resume(returning: data)
    }
}

struct TestSession { let api: APIClient }

// Only the SwiftUI storage/lifecycle dependencies are substituted. load() and
// adoptCachedDetail() come verbatim from MediaDetailCard, including their access levels.
@MainActor
final class CardLoadHarness {
    let pick: MediaPick
    let session: TestSession
    var detail: MediaDetail?
    var error: String?
    var detailLoadID = UUID()
    var isCurrent = true

    init(_ pick: MediaPick, api: APIClient) {
        self.pick = pick
        session = TestSession(api: api)
    }

    func refresh() async { await load() }

    // EXTRACTED_MEDIA_DETAIL_LOAD_METHODS
}

@main
@MainActor
struct MediaCacheChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
        print("PASS: \(message)")
    }

    // Synchronize on observable state, not an assumed scheduler delay. The deadline
    // turns a missing request/write into a useful failure rather than an infinite wait.
    static func waitUntil(_ label: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func sample(_ title: String) throws -> MediaDetail {
        let json = """
        {"id":1,"title":"\(title)","mediaType":"movie","genres":[],"alreadyRequested":false,"available":false,"playerOnline":false,"canLaunchPlayer":false}
        """
        return try JSONDecoder().decode(MediaDetail.self, from: Data(json.utf8))
    }

    static func pick(_ id: Int) -> MediaPick {
        MediaPick(id: id, mediaType: .movie, title: "Test", posterURL: nil)
    }

    static func runChecks() async throws {
        // One ordered scenario per fresh process/file; distinct keys isolate each race.
        let old = try sample("old"), fresh = try sample("fresh")
        let oldData = try JSONEncoder().encode(old), freshData = try JSONEncoder().encode(fresh)
        let writer = MediaDetailCacheFile()

        // 1. Deliberately deliver snapshots out of order, not via a probabilistic race.
        await writer.write(["movie-1": old, "movie-2": old], revision: 1)
        await writer.write(["movie-1": fresh, "movie-2": old], revision: 3)
        await writer.write(["movie-1": old], revision: 2)
        let ordered = await writer.read()
        try check(ordered["movie-1"]?.title == "fresh" && ordered["movie-2"] != nil,
                  "out-of-order disk snapshots rejected")

        // 2. Invalidate before the first disk restoration; the tombstone must win.
        MediaDetailCache.set(nil, for: pick(1))
        await MediaDetailCache.restore()
        try check(MediaDetailCache.get(pick(1)) == nil && MediaDetailCache.get(pick(2))?.title == "old",
                  "restore preserves invalidations and untouched saved entries")

        // 3. Wait for a unique final marker, proving the latest complete snapshot reached disk.
        MediaDetailCache.set(fresh, for: pick(3))
        MediaDetailCache.set(nil, for: pick(3))
        MediaDetailCache.set(fresh, for: pick(4))
        try await waitUntil("latest snapshot persistence") {
            await writer.read()["movie-4"]?.title == "fresh"
        }
        let persisted = await writer.read()
        try check(persisted["movie-1"] == nil && persisted["movie-3"] == nil
                  && persisted["movie-2"]?.title == "old" && persisted["movie-4"]?.title == "fresh",
                  "latest additions/deletions persist without losing saved entries")

        let api = APIClient()

        // 4. Invalidation occurs after request registration, before its response.
        let prefetch = Task { await MediaDetailCache.prefetch([pick(5)], api: api) }
        try await waitUntil("prefetch registration") { api.pending == 1 }
        MediaDetailCache.set(nil, for: pick(5))
        api.resolve(oldData)
        await prefetch.value
        try check(MediaDetailCache.get(pick(5)) == nil, "late prefetch cannot resurrect invalidated detail")

        // 5. The transport returns success even after cancellation.
        let cancelled = Task { await MediaDetailCache.prefetch([pick(6)], api: api) }
        try await waitUntil("cancelled prefetch registration") { api.pending == 1 }
        cancelled.cancel()
        api.resolve(oldData)
        await cancelled.value
        try check(MediaDetailCache.get(pick(6)) == nil, "cancelled prefetch does not commit")

        // 6. Another fetch fills the cache while the card is still loading.
        let card = CardLoadHarness(pick(7), api: api)
        let loading = Task { await card.refresh() }
        try await waitUntil("card refresh registration") { api.pending == 1 }
        MediaDetailCache.set(fresh, for: pick(7))
        api.resolve(oldData)
        await loading.value
        try check(card.detail?.title == "fresh" && MediaDetailCache.get(pick(7))?.title == "fresh",
                  "card adopts the cache winner instead of retaining a placeholder")

        // 7. A nil cache winner is an invalidation, not permission to use the old response.
        let invalidatedCard = CardLoadHarness(pick(8), api: api)
        let invalidatedLoad = Task { await invalidatedCard.refresh() }
        try await waitUntil("invalidated card registration") { api.pending == 1 }
        MediaDetailCache.set(nil, for: pick(8))
        api.resolve(oldData)
        await invalidatedLoad.value
        try check(invalidatedCard.detail == nil && MediaDetailCache.get(pick(8)) == nil,
                  "card refresh cannot restore invalidated detail")

        // 8. Resolve the second refresh first; the older callback must be ignored.
        let replacedCard = CardLoadHarness(pick(9), api: api)
        let earlier = Task { await replacedCard.refresh() }
        try await waitUntil("first refresh registration") { api.pending == 1 }
        let later = Task { await replacedCard.refresh() }
        try await waitUntil("second refresh registration") { api.pending == 2 }
        api.resolve(freshData, at: 1)
        await later.value
        api.resolve(oldData)
        await earlier.value
        try check(replacedCard.detail?.title == "fresh" && MediaDetailCache.get(pick(9))?.title == "fresh",
                  "superseded detail refresh ignored")

        // 9. Simulate the presentation identity changing before the response arrives.
        let closedCard = CardLoadHarness(pick(10), api: api)
        let closing = Task { await closedCard.refresh() }
        try await waitUntil("dismissed card registration") { api.pending == 1 }
        closedCard.isCurrent = false
        api.resolve(oldData)
        await closing.value
        try check(closedCard.detail == nil && MediaDetailCache.get(pick(10)) == nil,
                  "dismissed card refresh ignored")
    }

    static func main() async {
        do {
            try await runChecks()
            print("9 media cache regression checks passed")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
