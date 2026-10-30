import SwiftUI

/// Picks which devices the Home tab (and the website) shows.
struct ManageDevicesView: View {
    let entities: [HAEntity]
    let visible: [String]?
    let onSaved: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var search = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error)
                        .foregroundStyle(HubDesign.danger)
                        .listRowBackground(HubDesign.raised)
                }
                ForEach(filtered) { e in
                    Button {
                        if picked.contains(e.id) { picked.remove(e.id) } else { picked.insert(e.id) }
                    } label: {
                        HStack {
                            Image(systemName: e.symbol).frame(width: 24).foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(e.name).foregroundStyle(.primary)
                                Text(e.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: picked.contains(e.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(e.id) ? HubDesign.action : HubDesign.secondary)
                        }
                    }
                    .listRowBackground(HubDesign.raised)
                }
            }
            .hubListStyle()
            .searchable(text: $search)
            .navigationTitle("\(picked.count) devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Show everything available") { picked = [] ; save() }
                }
            }
            .onAppear {
                picked = Set(visible ?? entities.filter { !$0.isUnavailable }.map(\.id))
            }
        }
    }

    private var filtered: [HAEntity] {
        let q = search.lowercased()
        let list = q.isEmpty ? entities : entities.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) }
        return list.sorted { (picked.contains($0.id) ? 0 : 1, $0.name) < (picked.contains($1.id) ? 0 : 1, $1.name) }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let _: Empty? = try await session.api.run("saveVisibleDevices", [.array(picked.sorted().map { .string($0) })])
                onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
