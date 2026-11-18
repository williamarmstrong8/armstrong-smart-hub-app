import Foundation
import JavaScriptCore

/// Runs the hub's fitness math on the phone: fitness.js is the hub's own
/// lib/fitness modules (FIT decoding, scores, recovery, check-in models),
/// bundled by scripts/fitness-js/build.mjs, so every number matches what the
/// hub computed. Swift does the queries (LocalFitness); this does the math.
///
/// Every function in the script takes one JSON string and returns one, except
/// the file readers, which take the file's bytes as a Uint8Array.
nonisolated final class FitnessJS: @unchecked Sendable {
    static let shared = FitnessJS()

    private let lock = NSLock()
    private let context: JSContext?
    private var lastError: String?

    init(script: String? = FitnessJS.bundledScript()) {
        guard let script, let context = JSContext() else {
            self.context = nil
            return
        }
        self.context = context
        context.name = "Fitness"
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastError = exception?.toString() ?? "JavaScript error"
            #if DEBUG
            print("FitnessJS:", self?.lastError ?? "")
            #endif
        }
        context.evaluateScript(script)
    }

    static func bundledScript() -> String? {
        guard let url = Bundle.main.url(forResource: "fitness", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Calls `Fitness.<name>(JSON.stringify(input))` and parses what it returns.
    func call(_ name: String, _ input: Any) -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let fn = context?.objectForKeyedSubscript("Fitness")?.objectForKeyedSubscript(name) else { return nil }
        return Self.parse(fn.call(withArguments: [json]))
    }

    /// Calls `Fitness.<name>(bytes, ...rest)` with the bytes as a Uint8Array.
    func call(_ name: String, bytes: Data, _ rest: [Any] = []) -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard let context, let fn = context.objectForKeyedSubscript("Fitness")?.objectForKeyedSubscript(name),
              let array = Self.uint8Array(bytes, in: context) else { return nil }
        return Self.parse(fn.call(withArguments: [array] + rest))
    }

    private static func parse(_ value: JSValue?) -> Any? {
        guard let value, value.isString, let text = value.toString(), let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// A Uint8Array over a copy of the bytes, freed when JavaScript lets go of it.
    private static func uint8Array(_ data: Data, in context: JSContext) -> JSValue? {
        let count = data.count
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 8)
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: count)
        var exception: JSValueRef?
        let object = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, buffer, count,
            { bytes, _ in bytes?.deallocate() }, nil, &exception)
        guard let object, exception == nil else {
            buffer.deallocate()
            return nil
        }
        return JSValue(jsValueRef: object, in: context)
    }
}
