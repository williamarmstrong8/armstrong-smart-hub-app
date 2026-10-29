import AVFoundation
import Foundation
import Observation
import SwiftUI

/// "Hey Jarvis": the iPad's hands-free agent.
///
/// The wake word runs on-device. When it fires, the app opens a realtime
/// WebSocket straight to the AI Gateway (with a secret the hub minted ahead of
/// time), streams the mic up, and plays Jarvis's voice as it streams back.
/// Function calls go to the hub, whose replies carry the card to show. While
/// the model is still choosing a tool, Jev guesses the screen from the
/// transcript so the UI can morph early.
@MainActor
@Observable
final class VoiceAgent {
    enum Phase: Equatable { case idle, connecting, listening, thinking, speaking }

    private(set) var phase: Phase = .idle
    /// Whether the overlay is up. Stays true through the follow-up window.
    private(set) var presented = false
    /// A card worth the whole screen. Lights aren't: the wall's own light cards already show the
    /// change, so Jarvis stays a small orb in the corner for them.
    var hasCard: Bool {
        guard let kind = view?.kind ?? hint else { return false }
        return kind != .lights
    }
    /// Jarvis has a card to show, so it takes the screen. Until then it's a small orb in the corner.
    var takingOver: Bool { presented && hasCard }
    /// The card on screen, if any.
    private(set) var view: VoiceView?
    /// Bumped whenever a new card lands, so the same kind still re-animates.
    private(set) var viewToken = 0
    /// A screen Jev expects but has no data for yet (movie, finance): shown as a placeholder.
    private(set) var hint: VoiceView.Kind?
    private(set) var heard = ""
    private(set) var reply = ""
    private(set) var notice: String?
    /// The wake word is loaded and the mic is delivering audio to it.
    private(set) var wakeReady = false
    /// Mic permission or the wake word model: needs a fix, not a retry.
    private(set) var setupError: String?
    /// The mic wouldn't start; retried every few seconds.
    private(set) var audioError: String?
    /// The hub couldn't mint a voice session; retried with backoff.
    private(set) var sessionError: String?

    enum Status: Equatable { case starting, ready, noMic(String), offline(String) }

    /// One line for the dashboard: can you say "Hey Jarvis" right now, and if not, why.
    var status: Status {
        if let setupError { return .noMic(setupError) }
        if let audioError { return .noMic(audioError) }
        if !wakeReady { return .starting }
        if let sessionError { return .offline(sessionError) }
        return .ready
    }

    /// Called after a tool changed something, so the dashboard can refresh that section.
    var onAction: ((VoiceView.Kind) -> Void)?

    /// Tools that run here on the iPad instead of on the hub (the wake-up alarm lives in
    /// AlarmKit on this device). Returns nil for a tool it doesn't handle.
    var localTool: ((_ name: String, _ arguments: String) async -> (output: [String: Any], view: VoiceView?)?)?

    private var api: APIClient?
    /// Replaced with a fresh one whenever the mic stops delivering audio.
    private var audio = VoiceAudio()
    private var restartingAudio = false
    private var health: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var detector: WakeWordDetector?
    private var client: RealtimeClient?
    private let pipe = StreamPipe()
    private var prefetched: VoiceSession?
    private var prefetchTask: Task<Void, Never>?
    private var followUp: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var started = false

    // Per-turn bookkeeping.
    private var turn = 0
    private var toolViewThisTurn = false
    private var pendingCalls = 0
    private var responseHadCalls = false
    private var responseFinished = false

    // Watchdog bookkeeping: a conversation that stalls ends itself, so the wake word comes back.
    private var activatedAt = Date.distantPast
    private var lastActivity = Date.distantPast
    private var socketOpen = false
    private var userSpeaking = false

    private static let followUpSeconds: Double = 8
    /// End right after this reply instead of listening for a follow-up (bedtime).
    private var endAfterReply = false

    /// Ends the conversation as soon as Jarvis finishes its current reply.
    func finishAfterReply() { endAfterReply = true }

    // Talking over Jarvis: the mic only sends loud sound while it speaks (VoiceAudio), so its own
    // echo and room noise never reach the service. Anything that does is you: Jarvis stops,
    // listens, and answers.
    private var gate: SocketGate?

    func levels() -> (mic: Float, output: Float) { audio.levels() }

    // MARK: Lifecycle

    func start(api: APIClient) async {
        self.api = api
        guard !started else { return }
        started = true

        guard await AVAudioApplication.requestRecordPermission() else {
            setupError = "Microphone access is off. Turn it on in Settings to use Hey Jarvis."
            return
        }

        do {
            let detector = try WakeWordDetector()
            detector.onWake = { [weak self] _ in self?.activate() }
            self.detector = detector
        } catch {
            setupError = error.localizedDescription
        }

        await startAudio()
        prefetchSession()

        // Every few seconds: is the mic still feeding the wake word? An interruption, the app
        // going to the background, or a route change can leave it silent with no error.
        health?.cancel()
        health = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await self?.checkHealth()
            }
        }
    }

    func stop() {
        end(immediately: true)
        health?.cancel()
        audio.stop()
        prefetchTask?.cancel()
        started = false
        wakeReady = false
    }

    /// The app came back to the front: check the mic now and get a voice session if there isn't one.
    func resume() {
        guard started else { return }
        Task { await checkHealth() }
        if prefetched?.isFresh != true { prefetchSession() }
    }

    // MARK: Audio

    private func startAudio() async {
        let fresh = VoiceAudio()
        let detector = detector
        let pipe = pipe
        fresh.onWakeAudio = { samples in detector?.process(samples) }
        fresh.onStreamAudio = { data in pipe.send(data) }
        do {
            // Activating the audio session blocks, so keep it off the main thread.
            try await Task.detached(priority: .userInitiated) { try fresh.start() }.value
            audio = fresh
            audioError = nil
            wakeReady = detector != nil
        } catch {
            audioError = "Couldn't start the microphone: \(error.localizedDescription)"
            wakeReady = false
        }
    }

    /// Tears the mic down and builds it again from scratch.
    private func restartAudio() async {
        guard !restartingAudio else { return }
        restartingAudio = true
        defer { restartingAudio = false }
        let old = audio
        await Task.detached(priority: .userInitiated) { old.stop() }.value
        await startAudio()
    }

    private func checkHealth() async {
        // Never swap the mic out from under a conversation.
        guard started, setupError == nil, phase == .idle, !presented else { return }
        if !audio.micIsFlowing {
            wakeReady = false
            await restartAudio()
        } else if !wakeReady, detector != nil {
            wakeReady = true
        }
    }

    /// Tap-to-talk, and dismissing by tapping away.
    func toggle() {
        if presented { end() } else { activate() }
    }

    // MARK: Session tokens

    /// Keeps one single-use secret ready so the socket can open the moment the wake word fires.
    /// Failures retry quickly at first, backing off to a minute, and right away when the hub or
    /// the network comes back.
    private func prefetchSession() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            var backoff: Double = 5
            while !Task.isCancelled {
                guard let self, let api = self.api else { return }
                do {
                    let session: VoiceSession = try await api.post("/api/mobile/voice/session")
                    self.prefetched = session
                    self.sessionError = nil
                    backoff = 5
                    // Refresh a little before it expires.
                    let wait = max(30, session.expiresAt - Date().timeIntervalSince1970 - 90)
                    try await Task.sleep(for: .seconds(wait))
                } catch is CancellationError {
                    return
                } catch {
                    self.sessionError = error.localizedDescription
                    await HubLink.shared.wait(backoff)
                    backoff = min(backoff * 2, 60)
                }
            }
        }
    }

    private func takeSession() async throws -> VoiceSession {
        if let s = prefetched, s.isFresh {
            prefetched = nil
            prefetchSession()
            return s
        }
        guard let api else { throw APIError(message: "Not signed in.") }
        // One retry: the wake word often fires right as the tailnet wakes up.
        let s: VoiceSession
        do {
            s = try await api.post("/api/mobile/voice/session")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await Task.sleep(for: .seconds(1))
            s = try await api.post("/api/mobile/voice/session")
        }
        sessionError = nil
        prefetchSession()
        return s
    }

    // MARK: Conversation

    func activate() {
        guard phase == .idle else { return }
        followUp?.cancel()
        followUp = nil
        notice = nil
        endAfterReply = false
        activatedAt = .now
        lastActivity = .now
        socketOpen = false
        userSpeaking = false
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.presented else { return }
                self.watch()
            }
        }
        heard = ""
        reply = ""
        hint = nil
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
            presented = true
            phase = .connecting
            view = nil
        }
        detector?.setEnabled(false)
        // Mic audio (from just before the wake word) buffers until the socket opens.
        pipe.reset()
        audio.beginStreaming()
        beginTurn()

        Task {
            do {
                let session = try await takeSession()
                guard phase != .idle, let url = URL(string: session.url) else { return }
                connect(url: url, session: session)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func connect(url: URL, session: VoiceSession) {
        let client = RealtimeClient()
        let config = session.config
        let pipe = pipe
        client.onOpen = { [weak client, weak self] in
            client?.updateSession(config.value)
            pipe.open(client)
            Task { @MainActor in self?.socketOpen = true }
        }
        // Events must be handled in the order they arrive (a tool call before its
        // response-done), so they go through one stream instead of a Task each.
        // Audio is queued right here on the socket's serial queue, in order and
        // without waiting on the main thread.
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        let audio = audio
        let gate = SocketGate()
        self.gate = gate
        client.onEvent = { event in
            switch event.type {
            case "response-created":
                gate.startResponse()
            case "audio-delta", "audio-chunk":
                if !gate.dropAudio, let delta = event.delta, let data = Data(base64Encoded: delta) {
                    audio.play(pcm16: data)
                }
            default:
                break
            }
            continuation.yield(event)
        }
        client.onClose = { reason in
            gate.closeReason = reason
            continuation.finish()
        }
        events?.cancel()
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
            self?.socketClosed(gate.closeReason)
        }
        self.client = client
        client.connect(url: url, token: session.token)
        withAnimation(.easeOut(duration: 0.3)) { phase = .listening }
    }

    private func beginTurn() {
        turn += 1
        toolViewThisTurn = false
        responseHadCalls = false
        responseFinished = false
    }

    private func handle(_ event: RealtimeEvent) {
        guard phase != .idle else { return }
        lastActivity = .now
        switch event.type {
        case "speech-started":
            // Talking over Jarvis stops it mid-sentence; drop the rest of that reply.
            if audio.isPlaying || phase == .speaking {
                gate?.dropCurrent()
                audio.flushPlayback()
                client?.cancelResponse()
            }
            interrupted()

        case "speech-stopped":
            userSpeaking = false
            withAnimation(.easeOut(duration: 0.25)) { phase = .thinking }

        case "input-transcription-completed":
            let text = (event.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.2)) { heard = text }
            route(text, turn: turn)

        case "response-created":
            responseHadCalls = false
            responseFinished = false
            reply = ""

        case "audio-delta", "audio-chunk":
            // Already queued for playback on the socket's queue.
            if phase != .speaking { withAnimation(.easeOut(duration: 0.2)) { phase = .speaking } }

        case "audio-transcript-delta", "text-delta":
            reply += event.delta ?? ""

        case "function-call-arguments-done":
            guard let callId = event.callId, let name = event.name else { return }
            call(name, callId: callId, arguments: event.arguments ?? "{}")

        case "response-done":
            if responseHadCalls {
                responseFinished = true
                if pendingCalls == 0 { client?.createResponse() }
            } else {
                scheduleFollowUp()
            }

        case "error":
            let message = event.message ?? "Something went wrong."
            // Harmless races, e.g. cancelling a response that already finished.
            if event.code == "response_cancel_not_active" { return }
            notice = message

        default:
            break
        }
    }

    private func call(_ name: String, callId: String, arguments: String) {
        responseHadCalls = true
        pendingCalls += 1
        if phase != .speaking { withAnimation { phase = .thinking } }

        Task {
            defer {
                pendingCalls -= 1
                if pendingCalls == 0, responseFinished { client?.createResponse() }
            }
            let output: String
            if let refusal = guardCall(name, arguments: arguments) {
                output = refusal
            } else if let local = await localTool?(name, arguments) {
                if let v = local.view {
                    toolViewThisTurn = true
                    show(v)
                }
                output = JSONObject(local.output).jsonString
            } else {
                do {
                    guard let api else { return }
                    struct Body: Encodable { let name: String; let arguments: String }
                    let result: VoiceToolReply = try await api.send(
                        api.request("/api/mobile/voice/tool", method: "POST", body: Body(name: name, arguments: arguments), timeout: 60)
                    )
                    if let v = result.view {
                        toolViewThisTurn = true
                        show(v)
                        if !name.hasPrefix("show"), name != "findTitle" {
                            onAction?(v.kind)
                        }
                    }
                    output = result.output.jsonString
                } catch {
                    output = JSONObject(["error": error.localizedDescription]).jsonString
                }
            }
            client?.sendToolOutput(callId: callId, name: name, output: output)
        }
    }

    /// Downloads only go through for the title whose poster is on screen awaiting a yes, and
    /// Pi services only change with the Pi on screen.
    private func guardCall(_ name: String, arguments: String) -> String? {
        if name == "controlPi" {
            if case .pi = view { return nil }
            return JSONObject(["error": "Not confirmed. Call showPi, ask, and only change a service after a clear yes."]).jsonString
        }
        guard name == "downloadTitle" else { return nil }
        struct Args: Decodable { let id: Int }
        let id = (try? JSONDecoder().decode(Args.self, from: Data(arguments.utf8)))?.id
        if case .movie(let movie, .confirm) = view, movie.id == id { return nil }
        return JSONObject(["error": "Not confirmed. Call findTitle to show the poster, ask, and only download after a clear yes."]).jsonString
    }

    /// Jev's head start: morph to the likely screen while the model picks a tool.
    private func route(_ transcript: String, turn: Int) {
        guard let api else { return }
        Task {
            struct Body: Encodable { let transcript: String }
            guard let r: VoiceIntentReply = try? await api.post("/api/mobile/voice/intent", body: Body(transcript: transcript)),
                  turn == self.turn, !toolViewThisTurn, phase != .idle else { return }
            if let v = r.view {
                // Don't swap a card that's mid-conversation (e.g. the movie awaiting a yes) for a guess.
                if view == nil || view?.kind != v.kind { show(v) }
            } else if let kind = VoiceView.Kind(rawValue: r.screen), view?.kind != kind {
                withAnimation(.spring(duration: 0.5, bounce: 0.15)) { hint = kind }
            }
        }
    }

    private func show(_ v: VoiceView) {
        withAnimation(.spring(duration: 0.6, bounce: 0.18)) {
            hint = nil
            view = v
            viewToken += 1
        }
    }

    /// You started talking (for real): Jarvis stops and listens.
    private func interrupted() {
        followUp?.cancel()
        followUp = nil
        userSpeaking = true
        beginTurn()
        reply = ""
        withAnimation(.easeOut(duration: 0.25)) { phase = .listening }
    }

    /// After Jarvis finishes speaking, keep listening briefly for a follow-up.
    private func scheduleFollowUp() {
        followUp?.cancel()
        followUp = Task {
            while audio.isPlaying {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            if endAfterReply { return end() }
            withAnimation(.easeOut(duration: 0.3)) { phase = .listening }
            try? await Task.sleep(for: .seconds(Self.followUpSeconds))
            if Task.isCancelled { return }
            end()
        }
    }

    /// Once a second while the overlay is up: end a conversation that has stalled, so the
    /// overlay never hangs open with the wake word switched off.
    private func watch() {
        guard notice == nil else { return } // Already failing; it ends itself.
        let now = Date.now
        let quiet = now.timeIntervalSince(lastActivity)
        switch phase {
        case .idle:
            return
        case .connecting:
            if now.timeIntervalSince(activatedAt) > 12 { fail("Couldn't reach the voice service. Try again in a moment.") }
        case .listening:
            if !socketOpen {
                if now.timeIntervalSince(activatedAt) > 12 { fail("Couldn't reach the voice service. Try again in a moment.") }
            } else if followUp == nil, !audio.isPlaying, quiet > (userSpeaking ? 60 : 12) {
                // Woken by mistake, or nothing more to say.
                end()
            }
        case .thinking:
            if quiet > (pendingCalls > 0 ? 75 : 30) { fail("Jarvis stopped answering. Try again.") }
        case .speaking:
            if !audio.isPlaying, quiet > 15, followUp == nil { scheduleFollowUp() }
        }
    }

    private func socketClosed(_ reason: String?) {
        guard phase != .idle else { return }
        if view == nil, reply.isEmpty { notice = "Lost the connection to the voice service." }
        end()
    }

    private func fail(_ message: String) {
        notice = message
        followUp?.cancel()
        followUp = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { end() }
        }
    }

    /// Closes the overlay and cancels the conversation: the socket closes and anything Jarvis
    /// was still saying stops at once.
    func end(immediately: Bool = false) {
        audio.flushPlayback()
        followUp?.cancel()
        followUp = nil
        watchdog?.cancel()
        watchdog = nil
        gate = nil
        userSpeaking = false
        audio.endStreaming()
        pipe.reset()
        client?.close()
        client = nil
        events?.cancel()
        events = nil
        pendingCalls = 0
        detector?.setEnabled(true)
        guard presented || phase != .idle else { return }
        withAnimation(.smooth(duration: immediately ? 0.2 : 0.6)) {
            phase = .idle
            presented = false
        }
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            if !presented {
                view = nil
                hint = nil
                heard = ""
                reply = ""
            }
        }
    }
}

/// State shared between the socket's queue (which plays audio as it arrives) and the main actor
/// (which decides what counts as an interruption).
nonisolated private final class SocketGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _dropAudio = false
    private var _closeReason: String?

    var dropAudio: Bool { lock.withLock { _dropAudio } }
    var closeReason: String? {
        get { lock.withLock { _closeReason } }
        set { lock.withLock { _closeReason = newValue } }
    }

    /// A new reply plays.
    func startResponse() { lock.withLock { _dropAudio = false } }

    /// A real interruption: drop what's left of the reply in flight.
    func dropCurrent() { lock.withLock { _dropAudio = true } }
}

/// Hands mic audio from the audio thread to the socket, holding it until the socket opens.
nonisolated private final class StreamPipe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var client: RealtimeClient?
    private var buffered: [Data] = []

    // Sends happen under the lock so the backlog always goes out before live audio.
    func send(_ data: Data) {
        lock.withLock {
            if let client {
                client.appendAudio(data)
            } else {
                buffered.append(data)
                // Never hold more than ~10 s if the socket is slow to open.
                if buffered.count > 500 { buffered.removeFirst() }
            }
        }
    }

    func open(_ client: RealtimeClient?) {
        lock.withLock {
            self.client = client
            // Coalesce the backlog into a few larger frames.
            var chunk = Data()
            for d in buffered {
                chunk.append(d)
                if chunk.count >= 48_000 { client?.appendAudio(chunk); chunk = Data() }
            }
            if !chunk.isEmpty { client?.appendAudio(chunk) }
            buffered = []
        }
    }

    func reset() {
        lock.withLock {
            client = nil
            buffered = []
        }
    }
}
