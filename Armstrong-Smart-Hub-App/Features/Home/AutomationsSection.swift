import SwiftUI

/// Automations, scenes and scripts from Home Assistant. Run, enable or disable
/// here; the agent can also create, edit and delete hub automations.
struct AutomationsSection: View {
    let payload: AutomationsPayload
    let store: HomeStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @State private var running: String?
    @State private var deleting: HAAutomation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Automations", meta: "\(payload.automations.filter { $0.state == "on" }.count) active")

            if !payload.scenes.isEmpty || !payload.scripts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(payload.scenes + payload.scripts) { item in
                            Button {
                                run(item.id, name: item.name)
                            } label: {
                                Label(item.name, systemImage: item.id.hasPrefix("scene.") ? "sparkles" : "play.circle")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .disabled(running == item.id)
                        }
                    }
                }
            }

            if payload.automations.isEmpty {
                Text("No automations yet. Ask the agent to make one, like \"turn on the porch light at sunset\".")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(payload.automations) { a in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(a.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    if a.hubMade {
                                        Text("Hub").font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                                    }
                                }
                                Text(lastRun(a.lastTriggered)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(a.name, isOn: Binding(
                                get: { a.state == "on" },
                                set: { on in Task { await store.setAutomation(a, enabled: on, api: session.api, toast: toast) } }
                            ))
                            .labelsHidden()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .contextMenu {
                            Button("Run now", systemImage: "play") { run(a.id, name: a.name) }
                            if a.hubMade, a.configId != nil {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = a }
                            }
                        }
                        if a.id != payload.automations.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                Text("Touch and hold an automation to run or delete it.").font(.caption).foregroundStyle(.secondary)
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

    private func lastRun(_ iso: String?) -> String {
        guard let iso, let date = ISO.parse(iso) else { return "Never run" }
        return "Ran \(date.formatted(.relative(presentation: .named)))"
    }
}
