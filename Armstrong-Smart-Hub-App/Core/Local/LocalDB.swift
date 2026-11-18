import Foundation
import SQLite3

/// The app's own database: one SQLite file in the App Group container, so the
/// widgets and extensions can read it too. It replaces the hub's Postgres for
/// everything that no longer lives on a server (see LocalHub).
///
/// Rows come back as `[String: Any]` with JSON-friendly values (Int, Double,
/// String, Data, NSNull), so handlers can hand them straight to JSONSerialization.
/// Times are stored as UTC ISO-8601 text with milliseconds (`LocalDB.iso`), which
/// sorts and compares correctly as plain strings.
nonisolated final class LocalDB: @unchecked Sendable {
    typealias Row = [String: Any]

    static let shared = LocalDB()
    static let appGroup = "group.com.paularmstrong.ArmstrongSmartHubApp"

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// Where the file lives: the shared container when the entitlement is there, else Application Support.
    static var fileURL: URL {
        #if DEBUG
        // Tests point this at a scratch file.
        if let path = ProcessInfo.processInfo.environment["LOCAL_DB_PATH"] { return URL(fileURLWithPath: path) }
        #endif
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("hub.sqlite")
    }

    init(url: URL = LocalDB.fileURL) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            #if DEBUG
            print("LocalDB: couldn't open \(url.path)")
            #endif
        }
        sqlite3_busy_timeout(handle, 3000)
        exec("pragma journal_mode = wal")
        exec("pragma foreign_keys = on")
        LocalSchema.migrate(self)
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: Statements

    /// Runs one or more statements with no parameters (schema, pragmas).
    func exec(_ sql: String) {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            #if DEBUG
            print("LocalDB exec failed:", error.map { String(cString: $0) } ?? "?", sql.prefix(120))
            #endif
            sqlite3_free(error)
        }
    }

    /// Every row a statement returns.
    @discardableResult
    func query(_ sql: String, _ args: [Any?] = []) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                report(sql)
                break
            }
            var row: Row = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                row[name] = column(stmt, i)
            }
            rows.append(row)
        }
        return rows
    }

    /// The first row, if any.
    func one(_ sql: String, _ args: [Any?] = []) -> Row? { query(sql, args).first }

    /// Runs a write and answers how many rows it changed.
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(sql, args) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        if step != SQLITE_DONE && step != SQLITE_ROW { report(sql) }
        return Int(sqlite3_changes(handle))
    }

    /// How many `transaction` calls are open on this thread's hold of the lock; only the outermost begins and commits.
    private var depth = 0

    /// Runs `body` in one transaction: all of it lands, or none of it does when it throws.
    /// Nested calls join the outer transaction.
    func transaction<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        if depth > 0 {
            depth += 1
            defer { depth -= 1 }
            return try body()
        }
        exec("begin immediate")
        depth = 1
        defer { depth = 0 }
        do {
            let value = try body()
            exec("commit")
            return value
        } catch {
            exec("rollback")
            throw error
        }
    }

    // MARK: Plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            report(sql)
            return nil
        }
        for (offset, value) in args.enumerated() {
            let i = Int32(offset + 1)
            switch value {
            case nil, is NSNull: sqlite3_bind_null(stmt, i)
            case let v as Bool: sqlite3_bind_int64(stmt, i, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, i, v)
            case let v as Int32: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, i, v)
            case let v as Float: sqlite3_bind_double(stmt, i, Double(v))
            case let v as NSNumber: sqlite3_bind_double(stmt, i, v.doubleValue)
            case let v as String: sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), Self.transient) }
            case let v as Date: sqlite3_bind_text(stmt, i, Self.iso(v), -1, Self.transient)
            case let v?: sqlite3_bind_text(stmt, i, String(describing: v), -1, Self.transient)
            }
        }
        return stmt
    }

    private func column(_ stmt: OpaquePointer?, _ i: Int32) -> Any {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return Int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
        case SQLITE_TEXT: return String(cString: sqlite3_column_text(stmt, i))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, i))
            guard count > 0, let bytes = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: bytes, count: count)
        default: return NSNull()
        }
    }

    private func report(_ sql: String) {
        #if DEBUG
        print("LocalDB:", String(cString: sqlite3_errmsg(handle)), "—", sql.prefix(160))
        #endif
    }

    // MARK: Values

    nonisolated(unsafe) private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
    private static let isoLock = NSLock()

    /// A time as stored: "2026-11-17T14:03:00.000Z".
    static func iso(_ date: Date) -> String {
        isoLock.lock(); defer { isoLock.unlock() }
        return isoOut.string(from: date)
    }

    /// Reads an ISO-8601 time with or without fractional seconds or a Z.
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        isoLock.lock(); defer { isoLock.unlock() }
        return isoOut.date(from: text) ?? isoPlain.date(from: text)
    }

    /// An incoming time normalized to the stored form; nil when it isn't one.
    static func normalized(_ text: Any?) -> String? {
        (text as? String).flatMap(date).map(iso)
    }

    /// A new lowercase uuid, the form the hub always answered with.
    static func uuid() -> String { UUID().uuidString.lowercased() }

    /// The local calendar day as "YYYY-MM-DD".
    static func day(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Shifts a "YYYY-MM-DD" day by whole days.
    static func addDays(_ day: String, _ delta: Int) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let d = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let shifted = utc.date(byAdding: .day, value: delta, to: d) else { return day }
        return Self.day(shifted, calendar: utc)
    }

    /// JSON text for a value kept in a json column.
    static func json(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard JSONSerialization.isValidJSONObject(value) else {
            // Bare scalars aren't valid top-level objects for isValidJSONObject.
            return (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) }
        }
        return (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A json column read back (NSNull when empty).
    static func parse(_ text: Any?) -> Any {
        guard let text = text as? String, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return value
    }
}
