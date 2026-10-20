import Charts
import SwiftUI

/// The fitness console, in place of Garmin Connect: an overview of dials and
/// tiles, each opening its own page (FitnessPages.swift). Live numbers come straight from the watch over
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
    @State private var workouts = WorkoutStore()
    @State private var logging = false
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 40) {
                    VStack(spacing: 0) {
                        WatchHero(progress: watch.files.isSyncing ? (watch.files.fraction ?? 0.02) : nil).padding(.horizontal, -20).padding(.top, -12)
                        if watch.savedWatchID != nil {
                            Text(watchTitle)
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .onTapGesture { showingWatch = true }
                        }
                    }
                    if watch.savedWatchID == nil {
                        welcome
                        workoutsSection
                    } else {
                        if let error = store.error, !store.loaded {
                            ErrorBanner(message: error)
                        }
                        VStack(spacing: 0) {
                            dayHeader
                            TodayScores(store: store).padding(.vertical, 20)
                            today
                            workoutsSection
                            FitSection(title: "Body") {
                                OverviewList(store: store, liveBpm: watch.heartRate?.bpm,
                                             steps: max(watch.steps?.count ?? 0, store.today?.steps ?? 0),
                                             stepGoal: store.today?.stepGoal ?? watch.steps?.goal)
                            }
                            RecentActivities(activities: store.activities)
                        }
                        syncStatus
                    }
                }
                .padding(.horizontal, Fit.gutter)
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
            .navigationDestination(for: FitnessActivity.self) { ActivityPage(activity: $0, store: store) }
            .navigationDestination(for: FitnessPage.self) { $0.view(store: store) }
            .navigationDestination(for: WorkoutRoute.self) { WorkoutDetailPage(id: $0.id, store: workouts) }
            .navigationDestination(for: ExerciseRoute.self) { ExerciseDetailPage(route: $0, store: workouts) }
            .fullScreenCover(isPresented: $logging) {
                ActiveWorkoutView(store: workouts, maxHr: store.snapshot?.metrics?.profile?.maxHr)
            }
            // Live readings go into the workout in progress, whichever screen is showing.
            .onChange(of: watch.heartRateAt) { _, at in
                if let at, let bpm = watch.heartRate?.bpm, workouts.active != nil { workouts.record(bpm: bpm, at: at) }
            }
            .task {
                async let logged: Void = workouts.load(api: session.api)
                await store.load(api: session.api)
                await autoSync()
                await logged
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await autoSync() } }
            }
            .refreshable {
                // Return right away so the system spinner doesn't hold the page
                // open; the watch hero shows the sync instead.
                Task { await autoSync(force: true) }
                Task { await workouts.load(api: session.api) }
            }
            .onChange(of: watch.files.lastSync) { Task { await store.load(api: session.api) } }
            .sheet(isPresented: $showingWatch) { WatchSheet() }
            .sheet(isPresented: $pairing) { PairWatchSheet() }
        }
    }

    // MARK: Workouts

    private var workoutsSection: some View {
        WorkoutsSection(store: workouts, onStart: { routine in
            if workouts.active == nil { workouts.start(routine, unit: unit) }
            logging = true
        }, onResume: { logging = true })
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

    private var watchTitle: String {
        let name = watch.identity?.model ?? watch.savedWatchName ?? "Forerunner 965"
        return name.localizedCaseInsensitiveContains("forerunner") ? name : "Forerunner \(name)"
    }

    /// Sync status, centered at the bottom of the page.
    private var syncStatus: some View {
        Text(watch.files.progress ?? watchStatus)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { showingWatch = true }
    }

    /// A good sync stays fresh this long; opening the page or returning to the
    /// app inside the window doesn't sync again. Pull-to-refresh always does.
    private static let staleAfter: TimeInterval = 30 * 60
    /// After a failed sync, wait this long before retrying on its own.
    private static let retryAfter: TimeInterval = 60

    /// Reconnects if needed, waits briefly for the watch, then syncs. Runs on
    /// open and on return to the foreground only when the last sync is stale,
    /// and always on pull-to-refresh.
    private func autoSync(force: Bool = false) async {
        guard watch.savedWatchID != nil else { return }
        let files = watch.files
        if !force, files.isSyncing { return }
        if !force, let last = files.lastSync {
            let age = Date.now.timeIntervalSince(last.finishedAt)
            if age < (last.failed == nil ? Self.staleAfter : Self.retryAfter) { return }
        }
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

    /// "Today" and the date, Oura's page title.
    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today").font(.system(size: 34, weight: .semibold))
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.subheadline).foregroundStyle(Fit.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nextWorkoutView: some View {
        let next = nextWorkout
        return HStack(spacing: 14) {
            TablerIcon(name: next.icon, size: 26).foregroundStyle(Fit.muted).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(next.title).font(.system(size: 22, weight: .regular))
                Text(next.detail).font(.footnote).foregroundStyle(Fit.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture { pplOffset += 1 }
    }

    /// Next workout, then this week as seven dots, one per day.
    private var today: some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let week = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? start
        let weekDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
        let days = workoutDays
        let done = weekDays.filter { days.contains($0) }.count
        return FitSection(title: "Next workout", trailing: streak > 1 ? "\(streak)-day streak" : "\(done) of 7 days this week") {
            nextWorkoutView
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    let worked = days.contains(day)
                    let isToday = calendar.isDate(day, inSameDayAs: start)
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(isToday ? Color.primary : Fit.track, lineWidth: isToday ? 1.5 : 1)
                            if worked { Circle().fill(Fit.positive).padding(5) }
                        }
                        .frame(width: 26, height: 26)
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption.weight(isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? Color.primary : Fit.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(.smooth, value: days.count)
        }
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
                    NavigationLink("Inspect files") { FitnessInspectView() }
                    NavigationLink("Install to watch") { FitnessInstallView() }
                    LabeledContent("Files on this phone", value: "\(files.store.saved.count)")
                    LabeledContent("Waiting to send", value: "\(files.store.pendingUpload)")
                    if let last = files.lastSync {
                        LabeledContent("Last sync", value: last.failed ?? "\(last.downloaded) copied, \(last.uploaded) sent")
                        LabeledContent("On the watch", value: "\(last.listed) files")
                    }
                    Button {
                        Task { await watch.settings.push(api: session.api) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(watch.settings.isPushing ? "Updating glances…" : "Send hub values to the glances")
                            if let result = watch.settings.lastResult {
                                Text(result).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(watch.state != .connected || watch.settings.isPushing || files.isSyncing)
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
