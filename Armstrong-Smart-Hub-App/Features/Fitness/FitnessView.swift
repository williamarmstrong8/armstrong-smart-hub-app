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
    @AppStorage("fitness.pplOffset") private var pplOffset = 0
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 40) {
                    VStack(spacing: 4) {
                        WatchHero(progress: watch.files.isSyncing ? (watch.files.fraction ?? 0.02) : nil).padding(.horizontal, -20).padding(.top, -12)
                        if watch.savedWatchID != nil { watchBar }
                    }
                    if watch.savedWatchID == nil {
                        welcome
                    } else {
                        if let error = store.error, !store.loaded {
                            ErrorBanner(message: error)
                        }
                        today
                        heartRate
                        sleep
                        hrv
                        activities
                        trends
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .padding(.bottom, 24)
                .animation(.smooth, value: watch.state)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Fitness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                if watch.savedWatchID != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingWatch = true } label: { TablerIcon(name: "device-watch", size: 22) }.accessibilityLabel("Watch")
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
            Button { pairing = true } label: {
                HStack(spacing: 6) { TablerIcon(name: "plus", size: 18); Text("Pair your watch") }
            }
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

    // MARK: Next workout

    /// Push / pull / legs rotation. The watch doesn't label strength sessions, so the
    /// cycle is counted from the order of logged strength sessions, and tapping the
    /// suggestion shifts it by one when it is off (stored in `pplOffset`).
    private static let split = ["Push day", "Pull day", "Leg day"]

    private var nextWorkout: (icon: String, title: String, detail: String) {
        let calendar = Calendar.current
        let all = store.activities.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        let strength = all.filter { $0.subSport == "strength_training" || $0.sport == "training" || $0.sport == "fitness_equipment" }
        let todayStart = calendar.startOfDay(for: .now)
        let doneToday = workoutDays.contains(todayStart)
        let lastDate = all.last?.start
        let daysSince = lastDate.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: todayStart).day ?? 0 }
        guard let last = all.last, let gap = daysSince else {
            return ("walk", "Start easy", "Log a first workout to begin the streak")
        }
        if gap >= 5 {
            return ("walk", "Ease back in", "Easy 30 minutes, nothing heavy. Last workout \(gap) days ago")
        }
        let index = ((strength.count + pplOffset) % 3 + 3) % 3
        let name = Self.split[index]
        let lastWhen = gap == 0 ? "today" : gap == 1 ? "yesterday" : "\(gap) days ago"
        let detail = doneToday ? "Tomorrow. Last: \(last.title.lowercased()) \(lastWhen)"
                               : "Today. Last: \(last.title.lowercased()) \(lastWhen)"
        return ("barbell", name, detail)
    }

    private var nextWorkoutView: some View {
        let next = nextWorkout
        return HStack(spacing: 16) {
            TablerIcon(name: next.icon, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT WORKOUT").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                Text(next.title).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(next.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture { pplOffset += 1 }
    }

    private var today: some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let week = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? start
        let weekDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
        let days = workoutDays
        let steps = max(watch.steps?.count ?? 0, store.today?.steps ?? 0)
        let resting = watch.heartRate?.restingBPM ?? store.today?.restingHr ?? store.restingHr
        let bpm = watch.heartRate?.bpm
        let goal = store.today?.stepGoal ?? watch.steps?.goal
        return VStack(alignment: .leading, spacing: 36) {
            FloatingSection(title: "Today", trailing: Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                VStack(alignment: .leading, spacing: 32) {
                    nextWorkoutView
                    HStack(spacing: 0) {
                        ForEach(weekDays, id: \.self) { day in
                            let worked = days.contains(day)
                            let isToday = calendar.isDate(day, inSameDayAs: start)
                            VStack(spacing: 10) {
                                TablerIcon(name: worked ? "circle-check" : "circle", size: 44)
                                    .foregroundStyle(worked ? Color.green : Color.primary.opacity(isToday ? 0.5 : 0.18))
                                Text(day.formatted(.dateTime.weekday(.narrow)))
                                    .font(.caption.weight(isToday ? .bold : .regular))
                                    .foregroundStyle(isToday ? Color.primary : Color.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .animation(.smooth, value: days.count)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                BigMetric(symbol: "walk", tint: .green, title: "Steps", value: steps.formatted(),
                          progress: goal.flatMap { $0 > 0 ? min(Double(steps) / Double($0), 1) : nil })
                BigMetric(symbol: "heart", tint: .red, title: "Heart bpm", value: bpm.map { "\($0)" } ?? "–")
                BigMetric(symbol: "bed", tint: .indigo, title: "Resting bpm", value: resting.map(String.init) ?? "–")
            }
        }
    }

    // MARK: Heart rate

    private var heartRate: some View {
        let points = (store.snapshot?.heartRate ?? []).compactMap { p in p.date.map { ($0, p.bpm) } }
        return FloatingSection(title: "Heart rate", trailing: points.isEmpty ? nil : "\(points.map(\.1).min() ?? 0)–\(points.map(\.1).max() ?? 0) bpm today") {
            if points.isEmpty {
                Text("All-day heart rate appears once the watch hands over a monitoring file, usually after a day of wear.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                let low = points.map(\.1).min() ?? 0
                Chart(points, id: \.0) { point in
                    AreaMark(x: .value("Time", point.0), yStart: .value("Floor", max(low - 10, 0)), yEnd: .value("BPM", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [.red.opacity(0.28), .red.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.0), y: .value("BPM", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis(.hidden)
                .frame(height: 140)
            }
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
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                        Spacer()
                        if let score = night.score {
                            VStack(spacing: 0) {
                                Text("\(score)").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(.indigo)
                                Text("score").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    StageBar(night: night).frame(height: 14)
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

    // MARK: HRV

    @ViewBuilder private var hrv: some View {
        let nights = (store.snapshot?.hrv ?? []).filter { $0.lastNightAverage != nil && $0.date != nil }
        if let last = nights.first, let value = last.lastNightAverage {
            FloatingSection(title: "HRV", trailing: last.status.map { $0.capitalized }) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(value.rounded()))")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundStyle(.teal)
                            .monospacedDigit()
                        Text("ms").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let weekly = last.weeklyAverage {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int(weekly.rounded()))").font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                            Text("7-day avg").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Chart {
                    if let low = last.baselineBalancedLower, let high = last.baselineBalancedUpper, let first = nights.last?.date {
                        RectangleMark(xStart: .value("From", first), xEnd: .value("To", last.date ?? first),
                                      yStart: .value("Low", low), yEnd: .value("High", high))
                            .foregroundStyle(Color.teal.opacity(0.12))
                    }
                    ForEach(nights.reversed()) { night in
                        if let date = night.date, let average = night.lastNightAverage {
                            LineMark(x: .value("Night", date), y: .value("HRV", average))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(.teal)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            PointMark(x: .value("Night", date), y: .value("HRV", average))
                                .foregroundStyle(.teal)
                                .symbolSize(18)
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis(.hidden)
                .frame(height: 110)
            }
        }
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
                                    TablerIcon(name: "arrow-right", size: 34).foregroundStyle(.primary)
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
            TablerIcon(name: symbol, size: 18).foregroundStyle(color)
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
            TablerIcon(name: activity.symbol, size: 26).foregroundStyle(.primary)
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
                    if let hr = activity.avgHr { HStack(spacing: 3) { TablerIcon(name: "heart", size: 11); Text("\(hr)") } }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            TablerIcon(name: "chevron-right", size: 14).foregroundStyle(.tertiary)
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
    @State private var reparse: String?

    /// Asks the hub to parse every file it has stored again, so data from before a parser fix shows up.
    private func rereadHub() async {
        reparse = "Working…"
        struct Result: Decodable { var files: Int; var parsed: Int; var failed: Int }
        do {
            let request = session.api.request("/api/mobile/fitness/reparse?tz=\(TimeZone.current.secondsFromGMT())", method: "POST", timeout: 300)
            let result: Result = try await session.api.send(request)
            reparse = "\(result.parsed) of \(result.files) read\(result.failed > 0 ? ", \(result.failed) failed" : "")"
        } catch {
            reparse = error.localizedDescription
        }
    }

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
                    Button {
                        Task { await rereadHub() }
                    } label: {
                        HStack {
                            Text("Re-read stored files on the hub")
                            Spacer()
                            if let reparse { Text(reparse).foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                    .disabled(reparse == "Working…")
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

                Section {
                    let files = watch.files
                    if let last = files.lastSync {
                        ForEach(last.byKind.sorted { $0.key < $1.key }, id: \.key) { kind, count in
                            LabeledContent("Listed: \(kind)", value: "\(count)")
                        }
                    }
                    let kinds = Dictionary(grouping: files.store.saved.values, by: \.kind)
                    ForEach(kinds.keys.sorted(), id: \.self) { kind in
                        let items = kinds[kind] ?? []
                        LabeledContent("On phone: \(kind)", value: "\(items.count), \(items.filter { $0.uploadedAt != nil }.count) sent")
                    }
                    ForEach(files.store.saved.values.filter { $0.parseError != nil }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(10), id: \.id) { item in
                        Text("\(item.kind): \(item.parseError ?? "")").font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Data check")
                } footer: {
                    Text("Which file types the watch lists, what reached this phone, and any file the hub couldn't read.")
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
                    Label { Text("Unpair the watch from Garmin Connect or any other phone or computer. It holds one pairing at a time.") } icon: { Text("1").monospacedDigit().foregroundStyle(.secondary) }
                    Label { Text("On the watch: Settings → Connectivity → Phone → Pair Phone. Don't scan its QR code.") } icon: { Text("2").monospacedDigit().foregroundStyle(.secondary) }
                    Label { Text("Pick it below, then accept the pairing request iOS shows.") } icon: { Text("3").monospacedDigit().foregroundStyle(.secondary) }
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
