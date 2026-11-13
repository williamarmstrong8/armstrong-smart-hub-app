import CoreBluetooth
import Foundation
import Observation
import UIKit

/// The phone's Bluetooth link to the Garmin watch, in place of Garmin Connect.
///
/// Connects, lets iOS handle bonding (the system pairing prompt appears when
/// the watch's characteristic is first subscribed to), opens the GFDI channel
/// (CLOSE_ALL, then a handle per service) and streams live heart rate,
/// steps, stress and Body Battery. It never archives, deletes or changes anything on the watch.
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

    private(set) var state: State = .idle {
        didSet { if state != oldValue { stateChangedAt = .now } }
    }
    /// When `state` last changed, so a connection attempt that has stalled can be started over.
    private var stateChangedAt = Date.now
    private(set) var candidates: [Candidate] = []
    private(set) var identity: WatchIdentity?
    private(set) var heartRate: HeartRateReading?
    private(set) var heartRateAt: Date?
    private(set) var steps: StepsReading?
    private(set) var stepsAt: Date?
    /// Live stress and Body Battery (0-100), as Garmin Connect shows them between syncs.
    private(set) var stress: Int?
    private(set) var stressAt: Date?
    private(set) var bodyBattery: Int?
    private(set) var bodyBatteryAt: Date?
    /// Every live reading, kept on the phone until the hub has it (and two days for the charts).
    let live = LiveStore.shared
    /// Set by the app once signed in, so readings go to the hub without the Fitness tab open.
    var api: APIClient?
    private var lastLivePost = Date.distantPast
    private static let livePostEvery: TimeInterval = 5 * 60
    /// DIAGNOSTIC: raw payloads logged per live service, so the stress layout can be checked.
    private var rawLogged: [UInt16: Int] = [:]
    /// Protocol events for the diagnostics list: message names and sizes, never contents.
    private(set) var log: [LogLine] = []
    /// History downloads over this link.
    let files = WatchFiles()
    /// Sends Connect IQ apps (watch faces) to the watch.
    let installer = WatchInstaller()
    /// Writes hub-only values into the glances' Connect IQ settings.
    let settings = WatchSettings()

    /// The paired watch, remembered so the app can reconnect without scanning.
    private(set) var savedWatchID: UUID? {
        didSet { UserDefaults.standard.set(savedWatchID?.uuidString, forKey: Self.savedKey) }
    }
    private(set) var savedWatchName: String? {
        didSet { UserDefaults.standard.set(savedWatchName, forKey: Self.savedNameKey) }
    }

    private static let savedKey = "fitness.watch.id"
    private static let savedNameKey = "fitness.watch.name"
    /// Set when the user forgets the watch here, so launch doesn't pick it straight back up.
    private static let forgottenKey = "fitness.watch.forgotten"
    /// Lets iOS relaunch the app in the background for the watch after it was suspended or closed.
    private static let restoreID = "fitness.watch.central"

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
    /// The UTC offset the watch was last given on this connection; nil until it has asked for the time.
    private var offsetSentToWatch: Int?
    private var lastClockNudge = Date.distantPast
    private var lastClockCheck = Date.distantPast

    override init() {
        super.init()
        files.link = self
        installer.link = self
        settings.link = self
        savedWatchID = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:))
        savedWatchName = UserDefaults.standard.string(forKey: Self.savedNameKey)
        #if DEBUG
        // The film's watch: connected, beating, and never touching Bluetooth (no permission prompt).
        if Demo.isOn { startDemoWatch(); return }
        #endif
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
        // A new time zone (travel) or a clock change (daylight saving): tell the watch straight away.
        for name in [Notification.Name.NSSystemTimeZoneDidChange, UIApplication.significantTimeChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncClock(reason: "the phone's time changed", force: true) }
            }
        }
    }

    // MARK: Clock

    /// The phone's UTC offset right now. The cached zone is dropped first: a
    /// process woken in the background keeps the zone it started with otherwise.
    private static func phoneOffset() -> Int {
        NSTimeZone.resetSystemTimeZone()
        return TimeZone.current.secondsFromGMT()
    }

    private static func offsetName(_ seconds: Int) -> String {
        String(format: "UTC%+d:%02d", seconds / 3600, abs(seconds) % 3600 / 60)
    }

    /// The watch sets its clock and time zone from the phone, but only when it
    /// asks, which it does on connecting. With the link up for days it never
    /// asks again, so a flight or the end of daylight saving left it on the old
    /// zone. TIME_UPDATED is the system event Garmin Connect and Gadgetbridge
    /// send when the phone's time changes; the watch answers by asking for the
    /// time. Sent when the offset differs from what the watch last got, at most
    /// every 2 minutes.
    func syncClock(reason: String, force: Bool = false) {
        guard state == .connected else { return }
        let offset = Self.phoneOffset()
        guard force || offset != offsetSentToWatch else { return }
        guard Date.now.timeIntervalSince(lastClockNudge) > 120 else { return }
        lastClockNudge = .now
        send(GFDIMessage.systemEvent(.timeUpdated))
        note("Asked the watch to take the time again (\(reason)): phone is on \(Self.offsetName(offset)), watch last got \(offsetSentToWatch.map(Self.offsetName) ?? "nothing")")
    }

    var isBusy: Bool {
        switch state {
        case .scanning, .connecting, .pairing, .handshaking: true
        default: false
        }
    }

    // MARK: Commands

    func startScan() {
        guard !Demo.isOn else { return }
        guard central.state == .poweredOn else { return }
        candidates = []
        discovered = [:]
        state = .scanning
        note("Scanning")
        // Not filtered by service: the 965 does not always advertise it, and
        // only shows up at all while its Pair Phone screen is open.
        central.scanForPeripherals(withServices: nil)
        // A watch already bonded and connected to iOS doesn't advertise, so list it too.
        for known in systemConnectedWatches() {
            discovered[known.identifier] = known
            candidates.append(Candidate(id: known.identifier, name: known.name ?? "Garmin watch", rssi: 0))
        }
    }

    /// Garmin watches iOS itself is connected to (bonded in Settings → Bluetooth).
    /// Peripheral IDs are per app, so after a reinstall or a new bundle ID this
    /// is how the app finds the watch again without re-pairing.
    private func systemConnectedWatches() -> [CBPeripheral] {
        central.retrieveConnectedPeripherals(withServices: [CBUUID(string: Garmin.advertisedService)])
    }

    /// Connects to the watch iOS is already connected to, if there is one.
    @discardableResult
    private func adoptSystemWatch() -> Bool {
        let watches = systemConnectedWatches()
        guard let watch = watches.first(where: { $0.name != nil && $0.name == savedWatchName }) ?? watches.first else { return false }
        note("Found \(watch.name ?? "the watch") connected to iOS")
        if savedWatchName == nil { savedWatchName = watch.name }
        connect(watch)
        return true
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    /// Connects to a watch the user picked from the scan.
    func pair(_ candidate: Candidate) {
        guard let peripheral = discovered[candidate.id] else { return }
        UserDefaults.standard.removeObject(forKey: Self.forgottenKey)
        central.stopScan()
        savedWatchName = candidate.name
        connect(peripheral)
    }

    /// Reconnects to the remembered watch. iOS keeps the request open until
    /// the watch is in range.
    func connectSaved() {
        guard !Demo.isOn else { return }
        guard central.state == .poweredOn, let id = savedWatchID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else if !adoptSystemWatch() {
            fail("This phone no longer knows the watch. Pair it again.")
        }
    }

    /// Makes sure the saved watch's link is up or on its way: reconnects if it is
    /// down, and starts over if an attempt has sat in connecting, pairing or
    /// opening the channel for 30 seconds (iOS can hand back a restored link
    /// that never finishes). A fresh attempt while the watch is out of range
    /// just renews iOS's pending request.
    func ensureConnected() {
        guard !Demo.isOn else { return }
        if state == .connected { syncClock(reason: "the phone's time zone changed") }
        guard savedWatchID != nil, central.state == .poweredOn, state != .connected, state != .scanning else { return }
        if isBusy {
            guard Date.now.timeIntervalSince(stateChangedAt) > 30, let peripheral else { return }
            note("No progress for 30 s while \(state); starting over")
            connect(peripheral)
            return
        }
        connectSaved()
    }

    func disconnect() {
        wantsConnection = false
        handshakeTask?.cancel()
        if let peripheral {
            for service in Garmin.Service.live {
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
        UserDefaults.standard.set(true, forKey: Self.forgottenKey)
        identity = nil
        heartRate = nil
        steps = nil
        stress = nil
        bodyBattery = nil
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
        offsetSentToWatch = nil
        lastClockNudge = .distantPast
        rawLogged = [:]
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
        // Try again on its own, in the background too: a hole in today's data
        // can't be filled until the watch's midnight file.
        guard wantsConnection, savedWatchID != nil, let peripheral else { return }
        Task {
            try? await Task.sleep(for: .seconds(15))
            guard case .failed = state, wantsConnection, self.peripheral === peripheral else { return }
            note("Retrying after: \(message)")
            connect(peripheral)
        }
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

    /// CLOSE_ALL, the GFDI handle, then the live services.
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
            for service in Garmin.Service.live {
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

    // MARK: Live streams

    private var lastReopen = Date.distantPast

    /// Registers a live service again and turns it on.
    private func reopen(_ service: Garmin.Service) async {
        guard state == .connected else { return }
        if let handle = await register(service.rawValue) {
            write([handle, 0x01])
            note("Reopened \(service)")
        } else {
            note("Watch refused \(service) again")
        }
    }

    /// For a screen that needs heart rate now (a workout): reconnects if the
    /// link is down, and if it's up but no reading has come for 20 seconds,
    /// opens the heart rate stream again (at most every 30 seconds).
    func keepHeartRateFlowing() {
        guard !Demo.isOn else { return }
        guard savedWatchID != nil else { return }
        if state != .connected {
            ensureConnected()
            return
        }
        let quiet = heartRateAt.map { Date.now.timeIntervalSince($0) > 20 } ?? true
        guard quiet, Date.now.timeIntervalSince(lastReopen) > 30 else { return }
        lastReopen = .now
        note("No heart rate for 20 s; reopening the stream")
        Task { await reopen(.realtimeHeartRate) }
    }

    /// What a heart rate readout says while it has no reading.
    var heartRateStatus: String {
        guard savedWatchID != nil else { return "No watch" }
        switch state {
        case .connected: return "Waiting for watch…"
        case .connecting, .pairing, .handshaking, .scanning: return "Connecting…"
        case .bluetoothOff: return "Bluetooth off"
        case .idle, .failed: return "Watch not connected"
        }
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
        // Stress arrives every few seconds even when heart rate has gone quiet,
        // so any packet is a chance to reopen a stalled heart rate stream, in the
        // background as well as with the app open.
        if state == .connected, let at = heartRateAt, Date.now.timeIntervalSince(at) > 30 { keepHeartRateFlowing() }
        // The watch's packets wake the app in the background, so this catches a new
        // time zone without the app being opened.
        if state == .connected, offsetSentToWatch != nil, Date.now.timeIntervalSince(lastClockCheck) > 60 {
            lastClockCheck = .now
            syncClock(reason: "the phone's time zone changed")
        }
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
            // A live stream the watch shut (it can, mid-connection): open it again.
            if let live = Garmin.Service(rawValue: service), Garmin.Service.live.contains(live), state == .connected {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await reopen(live)
                }
            }
        case let .data(handle, payload):
            switch handles.first(where: { $0.value == handle })?.key {
            case Garmin.Service.gfdi.rawValue:
                for frame in assembler.append(payload) { receivedGFDI(frame) }
            case Garmin.Service.realtimeHeartRate.rawValue:
                if let reading = HeartRateReading(payload) {
                    heartRate = reading
                    heartRateAt = .now
                    if reading.bpm > 0 { keep(.heartRate, reading.bpm) }
                }
            case Garmin.Service.realtimeStress.rawValue:
                logRaw(.realtimeStress, payload)
                if let reading = LevelReading(payload) {
                    stress = reading.value
                    stressAt = .now
                    keep(.stress, reading.value)
                }
            case Garmin.Service.realtimeBodyBattery.rawValue:
                logRaw(.realtimeBodyBattery, payload)
                if let reading = LevelReading(payload) {
                    bodyBattery = reading.value
                    bodyBatteryAt = .now
                    keep(.bodyBattery, reading.value)
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

    private func logRaw(_ service: Garmin.Service, _ payload: [UInt8]) {
        guard rawLogged[service.rawValue, default: 0] < 5 else { return }
        rawLogged[service.rawValue, default: 0] += 1
        note("Live \(service): \(payload.map { String(format: "%02x", $0) }.joined())")
    }

    // MARK: Live readings

    /// Stores the reading on the phone, and every few minutes sends what the hub
    /// doesn't have yet. This runs in the background too (the watch's packets
    /// wake the app), so the hub keeps up without the app open; with no hub in
    /// reach the readings just wait on the phone.
    private func keep(_ kind: LiveStore.Kind, _ value: Int) {
        live.record(kind, value)
        guard let api, Date.now.timeIntervalSince(lastLivePost) > Self.livePostEvery, !files.isSyncing else { return }
        lastLivePost = .now
        Task { await files.postLive(api: api) }
    }

    private func receivedGFDI(_ frame: [UInt8]) {
        guard let message = GFDIMessage(frame: frame) else {
            note("Bad GFDI frame (\(frame.count) bytes)")
            return
        }
        note("← \(message.name) (\(message.payload.count) bytes)\(message.type == 5037 || message.type == 5030 ? " " + message.payload.map { String(format: "%02x", $0) }.joined() : "")")
        if installer.handle(message) { return }
        if settings.handle(message) { return }
        if files.handle(message) { return }
        switch Garmin.Message(rawValue: message.type) {
        case .response:
            if let types = GFDIMessage.supportedFileTypes(message.payload) {
                note("Watch serves \(types.count) file types: \(types.joined(separator: ", "))")
            }
            return
        case .notificationSubscription:
            send(GFDIMessage.notificationSubscriptionReply(message.payload))
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
            let offset = Self.phoneOffset()
            send(GFDIMessage.timeResponse(timeZone: .current))
            offsetSentToWatch = offset
            note("Gave the watch the time, \(Self.offsetName(offset))")
            return
        case .configuration:
            send(GFDIMessage.ack(message.type))
            // The watch lists what it can do and expects the phone's list back; until
            // it has one it treats the phone as able to do nothing (no phone-asked
            // syncs, no newer sync, no health files, no web requests).
            let theirs = Array(message.payload.dropFirst())
            note("Watch capabilities: \(theirs.map { String(format: "%02x", $0) }.joined()) (\(Garmin.capabilityNames(theirs).joined(separator: ", ")))")
            send(GFDIMessage.frame(Garmin.Message.configuration.rawValue, [UInt8(Garmin.phoneCapabilities.count)] + Garmin.phoneCapabilities))
            note("Told the watch the phone's capabilities")
            completeSetup()
            return
        case .synchronization:
            // The watch has new files for the phone: type (0 manual, 1 automatic), then a bitmask of what.
            send(GFDIMessage.ack(message.type))
            files.watchAskedForSync(manual: message.payload.first == 0)
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
        send(GFDIMessage.supportedFileTypesRequest())
        let args = ProcessInfo.processInfo.arguments // DIAGNOSTIC
        let events: [Garmin.SystemEvent] = args.contains("-noSyncComplete")
            ? [.syncReady, .pairComplete, .setupWizardComplete]
            : [.syncReady, .pairComplete, .syncComplete, .setupWizardComplete]
        for event in events {
            send(GFDIMessage.systemEvent(event))
        }
        note("Told the watch setup is complete")
        // The watch normally asks for the time by itself on connecting; if it hasn't, prompt it.
        Task {
            try? await Task.sleep(for: .seconds(12))
            if state == .connected, offsetSentToWatch == nil { syncClock(reason: "it hadn't asked since connecting", force: true) }
        }
        if ProcessInfo.processInfo.arguments.contains("-probeFiles") { // DIAGNOSTIC
            Task { try? await Task.sleep(for: .seconds(4)); await files.probeOnly() }
        }
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
                if let peripheral {
                    // Restored by iOS, or Bluetooth came back: set the channel up now,
                    // since calls made before power-on are dropped.
                    if wantsConnection, rx == nil { connect(peripheral) }
                } else {
                    if savedWatchID != nil {
                        connectSaved()
                    } else if !UserDefaults.standard.bool(forKey: Self.forgottenKey) {
                        adoptSystemWatch()
                    }
                }
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

    /// iOS relaunched the app in the background for the watch: pick the link back up.
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        MainActor.assumeIsolated {
            guard let watch = restored.first(where: { $0.identifier == savedWatchID }) ?? restored.first else { return }
            note("Restored by iOS (\(watch.state == .connected ? "connected" : "waiting for the watch"))")
            // The app's handles died with the old process. Calls to Bluetooth are
            // ignored until it reports power-on, so the channel is set up again there.
            reset()
            wantsConnection = true
            peripheral = watch
            watch.delegate = self
            state = .connecting
            if central.state == .poweredOn { connect(watch) }
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
            note(message.map { "Connection lost: \($0)" } ?? "The watch disconnected.")
            // Ask again straight away: iOS keeps the request open (in the background too)
            // and reconnects when the watch is back in range, as Garmin Connect does.
            connect(peripheral)
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

#if DEBUG
extension WatchLink {
    /// A Forerunner 965 that is already paired and connected, with a steady, repeatable pulse.
    fileprivate func startDemoWatch() {
        savedWatchID = UUID(uuidString: "9E5D1C2A-965A-4F00-9D3E-000000000965")
        savedWatchName = "Forerunner 965"
        state = .connected
        bodyBattery = 78
        bodyBatteryAt = .now
        stress = 18
        stressAt = .now
        files.demoLastSync()
        Task { @MainActor [weak self] in
            var tick = 0.0
            while let self {
                let bpm = 66 + Int((3 * DemoHub.wave(tick / 6)).rounded())
                self.heartRate = HeartRateReading([0, UInt8(bpm), 48])
                self.heartRateAt = .now
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
#endif
