import Foundation
import Observation

private struct AgentErrorBody: Decodable { let error: String? }

struct AgentModel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let group: String?
    /// List price per million tokens, in USD.
    let inputPerM: Double?
    let outputPerM: Double?

    var priceText: String? {
        guard let i = inputPerM, let o = outputPerM else { return nil }
        return "$\(Self.short(i)) in · $\(Self.short(o)) out per 1M"
    }

    private static func short(_ v: Double) -> String {
        v >= 1 ? String(format: "%.2f", v) : String(format: "%.2f", v).replacingOccurrences(of: "0.", with: ".")
    }
}

/// One step the agent took while answering: a query, a lookup.
struct AgentStep: Identifiable, Equatable {
    let id: String
    var label: String
    var done = false
}

struct AgentMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var steps: [AgentStep] = []
    var failed = false
    /// What each model call behind this answer cost, by the hub's step id.
    var costs: [String: Double] = [:]
    /// Step ids whose cost is the gateway's exact charge rather than the list-price estimate.
    var exact: Set<String> = []

    var cost: Double { costs.values.reduce(0, +) }
    var costIsExact: Bool { !costs.isEmpty && exact.count == costs.count }
}

/// A conversation with the hub's data agent: Jarvis on the phone, with a SQL view of the stored
/// data. Each turn posts the conversation and reads back newline-delimited events. Shared, so
/// closing the sheet and opening it again keeps the chat.
@MainActor
@Observable
final class AgentStore {
    static let shared = AgentStore()

    var messages: [AgentMessage] = []
    var models: [AgentModel] = []
    var sending = false
    /// Why the model list didn't load, shown in the picker.
    var modelsError: String?
    /// The chosen model's gateway id; empty until the list loads, then the hub's default.
    var modelID: String = UserDefaults.standard.string(forKey: AgentStore.modelKey) ?? "" {
        didSet { UserDefaults.standard.set(modelID, forKey: AgentStore.modelKey) }
    }

    /// Bumped when the default model changes, so the new default applies once.
    private static let modelKey = "agent.model.2"

    private var task: Task<Void, Never>?

    var model: AgentModel? { models.first { $0.id == modelID } ?? models.first }

    /// This conversation's spend so far, from the AI Gateway.
    var sessionCost: Double { messages.reduce(0) { $0 + $1.cost } }
    /// False while any figure is still a list-price estimate.
    var sessionCostIsExact: Bool { messages.allSatisfy { $0.costs.isEmpty || $0.costIsExact } }

    func loadModels(api: APIClient) async {
        guard models.isEmpty else { return }
        struct Reply: Decodable { let models: [AgentModel]; let `default`: String }
        let reply: Reply
        do {
            reply = try await api.get("/api/mobile/agent")
        } catch {
            modelsError = "The hub doesn't have the agent yet. Redeploy it."
            return
        }
        modelsError = nil
        models = reply.models
        if !reply.models.contains(where: { $0.id == modelID }) { modelID = reply.default }
    }

    func reset() {
        task?.cancel()
        messages = []
        sending = false
    }

    func stop() {
        task?.cancel()
    }

    func send(_ text: String, api: APIClient) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending else { return }
        // Failed or stopped answers stay on screen but aren't sent back as context.
        let history = messages
            .filter { !$0.failed && !$0.text.isEmpty && !($0.role == .assistant && $0.text == Self.stopped) }
            .map { ["role": $0.role.rawValue, "content": $0.text] }
            + [["role": "user", "content": prompt]]
        messages.append(AgentMessage(role: .user, text: prompt))
        let reply = AgentMessage(role: .assistant, text: "")
        messages.append(reply)
        sending = true
        let model = modelID
        task = Task { [weak self] in
            await self?.run(reply: reply.id, history: history, model: model, api: api)
            if self?.messages.last?.id == reply.id { self?.sending = false }
        }
    }

    private static let stopped = "Stopped."

    private struct Body: Encodable {
        let messages: [[String: String]]
        let model: String
    }

    private func update(_ id: UUID, _ change: (inout AgentMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    private func run(reply id: UUID, history: [[String: String]], model: String, api: APIClient) async {
        var request = api.request("/api/mobile/agent", method: "POST", body: Body(messages: history, model: model), timeout: 300)
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from the hub.") }
            if http.statusCode == 401 { api.onUnauthorized?(); throw APIError.unauthorized }
            guard http.statusCode == 200 else {
                var raw = ""
                for try await line in bytes.lines { raw += line }
                let message = (try? JSONDecoder().decode(AgentErrorBody.self, from: Data(raw.utf8)))?.error
                throw APIError(message: message ?? "The hub couldn't answer (\(http.statusCode)). Does it have the agent route yet?")
            }
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = event["t"] as? String else { continue }
                switch kind {
                case "text":
                    if let d = event["d"] as? String { update(id) { $0.text += d } }
                case "tool":
                    let stepID = event["id"] as? String ?? UUID().uuidString
                    let step = AgentStep(id: stepID, label: Self.label(name: event["name"] as? String ?? "", purpose: event["label"] as? String))
                    update(id) { $0.steps.append(step) }
                case "toolDone":
                    let stepID = event["id"] as? String
                    update(id) { m in
                        if let i = m.steps.firstIndex(where: { $0.id == stepID }) { m.steps[i].done = true }
                    }
                case "cost":
                    guard let stepID = event["id"] as? String, let usd = (event["usd"] as? NSNumber)?.doubleValue else { break }
                    let exact = event["exact"] as? Bool ?? false
                    update(id) { m in
                        // An estimate never replaces the exact charge.
                        if m.exact.contains(stepID), !exact { return }
                        m.costs[stepID] = usd
                        if exact { m.exact.insert(stepID) }
                    }
                case "answered":
                    update(id) { m in for i in m.steps.indices { m.steps[i].done = true } }
                    if messages.last?.id == id { sending = false }
                case "error":
                    let m = event["m"] as? String ?? "The agent hit an error."
                    update(id) { $0.text += ($0.text.isEmpty ? "" : "\n\n") + m; $0.failed = true }
                default: break
                }
            }
        } catch is CancellationError {
            update(id) { if $0.text.isEmpty { $0.text = Self.stopped } }
        } catch let error as URLError where error.code == .cancelled {
            update(id) { if $0.text.isEmpty { $0.text = Self.stopped } }
        } catch {
            let message = (error as? APIError)?.message ?? "Can't reach the hub. Check that you're on the tailnet."
            update(id) { $0.text += ($0.text.isEmpty ? "" : "\n\n") + message; $0.failed = true }
        }
        update(id) { m in for i in m.steps.indices { m.steps[i].done = true } }
    }

    private static func label(name: String, purpose: String?) -> String {
        if let purpose, !purpose.isEmpty { return purpose }
        switch name {
        case "queryDatabase": return "Querying your data"
        case "describeSchema": return "Reading the schema"
        case "loadSkill": return "Reading instructions"
        default: return "Using \(name)"
        }
    }
}

enum AgentCost {
    /// "$0.0042" under a cent, "$0.12" above.
    static func format(_ usd: Double) -> String {
        if usd == 0 { return "$0.00" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }
}
