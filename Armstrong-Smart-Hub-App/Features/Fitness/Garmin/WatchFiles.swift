import Foundation
import Observation

/// Copies FIT files from the watch to the phone: activities, all-day
/// monitoring and sleep. Read-only towards the watch: it lists and downloads,
/// and never archives, deletes or marks files synced.
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
    /// Files the watch announced with a NewFileNotification during this sync.
    private var announced: [GarminFiles.ListedFile] = []
    private var nextRequestID: UInt16 = 0xC000
    private var lastProgress = Date()

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
        defer {
            isSyncing = false
            progress = nil
            reset()
        }
        var listed: [GarminFiles.ListedFile] = []
        var downloaded = 0
        var uploaded = 0
        var failure: String?
        if link.state == .connected { do {
            progress = "Reading the watch's directory"
            // Makes the watch flush pending data, as Gadgetbridge does before every sync.
            let directory = try await downloadLegacy(GarminFiles.directoryIndex, maxBytes: 256 * 1024)
            link.note("Legacy directory: \(GarminFiles.directoryFITCount(directory)) FIT files")
            // The flush can make the watch announce new files; give it a moment.
            try? await Task.sleep(for: .seconds(2))

            progress = "Listing files"
            listed = try await listFiles()
            store.saveListing(listed)

            let wanted = listed
                .filter { GarminFiles.healthKinds.contains($0.kind) && $0.size > 0 && $0.size <= maxFileBytes && !store.has($0) }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                .prefix(perSyncLimit)
            for (number, file) in wanted.enumerated() {
                progress = "Downloading \(file.kind.replacingOccurrences(of: "_", with: " ")) \(number + 1) of \(wanted.count)"
                let data = try await download(file)
                try store.save(file, data: data)
                downloaded += 1
                link.note("Saved \(file.kind) (\(data.count) bytes, FIT \(GarminFiles.isFIT(data) ? "valid" : "INVALID"))")
            }
        } catch {
            failure = error.localizedDescription
            link.note("Sync stopped: \(failure!)")
        } }
        // Whatever made it onto the phone goes to the hub, even after a watch error.
        do {
            await postLive(api: api)
            uploaded = try await upload(api: api)
        } catch is CancellationError {
        } catch {
            failure = failure ?? error.localizedDescription
            link.note("Upload stopped: \(error.localizedDescription)")
        }
        lastSync = Summary(listed: listed.count, byKind: Dictionary(grouping: listed, by: \.kind).mapValues(\.count),
                           downloaded: downloaded, uploaded: uploaded, failed: failure, finishedAt: .now)
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
            let result: UploadResult = try await api.send(request)
            if let error = result.error, result.parsed == nil { throw APIError(message: error) }
            store.markUploaded(item.id, parseError: result.error)
            count += 1
            link?.note("Sent \(item.kind) to the hub\(result.duplicate == true ? " (already there)" : "")")
        }
        return count
    }

    /// Today's live step count, so the hub has today before a monitoring file does.
    private func postLive(api: APIClient) async {
        guard let link, link.steps != nil || link.heartRate?.restingBPM != nil else { return }
        struct Live: Encodable { var day: String; var steps: Int?; var goal: Int?; var restingHr: Int? }
        let day = localDay()
        let body = Live(day: day, steps: link.steps?.count, goal: link.steps.flatMap { $0.goal > 0 ? $0.goal : nil },
                        restingHr: link.heartRate?.restingBPM)
        let _: Empty? = try? await api.post("/api/mobile/fitness/live", body: body)
    }

    private func reset() {
        pending = [:]
        inbox = []
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
        guard let sync = GarminFiles.fileSyncFields(body) else { return ours }
        if !ours { link.send(GFDIMessage.protobufAck(message.type, requestID: chunk.requestID, offset: 0)) }
        if sync.has(5) { // TransferStatusRequest: answer as Gadgetbridge does
            link.send(GarminFiles.protobufRequest(.protobufResponse, requestID: chunk.requestID, body: GarminFiles.transferStatusResponse()))
        }
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
        /// When the hub stored it; nil until then.
        var uploadedAt: Date?
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
                               fitValid: GarminFiles.isFIT(data), savedAt: .now)
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
