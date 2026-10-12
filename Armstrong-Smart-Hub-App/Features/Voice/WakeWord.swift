import Foundation
import OnnxRuntimeBindings

/// On-device "Hey Jarvis" detection with openWakeWord (github.com/dscripka/openWakeWord).
///
/// Three small ONNX models run every 80 ms of 16 kHz audio, mirroring the
/// Python reference implementation:
/// 1. melspectrogram: raw samples → 32-bin mel frames (10 ms hop), scaled x/10 + 2
/// 2. embedding_model: the last 76 mel frames → one 96-dim speech embedding
/// 3. hey_jarvis: the last 16 embeddings (~1.3 s) → a score from 0 to 1
///
/// Nothing leaves the device. Audio arrives on the audio thread and is
/// processed on a private serial queue.
nonisolated final class WakeWordDetector: @unchecked Sendable {
    /// openWakeWord's recommended default.
    var threshold: Float = 0.5
    /// Called on the main actor with the score that crossed the threshold.
    var onWake: (@MainActor @Sendable (Float) -> Void)?

    private static let chunk = 1280 // 80 ms at 16 kHz
    private static let melContext = 160 * 3 // extra samples so each chunk yields 8 full frames
    private static let melBins = 32
    private static let embeddingWindow = 76
    private static let embeddingSize = 96
    private static let featureWindow = 16

    private let queue = DispatchQueue(label: "hub.wakeword", qos: .userInitiated)
    private let env: ORTEnv
    private let mel: Model
    private let embedding: Model
    private let wake: Model

    private var samples: [Float] = []
    private var pending = 0
    private var melFrames: [[Float]] = []
    private var features: [[Float]] = []
    private var cooldownUntil = Date.distantPast
    private var enabled = true

    private struct Model {
        let session: ORTSession
        let input: String
        let output: String
    }

    enum LoadError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self { case .missing(let name): "The wake word model \(name) isn't in the app bundle." }
        }
    }

    init() throws {
        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)

        // A closure over the local env, so it doesn't touch a half-initialized self.
        let load = { (name: String) throws -> Model in
            guard let url = Bundle.main.url(forResource: name, withExtension: "onnx") else { throw LoadError.missing(name) }
            let session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
            guard let input = try session.inputNames().first, let output = try session.outputNames().first else {
                throw LoadError.missing(name)
            }
            return Model(session: session, input: input, output: output)
        }
        mel = try load("melspectrogram")
        embedding = try load("embedding_model")
        wake = try load("hey_jarvis_v0.1")
    }

    /// Pauses detection (while a conversation is running) and drops buffered audio.
    func setEnabled(_ on: Bool) {
        queue.async {
            self.enabled = on
            if !on { self.reset() }
        }
    }

    /// Feeds 16 kHz mono samples (Int16 range, as floats).
    func process(_ input: [Float]) {
        queue.async { self.consume(input) }
    }

    private func reset() {
        samples.removeAll(keepingCapacity: true)
        pending = 0
        melFrames.removeAll(keepingCapacity: true)
        features.removeAll(keepingCapacity: true)
    }

    private func consume(_ input: [Float]) {
        guard enabled else { return }
        samples.append(contentsOf: input)
        pending += input.count
        // Keep just enough history for every unprocessed chunk plus its mel context.
        let keep = pending + Self.chunk + Self.melContext
        if samples.count > keep { samples.removeFirst(samples.count - keep) }

        while pending >= Self.chunk {
            pending -= Self.chunk
            let end = samples.count - pending
            let start = max(0, end - Self.chunk - Self.melContext)
            guard end - start == Self.chunk + Self.melContext else { continue }
            do {
                try step(Array(samples[start..<end]))
            } catch {
                #if DEBUG
                print("Wake word step failed:", error)
                #endif
            }
        }
    }

    private func step(_ window: [Float]) throws {
        // 1. Mel frames for this chunk.
        let melOut = try run(mel, window, shape: [1, window.count])
        let frameCount = melOut.count / Self.melBins
        for i in 0..<frameCount {
            let frame = melOut[(i * Self.melBins)..<((i + 1) * Self.melBins)].map { $0 / 10 + 2 }
            melFrames.append(frame)
        }
        if melFrames.count > 120 { melFrames.removeFirst(melFrames.count - 120) }
        guard melFrames.count >= Self.embeddingWindow else { return }

        // 2. One embedding from the latest 76 frames.
        let melWindow = melFrames.suffix(Self.embeddingWindow).flatMap { $0 }
        let emb = try run(embedding, melWindow, shape: [1, Self.embeddingWindow, Self.melBins, 1])
        guard emb.count >= Self.embeddingSize else { return }
        features.append(Array(emb.prefix(Self.embeddingSize)))
        if features.count > 32 { features.removeFirst(features.count - 32) }
        guard features.count >= Self.featureWindow else { return }

        // 3. Score the last 16 embeddings.
        let score = try run(wake, features.suffix(Self.featureWindow).flatMap { $0 }, shape: [1, Self.featureWindow, Self.embeddingSize]).first ?? 0
        let now = Date()
        if score >= threshold, now >= cooldownUntil {
            cooldownUntil = now.addingTimeInterval(2)
            // Start the next detection from a clean slate.
            features.removeAll(keepingCapacity: true)
            let handler = onWake
            Task { @MainActor in handler?(score) }
        }
    }

    private func run(_ model: Model, _ values: [Float], shape: [Int]) throws -> [Float] {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size) }
        let tensor = try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
        let outputs = try model.session.run(withInputs: [model.input: tensor], outputNames: [model.output], runOptions: nil)
        guard let out = try outputs[model.output]?.tensorData() else { return [] }
        let count = out.length / MemoryLayout<Float>.size
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            out.getBytes(buffer.baseAddress!, length: count * MemoryLayout<Float>.size)
            initialized = count
        }
    }
}
