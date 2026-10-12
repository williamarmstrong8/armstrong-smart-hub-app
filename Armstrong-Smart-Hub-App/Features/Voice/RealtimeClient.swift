import Foundation

/// One event from the realtime model, in the AI SDK's normalized realtime
/// protocol (the Gateway translates the provider's own events into these).
/// Only the fields the app reads are decoded.
nonisolated struct RealtimeEvent: Decodable, Sendable {
    let type: String
    let delta: String?
    let transcript: String?
    let callId: String?
    let name: String?
    let arguments: String?
    let itemId: String?
    let responseId: String?
    let status: String?
    let message: String?
    let code: String?
}

/// A bidirectional WebSocket to the AI Gateway's realtime endpoint.
///
/// Auth rides the WebSocket subprotocols (`ai-gateway-auth.<secret>`), exactly
/// like the AI SDK's browser client, using the short-lived secret the hub
/// minted. Mic audio goes up as base64 PCM16 in `input-audio-append`; speech,
/// transcripts and function calls come back as events.
nonisolated final class RealtimeClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (@Sendable () -> Void)?
    var onEvent: (@Sendable (RealtimeEvent) -> Void)?
    var onClose: (@Sendable (String?) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var closed = false

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect(url: URL, token: String) {
        let task = session.webSocketTask(with: url, protocols: ["ai-gateway-realtime.v1", "ai-gateway-auth.\(token)"])
        task.maximumMessageSize = 16 * 1024 * 1024
        lock.withLock {
            self.task = task
            closed = false
        }
        task.resume()
        receive()
    }

    func close() {
        let t: URLSessionWebSocketTask? = lock.withLock {
            closed = true
            let t = task
            task = nil
            return t
        }
        t?.cancel(with: .normalClosure, reason: nil)
        // The session retains its delegate; let both go.
        session.finishTasksAndInvalidate()
    }

    // MARK: Client events

    func updateSession(_ config: [String: Any]) { send(["type": "session-update", "config": config]) }

    func appendAudio(_ pcm16: Data) { send(["type": "input-audio-append", "audio": pcm16.base64EncodedString()]) }

    func sendToolOutput(callId: String, name: String, output: String) {
        send(["type": "conversation-item-create", "item": ["type": "function-call-output", "callId": callId, "name": name, "output": output]])
    }

    func createResponse() { send(["type": "response-create"]) }

    func cancelResponse() { send(["type": "response-cancel"]) }

    private func send(_ event: [String: Any]) {
        guard let task = lock.withLock({ closed ? nil : task }),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            #if DEBUG
            if let error { print("Realtime send failed:", error.localizedDescription) }
            #endif
        }
    }

    // MARK: Receiving

    private func receive() {
        guard let task = lock.withLock({ self.task }) else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let data: Data? = switch message {
                case .string(let s): s.data(using: .utf8)
                case .data(let d): d
                @unknown default: nil
                }
                if let data, let event = try? self.decoder.decode(RealtimeEvent.self, from: data) {
                    self.onEvent?(event)
                }
                self.receive()
            case .failure(let error):
                self.finish(reason: error.localizedDescription)
            }
        }
    }

    private func finish(reason: String?) {
        let wasOpen: Bool = lock.withLock {
            let open = !closed
            closed = true
            task = nil
            return open
        }
        if wasOpen { onClose?(reason) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(reason: reason.flatMap { String(data: $0, encoding: .utf8) })
    }
}
