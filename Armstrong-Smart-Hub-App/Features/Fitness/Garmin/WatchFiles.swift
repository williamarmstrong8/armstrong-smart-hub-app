import Foundation
import Observation
import UIKit

/// Copies FIT files from the watch to the phone: activities, all-day
/// monitoring and sleep. Towards the watch it lists, downloads and, once the
/// hub has a file, marks it synced as Garmin Connect does; it never archives
/// or deletes anything.
///
/// The flow is a port of the Pi collector's fetch_fit.py (FileTransfer and
/// FileSync, after Gadgetbridge; AGPL-3.0-or-later). WatchLink hands every
/// inbound message to `handle` first, so transfer chunks get their own ACKs
/// instead of the generic one.
@MainActor
@Observable
final class WatchFiles {
    struct Summary: Equatable {
        var listed: Int
        var byKind: [String: Int]
        var downloaded: Int
        var uploaded: Int
        var failed: String?
        var finishedAt: Date
    }

    private(set) var isSyncing = false
    private(set) var progress: String?
    /// 0...1 while a sync runs; nil when idle.
    private(set) var fraction: Double?
    private(set) var lastSync: Summary?
    let store = FitStore()

    /// Newest files fetched per sync, so a first sync of a full watch is gradual.
    var perSyncLimit = 25
    private let maxFileBytes = 4 * 1024 * 1024
    private let idleTimeout: TimeInterval = 15

    weak var link: WatchLink?

    // Protobuf requests waiting for their reply, by request id.
    private var pending: [UInt16: [UInt8]] = [:]
    private var inbox: [Protobuf.Fields] = []
    /// Replies to our requests from services other than file sync, as whole Smart messages.
    private var smartInbox: [Protobuf.Fields] = []
    /// Files the watch announced with a NewFileNotification during this sync.
    private var announced: [GarminFiles.ListedFile] = []
    private var nextRequestID: UInt16 = 0xC000
    private var lastProgress = Date()
    /// When the watch last asked for a sync on its own, to pace automatic requests.
    private var lastWatchRequest = Date.distantPast

    // The legacy transfer in flight.
    private var legacy: GarminFiles.LegacyDownload?
    private var legacyError: FileError?

    // The 0x2018 stream in flight.
    private var streamHandle: UInt8?
    private var stream: [UInt8]?
    private var streamClosed = false
    private var streamError: FileError?

    // MARK: Sync

    /// Copies new files off the watch, then sends everything the hub doesn't have yet.
    func sync(api: APIClient) async {
        guard !isSyncing, let link else { return }
        isSyncing = true
        fraction = 0.02
        defer {
            isSyncing = false
            progress = nil
            fraction = nil
            reset()
        }
        var listed: [GarminFiles.ListedFile] = []
        var downloaded = 0
        var uploaded = 0
        var failure: String?
        if link.state == .connected { do {
            progress = "Reading the watch's directory"
            fraction = 0.05
            // Makes the watch flush pending data, as Gadgetbridge does before every sync.
            let directory = try await downloadLegacy(GarminFiles.directoryIndex, maxBytes: 256 * 1024)
            link.note("Legacy directory: \(GarminFiles.directoryFITCount(directory)) FIT files")
            link.note("Legacy directory bytes: \(directory.prefix(512).map { String(format: "%02x", $0) }.joined())") // DIAGNOSTIC
            // The flush can make the watch announce new files; give it a moment.
            try? await Task.sleep(for: .seconds(2))

            progress = "Asking the watch for today"
            fraction = 0.1
            await askForToday()

            progress = "Listing files"
            fraction = 0.15
            listed = try await listFiles()
            store.saveListing(listed)
            noteToday(listed)
            await probeListing() // DIAGNOSTIC: remove once health files arrive

            let wanted = listed
                .filter { GarminFiles.healthKinds.contains($0.kind) && $0.size <= maxFileBytes && store.needsDownload($0) }
                // Sleep, HRV and metrics first so the many monitoring files can't use up the
                // per-sync limit; newest first within each kind.
                .sorted {
                    let (a, b) = (Self.priority($0.kind), Self.priority($1.kind))
                    return a != b ? a < b : ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
                }
                .prefix(perSyncLimit)
            for (number, file) in wanted.enumerated() {
                progress = "Downloading \(file.kind.replacingOccurrences(of: "_", with: " ")) \(number + 1) of \(wanted.count)"
                fraction = 0.2 + 0.65 * Double(number) / Double(max(wanted.count, 1))
                do {
                    let refresh = store.saved[file.id] != nil
                    let data = try await download(file)
                    try store.save(file, data: data)
                    downloaded += 1
                    link.note("Saved \(file.kind)\(refresh ? " again (it grew)" : "") (\(data.count) bytes, FIT \(GarminFiles.isFIT(data) ? "valid" : "INVALID"))")
                } catch {
                    // One bad file shouldn't stop the rest; a lost connection does.
                    link.note("Skipped \(file.kind): \(error.localizedDescription)")
                    failure = failure ?? "\(file.kind): \(error.localizedDescription)"
                    if link.state != .connected { throw error }
                }
            }
        } catch {
            failure = error.localizedDescription
            link.note("Sync stopped: \(failure!)")
        } }
        // Whatever made it onto the phone goes to the hub, even after a watch error.
        fraction = 0.9
        do {
            await postLive(api: api)
            uploaded = try await upload(api: api)
        } catch is CancellationError {
        } catch {
            failure = failure ?? error.localizedDescription
            link.note("Upload stopped: \(error.localizedDescription)")
        }
        if link.state == .connected { await markSynced(listed) }
        lastSync = Summary(listed: listed.count, byKind: Dictionary(grouping: listed, by: \.kind).mapValues(\.count),
                           downloaded: downloaded, uploaded: uploaded, failed: failure, finishedAt: .now)
        // The hub has parsed what was just sent; put its sleep, HRV and training numbers on the glances.
        progress = "Updating the glances"
        fraction = 0.97
        await link.settings.push(api: api)
    }

    // MARK: Watch-initiated sync

    /// The watch asks for a sync after a workout or sleep, on its own schedule,
    /// or from its menu, as it does with Garmin Connect. A manual request runs
    /// straight away; automatic ones at most every 10 minutes. It runs in the
    /// background too: the request's packet wakes the app, and the background
    /// task keeps it awake for the few small files it brings.
    func watchAskedForSync(manual: Bool) {
        guard let api = link?.api, !isSyncing else { return }
        if !manual, Date.now.timeIntervalSince(lastWatchRequest) < 10 * 60 { return }
        lastWatchRequest = .now
        link?.note("Syncing because the watch asked (\(manual ? "manual" : "automatic"))")
        Task {
            let task = UIApplication.shared.beginBackgroundTask(withName: "Watch sync")
            defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
            await sync(api: api)
        }
    }

    // MARK: Marking synced

    /// Sets the synced flag on every listed file the hub has stored, so the
    /// watch treats it as Garmin Connect's: it can start a fresh all-day file
    /// rather than keeping one open until midnight. Only files safely on the
    /// hub are marked; a refusal is logged and tried again next sync.
    private func markSynced(_ listed: [GarminFiles.ListedFile]) async {
        let ready = listed.filter { store.saved[$0.id]?.uploadedAt != nil && store.saved[$0.id]?.markedSyncedAt == nil }
        guard !ready.isEmpty else { return }
        progress = "Marking \(ready.count) file\(ready.count == 1 ? "" : "s") synced"
        var marked = 0
        for file in ready {
            guard link?.state == .connected, let body = GarminFiles.markSyncedRequest(file.entry) else { break }
            do {
                let reply = try await request(body, answer: 16)
                let status = GarminFiles.modifyFlagsStatus(reply) ?? 0
                guard status == 0 else {
                    link?.note("Watch wouldn't mark \(file.kind) synced (status \(status))")
                    continue
                }
                store.markSyncedOnWatch(file.id)
                marked += 1
            } catch {
                link?.note("Marking \(file.kind) synced stopped: \(error.localizedDescription)")
                break
            }
        }
        link?.note("Marked \(marked) of \(ready.count) files synced on the watch")
    }

    // MARK: Hub

    private struct UploadResult: Decodable {
        var duplicate: Bool?
        var parsed: Bool?
        var error: String?
    }

    /// Sends saved files the hub hasn't acknowledged, oldest first. The hub
    /// ignores files it already has, so a retry is harmless.
    private func upload(api: APIClient) async throws -> Int {
        var count = 0
        for item in store.saved.values.filter({ $0.uploadedAt == nil }).sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            progress = "Sending to the hub (\(count + 1))"
            guard let data = try? Data(contentsOf: store.url(item)) else { continue }
            var query = URLComponents()
            query.queryItems = [
                URLQueryItem(name: "id", value: item.id),
                URLQueryItem(name: "kind", value: item.kind),
                URLQueryItem(name: "tz", value: String(TimeZone.current.secondsFromGMT())),
            ] + (item.date.map { [URLQueryItem(name: "recordedAt", value: $0.formatted(.iso8601))] } ?? [])
            var request = api.request("/api/mobile/fitness?\(query.percentEncodedQuery ?? "")", method: "POST", timeout: 120)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            let result: UploadResult
            do {
                result = try await api.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The hub refused this file; keep going so it doesn't block the ones behind it.
                store.markFailed(item.id, error: error.localizedDescription)
                link?.note("Hub refused \(item.kind): \(error.localizedDescription)")
                continue
            }
            if let error = result.error, result.parsed == nil { throw APIError(message: error) }
            store.markUploaded(item.id, parseError: result.error)
            if let error = result.error { link?.note("Hub couldn't read \(item.kind): \(error)") }
            count += 1
            link?.note("Sent \(item.kind) to the hub\(result.duplicate == true ? " (already there)" : "")")
        }
        return count
    }

    /// Today's live steps, plus every heart rate, stress and Body Battery
    /// reading the phone has that the hub doesn't, in batches. Readings are only
    /// marked sent once the hub says it has them; with no hub in reach they stay
    /// on the phone for next time.
    func postLive(api: APIClient) async {
        guard let link else { return }
        // Packets from the watch wake the app for seconds; ask iOS for long enough to finish.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Send live readings")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        struct Live: Encodable {
            var day: String; var steps: Int?; var goal: Int?; var restingHr: Int?; var samples: [Sample]
        }
        struct Sample: Encodable { var kind: String; var at: String; var value: Int }
        var first = true
        while true {
            let batch = link.live.pending(limit: 2000)
            // The first post goes even without readings when there are steps to report.
            let hasDay = first && (link.steps != nil || link.heartRate?.restingBPM != nil)
            guard !batch.isEmpty || hasDay else { return }
            let body = Live(day: localDay(), steps: first ? link.steps?.count : nil,
                            goal: first ? link.steps.flatMap { $0.goal > 0 ? $0.goal : nil } : nil,
                            restingHr: first ? link.heartRate?.restingBPM : nil,
                            samples: batch.map { Sample(kind: $0.kind.rawValue, at: $0.at.formatted(.iso8601), value: $0.value) })
            do {
                // A 400 decodes too, so only the hub's "ok" counts as having them.
                struct Reply: Decodable { var ok: Bool?; var error: String? }
                let reply: Reply = try await api.post("/api/mobile/fitness/live", body: body)
                guard reply.ok == true else { throw APIError(message: reply.error ?? "The hub didn't take them.") }
            } catch {
                link.note("Live readings wait on the phone: \(error.localizedDescription)")
                return
            }
            link.live.markSent(batch)
            first = false
            if batch.count < 2000 { return }
        }
    }

    /// Download order: the data that was missing from the app comes before bulk monitoring.
    private static func priority(_ kind: String) -> Int {
        ["sleep": 0, "hrv_status": 1, "metrics": 2, "sleep_disruption": 3, "activity": 4,
         "monitor_daily": 5, "monitor_a": 6, "monitor": 7, "skin_temp": 8, "weight": 9][kind] ?? 10
    }

    private func reset() {
        pending = [:]
        inbox = []
        smartInbox = []
        legacy = nil
        legacyError = nil
        streamHandle = nil
        stream = nil
        streamClosed = false
        streamError = nil
    }

    /// Waits for `done` while the watch keeps making progress.
    private func wait(_ what: String, until done: () throws(FileError) -> Bool) async throws(FileError) {
        lastProgress = .now
        while true {
            if try done() { return }
            guard link?.state == .connected else { throw .disconnected }
            if Date.now.timeIntervalSince(lastProgress) > idleTimeout { throw .timeout(what) }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Today's all-day data

    /// The watch keeps today's all-day file open until midnight and doesn't
    /// list it. Before listing, ask in every way the protocol has for the watch
    /// to sync now, in case one makes it close the file early:
    /// CoreService.SyncRequest (Smart field 13, a request in Gadgetbridge's
    /// protocol definitions it never sends), then the "app in foreground",
    /// "sync ready" and "new download available" system events. Whatever the
    /// watch answers is logged, and noteToday says whether a file for today
    /// showed up. Nothing on the watch is changed.
    private func askForToday() async {
        guard let link else { return }
        nextRequestID = 0xC000 + (nextRequestID &+ 1) % 0x3000
        let id = nextRequestID
        pending[id] = []
        smartInbox = []
        let syncRequest = Protobuf.encode([(13, .bytes(Protobuf.encode([(1, .bytes([]))])))])
        link.send(GarminFiles.protobufRequest(.protobufRequest, requestID: id, body: syncRequest))
        let deadline = Date.now.addingTimeInterval(5)
        while smartInbox.isEmpty, Date.now < deadline, link.state == .connected {
            try? await Task.sleep(for: .milliseconds(100))
        }
        pending[id] = nil
        if let reply = smartInbox.first {
            let core = reply.bytes(13).flatMap(Protobuf.decode)
            let status = core?.bytes(2).flatMap(Protobuf.decode)?.int(1)
            link.note("TODAY core sync request: answered, Smart fields \(reply.values.keys.sorted()), core \(core?.values.keys.sorted() ?? []), status \(status.map(String.init) ?? "-")")
        } else {
            link.note("TODAY core sync request: no answer in 5 s")
        }
        for event in [Garmin.SystemEvent.hostDidEnterForeground, .syncReady, .newDownloadAvailable] {
            link.send(GFDIMessage.systemEvent(event))
        }
        // Room for the watch to close a file and announce it (ItemAddedNotification).
        try? await Task.sleep(for: .seconds(3))
        link.note("TODAY after sync request and events: \(announced.count) file(s) announced")
    }

    /// Logs whether the listing has an all-day file from today, and the newest one it has.
    private func noteToday(_ listed: [GarminFiles.ListedFile]) {
        let monitors = listed.filter { $0.kind == "monitor" }.compactMap(\.date)
        let midnight = Calendar.current.startOfDay(for: .now)
        let newest = monitors.max()
        let today = monitors.filter { $0 > midnight.addingTimeInterval(60) }.count
        link?.note("TODAY listing: \(today) all-day file(s) from after midnight; newest \(newest.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "none")")
    }

    // MARK: Legacy download

    private func downloadLegacy(_ index: UInt16, maxBytes: Int) async throws(FileError) -> [UInt8] {
        legacy = GarminFiles.LegacyDownload(maxBytes: maxBytes)
        legacyError = nil
        defer { legacy = nil }
        link?.send(GarminFiles.downloadRequest(index))
        try await wait("file \(index)") { () throws(FileError) in
            if let legacyError { throw legacyError }
            return legacy?.complete == true
        }
        return legacy?.data ?? []
    }

    // MARK: File sync

    private func request(_ body: [UInt8], answer field: UInt64) async throws(FileError) -> Protobuf.Fields {
        nextRequestID = 0xC000 + (nextRequestID &+ 1) % 0x3000
        let id = nextRequestID
        pending[id] = []
        defer { pending[id] = nil }
        inbox = []
        link?.send(GarminFiles.protobufRequest(.protobufRequest, requestID: id, body: body))
        var answer: Protobuf.Fields?
        try await wait("file sync") {
            answer = inbox.first { $0.has(field) }
            return answer != nil
        }
        return answer!
    }

    /// The whole file list: follow the cursor, then newer pages, at most 30 responses.
    /// Lists files not yet synced (where new monitoring and sleep files are),
    /// then everything, and merges the two by id.
    private func listFiles() async throws(FileError) -> [GarminFiles.ListedFile] {
        var files: [GarminFiles.ListedFile] = []
        var ids: Set<String> = []
        for unsyncedOnly in [true, false] {
            let listed = try await listFiles(unsyncedOnly: unsyncedOnly)
            link?.note("Watch lists \(unsyncedOnly ? "unsynced" : "all"): \(Self.describe(listed))")
            for file in listed where ids.insert(file.id).inserted { files.append(file) }
        }
        for file in announced where ids.insert(file.id).inserted { files.append(file) }
        return files
    }

    private func listFiles(unsyncedOnly: Bool) async throws(FileError) -> [GarminFiles.ListedFile] {
        var files: [GarminFiles.ListedFile] = []
        var ids: Set<String> = []
        var cursor: UInt64?
        var page: UInt64?
        var seen: Set<UInt64> = []
        for _ in 0..<30 {
            let reply = try await request(GarminFiles.fileListRequest(cursor: cursor, page: page, unsyncedOnly: unsyncedOnly), answer: 10)
            guard let list = GarminFiles.fileList(reply) else { throw .protocolError("file list didn't decode") }
            link?.note("LIST \(unsyncedOnly ? "unsynced" : "all") page \(page.map(String.init) ?? "-") cursor \(cursor.map(String.init) ?? "-"): \(Self.describeResponse(reply))")
            if let status = list.status, status != 0 { throw .refused("file list status \(status)") }
            let fresh = list.files.filter { ids.insert($0.id).inserted }
            files += fresh
            progress = "Listing files (\(files.count))"
            cursor = list.cursor
            if cursor == nil {
                // Some watches leave out next_page_id; it matches the highest page id
                // listed (Gadgetbridge #5461).
                let next = list.nextPage ?? list.files.compactMap(\.page).max()
                guard !fresh.isEmpty, let next, seen.insert(next).inserted else { break }
                page = next
            }
        }
        return files
    }

    // MARK: Diagnostic probes (read-only list requests)

    /// DIAGNOSTIC: run with launch argument -probeFiles; lists and probes, downloads nothing.
    func probeOnly() async {
        guard !isSyncing, link?.state == .connected else { return }
        isSyncing = true
        defer { isSyncing = false; reset() }
        // -probeSend=6,8: system events to send first, then wait for the watch to react.
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-probeSend=") }) {
            for raw in arg.dropFirst(11).split(separator: ",").compactMap({ UInt8($0) }) {
                link?.send(GFDIMessage.frame(Garmin.Message.systemEvent.rawValue, [raw, 0]))
                link?.note("PROBE sent system event \(raw)")
            }
            try? await Task.sleep(for: .seconds(20))
        }
        await probeHealthTypes("before flush")
        do {
            let directory = try await downloadLegacy(GarminFiles.directoryIndex, maxBytes: 256 * 1024)
            link?.note("Legacy directory bytes: \(directory.prefix(512).map { String(format: "%02x", $0) }.joined())")
            try? await Task.sleep(for: .seconds(2))
            let listed = try await listFiles()
            link?.note("PROBE listed \(listed.count): \(Self.describe(listed))")
        } catch {
            link?.note("PROBE list failed: \(error.localizedDescription)")
        }
        try? await Task.sleep(for: .seconds(10))
        await probeHealthTypes("after flush+10s")
        link?.note("PROBE done")
    }

    /// Asks for the file list in ways the normal sync doesn't, and logs the raw answers.
    private func probeListing() async {
        func type(_ fields: [(UInt64, Protobuf.Value)]) -> (UInt64, Protobuf.Value) { (6, .bytes(Protobuf.encode(fields))) }
        let synced = Protobuf.encode([(1, .fixed64(GarminFiles.syncedFlag)), (2, .fixed64(GarminFiles.syncedFlag))])
        let probes: [(String, [(UInt64, Protobuf.Value)])] = [
            ("plain", []),
            ("plain+meta", [(7, .varint(0))]),
            ("excl-synced flags1 only", [(4, .bytes(synced)), (7, .varint(0))]),
            ("type name SLEEP", [type([(2, .bytes(Array("SLEEP".utf8)))]), (7, .varint(0))]),
            ("type name FIT_TYPE_49", [type([(2, .bytes(Array("FIT_TYPE_49".utf8)))]), (7, .varint(0))]),
            ("type code0 FIT_TYPE_49", [type([(1, .varint(0)), (2, .bytes(Array("FIT_TYPE_49".utf8)))]), (7, .varint(0))]),
            ("type name MONITOR", [type([(2, .bytes(Array("MONITOR".utf8)))]), (7, .varint(0))]),
            ("type name FIT_TYPE_32", [type([(2, .bytes(Array("FIT_TYPE_32".utf8)))]), (7, .varint(0))]),
            ("type name ACTIVITY", [type([(2, .bytes(Array("ACTIVITY".utf8)))]), (7, .varint(0))]),
            ("max_count 500", [(3, .varint(500)), (7, .varint(0))]),
        ]
        for (label, request) in probes {
            do {
                let reply = try await self.request(GarminFiles.fileSync([(9, .bytes(Protobuf.encode(request)))]), answer: 10)
                link?.note("PROBE \(label): \(Self.describeResponse(reply))")
            } catch {
                link?.note("PROBE \(label): \(error.localizedDescription)")
            }
        }
    }

    /// Lists only health types (code 0 + FIT_TYPE_n is the filter form the watch accepts).
    private func probeHealthTypes(_ label: String) async {
        for number in [32, 44, 49, 68, 70, 15, 28] {
            let type = Protobuf.encode([(1, .varint(0)), (2, .bytes(Array("FIT_TYPE_\(number)".utf8)))])
            do {
                let reply = try await self.request(GarminFiles.fileSync([(9, .bytes(Protobuf.encode([(6, .bytes(type)), (7, .varint(0))])))]), answer: 10)
                link?.note("PROBE \(label) type \(number): \(Self.describeResponse(reply))")
            } catch {
                link?.note("PROBE \(label) type \(number): \(error.localizedDescription)")
            }
        }
    }

    /// Status, cursor, page ids, extra fields and the raw (code, name, name id) of each type.
    private static func describeResponse(_ sync: Protobuf.Fields) -> String {
        guard let raw = sync.bytes(10), let fields = Protobuf.decode(raw) else { return "no FileListResponse, fields \(sync.values.keys.sorted())" }
        var types: [String: Int] = [:]
        var pages: [UInt64] = []
        for entry in fields.all(4).compactMap(\.bytes) {
            guard let file = Protobuf.decode(entry) else { continue }
            let type = file.bytes(2).flatMap(Protobuf.decode) ?? Protobuf.Fields()
            let name = type.bytes(2).map { String(decoding: $0, as: UTF8.self) } ?? "-"
            types["\(type.int(1).map(String.init) ?? "-")/\(name)/\(type.int(3).map(String.init) ?? "-")", default: 0] += 1
            if let page = file.int(5) { pages.append(page) }
        }
        let extra = fields.values.keys.filter { ![1, 2, 3, 4].contains($0) }.sorted().map { "f\($0)=\(fields.values[$0]!.map { $0.int.map(String.init) ?? "bytes" })" }
        return "status \(fields.int(1).map(String.init) ?? "-") cursor \(fields.int(2).map(String.init) ?? "-") next \(fields.int(3).map(String.init) ?? "-") files \(fields.all(4).count) pages \(pages.min().map(String.init) ?? "-")…\(pages.max().map(String.init) ?? "-") \(extra) types \(types.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))"
    }

    /// "activity 12, sleep 3, …", most first.
    private static func describe(_ files: [GarminFiles.ListedFile]) -> String {
        let counts = Dictionary(grouping: files, by: \.kind).mapValues(\.count).sorted { $0.value > $1.value }
        return counts.isEmpty ? "none" : counts.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private func download(_ file: GarminFiles.ListedFile) async throws(FileError) -> [UInt8] {
        let reply = try await request(GarminFiles.fileRequest(file.entry), answer: 2)
        guard let response = GarminFiles.fileResponse(reply), response.status == 0, let handle = response.handle else {
            throw .refused("file request status \(GarminFiles.fileResponse(reply)?.status ?? 0)")
        }
        guard let link, let serviceHandle = await link.register(GarminFiles.fileTransferService) else {
            throw .refused("file-transfer service")
        }
        streamHandle = serviceHandle
        stream = nil
        streamClosed = false
        streamError = nil
        defer { streamHandle = nil }
        link.write([serviceHandle] + GarminFiles.streamRequest(handle: UInt16(truncatingIfNeeded: handle)))
        let cap = maxFileBytes
        try await wait("file stream") { () throws(FileError) in
            if let streamError { throw streamError }
            if (stream?.count ?? 0) > cap { throw .tooLarge }
            return streamClosed
        }
        guard let stream, !stream.isEmpty else { throw .protocolError("file stream closed with no data") }
        return try GarminFiles.inflate(stream, maxBytes: maxFileBytes)
    }

    // MARK: Inbound

    /// A multi-link packet. True when it belongs to the file stream.
    func handle(_ packet: MLRPacket) -> Bool {
        switch packet {
        case let .closedHandle(service) where service == GarminFiles.fileTransferService && streamHandle != nil:
            streamClosed = true
            return true
        case let .data(handle, payload) where handle == streamHandle:
            if stream == nil {
                guard payload.starts(with: GarminFiles.streamStart) else {
                    streamError = .protocolError("file stream didn't start with 00 00 00")
                    return true
                }
                stream = Array(payload.dropFirst(3))
            } else {
                stream! += payload
            }
            lastProgress = .now
            return true
        default:
            return false
        }
    }

    /// A GFDI message. True when consumed here, so WatchLink sends no generic ACK.
    func handle(_ message: GFDIMessage) -> Bool {
        guard let link else { return false }
        switch Garmin.Message(rawValue: message.type) {
        case .response:
            guard let status = GarminFiles.downloadStatus(message.payload) else { return false }
            switch status {
            case let .success(size) where legacy != nil:
                if size > legacy!.maxBytes { legacyError = .tooLarge } else { legacy!.size = size }
                lastProgress = .now
            case let .failure(error):
                legacyError = error
            default:
                break
            }
            return true
        case .fileTransferData:
            guard legacy != nil, legacyError == nil, let chunk = GarminFiles.Chunk(message.payload) else {
                link.send(GarminFiles.transferAck(nextOffset: 0, abort: true))
                return true
            }
            do {
                let next = try legacy!.append(chunk)
                lastProgress = .now
                link.send(GarminFiles.transferAck(nextOffset: next))
            } catch {
                link.send(GarminFiles.transferAck(nextOffset: UInt32(legacy!.data.count), abort: true))
                legacyError = error
            }
            return true
        case .protobufRequest, .protobufResponse:
            return handleProtobuf(message)
        default:
            return false
        }
    }

    private func handleProtobuf(_ message: GFDIMessage) -> Bool {
        guard let link, let chunk = GarminFiles.ProtobufChunk(message.payload) else { return false }
        let ours = message.type == Garmin.Message.protobufResponse.rawValue && pending[chunk.requestID] != nil
        let body: [UInt8]
        if ours {
            guard Int(chunk.offset) == pending[chunk.requestID]!.count else { return true } // out of order: no ACK
            pending[chunk.requestID]! += chunk.data
            lastProgress = .now
            link.send(GFDIMessage.protobufAck(message.type, requestID: chunk.requestID, offset: chunk.offset))
            guard pending[chunk.requestID]!.count >= Int(chunk.total) else { return true }
            body = pending.removeValue(forKey: chunk.requestID)!
        } else if chunk.offset == 0, Int(chunk.total) == chunk.data.count {
            body = chunk.data
        } else {
            return false
        }
        guard let sync = GarminFiles.fileSyncFields(body) else {
            // Another service's reply to one of our requests (askForToday).
            if ours, let smart = Protobuf.decode(body) { smartInbox.append(smart) }
            return ours
        }
        if !ours { link.send(GFDIMessage.protobufAck(message.type, requestID: chunk.requestID, offset: 0)) }
        if sync.has(5) { // TransferStatusRequest: answer as Gadgetbridge does
            link.send(GarminFiles.protobufRequest(.protobufResponse, requestID: chunk.requestID, body: GarminFiles.transferStatusResponse()))
        }
        if sync.has(22) { // SyncButtonNotification: sync pressed on the watch
            link.note("Watch asks for a sync")
            watchAskedForSync(manual: true)
        }
        if sync.has(17) { link.note("Watch updated a file's flags") } // ItemUpdatedNotification, after marking synced
        let unhandled = sync.values.keys.filter { ![2, 5, 10, 12, 16, 17, 22].contains($0) }.sorted()
        if !unhandled.isEmpty { link.note("Watch file sync message, fields \(unhandled)") }
        if sync.has(12) {
            let files = GarminFiles.newFiles(sync)
            announced += files
            link.note("Watch announced \(files.count) new file(s): \(Self.describe(files))")
        }
        inbox.append(sync)
        return true
    }
}

/// FIT files on the phone, until the hub has them: Application Support/Fitness,
/// excluded from backups and readable after the first unlock (for background sync).
@MainActor
final class FitStore {
    struct Saved: Codable, Equatable {
        var id: String
        var kind: String
        var size: Int
        var date: Date?
        var path: String
        var fitValid: Bool
        var savedAt: Date
        /// When the hub stored it; nil until then (and again after a newer copy replaces it).
        var uploadedAt: Date?
        /// The size the watch listed when this copy was taken, to spot a file that has grown.
        var listedSize: Int?
        /// When the watch accepted the synced flag for this file.
        var markedSyncedAt: Date?
        var parseError: String?
    }

    struct Listed: Codable {
        var id: String
        var kind: String
        var size: Int
        var date: Date?
    }

    private(set) var saved: [String: Saved] = [:]
    private(set) var listing: [Listed] = []
    private let root: URL

    init() {
        root = URL.applicationSupportDirectory.appending(path: "Fitness", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try? url.setResourceValues(values)
        saved = load("saved.json") ?? [:]
        listing = load("listing.json") ?? []
    }

    func has(_ file: GarminFiles.ListedFile) -> Bool { saved[file.id] != nil }

    /// Kinds the watch keeps writing to through the day: today's all-day
    /// monitoring file is listed before midnight and grows on every flush.
    static let growingKinds: Set<String> = ["monitor", "monitor_a", "monitor_daily"]

    /// New files, and any day file that has changed since the copy we have:
    /// a different listed size, or (when the watch lists an open file without
    /// a size) a copy over 15 minutes old from the last two days. Older files
    /// are never pulled twice, so history isn't downloaded again.
    func needsDownload(_ file: GarminFiles.ListedFile) -> Bool {
        guard let copy = saved[file.id] else { return true }
        guard Self.growingKinds.contains(file.kind) else { return false }
        let recent = (file.date ?? copy.date).map { Date.now.timeIntervalSince($0) < 2 * 86400 } ?? true
        guard recent else { return false }
        if file.size > 0, let listed = copy.listedSize { return file.size != listed }
        return Date.now.timeIntervalSince(copy.savedAt) > 15 * 60
    }

    func url(_ item: Saved) -> URL { root.appending(path: item.path) }

    func save(_ file: GarminFiles.ListedFile, data: [UInt8]) throws(FileError) {
        let path = "fit/\(file.kind)/\(file.id).fit"
        let url = root.appending(path: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(data).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw .protocolError("couldn't save the file on the phone")
        }
        saved[file.id] = Saved(id: file.id, kind: file.kind, size: data.count, date: file.date, path: path,
                               fitValid: GarminFiles.isFIT(data), savedAt: .now, listedSize: file.size)
        write(saved, to: "saved.json")
    }

    func markFailed(_ id: String, error: String) {
        saved[id]?.parseError = "not accepted: \(error)"
        write(saved, to: "saved.json")
    }

    func markSyncedOnWatch(_ id: String) {
        saved[id]?.markedSyncedAt = .now
        write(saved, to: "saved.json")
    }

    func markUploaded(_ id: String, parseError: String?) {
        saved[id]?.uploadedAt = .now
        saved[id]?.parseError = parseError
        write(saved, to: "saved.json")
    }

    var pendingUpload: Int { saved.values.filter { $0.uploadedAt == nil }.count }

    func saveListing(_ files: [GarminFiles.ListedFile]) {
        listing = files.map { Listed(id: $0.id, kind: $0.kind, size: $0.size, date: $0.date) }
        write(listing, to: "listing.json")
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write(_ value: some Encodable, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: root.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
