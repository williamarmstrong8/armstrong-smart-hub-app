import SwiftUI

/// Live data straight from the Garmin watch over Bluetooth: no Garmin
/// Connect, no Garmin cloud.
struct FitnessView: View {
    @Environment(WatchLink.self) private var watch
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    status
                    if watch.savedWatchID != nil {
                        live
                        history
                    }
                    diagnostics
                }
                .padding(16)
                .animation(.smooth, value: watch.state)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Fitness")
            .toolbar { ToolbarItem(placement: .topBarLeading) { AccountButton() } }
            .sheet(isPresented: $pairing) { PairWatchSheet() }
        }
    }

    // MARK: Status

    private var status: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(watch.state == .connected ? .green : .secondary)
                    .symbolEffect(.pulse, isActive: watch.isBusy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(watch.identity?.model ?? watch.savedWatchName ?? "No watch").font(.headline)
                    Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if watch.savedWatchID == nil {
                Button("Pair your watch", systemImage: "plus") { pairing = true }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    switch watch.state {
                    case .connected, .connecting, .pairing, .handshaking:
                        Button("Disconnect", systemImage: "xmark") { watch.disconnect() }
                            .buttonStyle(.bordered)
                    default:
                        Button("Connect", systemImage: "bolt.horizontal") { watch.connectSaved() }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Pair a different watch", systemImage: "plus") { pairing = true }
                        Button("Forget this watch", systemImage: "trash", role: .destructive) { watch.forget() }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
    }

    private var statusText: String {
        switch watch.state {
        case let .bluetoothOff(reason): reason
        case .idle: watch.savedWatchID == nil ? "Pair it to see live data" : "Not connected"
        case .scanning: "Looking for watches"
        case .connecting: "Connecting… keep the watch nearby"
        case .pairing: "Accept the pairing request if iOS asks"
        case .handshaking: "Opening the data channel"
        case .connected:
            if let identity = watch.identity { "Connected · firmware \(identity.firmware)" } else { "Connected" }
        case let .failed(reason): reason
        }
    }

    // MARK: Live

    private var live: some View {
        HStack(spacing: 16) {
            Card(title: "Heart rate") {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                        .symbolEffect(.bounce, value: watch.heartRateAt)
                    Text(watch.heartRate.map { "\($0.bpm)" } ?? "–")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                        .monospacedDigit()
                    Text("bpm").font(.subheadline).foregroundStyle(.secondary)
                }
                Text(watch.heartRate?.restingBPM.map { "Resting \($0)" } ?? "Resting –")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "Steps today") {
                let count = watch.steps?.count
                let goal = watch.steps?.goal ?? 0
                Text(count.map { $0.formatted() } ?? "–")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                ProgressView(value: min(Double(count ?? 0) / Double(max(goal, 1)), 1))
                    .tint(.green)
                Text(goal > 0 ? "Goal \(goal.formatted())" : "Goal –")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(.smooth, value: watch.heartRate)
        .animation(.smooth, value: watch.steps)
    }

    // MARK: History

    private var history: some View {
        let files = watch.files
        let saved = files.store.saved.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return Card(title: "History", trailing: saved.isEmpty ? nil : "\(saved.count) on this phone") {
            if let progress = files.progress {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(progress).font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Button("Sync from watch", systemImage: "arrow.triangle.2.circlepath") { Task { await files.sync() } }
                    .buttonStyle(.bordered)
                    .disabled(watch.state != .connected)
            }
            if let last = files.lastSync {
                VStack(alignment: .leading, spacing: 2) {
                    Text(last.failed ?? "Copied \(last.downloaded) new file\(last.downloaded == 1 ? "" : "s")")
                        .foregroundStyle(last.failed == nil ? Color.primary : Color.red)
                    Text("Watch lists \(last.listed) files: " + last.byKind.sorted { $0.value > $1.value }.prefix(5)
                        .map { "\($0.value) \($0.key.replacingOccurrences(of: "_", with: " "))" }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            ForEach(saved.prefix(8), id: \.id) { item in
                HStack {
                    Image(systemName: icon(item.kind)).foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading) {
                        Text(item.kind.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline)
                        if let date = item.date {
                            Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(item.size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if !item.fitValid {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            Text("Copies up to \(files.perSyncLimit) of the newest activity, sleep and monitoring files per sync. Nothing on the watch is changed or removed.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .animation(.smooth, value: files.progress)
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "activity": "figure.run"
        case "sleep", "sleep_disruption": "bed.double"
        case "hrv_status": "waveform.path.ecg"
        default: "chart.bar"
        }
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        Card {
            DisclosureGroup("Connection log") {
                VStack(alignment: .leading, spacing: 4) {
                    if watch.log.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(watch.log.suffix(60).reversed()) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.time, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary).monospacedDigit()
                            Text(line.text)
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            Text("The watch talks only to this phone. Message types are logged here, never their contents.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Finds watches in pairing mode and connects to the one the user picks.
struct PairWatchSheet: View {
    @Environment(WatchLink.self) private var watch
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Unpair the watch from Garmin Connect or any other phone or computer. It holds one pairing at a time.", systemImage: "1.circle")
                    Label("On the watch: Settings → Connectivity → Phone → Pair Phone. Don't scan its QR code.", systemImage: "2.circle")
                    Label("Pick it below, then accept the pairing request iOS shows.", systemImage: "3.circle")
                }
                .font(.subheadline)

                Section {
                    if watch.candidates.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for watches…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(watch.candidates) { candidate in
                        Button {
                            watch.pair(candidate)
                            dismiss()
                        } label: {
                            HStack {
                                Text(candidate.name)
                                Spacer()
                                Text("\(candidate.rssi) dBm").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Only pick your own watch.")
                }
            }
            .navigationTitle("Pair watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { watch.startScan() }
            .onDisappear { watch.stopScan() }
        }
    }
}
