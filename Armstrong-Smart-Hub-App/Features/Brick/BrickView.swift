import SwiftUI

#if os(iOS)
import FamilyControls

/// Where the Brick page can go. Everything lives under the one page; these open on top of it.
enum BrickRoute: Hashable {
    case modes, mode(UUID), schedules, schedule(UUID), activity, screenTime, tag, emergency
}

/// Brick's app on one page: the device sheet on top, then screen time, today, and settings.
/// Each section shows its picture here and opens a page for the rest.
struct BrickView: View {
    private let store = BrickStore.shared
    @State private var path: [BrickRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    BrickSheet(store: store, path: $path)
                    BrickScreenTimeSection(store: store, path: $path).padding(.top, 56)
                    BrickDayCard(day: Date(), seconds: store.seconds(on: Date()), sessions: store.sessions(on: Date()))
                        .padding(.horizontal, Fit.gutter).padding(.top, 26)
                    settings.padding(.top, 56)
                }
                .padding(.bottom, 40)
            }
            .background(BrickLook.page.ignoresSafeArea())
            .foregroundStyle(BrickLook.ink)
            .tint(BrickLook.ink)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { store.check() }
            .navigationDestination(for: BrickRoute.self) { route in
                switch route {
                case .modes: BrickModesPage(store: store, path: $path)
                case .mode(let id): BrickModePage(store: store, id: id)
                case .schedules: BrickSchedulesPage(store: store, path: $path)
                case .schedule(let id): BrickSchedulePage(store: store, id: id)
                case .activity: BrickActivityPage(store: store)
                case .screenTime: BrickScreenTimePage(store: store)
                case .tag: BrickTagPage(store: store)
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
        VStack(spacing: 16) {
            BrickCard(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink(value: BrickRoute.tag) {
                        BrickRow(icon: "wave.3.right", title: "My Brick", value: store.tagID == nil ? "Set up" : "Paired",
                                 dot: store.tagID == nil)
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
        .padding(.horizontal, Fit.gutter)
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
                    Text("Create schedule").font(.system(size: 18)).foregroundStyle(BrickLook.soft)
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

    /// The button's height; the sheet's corners are its radius plus the gap around it, so the two curves run parallel.
    private static let buttonHeight: CGFloat = 64
    private static let cornerRadius = buttonHeight / 2 + Fit.gutter

    var body: some View {
        let p = store.blockingProfile ?? store.selected
        VStack(spacing: 0) {
            HStack {
                Button { path.append(.schedules) } label: { Image(systemName: "calendar.badge.clock") }
                    .accessibilityLabel("Schedules")
                Spacer()
                Button { path.append(.modes) } label: { Image(systemName: "square.on.square") }
                    .accessibilityLabel("Modes")
            }
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(BrickLook.ink)
            .padding(.top, 12).padding(.horizontal, -20)
            device.padding(.top, 20)
            Text(p?.name ?? "Focus").font(.system(size: 34, weight: .light)).padding(.top, 24)
            Group {
                if store.isBlocking, let s = store.current {
                    if let end = store.endsAt {
                        Text("Unbricks in \(Text(timerInterval: Date()...max(Date(), end)))")
                    } else {
                        Text("Bricked for \(Text(s.start, style: .timer))")
                    }
                } else {
                    let n = p?.blockedCount ?? 0
                    Text(n == 1 ? "Blocks 1 app" : "Blocks \(n) apps")
                }
            }
            .font(.system(size: 18)).monospacedDigit().foregroundStyle(BrickLook.soft).padding(.top, 14)
            stats.padding(.top, 30)
            brickButton.padding(.top, 30).padding(.bottom, Fit.gutter)
        }
        .padding(.horizontal, Fit.gutter + 20)
        .frame(maxWidth: .infinity)
        .background {
            // Reaches up under the status bar and past the top when pulled down.
            UnevenRoundedRectangle(bottomLeadingRadius: Self.cornerRadius, bottomTrailingRadius: Self.cornerRadius, style: .continuous)
                .fill(BrickLook.sheet)
                .padding(.top, -600)
                .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
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
            Text(value).font(.system(size: 26, weight: .light).monospacedDigit())
            Text(label).font(.system(size: 14)).foregroundStyle(BrickLook.soft)
        }
        .frame(maxWidth: .infinity)
    }

    private var device: some View {
        Image("BrickDevice")
            .resizable().scaledToFit()
            .frame(width: 168, height: 168)
            .shadow(color: .black.opacity(0.16), radius: 20, y: 14)
            .saturation(store.isBlocking ? 0 : 1)
            .opacity(store.isBlocking ? 0.7 : 1)
            .onTapGesture { store.tapTag() }
            .accessibilityLabel(store.isBlocking ? "Unbrick with tag" : "Brick with tag")
            .accessibilityAddTraits(.isButton)
    }

    private var brickButton: some View {
        VStack(spacing: 14) {
            Button { store.tapTag() } label: {
                Text(store.isBlocking ? "Tap to Unbrick" : "Tap to Brick")
                    .font(.system(size: 18, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: Self.buttonHeight)
                    .background(BrickLook.pill, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
            }
            .buttonStyle(.plain)
            if !store.authorized {
                Button("Allow Screen Time access") { Task { await store.authorize() } }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(BrickLook.soft)
            } else if store.isBlocking, store.blockingProfile?.strict == false {
                Button("Unbrick without tag") { store.unlockWithoutTag() }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(BrickLook.soft)
            }
        }
        .padding(.horizontal, -20)
    }
}

/// "Avg Brick Time" and its number, or a dash until a full day has passed.
struct BrickAverage: View {
    var value: TimeInterval?
    var body: some View {
        VStack(spacing: 6) {
            Text("Avg Brick Time").font(.system(size: 16)).foregroundStyle(BrickLook.soft)
            if let value {
                Text(brickDuration(value)).font(.system(size: 40, weight: .regular).monospacedDigit())
            } else {
                Text("--").font(.system(size: 40, weight: .regular))
                Text("Check back after your first full day")
                    .font(.system(size: 14)).foregroundStyle(BrickLook.soft)
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
                    Text(schedule.name).font(.system(size: 18, weight: .medium))
                    Group {
                        Text(schedule.summary)
                        Text("Mode: \(mode)")
                    }
                    .font(.system(size: 16)).foregroundStyle(BrickLook.soft)
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
