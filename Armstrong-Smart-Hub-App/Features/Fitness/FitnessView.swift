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
    @State private var checkins = CheckinStore.shared
    @State private var showingWatch = false
    @AppStorage("fitness.pplOffset") private var pplOffset = 0
    @State private var pairing = false
    @State private var workouts = WorkoutStore.shared
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    sheet
                    VStack(spacing: 0) {
                        if watch.savedWatchID == nil {
                            workoutsSection
                            routinesButton
                        } else {
                            if let error = store.error, !store.loaded {
                                ErrorBanner(message: error).padding(.bottom, 24)
                            }
                            MorningCheckin(store: checkins)
                            today
                            // Straight on the page, not on a card. It reads the watch's live
                            // numbers itself, so a heartbeat redraws one row, not this page.
                            OverviewList(store: store).padding(.bottom, 36)
                            workoutsSection
                            syncStatus
                            routinesButton.padding(.top, 24)
                        }
                    }
                    .environment(\.fitnessCards, true)
                    .padding(.horizontal, Fit.gutter)
                    .padding(.top, 48)
                }
                .padding(.bottom, 40)
            }
            .background(BrickLook.page.ignoresSafeArea())
            .foregroundStyle(BrickLook.ink)
            .tint(BrickLook.ink)
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
                // Return right away so the system spinner doesn't hold the page
                // open; the watch hero shows the sync instead.
                Task { await autoSync(force: true) }
                Task { await workouts.load(api: session.api) }
            }
            .onChange(of: watch.files.lastSync) {
                Task { await store.load(api: session.api) }
                // Last night's sleep only reaches the hub on a sync, and the guess needs it.
                Task { await checkins.load(api: session.api) }
            }
            .sheet(isPresented: $showingWatch) { WatchSheet() }
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

    private var routinesButton: some View {
        RoutinesAndHistoryButton(store: workouts, onStart: startWorkout)
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

    /// The top sheet, like Brick's: the watch floating on it, the day, and the three scores.
    private var sheet: some View {
        VStack(spacing: 0) {
            BrickTopBar {
                if watch.savedWatchID != nil {
                    Button { showingWatch = true } label: { TablerIcon(name: "device-watch", size: 22) }
                        .accessibilityLabel("Watch")
                }
            }
            .padding(.top, 12)
            WatchHero(progress: watch.files.isSyncing ? (watch.files.fraction ?? 0.02) : nil)
                .padding(.horizontal, -16).padding(.top, 4)
            if watch.savedWatchID != nil {
                BrickCaps(text: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .foregroundStyle(BrickLook.soft).padding(.top, 14)
                Text(watchTitle).font(.system(size: 34, weight: .light)).padding(.top, 12)
                    .onTapGesture { showingWatch = true }
                TodayScores(store: store).padding(.top, 34)
            } else {
                welcome.padding(.top, 20)
            }
            Spacer(minLength: 0).frame(height: 40)
        }
        .padding(.horizontal, Fit.gutter)
        .frame(maxWidth: .infinity)
        .background {
            // Reaches up under the status bar and past the top when pulled down.
            UnevenRoundedRectangle(bottomLeadingRadius: BrickLook.sheetRadius, bottomTrailingRadius: BrickLook.sheetRadius, style: .continuous)
                .fill(BrickLook.sheet)
                .padding(.top, -600)
                .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
        }
    }

    private var nextWorkoutView: some View {
        let next = nextWorkout
        return HStack(spacing: 14) {
            TablerIcon(name: next.icon, size: 26).foregroundStyle(Fit.muted).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(next.title).font(.system(size: 22, weight: .regular))
                Text(next.detail).font(.footnote).foregroundStyle(BrickLook.soft).fixedSize(horizontal: false, vertical: true)
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
        return FitSection(trailing: streak > 1 ? "\(streak)-day streak" : "\(done) of 7 days this week",
                          trailingTint: streak > 1 ? Fit.action : nil) {
            nextWorkoutView
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    let worked = days.contains(day)
                    let isToday = calendar.isDate(day, inSameDayAs: start)
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(worked ? Fit.action : isToday ? BrickLook.ink : BrickLook.line, lineWidth: isToday ? 1.5 : 1)
                            if worked { Circle().fill(Fit.action) }
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
