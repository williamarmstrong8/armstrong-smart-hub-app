import SwiftUI

#if os(iOS)
import FamilyControls

/// Brick tab: one big tap target, profiles below. Floating layout, no card backgrounds.
struct BrickView: View {
    @State private var store = BrickStore()
    @State private var picking: UUID?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    if !store.authorized { setupRow }
                    profilesSection
                    tagSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("Brick")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { BrickStatsView(store: store) } label: { Image(systemName: "chart.bar") }
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

    private var hero: some View {
        VStack(spacing: 14) {
            Button { store.tapTag() } label: {
                Image(systemName: store.isBlocking ? "lock.fill" : "lock.open")
                    .font(.system(size: 64, weight: .light))
                    .frame(width: 180, height: 180)
                    .overlay(Circle().stroke(store.isBlocking ? Color.orange : Color.secondary.opacity(0.4), lineWidth: 3))
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.isBlocking ? Color.orange : Color.primary)
            if store.isBlocking, let end = store.endsAt {
                Text(end, style: .timer).font(.title2.monospacedDigit())
            }
            if store.isBlocking, store.blockingProfile?.strict == false {
                Button("Unlock without tag") { store.unlockWithoutTag() }.font(.footnote)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var setupRow: some View {
        Button("Allow Screen Time access") { Task { await store.authorize() } }
            .buttonStyle(.borderedProminent)
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button { store.addProfile() } label: { Image(systemName: "plus") }
                    .disabled(store.isBlocking)
            }
            ForEach(store.profiles) { p in profileRow(p) }
        }
    }

    private func profileRow(_ p: BrickProfile) -> some View {
        let count = p.selection.applicationTokens.count + p.selection.categoryTokens.count + p.selection.webDomainTokens.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: store.selectedID == p.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.selectedID == p.id ? Color.green : Color.secondary)
                    .onTapGesture { if !store.isBlocking { store.selectedID = p.id } }
                TextField("Name", text: Binding(get: { p.name }, set: { var q = p; q.name = $0; store.update(q) }))
                    .disabled(store.isBlocking)
                Spacer()
                Button("\(count) selected") { picking = p.id }
                    .font(.footnote).disabled(store.isBlocking)
            }
            Toggle("Strict (only the tag unlocks)", isOn: Binding(get: { p.strict }, set: { var q = p; q.strict = $0; store.update(q) }))
                .font(.footnote).disabled(store.isBlocking)
            Stepper(p.timerMinutes.map { "Auto-unlock after \($0) min" } ?? "No timer",
                    onIncrement: { var q = p; q.timerMinutes = (p.timerMinutes ?? 0) + 15; store.update(q) },
                    onDecrement: { var q = p; let m = (p.timerMinutes ?? 0) - 15; q.timerMinutes = m > 0 ? m : nil; store.update(q) })
                .font(.footnote).disabled(store.isBlocking)
            if store.profiles.count > 1 {
                Button("Delete", role: .destructive) { store.delete(p) }.font(.footnote)
            }
            Divider()
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tag").font(.headline)
            Text(store.tagID == nil ? "No tag registered" : "Registered: \(String(store.tagID!.prefix(8)))")
                .font(.footnote).foregroundStyle(.secondary)
            Button(store.tagID == nil ? "Register tag" : "Replace tag") { store.registerTag() }
                .disabled(store.isBlocking)
        }
    }
}
#else
struct BrickView: View {
    var body: some View { Text("Brick needs an iPhone.").foregroundStyle(.secondary) }
}
#endif
