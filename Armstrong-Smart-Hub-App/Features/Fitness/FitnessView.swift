import Charts
import SwiftUI

/// The fitness console, in place of Garmin Connect: today, heart rate, sleep,
/// activities and trends. Live numbers come straight from the watch over
/// Bluetooth; history comes from the hub, which parses the files the watch
/// hands over on each sync.
struct FitnessView: View {
    @Environment(AppSession.self) private var session
    @Environment(WatchLink.self) private var watch
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = FitnessStore()
    @State private var showingWatch = false
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    WatchHero(progress: watch.files.isSyncing ? (watch.files.fraction ?? 0.02) : nil).padding(.horizontal, -16).padding(.top, -12)
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
            .background(Color(.systemBackground))
            .navigationTitle("Fitness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                if watch.savedWatchID != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Watch", systemImage: "applewatch") { showingWatch = true }
                    }
                }
            }
            .navigationDestination(for: FitnessActivity.self) { ActivityDetailView(activity: $0, store: store) }
            .task {
                await store.load(api: session.api)
                await autoSync()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await autoSync() } }
            }
            .refreshable {
                await store.load(api: session.api)
                await autoSync(force: true)
            }
            .onChange(of: watch.files.lastSync) { Task { await store.load(api: session.api) } }
            .sheet(isPresented: $showingWatch) { WatchSheet() }
            .sheet(isPresented: $pairing) { PairWatchSheet() }
        }
    }

    // MARK: Watch

    private var welcome: some View {
        VStack(spacing: 10) {
            Text("Connect your Garmin").font(.title2.bold())
            Text("The watch talks straight to this phone, and your history goes to the hub. No Garmin Connect, no Garmin cloud.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Pair your watch", systemImage: "plus") { pairing = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
    }

    /// The watch's name and status; sync progress shows on the watch face above.
    private var watchBar: some View {
        let files = watch.files
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(watch.identity?.model ?? watch.savedWatchName ?? "Watch").font(.subheadline.weight(.semibold))
                Text(files.progress ?? watchStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(.rect)
        .onTapGesture { showingWatch = true }
    }

    /// Reconnects if needed, waits briefly for the watch, then syncs. Runs on
    /// open, when the app returns to the foreground, and on pull-to-refresh.
    private func autoSync(force: Bool = false) async {
        guard watch.savedWatchID != nil else { return }
        let files = watch.files
        if !force, files.isSyncing { return }
        if !force, let last = files.lastSync, Date.now.timeIntervalSince(last.finishedAt) < 60 { return }
        if watch.state != .connected, !watch.isBusy { watch.connectSaved() }
        var waited = 0.0
        while watch.state != .connected, waited < 20 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 0.5
            if Task.isCancelled { return }
        }
        await files.sync(api: session.api)
        await store.load(api: session.api)
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

    private var workoutDays: Set<Date> {
        Set(store.activities.compactMap { $0.start.map { Calendar.current.startOfDay(for: $0) } })
    }

    /// Consecutive days with a workout, counting back from today (or from
    /// yesterday while today's workout is still to come).
    private var streak: Int {
        let calendar = Calendar.current
        let days = workoutDays
        var day = calendar.startOfDay(for: .now)
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    private var today: some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let done = workoutDays.contains(start)
        let week = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? start
        let weekDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
        let days = workoutDays
        let streakCount = self.streak
        let steps = max(watch.steps?.count ?? 0, store.today?.steps ?? 0)
        let resting = watch.heartRate?.restingBPM ?? store.today?.restingHr ?? store.restingHr
        let bpm = watch.heartRate?.bpm
        return VStack(alignment: .leading, spacing: 28) {
            FloatingSection(title: "Today", trailing: Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(done ? "Done" : "Not yet")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                        Text("workout today").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(streakCount)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("day streak").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(weekDays, id: \.self) { day in
                        let worked = days.contains(day)
                        let isToday = calendar.isDate(day, inSameDayAs: start)
                        VStack(spacing: 8) {
                            Image(systemName: worked ? "checkmark.circle" : "circle")
                                .font(.system(size: 28, weight: .ultraLight))
                                .foregroundStyle(worked ? Color.primary : Color.primary.opacity(0.2))
                                .frame(height: 36)
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption.weight(isToday ? .bold : .regular))
                                .foregroundStyle(isToday ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 6)
                .animation(.smooth, value: streakCount)
            }
            triathlon
            HStack(alignment: .top) {
                BigMetric(symbol: "figure.walk", color: .primary, title: "Steps", value: steps.formatted(), unit: "today")
                BigMetric(symbol: "heart", color: .primary, title: "Heart rate",
                          value: bpm.map { "\($0)" } ?? "–", unit: "bpm", live: bpm != nil && watch.state == .connected)
                BigMetric(symbol: "bed.double", color: .primary, title: "Resting", value: resting.map(String.init) ?? "–", unit: "bpm")
            }
        }
    }

    // MARK: Triathlon mix

    private var triathlon: some View {
        let calendar = Calendar.current
        let week = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? calendar.startOfDay(for: .now)
        let thisWeek = store.activities.filter { ($0.start ?? .distantPast) >= week }
        let legs: [(name: String, symbol: String, sports: Set<String>)] = [
            ("Swim", "figure.pool.swim", ["swimming"]),
            ("Bike", "figure.outdoor.cycle", ["cycling", "e_biking"]),
            ("Run", "figure.run", ["running"]),
        ]
        let rows = legs.map { leg -> (String, String, [FitnessActivity]) in
            (leg.name, leg.symbol, thisWeek.filter { leg.sports.contains($0.sport) })
        }
        let totals = rows.map { $0.2.reduce(0) { $0 + ($1.duration ?? 0) } }
        let biggest = max(totals.max() ?? 0, 1)
        return FloatingSection(title: "Triathlon mix", trailing: "This week") {
            VStack(spacing: 18) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let distance = row.2.reduce(0) { $0 + ($1.distanceMeters ?? 0) }
                    HStack(spacing: 14) {
                        Image(systemName: row.1)
                            .font(.system(size: 26, weight: .ultraLight))
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.0).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(row.2.isEmpty ? "–" : "\(FitnessFormat.distance(distance))  \(FitnessFormat.duration(totals[index]))")
                                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.12))
                                    Capsule().fill(Color.primary)
                                        .frame(width: geo.size.width * totals[index] / biggest)
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                }
            }
        }
    }

    // MARK: Heart rate

    private var heartRate: some View {
        let points = (store.snapshot?.heartRate ?? []).compactMap { p in p.date.map { ($0, p.bpm) } }
        return FloatingSection(title: "Heart rate", trailing: points.isEmpty ? nil : "24 hours") {
            if points.isEmpty {
                Text("All-day heart rate appears once the watch hands over a monitoring file, usually after a day of wear.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                let low = points.map(\.1).min() ?? 0, high = points.map(\.1).max() ?? 0
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    heartStat("Low", "\(low)")
                    heartStat("High", "\(high)")
                    heartStat("Resting", store.restingHr.map(String.init) ?? "–")
                }
                Chart(points, id: \.0) { point in
                    AreaMark(x: .value("Time", point.0), yStart: .value("Floor", max(low - 10, 0)), yEnd: .value("BPM", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [.red.opacity(0.4), .red.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.0), y: .value("BPM", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis(.hidden)
                .frame(height: 150)
            }
        }
    }

    private func heartStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Sleep

    private var sleep: some View {
        NavigationLink {
            SleepView(nights: store.nights)
        } label: {
            FloatingSection(title: "Sleep", trailing: store.lastNight?.startDate.map { $0.formatted(.dateTime.weekday(.wide)) }) {
                if let night = store.lastNight {
                    HStack(alignment: .firstTextBaseline) {
                        Text(FitnessFormat.duration(Double(night.asleepSeconds)))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Spacer()
                        if let score = night.score {
                            VStack(spacing: 0) {
                                Text("\(score)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.indigo)
                                Text("score").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    StageBar(night: night).frame(height: 22)
                    HStack(alignment: .top) {
                        ForEach(SleepNight.Stage.allCases) { stage in
                            VStack(spacing: 2) {
                                Text(FitnessFormat.duration(Double(night.seconds(stage)))).font(.subheadline.weight(.bold)).monospacedDigit()
                                Label(stage.name, systemImage: "circle.fill")
                                    .labelStyle(TintedDot(color: stage.color))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
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
        FloatingSection(title: "Activities", trailing: store.activities.isEmpty ? nil : "\(store.thisWeek.count) this week") {
            if store.activities.isEmpty {
                Text("Activities from the watch show here after a sync.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 26) {
                        ForEach(store.activities.prefix(8)) { activity in
                            NavigationLink(value: activity) { ActivityTile(activity: activity) }.buttonStyle(.plain)
                        }
                        if store.activities.count > 8 {
                            NavigationLink {
                                ActivitiesView(activities: store.activities)
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "arrow.right").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.primary)
                                    Text("All \(store.activities.count)").font(.subheadline.weight(.semibold))
                                }
                                .frame(width: 80, height: 120)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: Trends

    private var trends: some View {
        let days = store.days.filter { $0.steps != nil && $0.date != nil }.prefix(14)
        return NavigationLink {
            TrendsView(store: store)
        } label: {
            FloatingSection(title: "Steps", trailing: "Trends ›") {
                if days.isEmpty {
                    Text("Daily totals build up as you sync.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    StepsChart(days: Array(days), goal: store.today?.stepGoal ?? watch.steps?.goal).frame(height: 140)
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
                .font(.system(size: 24, weight: .ultraLight)).foregroundStyle(.primary)
                .frame(width: 40, height: 40)
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
                    if let hr = activity.avgHr { Label("\(hr)", systemImage: "heart").font(.caption.weight(.light)) }
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
                    .foregroundStyle(LinearGradient(colors: [.green, .mint.opacity((day.steps ?? 0) >= (goal ?? .max) ? 0.9 : 0.35)],
                                                    startPoint: .top, endPoint: .bottom))
                    .cornerRadius(5)
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
