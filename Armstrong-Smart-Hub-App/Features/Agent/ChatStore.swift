import Foundation
import Observation

/// One step the agent took (a tool call), shown as a quiet status row.
struct ToolStep: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case running, done, failed }
    let id: String
    let name: String
    var state: State

    /// Present-tense labels, matching components/agent/chat.tsx.
    var label: String {
        [
            "listDevices": "Checking devices",
            "setDevicePower": "Switching device",
            "setLight": "Adjusting light",
            "pressTvButton": "Pressing TV button",
            "searchMedia": "Searching titles",
            "getMediaStatus": "Checking title",
            "requestMedia": "Requesting title",
            "listDownloads": "Checking downloads",
            "playMedia": "Starting playback",
            "getFinanceSummary": "Reading finances",
            "searchTransactions": "Searching transactions",
            "loadSkill": "Reading instructions",
            "listAutomations": "Checking automations",
            "runAutomation": "Running automation",
            "setAutomationEnabled": "Updating automation",
            "createAutomation": "Creating automation",
            "updateAutomation": "Updating automation",
            "deleteAutomation": "Deleting automation",
            "getCalendarEvents": "Reading calendar",
        ][name] ?? name
    }
}

/// An assistant turn is a sequence of text blocks and tool steps, in order.
enum ChatPart: Identifiable, Equatable, Sendable {
    case text(id: String, String)
    case tool(ToolStep)

    var id: String {
        switch self {
        case .text(let id, _): return "text-\(id)"
        case .tool(let step): return "tool-\(step.id)"
        }
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id: String
    let role: Role
    var parts: [ChatPart]

    var text: String {
        parts.compactMap { if case .text(_, let t) = $0 { return t } else { return nil } }.joined(separator: "\n\n")
    }
}

/// Talks to the same /api/chat endpoint as the web chat, reading the AI SDK's
/// UI message stream (server-sent events) as it arrives.
@MainActor
@Observable
final class ChatStore {
    var messages: [ChatMessage] = []
    var isBusy = false
    var isThinking = false
    var error: String?

    private var task: Task<Void, Never>?

    func send(_ text: String, api: APIClient) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        messages.append(ChatMessage(id: UUID().uuidString, role: .user, parts: [.text(id: "0", trimmed)]))
        stream(api: api)
    }

    /// Re-runs the last turn after an error.
    func retry(api: APIClient) {
        if messages.last?.role == .assistant { messages.removeLast() }
        guard messages.last?.role == .user else { return }
        stream(api: api)
    }

    func stop() {
        task?.cancel()
        task = nil
        isBusy = false
        isThinking = false
    }

    func reset() {
        stop()
        messages = []
        error = nil
    }

    private func stream(api: APIClient) {
        error = nil
        isBusy = true
        isThinking = true
        let history = messages
        task = Task { [weak self] in
            await self?.run(history: history, api: api)
        }
    }

    private struct WirePart: Encodable { let type = "text"; let text: String }
    private struct WireMessage: Encodable { let id: String; let role: String; let parts: [WirePart] }
    private struct Body: Encodable { let messages: [WireMessage] }

    private struct Chunk: Decodable {
        let type: String
        let id: String?
        let delta: String?
        let toolCallId: String?
        let toolName: String?
        let errorText: String?
        let output: OutputProbe?
    }

    /// Only checks whether a tool's output carries an `error` key, like the web chat.
    private struct OutputProbe: Decodable {
        let hasError: Bool
        init(from decoder: Decoder) throws {
            struct Keys: CodingKey {
                var stringValue: String
                init?(stringValue: String) { self.stringValue = stringValue }
                var intValue: Int? { nil }
                init?(intValue: Int) { nil }
            }
            hasError = (try? decoder.container(keyedBy: Keys.self).contains(Keys(stringValue: "error")!)) ?? false
        }
    }

    private func run(history: [ChatMessage], api: APIClient) async {
        // Earlier assistant turns go back as their text; the server rebuilds model messages from these.
        let wire = Body(messages: history.map {
            WireMessage(id: $0.id, role: $0.role.rawValue, parts: [WirePart(text: $0.text)])
        })
        var req = api.request("/api/chat", method: "POST", body: wire, timeout: 180)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let reply = ChatMessage(id: UUID().uuidString, role: .assistant, parts: [])
        messages.append(reply)
        let index = messages.count - 1

        do {
            for try await line in try await api.lines(req) {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
                apply(chunk, at: index)
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }

        if messages.indices.contains(index), messages[index].parts.isEmpty, error == nil, !Task.isCancelled {
            error = "The agent didn't answer. Try again."
        }
        if messages.indices.contains(index), messages[index].parts.isEmpty {
            messages.remove(at: index)
        }
        isBusy = false
        isThinking = false
    }

    private func apply(_ chunk: Chunk, at index: Int) {
        guard messages.indices.contains(index) else { return }
        var parts = messages[index].parts
        switch chunk.type {
        case "text-start":
            isThinking = false
            parts.append(.text(id: chunk.id ?? UUID().uuidString, ""))
        case "text-delta":
            isThinking = false
            let id = chunk.id ?? ""
            if let i = parts.lastIndex(where: { if case .text(let pid, _) = $0 { return pid == id } else { return false } }),
               case .text(_, let existing) = parts[i] {
                parts[i] = .text(id: id, existing + (chunk.delta ?? ""))
            } else {
                parts.append(.text(id: id, chunk.delta ?? ""))
            }
        case "tool-input-start":
            isThinking = false
            if let callId = chunk.toolCallId {
                parts.append(.tool(ToolStep(id: callId, name: chunk.toolName ?? "tool", state: .running)))
            }
        case "tool-output-available", "tool-output-error", "tool-output-denied", "tool-input-error":
            guard let callId = chunk.toolCallId,
                  let i = parts.firstIndex(where: { if case .tool(let s) = $0 { return s.id == callId } else { return false } }),
                  case .tool(var step) = parts[i] else { break }
            let failed = chunk.type != "tool-output-available" || (chunk.output?.hasError ?? false)
            step.state = failed ? .failed : .done
            parts[i] = .tool(step)
        case "start-step":
            isThinking = true
        case "error":
            error = chunk.errorText ?? "The agent hit an error. Try again."
        default:
            break
        }
        messages[index].parts = parts
    }
}
