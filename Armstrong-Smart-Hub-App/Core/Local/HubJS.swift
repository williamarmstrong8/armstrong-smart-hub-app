import Foundation
import JavaScriptCore

/// Runs the hub's own math on the phone. Each script is the hub's pure
/// TypeScript modules bundled by scripts/hub-js/build.mjs, so the numbers match
/// what the hub computed; Swift does the queries (LocalFitness, LocalFinance).
///
/// - fitness.js (`Fitness`): FIT decoding, scores, recovery, check-in models.
/// - finance.js (`Finance`): categories, the dashboard, recurring charges, the goal, investments.
///
/// Every function in a script takes one JSON string and returns one, except
/// the file readers, which take the file's bytes as a Uint8Array.
nonisolated final class HubJS: @unchecked Sendable {
    static let fitness = HubJS(resource: "fitness", object: "Fitness")
    static let finance = HubJS(resource: "finance", object: "Finance")

    private let lock = NSLock()
    private let context: JSContext?
    private let object: String
    private var lastError: String?

    init(resource: String, object: String) {
        self.object = object
        guard let script = Self.bundledScript(resource), let context = JSContext() else {
            self.context = nil
            return
        }
        self.context = context
        context.name = object
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastError = exception?.toString() ?? "JavaScript error"
            #if DEBUG
            print("HubJS:", self?.lastError ?? "")
            #endif
        }
        context.evaluateScript(script)
    }

    static func bundledScript(_ resource: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Calls `<object>.<name>(JSON.stringify(input))` and parses what it returns.
    func call(_ name: String, _ input: Any) -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let fn = context?.objectForKeyedSubscript(object)?.objectForKeyedSubscript(name) else { return nil }
        return Self.parse(fn.call(withArguments: [json]))
    }

    /// Calls `<object>.<name>(bytes, ...rest)` with the bytes as a Uint8Array.
    func call(_ name: String, bytes: Data, _ rest: [Any] = []) -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard let context, let fn = context.objectForKeyedSubscript(object)?.objectForKeyedSubscript(name),
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
