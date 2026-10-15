import Foundation
import zlib

// Downloading files from the watch, as pure functions over bytes. Ported from
// the Pi collector's garmin_files.py, itself a port of Gadgetbridge's
// FileTransferHandler, FileSyncServiceHandler, downloadFileFromServiceV2,
// CommunicatorV2 and gdi_file_sync_service.proto
// (https://codeberg.org/Freeyourgadget/Gadgetbridge, Copyright (C) 2024-2026
// Daniele Gobbetti, José Rebelo, Thomas Kuehne and other Gadgetbridge
// contributors), AGPL-3.0-or-later.
//
// Only the download half exists: nothing here can build SET_FILE_FLAG
// (archive), FileSetFlags (mark synced), CREATE_FILE or UPLOAD_REQUEST, so this
// code cannot archive, delete or write files on the watch.
//
// Two flows:
//   Legacy   DOWNLOAD_REQUEST(index) → RESPONSE(size) → FILE_TRANSFER_DATA
//            chunks, each acknowledged with the next offset. Index 0 is the
//            directory. The 965 lists no FIT files there, but reading it makes
//            the watch flush pending data, so Gadgetbridge always does.
//   New sync Protobuf FileListRequest → FileListResponse (128-bit ids), then
//            FileRequest → FileResponse(handle). The phone registers service
//            0x2018 and writes `00 00 handle 00 00` on it; the watch answers
//            `00 00 00`, a deflate stream, then closes the service.

enum GarminFiles {
    static let directoryIndex: UInt16 = 0
    static let fileTransferService: UInt16 = 0x2018
    /// Smart.file_sync_service
    static let fileSyncField: UInt64 = 43
    static let streamStart: [UInt8] = [0, 0, 0]

    /// FIT sub-types (data type 128), from Gadgetbridge's FileType.FILETYPE.
    static let fitTypes: [Int: String] = [
        4: "activity", 9: "weight", 15: "monitor_a", 28: "monitor_daily", 29: "records",
        32: "monitor", 44: "metrics", 49: "sleep", 61: "ecg", 68: "hrv_status",
        73: "skin_temp", 79: "sleep_disruption",
    ]

    /// Health data worth keeping: activities, all-day monitoring, sleep and the rest.
    static let healthKinds: Set<String> = [
        "activity", "monitor", "monitor_a", "monitor_daily", "sleep", "sleep_disruption",
        "hrv_status", "metrics", "skin_temp", "weight",
    ]

    static func date(garminSeconds: UInt64) -> Date? {
        garminSeconds == 0 ? nil : Date(timeIntervalSince1970: Garmin.epochOffset + TimeInterval(garminSeconds))
    }

    // MARK: Legacy transfer

    /// DOWNLOAD_REQUEST for a whole file: index, offset 0, NEW, CRC seed 0, size 0, flags 0.
    static func downloadRequest(_ index: UInt16) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(index)
        payload.appendLE(UInt32(0))
        payload.append(1)
        payload.appendLE(UInt16(0))
        payload.appendLE(UInt32(0))
        payload.append(0)
        return GFDIMessage.frame(Garmin.Message.downloadRequest.rawValue, payload)
    }

    /// Acknowledges one FILE_TRANSFER_DATA chunk with the next offset; status 2 aborts.
    static func transferAck(nextOffset: UInt32, abort: Bool = false) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(Garmin.Message.fileTransferData.rawValue)
        payload.append(0)
        payload.append(abort ? 2 : 0)
        payload.appendLE(nextOffset)
        return GFDIMessage.frame(Garmin.Message.response.rawValue, payload)
    }

    /// The answer to a DOWNLOAD_REQUEST: nil if the RESPONSE is about something else.
    static func downloadStatus(_ payload: [UInt8]) -> Result<Int, FileError>? {
        guard payload.readLE(UInt16.self, at: 0) == Garmin.Message.downloadRequest.rawValue, payload.count >= 3 else { return nil }
        guard payload[2] == 0 else { return .failure(.refused("status \(payload[2])")) }
        guard payload.count >= 8, let size = payload.readLE(UInt32.self, at: 4) else { return .failure(.refused("truncated")) }
        let reasons = ["OK", "index unknown", "index not readable", "no space left", "invalid", "not ready", "CRC incorrect"]
        let code = Int(payload[3])
        guard code == 0 else { return .failure(.refused(code < reasons.count ? reasons[code] : "download status \(code)")) }
        return .success(Int(size))
    }

    struct Chunk {
        var crc: UInt16
        var offset: UInt32
        var data: [UInt8]

        /// flags (1), CRC (2), offset (4), data.
        init?(_ payload: [UInt8]) {
            guard payload.count >= 7, let crc = payload.readLE(UInt16.self, at: 1),
                  let offset = payload.readLE(UInt32.self, at: 3) else { return nil }
            self.crc = crc
            self.offset = offset
            data = Array(payload[7...])
        }
    }

    /// Reassembles one legacy file, checking offsets and the running CRC.
    struct LegacyDownload {
        let maxBytes: Int
        var size: Int?
        var data: [UInt8] = []
        var crc: UInt16 = 0

        var complete: Bool { size.map { data.count >= $0 } ?? false }

        mutating func append(_ chunk: Chunk) throws(FileError) -> UInt32 {
            guard let size else { throw .protocolError("data before the download was accepted") }
            guard Int(chunk.offset) == data.count else { throw .protocolError("chunk offset \(chunk.offset), expected \(data.count)") }
            let next = GarminCRC.compute(chunk.data, initial: crc)
            guard next == chunk.crc else { throw .protocolError("chunk CRC mismatch") }
            guard data.count + chunk.data.count <= size else { throw .protocolError("more data than announced") }
            crc = next
            data += chunk.data
            return UInt32(data.count)
        }
    }

    /// The number of FIT files in the legacy directory (16-byte entries).
    static func directoryFITCount(_ data: [UInt8]) -> Int {
        stride(from: 0, to: data.count - data.count % 16, by: 16).filter { data[$0 + 2] == 128 }.count
    }

    // MARK: FIT

    /// Whole-file check: header size 12 or 14, ".FIT", declared length and file CRC.
    static func isFIT(_ data: [UInt8]) -> Bool {
        guard data.count >= 14, data[0] == 12 || data[0] == 14, Array(data[8..<12]) == Array(".FIT".utf8),
              let length = data.readLE(UInt32.self, at: 4) else { return false }
        return data.count == Int(data[0]) + Int(length) + 2 && GarminCRC.compute(data) == 0
    }

    // MARK: Protobuf framing

    /// A PROTOBUF_REQUEST in one chunk: request id, offset 0, total, length, bytes.
    static func protobufRequest(_ type: Garmin.Message, requestID: UInt16, body: [UInt8]) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(requestID)
        payload.appendLE(UInt32(0))
        payload.appendLE(UInt32(body.count))
        payload.appendLE(UInt32(body.count))
        payload += body
        return GFDIMessage.frame(type.rawValue, payload)
    }

    struct ProtobufChunk {
        var requestID: UInt16
        var offset: UInt32
        var total: UInt32
        var data: [UInt8]

        init?(_ payload: [UInt8]) {
            guard let id = payload.readLE(UInt16.self, at: 0), let offset = payload.readLE(UInt32.self, at: 2),
                  let total = payload.readLE(UInt32.self, at: 6), let size = payload.readLE(UInt32.self, at: 10)
            else { return nil }
            requestID = id
            self.offset = offset
            self.total = total
            data = Array(payload[14..<min(payload.count, 14 + Int(size))])
        }
    }

    // MARK: File sync messages

    /// Wraps FileSyncService fields in the Smart envelope.
    static func fileSync(_ inner: [(UInt64, Protobuf.Value)]) -> [UInt8] {
        Protobuf.encode([(fileSyncField, .bytes(Protobuf.encode(inner)))])
    }

    /// The FileSyncService inside a Smart message, or nil.
    static func fileSyncFields(_ smart: [UInt8]) -> Protobuf.Fields? {
        guard let inner = Protobuf.decode(smart)?.bytes(fileSyncField) else { return nil }
        return Protobuf.decode(inner)
    }

    /// The "already synced" flag value, as both halves of a FileId (0xa5a5).
    static let syncedFlag: UInt64 = 42405

    /// FileListRequest (field 9), continuing from a cursor or a page, with timestamps.
    /// `unsyncedOnly` excludes files flagged as synced, as Gadgetbridge always does;
    /// without it the watch walks months of old files and may never reach the
    /// recent monitoring and sleep files. This app never sets the flag, so it only
    /// hides files Garmin Connect already took.
    static func fileListRequest(cursor: UInt64? = nil, page: UInt64? = nil, unsyncedOnly: Bool = false) -> [UInt8] {
        var request: [(UInt64, Protobuf.Value)] = []
        if let cursor { request.append((1, .varint(cursor))) } else if let page { request.append((2, .varint(page))) }
        if unsyncedOnly {
            let flag = Protobuf.encode([(1, .fixed64(syncedFlag)), (2, .fixed64(syncedFlag))])
            request += [(4, .bytes(flag)), (5, .bytes(flag))]
        }
        request.append((7, .varint(0)))
        return fileSync([(9, .bytes(Protobuf.encode(request)))])
    }

    /// FileRequest (field 1) for a listed file, with the values Gadgetbridge sends.
    static func fileRequest(_ entry: [UInt8]) -> [UInt8] {
        fileSync([(1, .bytes(Protobuf.encode([(1, .bytes(entry)), (2, .varint(24)), (3, .varint(0)), (4, .varint(0)), (5, .varint(15))])))])
    }

    /// The answer to the watch's TransferStatusRequest (field 5).
    static func transferStatusResponse() -> [UInt8] {
        fileSync([(21, .bytes(Protobuf.encode([(1, .varint(1))])))])
    }

    /// First write on the file-transfer service: 00 00 handle(LE16) 00 00.
    static func streamRequest(handle: UInt16) -> [UInt8] {
        var out: [UInt8] = [0, 0]
        out.appendLE(handle)
        out += [0, 0]
        return out
    }

    struct ListedFile: Equatable {
        /// Sent back verbatim to request the file.
        var entry: [UInt8]
        var id: String
        var kind: String
        var size: Int
        var date: Date?
        var page: UInt64?
    }

    struct FileList {
        var status: UInt64?
        var cursor: UInt64?
        var nextPage: UInt64?
        var files: [ListedFile]
    }

    /// FileListResponse (field 10). Only the first file of a type in each page
    /// carries the type's name; the rest refer to it by name id.
    static func fileList(_ sync: Protobuf.Fields) -> FileList? {
        guard let raw = sync.bytes(10), let fields = Protobuf.decode(raw) else { return nil }
        return FileList(status: fields.int(1), cursor: fields.int(2), nextPage: fields.int(3),
                        files: listedFiles(fields.all(4).compactMap(\.bytes)))
    }

    /// NewFileNotification (field 12): files the watch announces on its own,
    /// which can include ones its file list leaves out.
    static func newFiles(_ sync: Protobuf.Fields) -> [ListedFile] {
        guard let raw = sync.bytes(12), let fields = Protobuf.decode(raw) else { return [] }
        return listedFiles(fields.all(1).compactMap(\.bytes))
    }

    /// File messages, resolving type names given only by name id.
    private static func listedFiles(_ entries: [[UInt8]]) -> [ListedFile] {
        var names: [UInt64: String] = [:]
        var files: [ListedFile] = []
        for entry in entries {
            guard let file = Protobuf.decode(entry) else { continue }
            let ident = file.bytes(1).flatMap(Protobuf.decode) ?? Protobuf.Fields()
            let type = file.bytes(2).flatMap(Protobuf.decode) ?? Protobuf.Fields()
            let name = type.bytes(2).map { String(decoding: $0, as: UTF8.self) }
            let nameID = type.int(3)
            if let name, !name.isEmpty, let nameID, names[nameID] == nil { names[nameID] = name }
            let id = String(format: "%016llx%016llx", ident.int(1) ?? 0, ident.int(2) ?? 0)
            files.append(ListedFile(entry: entry, id: id, kind: kind(name: name ?? nameID.flatMap { names[$0] }, code: type.int(1)),
                                    size: Int(file.int(3) ?? 0), date: file.int(7).flatMap { date(garminSeconds: $0) },
                                    page: file.int(5)))
        }
        return files
    }

    /// Our name for a listed type: "FIT_TYPE_49" or "SLEEP" → "sleep".
    static func kind(name: String?, code: UInt64?) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
            return code.map { "code_\($0)" } ?? "unknown"
        }
        if name.hasPrefix("fit_type_"), let number = Int(name.dropFirst(9)) { return fitTypes[number] ?? name }
        return name
    }

    /// FileResponse (field 2): status and the transfer handle.
    static func fileResponse(_ sync: Protobuf.Fields) -> (status: UInt64, handle: UInt64?)? {
        guard let raw = sync.bytes(2), let fields = Protobuf.decode(raw) else { return nil }
        return (fields.int(1) ?? 0, fields.int(3))
    }

    // MARK: Inflate

    /// Inflates the transfer stream (zlib, else raw deflate), refusing output over `maxBytes`.
    static func inflate(_ data: [UInt8], maxBytes: Int) throws(FileError) -> [UInt8] {
        for windowBits in [MAX_WBITS, -MAX_WBITS] {
            if let out = inflate(data, windowBits: windowBits, maxBytes: maxBytes) {
                guard out.count <= maxBytes else { throw .tooLarge }
                return out
            }
        }
        throw .protocolError("file stream is not deflate data")
    }

    private static func inflate(_ data: [UInt8], windowBits: Int32, maxBytes: Int) -> [UInt8]? {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var input = data
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let result: Int32 = input.withUnsafeMutableBufferPointer { inputPointer in
            stream.next_in = inputPointer.baseAddress
            stream.avail_in = uInt(inputPointer.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { bufferPointer in
                    stream.next_out = bufferPointer.baseAddress
                    stream.avail_out = uInt(bufferPointer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                out += buffer[0..<(buffer.count - Int(stream.avail_out))]
                if status == Z_STREAM_END { return status }
                if status != Z_OK || out.count > maxBytes || (stream.avail_in == 0 && stream.avail_out != 0) { return status }
            }
        }
        if out.count > maxBytes { return out }
        // A stream cut short still returns what inflated; the FIT check then rejects it.
        return result == Z_STREAM_END || result == Z_OK ? out : nil
    }
}

enum FileError: Error, LocalizedError {
    case refused(String)
    case protocolError(String)
    case timeout(String)
    case tooLarge
    case disconnected

    var errorDescription: String? {
        switch self {
        case let .refused(reason): "The watch refused: \(reason)."
        case let .protocolError(reason): "Transfer failed: \(reason)."
        case let .timeout(what): "The watch stopped answering (\(what))."
        case .tooLarge: "The file is over the size cap."
        case .disconnected: "The watch disconnected."
        }
    }
}

// MARK: Protobuf (proto2 wire format, just what file sync needs)

enum Protobuf {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)

        var bytes: [UInt8]? { if case let .bytes(value) = self { value } else { nil } }
        var int: UInt64? {
            switch self {
            case let .varint(value), let .fixed64(value): value
            case let .fixed32(value): UInt64(value)
            case .bytes: nil
            }
        }
    }

    struct Fields {
        var values: [UInt64: [Value]] = [:]

        func all(_ number: UInt64) -> [Value] { values[number] ?? [] }
        func bytes(_ number: UInt64) -> [UInt8]? { values[number]?.first?.bytes }
        func int(_ number: UInt64) -> UInt64? { values[number]?.first?.int }
        func has(_ number: UInt64) -> Bool { values[number] != nil }
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            out.append(byte | (value != 0 ? 0x80 : 0))
        } while value != 0
        return out
    }

    static func encode(_ fields: [(UInt64, Value)]) -> [UInt8] {
        var out: [UInt8] = []
        for (number, value) in fields {
            switch value {
            case let .varint(v):
                out += varint(number << 3) + varint(v)
            case let .fixed64(v):
                out += varint(number << 3 | 1)
                out.appendLE(v)
            case let .bytes(v):
                out += varint(number << 3 | 2) + varint(UInt64(v.count)) + v
            case let .fixed32(v):
                out += varint(number << 3 | 5)
                out.appendLE(v)
            }
        }
        return out
    }

    /// Nil when truncated or using a wire type file sync never sends.
    static func decode(_ data: [UInt8]) -> Fields? {
        var fields = Fields()
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < data.count, shift < 64 {
                let byte = data[i]
                i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < data.count {
            guard let key = varint() else { return nil }
            let value: Value
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                value = .varint(v)
            case 1:
                guard let v = data.readLE(UInt64.self, at: i) else { return nil }
                i += 8
                value = .fixed64(v)
            case 2:
                guard let size = varint(), size <= UInt64(data.count - i) else { return nil }
                value = .bytes(Array(data[i..<(i + Int(size))]))
                i += Int(size)
            case 5:
                guard let v = data.readLE(UInt32.self, at: i) else { return nil }
                i += 4
                value = .fixed32(v)
            default:
                return nil
            }
            fields.values[key >> 3, default: []].append(value)
        }
        return fields
    }
}
