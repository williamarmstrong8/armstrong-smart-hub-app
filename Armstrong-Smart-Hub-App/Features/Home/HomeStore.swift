import Foundation
import Observation

/// Polls /api/home like components/home/use-home.ts: every 3s while something
/// is downloading, 8s otherwise, only while the screen is visible. Local
/// changes win over polls for a few seconds so switches never flicker back.
@MainActor
@Observable
final class HomeStore {
    private(set) var state: HomeState?
    private(set) var loadError: String?
    private(set) var pending: Set<String> = []

    private var overrides: [String: (patch: (inout HAEntity) -> Void, check: (HAEntity) -> Bool, until: Date)] = [:]
    private static let overrideSeconds: TimeInterval = 10
    /// Shared between Home and Display so either paints instantly.
    private static var lastKnown: HomeState?

    init() { state = Self.lastKnown }

    var entities: [HAEntity] { state?.entities ?? [] }

    /// Until devices are picked, everything that's actually available.
    var shownEntities: [HAEntity] {
        if let visible = state?.visible {
            let picked = Set(visible)
            return entities.filter { picked.contains($0.id) }
        }
        return entities.filter { !$0.isUnavailable }
    }

    var activeDownloads: [MediaRequest] {
        (state?.requests ?? []).filter { $0.stage.isActive || $0.stage == .pendingApproval }
    }

    var ready: [MediaRequest] { (state?.requests ?? []).filter { $0.stage == .available } }

    var isBusy: Bool { (state?.requests ?? []).contains { $0.stage.isActive } }

    func entity(_ id: String) -> HAEntity? { entities.first { $0.id == id } }

    func poll(api: APIClient) async {
        while !Task.isCancelled {
            await refresh(api: api)
            try? await Task.sleep(for: .seconds(isBusy ? 3 : 8))
        }
    }

    func refresh(api: APIClient) async {
        do {
            let next: HomeState = try await api.get("/api/home")
            var merged = next
            merged.entities = next.entities.map(applyOverrides) ?? state?.entities
            merged.requests = next.requests ?? state?.requests
            merged.automations = next.automations ?? state?.automations
            state = merged
            Self.lastKnown = merged
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func applyOverrides(_ list: [HAEntity]) -> [HAEntity] {
        let now = Date()
        return list.map { e in
            guard let o = overrides[e.id] else { return e }
            if o.until < now || o.check(e) {
                overrides[e.id] = nil
                return e
            }
            var copy = e
            o.patch(&copy)
            return copy
        }
    }

    /// Applies a change on screen now and keeps it until a poll confirms it.
    func patch(_ id: String, _ change: @escaping (inout HAEntity) -> Void, confirmedWhen check: @escaping (HAEntity) -> Bool) {
        let previous = overrides[id]?.patch
        let combined: (inout HAEntity) -> Void = { e in previous?(&e); change(&e) }
        overrides[id] = (combined, check, Date().addingTimeInterval(Self.overrideSeconds))
        guard var s = state, var list = s.entities, let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        s.entities = list
        state = s
        Self.lastKnown = s
    }

    private func revert(_ original: HAEntity) {
        overrides[original.id] = nil
        guard var s = state, var list = s.entities, let i = list.firstIndex(where: { $0.id == original.id }) else { return }
        list[i] = original
        s.entities = list
        state = s
    }

    func toggle(_ entity: HAEntity, api: APIClient, toast: Toast) async {
        let next = entity.isOn ? (entity.control == .lock ? "locked" : "off") : (entity.control == .lock ? "unlocked" : "on")
        patch(entity.id, { $0.state = next }, confirmedWhen: { $0.state == next })
        pending.insert(entity.id)
        defer { pending.remove(entity.id) }
        do {
            let _: Empty? = try await api.run("toggleEntity", [.string(entity.id)])
        } catch {
            revert(entity)
            toast.error(error)
        }
    }

    struct LightChange {
        var on: Bool?
        var brightnessPct: Int?
        var rgb: [Int]?
        var kelvin: Int?
    }

    func setLight(_ entity: HAEntity, _ change: LightChange, api: APIClient, toast: Toast) async {
        patch(entity.id, { e in
            e.state = change.on == false ? "off" : "on"
            if let b = change.brightnessPct { e.brightness = Double(b) / 100 * 255 }
            if let rgb = change.rgb { e.rgbColor = rgb }
            if let k = change.kelvin { e.colorTempKelvin = k }
        }, confirmedWhen: { e in
            (change.on == false ? e.state == "off" : e.state == "on")
                && (change.rgb == nil || e.rgbColor == change.rgb)
                && (change.kelvin == nil || e.colorTempKelvin == change.kelvin)
        })
        var body: [String: JSONValue] = [:]
        if let on = change.on { body["on"] = .bool(on) }
        if let b = change.brightnessPct { body["brightnessPct"] = .int(b) }
        if let rgb = change.rgb { body["rgb"] = .array(rgb.map { .int($0) }) }
        if let k = change.kelvin { body["kelvin"] = .int(k) }
        do {
            let _: Empty? = try await api.run("setLight", [.string(entity.id), .object(body)])
        } catch {
            revert(entity)
            toast.error(error)
        }
    }

    func setAutomation(_ automation: HAAutomation, enabled: Bool, api: APIClient, toast: Toast) async {
        updateAutomation(automation.id) { $0.state = enabled ? "on" : "off" }
        do {
            let _: Empty? = try await api.run("setAutomationEnabled", [.string(automation.id), .bool(enabled)])
        } catch {
            updateAutomation(automation.id) { $0.state = automation.state }
            toast.error(error)
        }
    }

    private func updateAutomation(_ id: String, _ change: (inout HAAutomation) -> Void) {
        guard var s = state, var payload = s.automations,
              let i = payload.automations.firstIndex(where: { $0.id == id }) else { return }
        change(&payload.automations[i])
        s.automations = payload
        state = s
    }
}
