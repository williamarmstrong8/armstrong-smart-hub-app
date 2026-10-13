import SwiftUI

/// Automations, scenes and scripts from Home Assistant, as small cards you tap.
struct AutomationsSection: View {
    let payload: AutomationsPayload
    let store: HomeStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @State private var running: String?
    @State private var deleting: HAAutomation?

    var body: some View {
        let items = payload.scenes + payload.scripts
        if !items.isEmpty || !payload.automations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Automations")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    // Scenes and scripts: tap to run.
                    ForEach(items) { item in
                        AutomationCard(
                            name: item.name,
                            symbol: item.id.hasPrefix("scene.") ? "sparkles" : "play.fill",
                            detail: running == item.id ? "Running…" : "Tap to run",
                            on: running == item.id
                        ) { run(item.id, name: item.name) }
                    }
                    // Automations: tap to switch on or off; hold to run or delete.
                    ForEach(payload.automations) { a in
                        AutomationCard(name: a.name, symbol: "bolt.fill", detail: a.state == "on" ? "On" : "Off", on: a.state == "on") {
                            Task { await store.setAutomation(a, enabled: a.state != "on", api: session.api, toast: toast) }
                        }
                        .contextMenu {
                            Button("Run now", systemImage: "play") { run(a.id, name: a.name) }
                            if a.hubMade, a.configId != nil {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = a }
                            }
                        }
                    }
                }
            }
            .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let a = deleting, let id = a.configId { delete(id, name: a.name) }
                }
            } message: {
                Text("It's removed from Home Assistant.")
            }
        }
    }

    private func run(_ id: String, name: String) {
        running = id
        Task {
            defer { running = nil }
            do {
                let _: Empty? = try await session.api.run("runAutomation", [.string(id)])
                toast.show("Ran \(name)")
            } catch {
                toast.error(error)
            }
        }
    }

    private func delete(_ configId: String, name: String) {
        Task {
            do {
                let _: Empty? = try await session.api.run("deleteAutomation", [.string(configId)])
                toast.show("Deleted \(name)")
                await store.refresh(api: session.api)
            } catch {
                toast.error(error)
            }
        }
    }
}

/// A small card that is itself the button.
private struct AutomationCard: View {
    let name: String
    let symbol: String
    let detail: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(on ? .white : .secondary)
                    .frame(width: 32, height: 32)
                    .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(CardPressStyle())
        .sensoryFeedback(.selection, trigger: on)
        .animation(.easeOut(duration: 0.2), value: on)
    }
}
