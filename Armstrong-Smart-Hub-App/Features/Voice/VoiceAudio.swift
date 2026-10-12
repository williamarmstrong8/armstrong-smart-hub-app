import AVFoundation
import Foundation

/// The microphone and speaker for the voice agent, on one AVAudioEngine with
/// Apple's voice processing (echo cancellation) on, so Jarvis doesn't hear
/// itself and you can talk over it.
///
/// The mic is always open while the dashboard is up. Each buffer is converted
/// to 16 kHz for the wake word and, while a conversation is live, to 24 kHz
/// PCM16 for the realtime socket. Jarvis's reply arrives as 24 kHz PCM16
/// chunks and plays through a player node as it streams in.
nonisolated final class VoiceAudio: @unchecked Sendable {
    /// 16 kHz samples in Int16 range, for the wake word.
    var onWakeAudio: (@Sendable ([Float]) -> Void)?
    /// 24 kHz little-endian PCM16, for the socket. Only called while streaming.
    var onStreamAudio: (@Sendable (Data) -> Void)?

    /// Smoothed 0...1 levels for the orb.
    private(set) var micLevel: Float = 0
    private(set) var outputLevel: Float = 0

    static let streamRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var wakeConverter: AVAudioConverter?
    private var streamConverter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let wakeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let streamFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: streamRate, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: streamRate, channels: 1, interleaved: false)!

    private var streaming = false
    /// The last ~300 ms of 24 kHz audio, so the first word after "Jarvis" isn't clipped.
    private var preroll = Data()
    private static let prerollBytes = Int(streamRate * 0.3) * 2
    private var queuedBuffers = 0

    var isPlaying: Bool { lock.withLock { queuedBuffers > 0 } }
    var isRunning: Bool { engine.isRunning }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // voiceChat is the mode Apple's echo cancellation expects; it can't run in a mixable session.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let input = engine.inputNode
        // Echo cancellation, so Jarvis doesn't hear itself. Some routes (and the
        // simulator) can't do it and leave the mic with a 0 Hz format, so check
        // and fall back to the plain mic rather than crash installing the tap.
        var usable = false
        if (try? input.setVoiceProcessingEnabled(true)) != nil {
            // Keep other audio (the TV, music) at full volume instead of ducking it.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            usable = Self.isUsable(input.outputFormat(forBus: 0))
        }
        if !usable {
            try? input.setVoiceProcessingEnabled(false)
            usable = Self.isUsable(input.outputFormat(forBus: 0))
        }
        guard usable else { throw AudioError.noMicrophone }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        installMicTap()

        // Turning echo cancellation on (or a route change) reconfigures the engine,
        // which stops it. Start it again whenever that happens.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restart()
        }

        engine.prepare()
        try engine.start()
        player.play()
    }

    private var configObserver: NSObjectProtocol?

    /// Taps the mic in whatever format it currently delivers (nil = the node's own),
    /// so a format change can never make the tap throw.
    private func installMicTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        guard Self.isUsable(input.outputFormat(forBus: 0)) else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
    }

    private func restart() {
        guard !engine.isRunning else { return }
        installMicTap()
        engine.prepare()
        do {
            try engine.start()
            player.play()
        } catch {
            #if DEBUG
            print("Voice audio restart failed:", error)
            #endif
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Starts forwarding mic audio to `onStreamAudio`, beginning with the pre-roll.
    func beginStreaming() {
        let head: Data = lock.withLock {
            streaming = true
            let d = preroll
            preroll = Data()
            return d
        }
        if !head.isEmpty { onStreamAudio?(head) }
    }

    func endStreaming() {
        lock.withLock { streaming = false }
    }

    /// Queues a chunk of Jarvis's reply (24 kHz PCM16).
    func play(pcm16 data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        let level = Self.level(buffer)
        lock.withLock {
            queuedBuffers += 1
            outputLevel = outputLevel * 0.5 + level * 0.5
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                self.queuedBuffers = max(0, self.queuedBuffers - 1)
                if self.queuedBuffers == 0 { self.outputLevel = 0 }
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// Drops whatever is still queued (you started talking over Jarvis).
    func flushPlayback() {
        player.stop()
        lock.withLock {
            queuedBuffers = 0
            outputLevel = 0
        }
        player.play()
    }

    /// Reads the smoothed levels; call from the UI's display loop.
    func levels() -> (mic: Float, output: Float) {
        lock.withLock { (micLevel, outputLevel) }
    }

    enum AudioError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "No microphone is available." }
    }

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    // MARK: Mic

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(buffer)
        lock.withLock { micLevel = micLevel * 0.6 + level * 0.4 }

        if converterInput != buffer.format {
            converterInput = buffer.format
            wakeConverter = AVAudioConverter(from: buffer.format, to: wakeFormat)
            streamConverter = AVAudioConverter(from: buffer.format, to: streamFormat)
        }

        if let wake = convert(buffer, with: wakeConverter, to: wakeFormat), let ch = wake.floatChannelData?[0] {
            let samples = (0..<Int(wake.frameLength)).map { ch[$0] * 32767 }
            onWakeAudio?(samples)
        }

        guard let stream = convert(buffer, with: streamConverter, to: streamFormat), let ch = stream.int16ChannelData?[0] else { return }
        let data = Data(bytes: ch, count: Int(stream.frameLength) * 2)
        let live: Bool = lock.withLock {
            if streaming { return true }
            preroll.append(data)
            if preroll.count > Self.prerollBytes { preroll.removeFirst(preroll.count - Self.prerollBytes) }
            return false
        }
        if live { onStreamAudio?(data) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// RMS of the first channel, mapped to a gentle 0...1 curve.
    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let f = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += f[i] * f[i] }
        } else if let s = buffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(s[i]) / 32768; sum += v * v }
        }
        let rms = (sum / Float(n)).squareRoot()
        // About -50 dB → 0, -10 dB → 1.
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }
}
