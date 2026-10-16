import CoreBluetooth
import Foundation
import Observation

/// The phone's Bluetooth link to the Garmin watch, in place of Garmin Connect.
///
/// Connects, lets iOS handle bonding (the system pairing prompt appears when
/// the watch's characteristic is first subscribed to), opens the GFDI channel
/// (CLOSE_ALL, then a handle per service) and streams live heart rate and
/// steps. It never archives, deletes or changes anything on the watch.
@MainActor
@Observable
final class WatchLink: NSObject {
    enum State: Equatable {
        case bluetoothOff(String)
        case idle
        case scanning
        case connecting
        case pairing
        case handshaking
        case connected
        case failed(String)
    }

    struct Candidate: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    private(set) var state: State = .idle
    private(set) var candidates: [Candidate] = []
    private(set) var identity: WatchIdentity?
    private(set) var heartRate: HeartRateReading?
    private(set) var heartRateAt: Date?
    private(set) var steps: StepsReading?
    private(set) var stepsAt: Date?
    /// Protocol events for the diagnostics list: message names and sizes, never contents.
    private(set) var log: [LogLine] = []
    /// History downloads over this link.
    let files = WatchFiles()
    /// Sends Connect IQ apps (watch faces) to the watch.
    let installer = WatchInstaller()

    /// The paired watch, remembered so the app can reconnect without scanning.
    private(set) var savedWatchID: UUID? {
        didSet { UserDefaults.standard.set(savedWatchID?.uuidString, forKey: Self.savedKey) }
    }
    private(set) var savedWatchName: String? {
        didSet { UserDefaults.standard.set(savedWatchName, forKey: Self.savedNameKey) }
    }

    private static let savedKey = "fitness.watch.id"
    private static let savedNameKey = "fitness.watch.name"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var discovered: [UUID: CBPeripheral] = [:]

    private var handles: [UInt16: UInt8] = [:]
    private var assembler = COBSAssembler()
    private var maxWrite = 20
    private var outbox: [[UInt8]] = []
    /// Requests waiting for the watch, each with a token so a timeout only answers its own.
    private var closeAllWaiter: (token: UUID, continuation: CheckedContinuation<Bool, Never>)?
    private var registerWaiters: [UInt16: (token: UUID, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var handshakeTask: Task<Void, Never>?
    private var wantsConnection = false
    /// Whether this connection has told the watch its setup is done.
    private var setupSent = false

    override init() {
        super.init()
        files.link = self
        installer.link = self
        savedWatchID = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:))
        savedWatchName = UserDefaults.standard.string(forKey: Self.savedNameKey)
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isBusy: Bool {
        switch state {
        case .scanning, .connecting, .pairing, .handshaking: true
        default: false
        }
    }

    // MARK: Commands

    func startScan() {
        guard central.state == .poweredOn else { return }
        candidates = []
        discovered = [:]
        state = .scanning
        note("Scanning")
        // Not filtered by service: the 965 does not always advertise it, and
        // only shows up at all while its Pair Phone screen is open.
        central.scanForPeripherals(withServices: nil)
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    /// Connects to a watch the user picked from the scan.
    func pair(_ candidate: Candidate) {
        guard let peripheral = discovered[candidate.id] else { return }
        central.stopScan()
        savedWatchName = candidate.name
        connect(peripheral)
    }

    /// Reconnects to the remembered watch. iOS keeps the request open until
    /// the watch is in range.
    func connectSaved() {
        guard central.state == .poweredOn, let id = savedWatchID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            fail("This phone no longer knows the watch. Pair it again.")
        }
    }

    func disconnect() {
        wantsConnection = false
        handshakeTask?.cancel()
        if let peripheral {
            for service in [Garmin.Service.realtimeHeartRate, .realtimeSteps] {
                if let handle = handles[service.rawValue] { write([handle, 0x00]) }
            }
            central.cancelPeripheralConnection(peripheral)
        }
        reset()
        state = .idle
        note("Disconnected")
    }

    /// Forgets the watch in this app. The bond itself lives in iOS Settings → Bluetooth.
    func forget() {
        disconnect()
        savedWatchID = nil
        savedWatchName = nil
        identity = nil
        heartRate = nil
        steps = nil
    }

    // MARK: Connection

    private func connect(_ peripheral: CBPeripheral) {
        reset()
        wantsConnection = true
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        note("Connecting")
        central.connect(peripheral)
    }

    private func reset() {
        handles = [:]
        setupSent = false
        assembler.reset()
        outbox = []
        rx = nil
        tx = nil
        closeAllWaiter?.continuation.resume(returning: false)
        closeAllWaiter = nil
        registerWaiters.values.forEach { $0.continuation.resume(returning: false) }
        registerWaiters = [:]
    }

    private func fail(_ message: String) {
        state = .failed(message)
        note("Stopped: \(message)")
    }

    func note(_ text: String) {
        log.append(LogLine(text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
        Self.appendToLogFile(text)
    }

    /// The log also goes to Application Support/Fitness/connection.log (last ~200 KB),
    /// so a sync can be diagnosed off the phone.
    private static func appendToLogFile(_ text: String) {
        let url = URL.applicationSupportDirectory.appending(path: "Fitness/connection.log")
        let line = Data("\(Date.now.formatted(.iso8601)) \(text)\n".utf8)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url)
            return
        }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > 200_000 {
            try? handle.close()
            try? line.write(to: url)
            return
        }
        try? handle.write(contentsOf: line)
    }

    /// CLOSE_ALL, the GFDI handle, then the live heart rate and steps services.
    private func handshake() {
        handshakeTask?.cancel()
        handshakeTask = Task {
            state = .handshaking
            guard await closeAll() else {
                if !Task.isCancelled { fail("The watch didn't answer. If it's still paired to Garmin Connect or the Pi, remove it there first.") }
                return
            }
            guard await register(Garmin.Service.gfdi.rawValue) != nil else {
                if !Task.isCancelled { fail("The watch refused the data channel.") }
                return
            }
            state = .connected
            note("Connected")
            // The watch normally sends CONFIGURATION first; finish setup anyway if it doesn't.
            Task {
                try? await Task.sleep(for: .seconds(5))
                if state == .connected { completeSetup() }
            }
            for service in [Garmin.Service.realtimeHeartRate, .realtimeSteps] {
                guard !Task.isCancelled else { return }
                if let handle = await register(service.rawValue) {
                    write([handle, 0x01])
                } else {
                    note("Watch refused \(service)")
                }
            }
        }
    }

    private func closeAll() async -> Bool {
        write(MLRPacket.closeAll())
        let token = UUID()
        return await withCheckedContinuation { continuation in
            closeAllWaiter = (token, continuation)
            Task {
                try? await Task.sleep(for: .seconds(10))
                guard closeAllWaiter?.token == token else { return }
                closeAllWaiter?.continuation.resume(returning: false)
                closeAllWaiter = nil
            }
        }
    }

    /// Asks for a handle for a service; nil if the watch refuses or doesn't answer.
    func register(_ service: UInt16) async -> UInt8? {
        handles[service] = nil // the watch may have closed it since
        registerWaiters.removeValue(forKey: service)?.continuation.resume(returning: false)
        write(MLRPacket.register(service))
        let token = UUID()
        let accepted = await withCheckedContinuation { continuation in
            registerWaiters[service] = (token, continuation)
            Task {
                try? await Task.sleep(for: .seconds(5))
                guard registerWaiters[service]?.token == token else { return }
                registerWaiters.removeValue(forKey: service)?.continuation.resume(returning: false)
            }
        }
        return accepted ? handles[service] : nil
    }

    // MARK: Sending

    /// Queues one raw multi-link packet.
    func write(_ packet: [UInt8]) {
        outbox.append(packet)
        flush()
    }

    /// Writes without response, as far as the link's flow control allows.
    private func flush() {
        guard let peripheral, let tx else { return }
        while !outbox.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(Data(outbox.removeFirst()), for: tx, type: .withoutResponse)
        }
    }

    /// Sends a GFDI frame on the GFDI handle. A frame's packets are queued
    /// together, so frames never interleave.
    func send(_ frame: [UInt8]) {
        guard let handle = handles[Garmin.Service.gfdi.rawValue] else { return }
        for packet in MLRPacket.packets(COBS.encode(frame), handle: handle, maxWrite: maxWrite) {
            write(packet)
        }
    }

    // MARK: Receiving

    private func received(_ bytes: [UInt8]) {
        guard let packet = MLRPacket(bytes) else {
            note("Undecodable packet (\(bytes.count) bytes)")
            return
        }
        if case let .closedHandle(service) = packet { handles[service] = nil }
        if files.handle(packet) { return }
        switch packet {
        case .closeAllResponse:
            handles = [:]
            closeAllWaiter?.continuation.resume(returning: true)
            closeAllWaiter = nil
        case let .registered(service, status, handle):
            if status == 0 { handles[service] = handle }
            note("Service \(service) \(status == 0 ? "on handle \(handle)" : "refused (\(status))")")
            registerWaiters.removeValue(forKey: service)?.continuation.resume(returning: status == 0)
        case let .control(type):
            note("Control message \(type)")
        case let .closedHandle(service):
            note("Watch closed service \(service)")
        case let .data(handle, payload):
            switch handles.first(where: { $0.value == handle })?.key {
            case Garmin.Service.gfdi.rawValue:
                for frame in assembler.append(payload) { receivedGFDI(frame) }
            case Garmin.Service.realtimeHeartRate.rawValue:
                if let reading = HeartRateReading(payload) {
                    heartRate = reading
                    heartRateAt = .now
                }
            case Garmin.Service.realtimeSteps.rawValue:
                if let reading = StepsReading(payload) {
                    steps = reading
                    stepsAt = .now
                }
            default:
                break
            }
        }
    }

    private func receivedGFDI(_ frame: [UInt8]) {
        guard let message = GFDIMessage(frame: frame) else {
            note("Bad GFDI frame (\(frame.count) bytes)")
            return
        }
        note("← \(message.name) (\(message.payload.count) bytes)")
        if installer.handle(message) { return }
        if files.handle(message) { return }
        switch Garmin.Message(rawValue: message.type) {
        case .response:
            return
        case .protobufRequest, .protobufResponse:
            if let header = message.protobufHeader {
                send(GFDIMessage.protobufAck(message.type, requestID: header.requestID, offset: header.offset))
            }
            return
        case .deviceInformation:
            if let info = WatchIdentity(message) {
                identity = info
                if info.maxPacketSize > 0 { maxWrite = min(maxWrite, Int(info.maxPacketSize)) }
            }
        case .currentTimeRequest:
            send(GFDIMessage.timeResponse())
            return
        case .configuration:
            send(GFDIMessage.ack(message.type))
            completeSetup()
            return
        default:
            break
        }
        // Every other message gets a plain ACK, as garmin-ble does.
        send(GFDIMessage.ack(message.type))
    }
}

extension WatchLink {
    /// Without these the watch shows "Finish setup in the app". Same events,
    /// same order, as Gadgetbridge's completeInitialization on a first connect.
    fileprivate func completeSetup() {
        guard !setupSent else { return }
        setupSent = true
        for event in [Garmin.SystemEvent.syncReady, .pairComplete, .syncComplete, .setupWizardComplete] {
            send(GFDIMessage.systemEvent(event))
        }
        note("Told the watch setup is complete")
    }
}

// MARK: CoreBluetooth

extension WatchLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let value = central.state
        MainActor.assumeIsolated {
            switch value {
            case .poweredOn:
                if case .bluetoothOff = state { state = .idle }
                if savedWatchID != nil, peripheral == nil { connectSaved() }
            case .unauthorized:
                state = .bluetoothOff("Allow Bluetooth for this app in Settings.")
            case .poweredOff:
                state = .bluetoothOff("Turn on Bluetooth.")
            case .unsupported:
                state = .bluetoothOff("This device has no Bluetooth LE.")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            let garminService = services.contains(CBUUID(string: Garmin.advertisedService))
            let hints = ["forerunner", "garmin", "fenix", "epix", "venu", "vivo", "instinct", "enduro"]
            guard garminService || hints.contains(where: name.lowercased().contains) else { return }
            discovered[peripheral.identifier] = peripheral
            let candidate = Candidate(id: peripheral.identifier, name: name.isEmpty ? "Garmin watch" : name, rssi: rssi)
            if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
                candidates[index] = candidate
            } else {
                candidates.append(candidate)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            note("Link up, finding the Garmin characteristics")
            maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "Couldn't connect."
        MainActor.assumeIsolated { fail(message) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            handshakeTask?.cancel()
            reset()
            guard wantsConnection else { return }
            wantsConnection = false
            fail(message.map { "Connection lost: \($0)" } ?? "The watch disconnected.")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let services = peripheral.services, !services.isEmpty else {
                fail("The watch exposed no services.")
                return
            }
            services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard rx == nil, let characteristics = service.characteristics else { return }
            for short in Garmin.receiveRange {
                guard let receive = characteristics.first(where: { $0.uuid == CBUUID(string: Garmin.uuid(short)) }),
                      let transmit = characteristics.first(where: { $0.uuid == CBUUID(string: Garmin.uuid(short + Garmin.transmitOffset)) })
                else { continue }
                rx = receive
                tx = transmit
                state = .pairing
                note("Subscribing (iOS asks to pair the first time)")
                peripheral.setNotifyValue(true, for: receive)
                return
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            guard characteristic.uuid == rx?.uuid else { return }
            if let message {
                fail("Pairing didn't finish: \(message)")
                return
            }
            savedWatchID = peripheral.identifier
            if savedWatchName == nil { savedWatchName = peripheral.name }
            handshake()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        MainActor.assumeIsolated { received(bytes) }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { flush() }
    }
}
