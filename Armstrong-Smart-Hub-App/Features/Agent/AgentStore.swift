import Foundation
import Observation

private struct AgentErrorBody: Decodable { let error: String? }

struct AgentModel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
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
}

/// A conversation with the hub's data agent: Jarvis on the phone, with a SQL view of the stored
/// data. Each turn posts the whole conversation and reads back newline-delimited events.
@MainActor
@Observable
final class AgentStore {
    var messages: [AgentMessage] = []
    var models: [AgentModel] = []
    var sending = false
    /// The chosen model's gateway id; empty until the list loads, then the hub's default.
    var modelID: String = UserDefaults.standard.string(forKey: "agent.model") ?? "" {
        didSet { UserDefaults.standard.set(modelID, forKey: "agent.model") }
    }

    private var task: Task<Void, Never>?

    var model: AgentModel? { models.first { $0.id == modelID } ?? models.first }

    func loadModels(api: APIClient) async {
        guard models.isEmpty else { return }
        struct Reply: Decodable { let models: [AgentModel]; let `default`: String }
        guard let reply: Reply = try? await api.get("/api/mobile/agent") else { return }
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
        messages.append(AgentMessage(role: .user, text: prompt))
        messages.append(AgentMessage(role: .assistant, text: ""))
        sending = true
        let history = messages.dropLast().map { ["role": $0.role.rawValue, "content": $0.text] }
        let model = modelID
        task = Task { [weak self] in
            await self?.run(history: Array(history), model: model, api: api)
            self?.sending = false
        }
    }

    private struct Body: Encodable {
        let messages: [[String: String]]
        let model: String
    }

    private func update(_ change: (inout AgentMessage) -> Void) {
        guard !messages.isEmpty else { return }
        change(&messages[messages.count - 1])
    }

    private func run(history: [[String: String]], model: String, api: APIClient) async {
        let request = api.request("/api/mobile/agent", method: "POST", body: Body(messages: history, model: model), timeout: 300)
        var request2 = request
        request2.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request2)
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
                    if let d = event["d"] as? String { update { $0.text += d } }
                case "tool":
                    let id = event["id"] as? String ?? UUID().uuidString
                    let step = AgentStep(id: id, label: Self.label(name: event["name"] as? String ?? "", purpose: event["label"] as? String))
                    update { $0.steps.append(step) }
                case "toolDone":
                    let id = event["id"] as? String
                    update { m in
                        if let i = m.steps.firstIndex(where: { $0.id == id }) { m.steps[i].done = true }
                    }
                case "error":
                    let m = event["m"] as? String ?? "The agent hit an error."
                    update { $0.text += ($0.text.isEmpty ? "" : "\n\n") + m; $0.failed = true }
                default: break
                }
            }
        } catch is CancellationError {
            update { if $0.text.isEmpty { $0.text = "Stopped." } }
        } catch let error as URLError where error.code == .cancelled {
            update { if $0.text.isEmpty { $0.text = "Stopped." } }
        } catch {
            let message = (error as? APIError)?.message ?? "Can't reach the hub. Check that you're on the tailnet."
            update { $0.text += ($0.text.isEmpty ? "" : "\n\n") + message; $0.failed = true }
        }
        update { m in for i in m.steps.indices { m.steps[i].done = true } }
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
