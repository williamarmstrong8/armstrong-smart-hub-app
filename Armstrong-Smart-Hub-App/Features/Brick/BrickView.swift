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
                        pageButtons
                        NavigationLink(value: BrickRoute.activity) {
                            BrickDayCard(day: Date(), seconds: store.seconds(on: Date()), sessions: store.sessions(on: Date()), chevron: true)
                        }
                        .buttonStyle(.plain)
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

    // MARK: Modes and schedules

    private var pageButtons: some View {
        HStack(spacing: 12) {
            pageButton("Modes", icon: "square.on.square", route: .modes)
            pageButton("Schedules", icon: "calendar.badge.clock", route: .schedules)
        }
    }

    private func pageButton(_ title: String, icon: String, route: BrickRoute) -> some View {
        Button { path.append(route) } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(BrickLook.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .glassGlare(.regular.interactive(), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
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
                if store.isLocked(s) {
                    BrickScheduleCard(store: store, schedule: s)
                } else {
                    NavigationLink(value: BrickRoute.schedule(s.id)) { BrickScheduleCard(store: store, schedule: s) }
                        .buttonStyle(.plain)
                }
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
            Color.clear.frame(height: HubLayout.minHitTarget)
            .padding(.top, HubLayout.topInset)
            device.padding(.top, HubLayout.sectionGap)
            // The film's plain circle has no face to print on, so its title stays underneath.
            if Demo.isOn {
                Text(p?.name ?? Demo.copy("Unbricked", "Ready to focus"))
                    .font(.largeTitle.weight(.light))
                    .multilineTextAlignment(.center)
                    .padding(.top, HubLayout.sectionGap)
            }
            if !store.activeLockdowns.isEmpty { lockdownLine.padding(.top, HubLayout.topInset) }
            // The stats sit centred in the room between the device and the button.
            Spacer(minLength: 8)
            // Smaller when a line under the button or a lockdown chip needs the room; gone when both do.
            if !Demo.isOn, store.activeLockdowns.isEmpty || !hasSubline {
                BrickLifeStats(store: store, size: store.activeLockdowns.isEmpty && !hasSubline ? 100 : 72)
                Spacer(minLength: 8)
            }
            brickButton
        }
        .frame(height: HubLayout.deviceSheetHeight, alignment: .top)
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
    private var device: some View {
        Button { store.tapTag() } label: {
            deviceArt
                .frame(width: 168, height: 168)
                .shadow(color: .black.opacity(0.16), radius: 20, y: 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isBlocking ? "Unbrick with tag" : "Brick with tag")
        .accessibilityValue(store.blockingProfile?.name ?? "Unbricked")
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
            Image("BrickDeviceBlank").resizable().scaledToFit()
                .overlay { faceText }
        }
    }

    /// The status pressed into the device where its "Brick" was: heavy rounded letters in the
    /// device's grey, a dark inner shadow along the top edge and a light catch along the bottom.
    private var faceText: some View {
        Text(store.blockingProfile?.name ?? "Unbricked")
            .font(.system(size: 34, weight: .heavy, design: .rounded))
            .tracking(-0.8)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(BrickLook.wordmark.shadow(.inner(color: .black.opacity(0.45), radius: 1.2, x: 0, y: 1.2)))
            .shadow(color: .white.opacity(0.7), radius: 0.4, x: 0, y: 0.8)
            .padding(.horizontal, 30)
            .contentTransition(.opacity)
            .hubAnimation(value: store.blockingProfile?.name)
            .accessibilityHidden(true)
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

    /// True when a line shows under the button ("Allow Screen Time access" or "Unbrick without tag").
    private var hasSubline: Bool {
        !store.authorized || (store.isBlocking && store.blockingProfile?.strict == false && !Demo.isOn)
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
                        Text(store.isLocked(schedule) ? "On now. Locked until it ends." : "Mode: \(mode)")
                    }
                    .font(.subheadline).foregroundStyle(BrickLook.soft)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { schedule.enabled },
                                         set: { var s = schedule; s.enabled = $0; store.update(s) }))
                    .labelsHidden().tint(BrickLook.bar)
                    .disabled(store.isLocked(schedule))
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
