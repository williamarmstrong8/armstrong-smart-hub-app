import SwiftUI

#if os(iOS)
import FamilyControls

/// Where the Brick page can go. Everything lives under the one page; these open on top of it.
enum BrickRoute: Hashable {
    case modes, mode(UUID), schedule(UUID), activity, tag, emergency
}

/// Brick on the iPhone, laid out like the other tabs: the device and its button
/// up top, then schedules, the week, and settings, each opening a page for the rest.
struct BrickView: View {
    private let store = BrickStore.shared
    @State private var path: [BrickRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    BrickHero(store: store)
                    schedules
                    activity
                    settings
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Brick")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
            }
            .navigationDestination(for: BrickRoute.self) { route in
                switch route {
                case .modes: BrickModesPage(store: store, path: $path)
                case .mode(let id): BrickModePage(store: store, id: id)
                case .schedule(let id): BrickSchedulePage(store: store, id: id)
                case .activity: BrickActivityPage(store: store)
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

    // MARK: Schedules

    private var schedules: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Schedules").font(.title3.weight(.semibold))
                Spacer()
                Button { path.append(.schedule(store.addSchedule())) } label: {
                    Label("Add", systemImage: "plus").font(.subheadline.weight(.medium))
                }
            }
            if store.schedules.isEmpty {
                Text("Brick automatically at set times.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(store.schedules) { s in
                NavigationLink(value: BrickRoute.schedule(s.id)) { BrickScheduleCard(store: store, schedule: s) }
                    .buttonStyle(.plain)
            }
        }
    }

    // MARK: Week

    private var activity: some View {
        let week = store.week()
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "This week", meta: store.average(week).map { "Avg \(brickDuration($0))" })
            NavigationLink(value: BrickRoute.activity) {
                VStack(alignment: .leading, spacing: 16) {
                    BrickWeekChart(days: week)
                    Divider()
                    BrickDayRow(day: Date(), seconds: store.seconds(on: Date()), sessions: store.sessions(on: Date()))
                    HStack {
                        Text("All activity").font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Settings")
            BrickList {
                NavigationLink(value: BrickRoute.tag) {
                    BrickRow(icon: "wave.3.right", title: "My Brick", value: store.tagID == nil ? "Set up" : "Paired",
                             dot: store.tagID == nil)
                }
                Divider().padding(.leading, 60)
                NavigationLink(value: BrickRoute.modes) {
                    BrickRow(icon: "square.on.square", title: "Modes", value: "\(store.profiles.count)")
                }
                Divider().padding(.leading, 60)
                NavigationLink(value: BrickRoute.emergency) {
                    BrickRow(icon: "lock.open", title: "Emergency Unbrick", value: "\(store.emergencyLeft) left")
                }
                Divider().padding(.leading, 60)
                Button { if !store.authorized { Task { await store.authorize() } } } label: {
                    BrickRow(icon: "hourglass", title: "Screen Time", value: store.authorized ? "On" : "Allow",
                             dot: !store.authorized, chevron: !store.authorized)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// The top card: the device, the mode, what it's doing now, and the one big button.
private struct BrickHero: View {
    let store: BrickStore

    var body: some View {
        let p = store.blockingProfile ?? store.selected
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                device
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.isBlocking ? "Bricked" : "Ready")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.isBlocking ? BrickLook.live : .secondary)
                    Text(p?.name ?? "Focus").font(.title2.weight(.semibold)).lineLimit(1)
                    Group {
                        if store.isBlocking, let s = store.current {
                            if let end = store.endsAt {
                                Text("Unbricks in \(Text(timerInterval: Date()...max(Date(), end)))")
                            } else {
                                Text("For \(Text(s.start, style: .timer))")
                            }
                        } else {
                            let n = p?.blockedCount ?? 0
                            Text(n == 1 ? "Blocks 1 app" : "Blocks \(n) apps")
                        }
                    }
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    NavigationLink(value: BrickRoute.modes) {
                        HStack(spacing: 4) {
                            Text("Change mode")
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    .disabled(store.isBlocking)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            HStack {
                Label("Today", systemImage: "clock").foregroundStyle(.secondary)
                Spacer()
                Text(brickDuration(store.seconds(on: Date()))).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            .font(.subheadline)

            VStack(spacing: 10) {
                Button { store.tapTag() } label: {
                    Label(store.isBlocking ? "Tap to Unbrick" : "Tap to Brick", systemImage: "wave.3.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if !store.authorized {
                    Button("Allow Screen Time access") { Task { await store.authorize() } }
                        .font(.footnote.weight(.medium))
                } else if store.isBlocking, store.blockingProfile?.strict == false {
                    Button("Unbrick without tag") { store.unlockWithoutTag() }
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private var device: some View {
        Image("BrickDevice")
            .resizable().scaledToFit()
            .frame(width: 96, height: 96)
            .saturation(store.isBlocking ? 0 : 1)
            .opacity(store.isBlocking ? 0.7 : 1)
            .onTapGesture { store.tapTag() }
            .accessibilityLabel(store.isBlocking ? "Unbrick with tag" : "Brick with tag")
            .accessibilityAddTraits(.isButton)
    }
}

/// A schedule as a card, with its switch.
struct BrickScheduleCard: View {
    let store: BrickStore
    var schedule: BrickSchedule

    var body: some View {
        let mode = store.profiles.first { $0.id == schedule.profileID }?.name ?? "None"
        HStack(spacing: 12) {
            BrickIcon(name: "calendar.badge.clock")
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name).font(.subheadline.weight(.medium))
                Text("\(schedule.summary) · \(mode)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { schedule.enabled },
                                     set: { var s = schedule; s.enabled = $0; store.update(s) }))
                .labelsHidden()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}
#else
struct BrickView: View {
    var body: some View { Text("Brick needs an iPhone.").foregroundStyle(.secondary) }
}
#endif
