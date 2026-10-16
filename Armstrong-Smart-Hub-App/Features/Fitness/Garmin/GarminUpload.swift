import Foundation

// Putting a file onto the watch: the reverse of GarminFiles' download.
// Ported from Gadgetbridge's Garmin support (codeberg.org/Freeyourgadget/
// Gadgetbridge, AGPL-3.0-or-later): FileTransferHandler.Upload,
// CreateFileMessage, UploadRequestMessage and the three status messages.
//
// The exchange, all GFDI:
//   CREATE_FILE (5005)   size, type 255/17 (a Connect IQ PRG)  ->  RESPONSE: status, create status, file index
//   UPLOAD_REQUEST (5003) file index, size, offset 0, CRC seed ->  RESPONSE: status, upload status, offset
//   FILE_TRANSFER_DATA (5004) one chunk at a time               ->  RESPONSE: status, transfer status, next offset
//   SYSTEM_EVENT sync complete once the last offset is acknowledged.
//
// None of this has run against a real Forerunner 965 yet.

enum GarminUpload {
    /// Data type and sub-type of a Connect IQ app (Gadgetbridge's FILETYPE.PRG).
    static let prgType: UInt8 = 255
    static let prgSubType: UInt8 = 17

    /// A GFDI message is at most this big on the wire; a chunk carries 13 bytes of framing.
    static let maxPacket = 375
    static let chunkSize = maxPacket - 13

    /// Every PRG Gadgetbridge accepts starts with these three bytes.
    static let prgMagic: [UInt8] = [0xD0, 0x00, 0xD0]
    static let maxBytes = 10 * 1024 * 1024

    enum Failure: Error, LocalizedError {
        case notPRG, tooLarge
        case refused(String)
        case protocolError(String)
        case timeout(String)
        case disconnected
        case busy

        var errorDescription: String? {
            switch self {
            case .notPRG: "That isn't a Connect IQ app file (.prg)."
            case .tooLarge: "That file is too large to send."
            case let .refused(why): "The watch refused it: \(why)."
            case let .protocolError(why): "Unexpected answer from the watch: \(why)."
            case let .timeout(what): "The watch stopped answering (\(what))."
            case .disconnected: "The watch disconnected."
            case .busy: "The watch is busy with a sync."
            }
        }
    }

    static func looksLikePRG(_ data: [UInt8]) -> Bool {
        data.count > prgMagic.count && Array(data.prefix(prgMagic.count)) == prgMagic
    }

    /// CREATE_FILE: size, type, sub-type, file index 0, reserved 0, sub-type mask 0,
    /// number mask 0xFFFF, empty path, random 64-bit file id.
    static func createFile(size: Int, fileID: UInt64 = .random(in: .min ... .max)) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(UInt32(size))
        payload.append(prgType)
        payload.append(prgSubType)
        payload.appendLE(UInt16(0))
        payload.append(0)
        payload.append(0)
        payload.appendLE(UInt16(0xFFFF))
        payload.appendLE(UInt16(0))
        payload.appendLE(fileID)
        return GFDIMessage.frame(Garmin.Message.createFile.rawValue, payload)
    }

    /// UPLOAD_REQUEST: file index, size, offset 0, CRC seed 0.
    static func uploadRequest(index: UInt16, size: Int) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(index)
        payload.appendLE(UInt32(size))
        payload.appendLE(UInt32(0))
        payload.appendLE(UInt16(0))
        return GFDIMessage.frame(Garmin.Message.uploadRequest.rawValue, payload)
    }

    /// FILE_TRANSFER_DATA going up: flags 0, running CRC after this chunk, offset, bytes.
    static func chunk(_ data: [UInt8], offset: Int, runningCRC: UInt16) -> [UInt8] {
        var payload: [UInt8] = [0]
        payload.appendLE(runningCRC)
        payload.appendLE(UInt32(offset))
        payload.append(contentsOf: data)
        return GFDIMessage.frame(Garmin.Message.fileTransferData.rawValue, payload)
    }

    // MARK: Replies (RESPONSE payload: the answered message id, then status 0 = ACK)

    struct CreateReply { var fileIndex: UInt16 }

    static func createReply(_ payload: [UInt8]) -> Result<CreateReply, Failure>? {
        guard payload.readLE(UInt16.self, at: 0) == Garmin.Message.createFile.rawValue, payload.count >= 3 else { return nil }
        guard payload[2] == 0 else { return .failure(.refused("create status \(payload[2])")) }
        guard payload.count >= 6, let index = payload.readLE(UInt16.self, at: 4) else { return .failure(.protocolError("short create reply")) }
        let reasons = ["OK", "a file like this already exists", "no space left", "not supported", "no free slots", "no space for this type"]
        let code = Int(payload[3])
        guard code == 0 else { return .failure(.refused(code < reasons.count ? reasons[code] : "create code \(code)")) }
        return .success(CreateReply(fileIndex: index))
    }

    /// The answer to UPLOAD_REQUEST: the offset the watch wants next.
    static func uploadReply(_ payload: [UInt8]) -> Result<Int, Failure>? {
        guard payload.readLE(UInt16.self, at: 0) == Garmin.Message.uploadRequest.rawValue, payload.count >= 3 else { return nil }
        guard payload[2] == 0 else { return .failure(.refused("upload status \(payload[2])")) }
        guard payload.count >= 8, let offset = payload.readLE(UInt32.self, at: 4) else { return .failure(.protocolError("short upload reply")) }
        let reasons = ["OK", "index unknown", "index not writable", "no space left", "invalid", "not ready", "CRC incorrect"]
        let code = Int(payload[3])
        guard code == 0 else { return .failure(.refused(code < reasons.count ? reasons[code] : "upload code \(code)")) }
        return .success(Int(offset))
    }

    /// The answer to one FILE_TRANSFER_DATA chunk: the next offset.
    static func transferReply(_ payload: [UInt8]) -> Result<Int, Failure>? {
        guard payload.readLE(UInt16.self, at: 0) == Garmin.Message.fileTransferData.rawValue, payload.count >= 3 else { return nil }
        guard payload[2] == 0 else { return .failure(.refused("transfer status \(payload[2])")) }
        guard payload.count >= 8, let offset = payload.readLE(UInt32.self, at: 4) else { return .failure(.protocolError("short transfer reply")) }
        let reasons = ["OK", "resend requested", "aborted", "CRC mismatch", "offset mismatch", "sync paused"]
        let code = Int(payload[3])
        guard code == 0 else { return .failure(.refused(code < reasons.count ? reasons[code] : "transfer code \(code)")) }
        return .success(Int(offset))
    }
}
