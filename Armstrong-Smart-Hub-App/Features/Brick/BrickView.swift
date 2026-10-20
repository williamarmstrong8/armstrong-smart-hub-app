import SwiftUI

#if os(iOS)
import FamilyControls

/// Brick tab, built from the Fitness page parts: no cards, hairline sections, thin ring, light numbers.
struct BrickView: View {
    @State private var store = BrickStore()
    @State private var picking: UUID?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 40) {
                    hero
                    if !store.authorized {
                        Button("Allow Screen Time access") { Task { await store.authorize() } }
                            .font(.subheadline.weight(.semibold))
                    }
                    VStack(spacing: 0) {
                        profilesSection
                        tagSection
                    }
                }
                .padding(.horizontal, Fit.gutter)
                .padding(.vertical, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Brick")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { BrickStatsView(store: store) } label: { TablerIcon(name: "chart-bar", size: 22) }
                        .accessibilityLabel("Stats")
                }
            }
            .alert("Brick", isPresented: Binding(get: { store.message != nil },
                                                 set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.message ?? "") }
            .onChange(of: scenePhase) { _, p in if p == .active { store.checkTimer() } }
            .familyActivityPicker(isPresented: Binding(get: { picking != nil },
                                                       set: { if !$0 { picking = nil } }),
                                  selection: pickerBinding)
        }
    }

    private var pickerBinding: Binding<FamilyActivitySelection> {
        Binding(
            get: { store.profiles.first { $0.id == picking }?.selection ?? FamilyActivitySelection() },
            set: { new in
                guard var p = store.profiles.first(where: { $0.id == picking }) else { return }
                p.selection = new
                store.update(p)
            })
    }

    private var accent: Color { store.isBlocking ? Fit.activity : Fit.muted }

    /// Thin ring with a lock in it. Tapping it is the same as tapping the tag with the phone.
    private var hero: some View {
        VStack(spacing: 14) {
            Button { store.tapTag() } label: {
                ZStack {
                    Circle().stroke(Fit.track, lineWidth: 5)
                    if store.isBlocking {
                        Circle().stroke(Fit.activity, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                    TablerIcon(name: store.isBlocking ? "lock" : "lock-open", size: 56)
                        .foregroundStyle(accent)
                }
                .frame(width: 180, height: 180)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isBlocking ? "Unlock with tag" : "Start blocking with tag")
            Text(store.isBlocking ? "Blocking" : "Unlocked").font(.title3.weight(.semibold))
            if store.isBlocking, let end = store.endsAt {
                Text(end, style: .timer).font(Fit.number(34)).foregroundStyle(Fit.activity)
            } else {
                Text(store.isBlocking ? "Tap your tag to unlock" : "Tap your tag to start")
                    .font(Fit.label).foregroundStyle(Fit.muted)
            }
            if store.isBlocking, store.blockingProfile?.strict == false {
                Button("Unlock without tag") { store.unlockWithoutTag() }.font(Fit.label)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var profilesSection: some View {
        FitSection(title: "Profiles") {
            VStack(spacing: 0) {
                ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, p in
                    profile(p, last: index == store.profiles.count - 1)
                }
            }
            if !store.isBlocking {
                Button { store.addProfile() } label: {
                    HStack(spacing: 8) { TablerIcon(name: "plus", size: 18); Text("New profile").font(.subheadline) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 24)
    }

    private func profile(_ p: BrickProfile, last: Bool) -> some View {
        let count = p.selection.applicationTokens.count + p.selection.categoryTokens.count + p.selection.webDomainTokens.count
        let chosen = store.selectedID == p.id
        return VStack(spacing: 0) {
            Button { if !store.isBlocking { store.selectedID = p.id } } label: {
                HStack {
                    TablerIcon(name: chosen ? "circle-check" : "circle", size: 20)
                        .foregroundStyle(chosen ? Fit.positive : Fit.faint)
                    TextField("Name", text: Binding(get: { p.name }, set: { var q = p; q.name = $0; store.update(q) }))
                        .font(.subheadline.weight(.semibold)).disabled(store.isBlocking)
                    Spacer()
                }
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            if chosen {
                Button { picking = p.id } label: {
                    DetailRow(label: "Apps and sites", value: count == 0 ? "Choose" : "\(count) selected")
                }
                .buttonStyle(.plain).disabled(store.isBlocking)
                HStack {
                    Text("Strict, only the tag unlocks").font(.subheadline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { p.strict }, set: { var q = p; q.strict = $0; store.update(q) }))
                        .labelsHidden().disabled(store.isBlocking)
                }
                .padding(.vertical, 6)
                Rectangle().fill(Fit.hairline).frame(height: 1)
                Stepper(value: Binding(get: { p.timerMinutes ?? 0 }, set: { var q = p; q.timerMinutes = $0 > 0 ? $0 : nil; store.update(q) }),
                        in: 0...480, step: 15) {
                    HStack {
                        Text("Auto-unlock").font(.subheadline)
                        Spacer()
                        Text(p.timerMinutes.map { "\($0) min" } ?? "Off").font(.subheadline).foregroundStyle(Fit.muted)
                    }
                }
                .padding(.vertical, 6).disabled(store.isBlocking)
                if store.profiles.count > 1 {
                    Button("Delete profile", role: .destructive) { store.delete(p) }
                        .font(Fit.label).padding(.vertical, 8).disabled(store.isBlocking)
                }
            }
            if !last { Rectangle().fill(Fit.hairline).frame(height: 1) }
        }
    }

    private var tagSection: some View {
        FitSection(title: "Tag") {
            VStack(spacing: 0) {
                DetailRow(label: "Registered tag", value: store.tagID.map { String($0.prefix(8)) } ?? "None", last: true)
            }
            Button(store.tagID == nil ? "Register tag" : "Replace tag") { store.registerTag() }
                .font(.subheadline.weight(.semibold)).disabled(store.isBlocking)
        }
    }
}
#else
struct BrickView: View {
    var body: some View { Text("Brick needs an iPhone.").foregroundStyle(.secondary) }
}
#endif
