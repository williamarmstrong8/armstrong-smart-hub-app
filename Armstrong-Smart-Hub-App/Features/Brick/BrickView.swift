import SwiftUI

#if os(iOS)
import FamilyControls

/// Where the Brick page can go. Everything lives under the one page; these open on top of it.
enum BrickRoute: Hashable {
    case modes, mode(UUID), restrictions(UUID), schedules, schedule(UUID), activity, screenTime, tag, tagDetail(String), emergency
}

/// Brick's app on one page: the device sheet on top, then screen time, today, and settings.
/// Each section shows its picture here and opens a page for the rest.
struct BrickView: View {
    private let store = BrickStore.shared
    @State private var path: [BrickRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical) {
                VStack(spacing: HubLayout.sectionGap) {
                    BrickSheet(store: store, path: $path)
                    LazyVStack(spacing: HubLayout.sectionGap) {
                        BrickDayCard(day: Date(), seconds: store.seconds(on: Date()), sessions: store.sessions(on: Date()))
                        settings
                    }
                    .padding(.horizontal, HubLayout.gutter)
                }
                .padding(.bottom, HubLayout.bottomInset)
                .containerRelativeFrame(.horizontal)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .demoScroll()
            .hubPageStyle(backdrop: true)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { store.check() }
            #if DEBUG
            .onAppear {
                DemoCue.on("focus") { store.tapTag() }
                // `nav modes|schedules|activity|tag|emergency`, then `back`.
                DemoCue.on("nav", arg: { name in
                    let routes: [String: BrickRoute] = ["modes": .modes, "schedules": .schedules, "activity": .activity,
                                                        "tag": .tag, "emergency": .emergency]
                    if let r = routes[name] { path.append(r) }
                })
                DemoCue.on("back") { if !path.isEmpty { path.removeLast() } }
            }
            #endif
            .navigationDestination(for: BrickRoute.self) { route in
                switch route {
                case .modes: BrickModesPage(store: store, path: $path)
                case .mode(let id): BrickModePage(store: store, id: id)
                case .restrictions(let id): BrickRestrictionsPage(store: store, id: id)
                case .schedules: BrickSchedulesPage(store: store, path: $path)
                case .schedule(let id): BrickSchedulePage(store: store, id: id)
                case .activity: BrickActivityPage(store: store)
                case .screenTime: BrickScreenTimePage(store: store)
                case .tag: BrickTagPage(store: store, path: $path)
                case .tagDetail(let id): BrickTagDetailPage(store: store, id: id)
                case .emergency: BrickEmergencyPage(store: store)
                }
            }
        }
        #if DEBUG
        .overlay { if let scan = store.demoScan { DemoScanSheet(scan: scan).transition(.move(edge: .bottom).combined(with: .opacity)) } }
        .animation(.spring(duration: 0.45, bounce: 0.12), value: store.demoScan)
        #endif
        .alert(Demo.copy("Brick", "Focus"), isPresented: Binding(get: { store.message != nil },
                                             set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.message ?? "") }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(spacing: HubLayout.sectionGap) {
            BrickCard(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink(value: BrickRoute.tag) {
                        BrickRow(icon: "wave.3.right", title: Demo.copy("My Bricks", "My Tags"),
                                 value: store.tags.isEmpty ? "Set up" : store.tags.count == 1 ? "1 tag" : "\(store.tags.count) tags",
                                 dot: store.tags.isEmpty)
                    }
                    BrickDivider()
                    NavigationLink(value: BrickRoute.emergency) {
                        BrickRow(icon: "lock.open", title: Demo.copy("Emergency Unbrick", "Emergency Unlock"), value: "\(store.emergencyLeft)")
                    }
                }
                .padding(.horizontal, 24)
            }
            BrickCard(padding: 0) {
                VStack(spacing: 0) {
                    Button { if !store.authorized { Task { await store.authorize() } } } label: {
                        BrickRow(icon: "hourglass", title: "Screen Time", value: store.authorized ? "On" : "Allow",
                                 dot: !store.authorized, chevron: !store.authorized)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .buttonStyle(.plain)
    }
}


/// Every schedule, and a way to make another.
struct BrickSchedulesPage: View {
    let store: BrickStore
    @Binding var path: [BrickRoute]

    var body: some View {
        BrickPage(title: "Schedules") {
            ForEach(store.schedules) { s in
                NavigationLink(value: BrickRoute.schedule(s.id)) { BrickScheduleCard(store: store, schedule: s) }
                    .buttonStyle(.plain)
            }
            Button { path.append(.schedule(store.addSchedule())) } label: {
                VStack(spacing: 16) {
                    Text("Create schedule").font(.body).foregroundStyle(BrickLook.soft)
                    BrickPlus()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }
}

/// The top sheet: today's time, the device, the mode and the one big button.
private struct BrickSheet: View {
    let store: BrickStore
    @Binding var path: [BrickRoute]

    /// The button's height; the sheet's corners (BrickLook.sheetRadius) are its radius plus the gap around it.
    private static let buttonHeight: CGFloat = 64

    var body: some View {
        let p = store.blockingProfile
        VStack(spacing: 0) {
            HStack {
                Button { path.append(.schedules) } label: {
                    Image(systemName: "calendar.badge.clock")
                        .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Schedules")
                Spacer()
                Button { path.append(.modes) } label: {
                    Image(systemName: "square.on.square")
                        .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Modes")
            }
            .font(.title2.weight(.light))
            .foregroundStyle(BrickLook.ink)
            .buttonStyle(.plain)
            .padding(.top, HubLayout.topInset)
            device.padding(.top, HubLayout.sectionGap)
            Text(p?.name ?? Demo.copy("Unbricked", "Ready to focus"))
                .font(.largeTitle.weight(.light))
                .multilineTextAlignment(.center)
                .padding(.top, HubLayout.sectionGap)
            Group {
                if store.isBlocking, let s = store.current {
                    if let end = store.endsAt {
                        Text("\(Demo.copy("Unbricks", "Ends")) in \(Text(timerInterval: Date()...max(Date(), end)))")
                    } else {
                        Text("\(Demo.copy("Bricked", "Focused")) for \(Text(s.start, style: .timer))")
                    }
                } else {
                    Text(store.hasTag ? "Tap a tag to start its mode" : "Register a tag to start")
                }
            }
            .font(.body).monospacedDigit().foregroundStyle(BrickLook.soft)
            .multilineTextAlignment(.center).padding(.top, HubLayout.topInset)
            if !store.activeLockdowns.isEmpty { lockdownLine.padding(.top, HubLayout.sectionGap) }
            stats.padding(.top, HubLayout.sectionGap)
            brickButton.padding(.top, HubLayout.sectionGap)
        }
        .padding(.horizontal, HubLayout.gutter)
        .padding(.bottom, HubLayout.sectionGap)
        .frame(maxWidth: .infinity)
        .background {
            Color.clear
                .glassGlare(.regular, in: UnevenRoundedRectangle(bottomLeadingRadius: BrickLook.sheetRadius, bottomTrailingRadius: BrickLook.sheetRadius, style: .continuous))
                .padding(.top, -600)
        }
    }

    /// Today's time, today's sessions and the weekly average, in the same place as Fitness's scores.
    private var stats: some View {
        let today = Date()
        let avg = store.average(store.week())
        return HStack(alignment: .top, spacing: 0) {
            stat(brickDuration(store.seconds(on: today)), "Today")
            stat("\(store.sessions(on: today).count)", "Sessions")
            stat(avg.map(brickDuration) ?? "--", "Daily avg")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.title2.weight(.light).monospacedDigit())
            Text(label).font(.subheadline).foregroundStyle(BrickLook.soft)
        }
        .frame(maxWidth: .infinity)
    }

    private var device: some View {
        Button { store.tapTag() } label: {
            deviceArt
                .frame(width: 168, height: 168)
                .shadow(color: .black.opacity(0.16), radius: 20, y: 14)
                .saturation(store.isBlocking ? 0 : 1)
                .opacity(store.isBlocking ? 0.7 : 1)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isBlocking ? "Unbrick with tag" : "Brick with tag")
    }

    /// The device picture; the film uses a plain circle in its place.
    @ViewBuilder private var deviceArt: some View {
        if Demo.isOn {
            ZStack {
                Circle().fill(store.isBlocking ? BrickLook.pill : BrickLook.ink)
                Circle().strokeBorder(BrickLook.ink, lineWidth: store.isBlocking ? 6 : 0)
            }
            .padding(14)
            .hubAnimation(value: store.isBlocking)
        } else {
            Image("BrickDevice").resizable().scaledToFit()
        }
    }

    /// Lockdowns on now. They don't count as Brick time, so they get a line here rather than the timer.
    private var lockdownLine: some View {
        VStack(spacing: 10) {
            ForEach(store.activeLockdowns) { l in
                HStack(spacing: 8) {
                    // Tapping the chip scans for its own tag only; any other tag is a wrong tag.
                    Button { store.tapTag(.ending(l.id)) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill").font(.caption)
                            Text("\(l.name) lockdown").font(.subheadline.weight(.medium))
                        }
                        .frame(minHeight: HubLayout.minHitTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if !l.strict {
                        Button { store.unlockWithoutTag(l.id) } label: {
                            Text("End")
                                .font(.subheadline.weight(.medium)).foregroundStyle(BrickLook.soft)
                                .frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassGlare(.regular, in: .capsule)
            }
        }
    }

    private var brickButton: some View {
        VStack(spacing: 14) {
            Button { store.tapTag() } label: {
                Text(store.isBlocking ? Demo.copy("Tap to Unbrick", "Tap to End") : Demo.copy("Tap to Brick", "Tap to Focus"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, HubLayout.cardPadding)
                    .padding(.vertical, HubLayout.topInset)
                    .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                    .glassGlare(.regular.interactive(), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            if !store.authorized {
                Button { Task { await store.authorize() } } label: {
                    Text("Allow Screen Time access")
                        .font(.subheadline.weight(.medium)).foregroundStyle(BrickLook.soft)
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else if store.isBlocking, store.blockingProfile?.strict == false, !Demo.isOn {
                Button { if let id = store.blockingProfileID { store.unlockWithoutTag(id) } } label: {
                    Text("Unbrick without tag")
                        .font(.subheadline.weight(.medium)).foregroundStyle(BrickLook.soft)
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// "Avg Brick Time" and its number, or a dash until a full day has passed.
struct BrickAverage: View {
    var value: TimeInterval?
    var body: some View {
        VStack(spacing: 6) {
            Text(Demo.copy("Avg Brick Time", "Avg Focus Time")).font(.subheadline).foregroundStyle(BrickLook.soft)
            if let value {
                Text(brickDuration(value)).font(.largeTitle.monospacedDigit())
            } else {
                Text("--").font(.largeTitle)
                Text("Check back after your first full day")
                    .font(.footnote).foregroundStyle(BrickLook.soft)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

/// A schedule as a card, with its switch.
struct BrickScheduleCard: View {
    let store: BrickStore
    var schedule: BrickSchedule

    var body: some View {
        let mode = store.profiles.first { $0.id == schedule.profileID }?.name ?? "None"
        BrickCard {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(schedule.name).font(.headline)
                    Group {
                        Text(schedule.summary)
                        Text("Mode: \(mode)")
                    }
                    .font(.subheadline).foregroundStyle(BrickLook.soft)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { schedule.enabled },
                                         set: { var s = schedule; s.enabled = $0; store.update(s) }))
                    .labelsHidden().tint(BrickLook.bar)
            }
        }
    }
}
#if DEBUG
/// The film's stand-in for iOS's NFC scan sheet (CoreNFC has no Simulator support): the same
/// bottom card, "Ready to Scan" with the phone-and-waves glyph, then a check when the tag reads.
struct DemoScanSheet: View {
    let scan: BrickStore.DemoScan

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Ready to Scan")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 34)
                ZStack {
                    if scan.done {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 86, weight: .light))
                            .foregroundStyle(Color(red: 0.0, green: 0.48, blue: 1.0))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 80, weight: .light))
                            .foregroundStyle(Color(red: 0.0, green: 0.48, blue: 1.0))
                            .symbolEffect(.pulse, options: .repeating)
                            .transition(.opacity)
                    }
                }
                .frame(height: 110)
                .animation(.spring(duration: 0.35), value: scan.done)
                Text(scan.done ? scan.doneText : scan.prompt)
                    .font(.system(size: 17))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .contentTransition(.opacity)
                Text("Cancel")
                    .font(.system(size: 17, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                    .opacity(scan.done ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 44, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
#endif

#else
struct BrickView: View {
    var body: some View { Text("Brick needs an iPhone.").foregroundStyle(.secondary) }
}

#endif
