import Charts
import SwiftUI

/// The fitness console, in place of Garmin Connect: today, heart rate, sleep,
/// activities and trends. Live numbers come straight from the watch over
/// Bluetooth; history comes from the hub, which parses the files the watch
/// hands over on each sync.
struct FitnessView: View {
    @Environment(AppSession.self) private var session
    @Environment(WatchLink.self) private var watch
    @State private var store = FitnessStore()
    @State private var showingWatch = false
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if watch.savedWatchID == nil {
                        welcome
                    } else {
                        watchBar
                        if let error = store.error, !store.loaded {
                            ErrorBanner(message: error)
                        }
                        today
                        heartRate
                        sleep
                        activities
                        trends
                    }
                }
                .padding(16)
                .animation(.smooth, value: watch.state)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Fitness")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                if watch.savedWatchID != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Watch", systemImage: "applewatch") { showingWatch = true }
                    }
                }
            }
            .navigationDestination(for: FitnessActivity.self) { ActivityDetailView(activity: $0, store: store) }
            .task { await store.load(api: session.api) }
            .refreshable {
                if watch.state == .connected { await watch.files.sync(api: session.api) }
                await store.load(api: session.api)
            }
            .onChange(of: watch.files.lastSync) { Task { await store.load(api: session.api) } }
            .sheet(isPresented: $showingWatch) { WatchSheet() }
            .sheet(isPresented: $pairing) { PairWatchSheet() }
        }
    }

    // MARK: Watch

    private var welcome: some View {
        Card {
            Image(systemName: "applewatch.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.tint)
            Text("Connect your Garmin").font(.title3.bold())
            Text("The watch talks straight to this phone, and your history goes to the hub. No Garmin Connect, no Garmin cloud.")
                .foregroundStyle(.secondary)
            Button("Pair your watch", systemImage: "plus") { pairing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    /// The watch's state and the sync button, in one line.
    private var watchBar: some View {
        let files = watch.files
        return HStack(spacing: 10) {
            Circle().fill(watch.state == .connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(watch.identity?.model ?? watch.savedWatchName ?? "Watch").font(.subheadline.weight(.semibold))
                Text(files.progress ?? watchStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if files.isSyncing {
                ProgressView()
            } else if watch.state == .connected || files.store.pendingUpload > 0 {
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") { Task { await files.sync(api: session.api) } }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if !watch.isBusy {
                Button("Connect") { watch.connectSaved() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: .capsule)
        .onTapGesture { showingWatch = true }
    }

    private var watchStatus: String {
        if let last = watch.files.lastSync, let failed = last.failed { return failed }
        switch watch.state {
        case .connected:
            if let last = watch.files.lastSync { return "Synced \(last.finishedAt.formatted(.relative(presentation: .named)))" }
            return "Connected"
        case .connecting, .pairing, .handshaking: return "Connecting…"
        case let .failed(reason), let .bluetoothOff(reason): return reason
        default: return "Not connected"
        }
    }

    // MARK: Today

    private var today: some View {
        let steps = max(watch.steps?.count ?? 0, store.today?.steps ?? 0)
        let goal = watch.steps.flatMap { $0.goal > 0 ? $0.goal : nil } ?? store.today?.stepGoal ?? 10_000
        let resting = watch.heartRate?.restingBPM ?? store.today?.restingHr ?? store.restingHr
        return Card(title: "Today") {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.green.opacity(0.18), lineWidth: 12)
                    Circle().trim(from: 0, to: min(Double(steps) / Double(max(goal, 1)), 1))
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(steps.formatted()).font(.title2.bold()).monospacedDigit().contentTransition(.numericText())
                        Text("of \(goal.formatted())").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 12) {
                    Metric(symbol: "heart.fill", color: .red, title: "Heart rate",
                           value: watch.heartRate.map { "\($0.bpm)" } ?? "–", unit: "bpm", live: watch.heartRate != nil && watch.state == .connected)
                    Metric(symbol: "bed.double.fill", color: .indigo, title: "Resting", value: resting.map(String.init) ?? "–", unit: "bpm")
                    Metric(symbol: "flame.fill", color: .orange, title: "This week",
                           value: "\(store.thisWeek.count)", unit: store.thisWeek.count == 1 ? "activity" : "activities")
                }
                Spacer(minLength: 0)
            }
            .animation(.smooth, value: steps)
        }
    }

    // MARK: Heart rate

    private var heartRate: some View {
        let points = (store.snapshot?.heartRate ?? []).compactMap { p in p.date.map { ($0, p.bpm) } }
        return Card(title: "Heart rate", trailing: points.isEmpty ? nil : "24 hours") {
            if points.isEmpty {
                Text("All-day heart rate appears once the watch hands over a monitoring file, usually after a day of wear.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                let low = points.map(\.1).min() ?? 0, high = points.map(\.1).max() ?? 0
                HStack {
                    Stat(label: "Low", value: "\(low)")
                    Stat(label: "High", value: "\(high)")
                    Stat(label: "Resting", value: store.restingHr.map(String.init) ?? "–")
                }
                Chart(points, id: \.0) { point in
                    LineMark(x: .value("Time", point.0), y: .value("BPM", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.red)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 140)
            }
        }
    }

    // MARK: Sleep

    private var sleep: some View {
        NavigationLink {
            SleepView(nights: store.nights)
        } label: {
            Card(title: "Sleep", trailing: store.lastNight?.startDate.map { $0.formatted(.dateTime.weekday(.wide)) }) {
                if let night = store.lastNight {
                    HStack(alignment: .firstTextBaseline) {
                        Text(FitnessFormat.duration(Double(night.asleepSeconds))).font(.title.bold())
                        Spacer()
                        if let score = night.score { Stat(label: "Score", value: "\(score)").fixedSize() }
                    }
                    StageBar(night: night).frame(height: 12)
                    HStack {
                        ForEach(SleepNight.Stage.allCases) { stage in
                            Label(FitnessFormat.duration(Double(night.seconds(stage))), systemImage: "circle.fill")
                                .labelStyle(TintedDot(color: stage.color))
                                .font(.caption)
                            if stage != .deep { Spacer() }
                        }
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("Sleep shows up after a night with the watch on, once it hands over the sleep file.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.nights.isEmpty)
    }

    // MARK: Activities

    private var activities: some View {
        Card(title: "Activities", trailing: store.activities.isEmpty ? nil : "\(store.thisWeek.count) this week") {
            if store.activities.isEmpty {
                Text("Activities from the watch show here after a sync.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(store.activities.prefix(4)) { activity in
                NavigationLink(value: activity) { ActivityRow(activity: activity) }.buttonStyle(.plain)
                if activity.id != store.activities.prefix(4).last?.id { Divider() }
            }
            if store.activities.count > 4 {
                NavigationLink {
                    ActivitiesView(activities: store.activities)
                } label: {
                    Text("All \(store.activities.count) activities").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Trends

    private var trends: some View {
        let days = store.days.filter { $0.steps != nil && $0.date != nil }.prefix(14)
        return NavigationLink {
            TrendsView(store: store)
        } label: {
            Card(title: "Steps", trailing: "Trends ›") {
                if days.isEmpty {
                    Text("Daily totals build up as you sync.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    StepsChart(days: Array(days), goal: store.today?.stepGoal ?? watch.steps?.goal).frame(height: 120)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Pieces

private struct Metric: View {
    var symbol: String
    var color: Color
    var title: String
    var value: String
    var unit: String
    var live = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                .symbolEffect(.pulse, isActive: live)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.headline).monospacedDigit().contentTransition(.numericText())
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct Stat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TintedDot: LabelStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color).font(.system(size: 7))
            configuration.title
        }
    }
}

/// The night's stages as one proportional bar.
struct StageBar: View {
    var night: SleepNight

    var body: some View {
        let total = Double(SleepNight.Stage.allCases.map { night.seconds($0) }.reduce(0, +))
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(SleepNight.Stage.allCases) { stage in
                    let share = total > 0 ? Double(night.seconds(stage)) / total : 0
                    if share > 0 {
                        Rectangle().fill(stage.color).frame(width: max(2, geometry.size.width * share - 2))
                    }
                }
            }
        }
        .clipShape(.capsule)
    }
}

struct ActivityRow: View {
    var activity: FitnessActivity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.symbol)
                .font(.title3).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(activity.color.gradient, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.subheadline.weight(.semibold))
                if let start = activity.start {
                    Text(start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(activity.hasDistance ? FitnessFormat.distance(activity.distanceMeters) : FitnessFormat.duration(activity.duration))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                HStack(spacing: 6) {
                    if activity.hasDistance { Text(FitnessFormat.duration(activity.duration)) }
                    if let hr = activity.avgHr { Label("\(hr)", systemImage: "heart.fill").labelStyle(TintedDot(color: .red)) }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }
}

struct StepsChart: View {
    var days: [FitnessDay]
    var goal: Int?

    var body: some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.date ?? .now, unit: .day), y: .value("Steps", day.steps ?? 0))
                    .foregroundStyle((day.steps ?? 0) >= (goal ?? .max) ? Color.green : Color.green.opacity(0.5))
                    .cornerRadius(3)
            }
            if let goal, goal > 0 {
                RuleMark(y: .value("Goal", goal)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
        }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: days.count > 10 ? 7 : 1)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
    }
}

// MARK: Watch sheet

/// Connection, pairing, files and the protocol log.
struct WatchSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(WatchLink.self) private var watch
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Watch", value: watch.identity?.model ?? watch.savedWatchName ?? "–")
                    if let identity = watch.identity { LabeledContent("Firmware", value: identity.firmware) }
                    LabeledContent("Status", value: status)
                    switch watch.state {
                    case .connected, .connecting, .pairing, .handshaking:
                        Button("Disconnect", role: .destructive) { watch.disconnect() }
                    default:
                        Button("Connect") { watch.connectSaved() }
                    }
                }

                Section {
                    let files = watch.files
                    Button {
                        Task { await files.sync(api: session.api) }
                    } label: {
                        HStack {
                            Text("Sync now")
                            Spacer()
                            if let progress = files.progress { Text(progress).foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                    .disabled(files.isSyncing || (watch.state != .connected && files.store.pendingUpload == 0))
                    LabeledContent("Files on this phone", value: "\(files.store.saved.count)")
                    LabeledContent("Waiting to send", value: "\(files.store.pendingUpload)")
                    if let last = files.lastSync {
                        LabeledContent("Last sync", value: last.failed ?? "\(last.downloaded) copied, \(last.uploaded) sent")
                        LabeledContent("On the watch", value: "\(last.listed) files")
                    }
                } header: {
                    Text("History")
                } footer: {
                    Text("Each sync copies up to \(watch.files.perSyncLimit) of the newest activity, sleep and monitoring files, then sends them to the hub. Nothing on the watch is changed or removed.")
                }

                Section("Connection log") {
                    if watch.log.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                    ForEach(watch.log.suffix(80).reversed()) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.time, format: .dateTime.hour().minute().second()).foregroundStyle(.tertiary).monospacedDigit()
                            Text(line.text)
                        }
                        .font(.caption)
                    }
                }

                Section {
                    Button("Pair a different watch") { pairing = true }
                    Button("Forget this watch", role: .destructive) {
                        watch.forget()
                        dismiss()
                    }
                } footer: {
                    Text("The log shows message types, never their contents. To fully unpair, also forget the watch in iOS Settings → Bluetooth.")
                }
            }
            .navigationTitle("Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $pairing) { PairWatchSheet() }
        }
    }

    private var status: String {
        switch watch.state {
        case let .bluetoothOff(reason), let .failed(reason): reason
        case .idle: "Not connected"
        case .scanning: "Scanning"
        case .connecting: "Connecting"
        case .pairing: "Pairing"
        case .handshaking: "Opening the data channel"
        case .connected: "Connected"
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
