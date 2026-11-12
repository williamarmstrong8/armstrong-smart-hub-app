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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = FitnessStore()
    @State private var checkins = CheckinStore.shared
    @State private var showingWatch = false
    @State private var showingFaces = false
    @State private var pairing = false
    @State private var workouts = WorkoutStore.shared
    /// The pages open on top of the overview.
    @State private var path = NavigationPath()
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical) {
                VStack(spacing: HubLayout.sectionGap) {
                    // Keep the hero and its account/watch presentation eagerly mounted.
                    sheet
                    LazyVStack(spacing: HubLayout.sectionGap) {
                        if watch.savedWatchID == nil {
                            workoutsSection
                        } else {
                            if let error = store.error, !store.loaded {
                                ErrorBanner(message: error)
                            }
                            VStack(spacing: 0) {
                                // MorningCheckin owns its trailing space; don't double it.
                                MorningCheckin(store: checkins)
                                today
                            }
                            // Live updates stay inside individual overview rows.
                            OverviewList(store: store)
                            // Keep the carousel's horizontal scroll targets together.
                            workoutsSection
                            syncStatus
                        }
                    }
                    .environment(\.fitnessCards, true)
                    .padding(.horizontal, HubLayout.gutter)
                }
                .padding(.bottom, HubLayout.bottomInset)
                .containerRelativeFrame(.horizontal)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .demoScroll()
            .hubPageStyle(backdrop: true)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FitnessActivity.self) { ActivityPage(activity: $0, store: store) }
            .navigationDestination(for: FitnessPage.self) { $0.view(store: store) }
            .navigationDestination(for: WorkoutRoute.self) { WorkoutDetailPage(id: $0.id, store: workouts) }
            .navigationDestination(for: ExerciseRoute.self) { ExerciseDetailPage(route: $0, store: workouts) }
            // The workout screen opens from the tab bar (MainTabView), which needs this for zones.
            // The check-in day turns over at waking, so it follows the newest sleep.
            .onChange(of: store.lastNight?.endDate, initial: true) { _, end in
                checkins.lastWake = end
                if checkins.page != nil, checkins.page?.day != checkins.day { Task { await checkins.load(api: session.api) } }
            }
            .onChange(of: store.snapshot?.metrics?.profile?.maxHr, initial: true) { _, max in
                if let max { workouts.maxHr = max }
            }
            .task {
                async let logged: Void = workouts.load(api: session.api)
                async let checkedIn: Void = checkins.load(api: session.api)
                await store.load(api: session.api)
                await autoSync()
                await logged
                await checkedIn
            }
            // While the page is open, keep the live link up: reconnect a dropped or
            // stalled one, or reopen a heart rate stream that went quiet.
            .task {
                while !Task.isCancelled {
                    watch.keepHeartRateFlowing()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    watch.ensureConnected()
                    Task { await autoSync() }
                }
                // A new day, or answers that waited for the hub.
                if phase == .active, checkins.page?.day != checkins.day || !checkins.pending.isEmpty {
                    Task { await checkins.load(api: session.api) }
                }
            }
            .refreshable {
                // Keep refresh active until both independent loads finish.
                async let synced: Void = autoSync(force: true)
                async let logged: Void = workouts.load(api: session.api)
                await (synced, logged)
            }
            .onChange(of: watch.files.lastSync) {
                Task { await store.load(api: session.api) }
                // Last night's sleep only reaches the hub on a sync, and the guess needs it.
                Task { await checkins.load(api: session.api) }
            }
            #if DEBUG
            .onAppear {
                DemoCue.on("sync") { Task { await watch.files.sync(api: session.api) } }
                // `nav readiness|recovery|strain|sleep|heart|energy|training|health|workout|activity`, then `back`.
                DemoCue.on("nav", arg: { name in
                    let pages: [String: FitnessPage] = ["readiness": .readiness, "recovery": .recovery, "strain": .strain,
                                                        "sleep": .sleep, "heart": .heart, "energy": .energy,
                                                        "training": .training, "health": .health]
                    if let page = pages[name] { path.append(page) }
                    else if name == "workout", let w = workouts.home?.workouts.first { path.append(WorkoutRoute(id: w.id)) }
                    else if name == "activity", let a = store.activities.first { path.append(a) }
                })
                DemoCue.on("back") { if !path.isEmpty { path.removeLast() } }
                DemoCue.on("workout.start") { startWorkout(workouts.home?.routines.first) }
                DemoCue.on("workout.set") {
                    guard let w = workouts.active else { return }
                    for e in w.exercises {
                        if let s = e.sets.first(where: { $0.completedAt == nil }) {
                            workouts.toggle(e.id, s.id, liveHr: watch.heartRate?.bpm)
                            return
                        }
                    }
                }
                DemoCue.on("workout.close") { workouts.isPresented = false }
                DemoCue.on("workout.end") { workouts.isPresented = false; workouts.discard() }
            }
            #endif
            .sheet(isPresented: $showingWatch) { WatchSheet() }
            .sheet(isPresented: $showingFaces) { WatchFacesSheet() }
            .sheet(isPresented: $pairing) { PairWatchSheet() }
        }
    }

    // MARK: Workouts

    private var workoutsSection: some View {
        WorkoutsSection(store: workouts, onStart: startWorkout, onResume: { workouts.isPresented = true })
    }

    private func startWorkout(_ routine: Routine?) {
        if workouts.active == nil { workouts.start(routine, unit: unit) }
        workouts.isPresented = true
    }

    // MARK: Watch

    private var welcome: some View {
        VStack(spacing: 10) {
            Text("Connect your Garmin").font(.title2.bold())
            Text("The watch talks straight to this phone, and your history goes to the hub. No Garmin Connect, no Garmin cloud.")
                .multilineTextAlignment(.center)
                .foregroundStyle(BrickLook.soft)
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
        Button { showingWatch = true } label: {
            Text(watch.files.progress ?? watchStatus)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens watch details")
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
        watch.ensureConnected()
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
        // No hub: say so, rather than an error, since the page still works from the phone.
        if store.isOffline {
            let since = store.updatedAt.map { " from \($0.formatted(.relative(presentation: .named)))" } ?? ""
            return "Offline · hub data\(since), today from the watch"
        }
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

    /// The top sheet, like Brick's: the watch floating on it, the day, and the three scores.
    private var sheet: some View {
        VStack(spacing: 0) {
            BrickTopBar {
                if watch.savedWatchID != nil {
                    Button { showingWatch = true } label: {
                        TablerIcon(name: "device-watch", size: 22)
                            .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Watch")
                }
            }
            .buttonStyle(.plain)
            .frame(minHeight: HubLayout.minHitTarget)
            .padding(.top, HubLayout.topInset)
            Button { if watch.savedWatchID != nil { showingFaces = true } } label: {
                WatchHero(progress: watch.files.isSyncing ? (watch.files.fraction ?? 0.02) : nil)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Watch faces")
            .padding(.top, 4)
            if watch.savedWatchID != nil {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .font(.caption.weight(.medium)).tracking(1.2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(BrickLook.soft).padding(.top, 14)
                Button { showingWatch = true } label: {
                    Text(watchTitle)
                        .font(.largeTitle.weight(.light))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens watch details")
                .padding(.top, HubLayout.topInset)
                TodayScores(store: store)
                    .hubAnimation(value: store.snapshot?.watch?.readiness?.score ?? store.snapshot?.metrics?.readiness.score)
                    .hubAnimation(value: store.snapshot?.watch?.sleep?.overall ?? store.lastNight?.score)
                    .hubAnimation(value: store.currentBodyBattery ?? store.snapshot?.metrics?.bodyBattery?.current ?? store.snapshot?.insights?.stress.bodyBattery?.current)
                    .transaction { transaction in
                        // ScoreRing also has its own animation in the shared component.
                        if reduceMotion {
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    }
                    .padding(.top, HubLayout.sectionGap)
            } else {
                welcome.padding(.top, HubLayout.sectionGap)
            }
        }
        .padding(.horizontal, HubLayout.gutter)
        .padding(.bottom, HubLayout.sectionGap)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: BrickLook.sheetRadius, bottomTrailingRadius: BrickLook.sheetRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .padding(.top, -600)
        }
    }

    /// This week: workouts and check-ins in one strip. Straight on the page.
    private var today: some View {
        let calendar = Calendar.current
        let week = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? calendar.startOfDay(for: .now)
        let days = workoutDays
        let done = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }.filter { days.contains($0) }.count
        return WeekStrip(store: checkins, workoutDays: days,
                         trailing: streak > 1 ? "\(streak)-day streak" : "\(done) of 7 days",
                         trailingTint: streak > 1 ? Fit.action : nil)
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
