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
                    // Keep the hosted report mounted instead of recreating it on scroll.
                    BrickScreenTimeSection(store: store, path: $path)
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
            .hubPageStyle()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { store.check() }
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
        .alert("Brick", isPresented: Binding(get: { store.message != nil },
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
                        BrickRow(icon: "wave.3.right", title: "My Bricks",
                                 value: store.tags.isEmpty ? "Set up" : store.tags.count == 1 ? "1 tag" : "\(store.tags.count) tags",
                                 dot: store.tags.isEmpty)
                    }
                    BrickDivider()
                    NavigationLink(value: BrickRoute.emergency) {
                        BrickRow(icon: "lock.open", title: "Emergency Unbrick", value: "\(store.emergencyLeft)")
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
            BrickTopBar {
                HStack(spacing: 8) {
                    Button { path.append(.schedules) } label: {
                        Image(systemName: "calendar.badge.clock")
                            .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Schedules")
                    Button { path.append(.modes) } label: {
                        Image(systemName: "square.on.square")
                            .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Modes")
                }
                .font(.title2.weight(.light))
            }
            .buttonStyle(.plain)
            .frame(minHeight: HubLayout.minHitTarget)
            .padding(.top, HubLayout.topInset)
            device.padding(.top, HubLayout.sectionGap)
            Text(p?.name ?? "Unbricked")
                .font(.largeTitle.weight(.light))
                .multilineTextAlignment(.center)
                .padding(.top, HubLayout.sectionGap)
            Group {
                if store.isBlocking, let s = store.current {
                    if let end = store.endsAt {
                        Text("Unbricks in \(Text(timerInterval: Date()...max(Date(), end)))")
                    } else {
                        Text("Bricked for \(Text(s.start, style: .timer))")
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
            UnevenRoundedRectangle(bottomLeadingRadius: BrickLook.sheetRadius, bottomTrailingRadius: BrickLook.sheetRadius, style: .continuous)
                .fill(BrickLook.sheet)
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
            Image("BrickDevice")
                .resizable().scaledToFit()
                .frame(width: 168, height: 168)
                .shadow(color: .black.opacity(0.16), radius: 20, y: 14)
                .saturation(store.isBlocking ? 0 : 1)
                .opacity(store.isBlocking ? 0.7 : 1)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isBlocking ? "Unbrick with tag" : "Brick with tag")
    }

    /// Lockdowns on now. They don't count as Brick time, so they get a line here rather than the timer.
    private var lockdownLine: some View {
        VStack(spacing: 10) {
            ForEach(store.activeLockdowns) { l in
                HStack(spacing: 8) {
                    // Tapping the chip scans, so its tag ends it right here.
                    Button { store.tapTag() } label: {
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
                .background(BrickLook.card, in: Capsule())
            }
        }
    }

    private var brickButton: some View {
        VStack(spacing: 14) {
            Button { store.tapTag() } label: {
                Text(store.isBlocking ? "Tap to Unbrick" : "Tap to Brick")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, HubLayout.cardPadding)
                    .padding(.vertical, HubLayout.topInset)
                    .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                    .background(BrickLook.pill, in: Capsule())
                    .contentShape(.capsule)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
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
            } else if store.isBlocking, store.blockingProfile?.strict == false {
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
            Text("Avg Brick Time").font(.subheadline).foregroundStyle(BrickLook.soft)
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
#else
struct BrickView: View {
    var body: some View { Text("Brick needs an iPhone.").foregroundStyle(.secondary) }
}
#endif
