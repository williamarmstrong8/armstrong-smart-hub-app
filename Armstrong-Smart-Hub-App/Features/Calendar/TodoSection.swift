import SwiftUI

/// The to-do list Jarvis keeps (lib/todos.ts), on the Calendar page: check boxes, open ones
/// first, a field to add one. Long-press an item to delete it.
struct TodoSection: View {
    @Environment(AppSession.self) private var session
    /// Owned by the page, so pull to refresh and coming back to the app reload it with the calendar.
    @Binding var items: [TodoItem]?
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var adding: Bool
    /// Changes sent and not answered yet; the hub's list only replaces the screen's once none are.
    @State private var inFlight = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 18) {
                if let items {
                    ForEach(items) { item in
                        row(item)
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(HubDesign.danger)
                }
                addField
            }
        }
    }

    private func row(_ item: TodoItem) -> some View {
        Button {
            toggle(item)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.title2.weight(.light))
                    .foregroundStyle(item.done ? HubDesign.positive : HubDesign.secondary)
                    .hubAnimation(value: item.done)
                Text(item.text)
                    .font(.body)
                    .strikethrough(item.done, color: HubDesign.secondary)
                    .foregroundStyle(item.done ? HubDesign.secondary : HubDesign.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(minHeight: HubLayout.minHitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: item.done) { old, new in new && !old }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                remove(item)
            }
        }
    }

    private var addField: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus")
                .font(.title2.weight(.light))
                .foregroundStyle(HubDesign.secondary)
                .frame(width: 30)
            TextField("Add a to-do", text: $draft)
                .font(.body)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit(add)
        }
        .frame(minHeight: HubLayout.minHitTarget)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        // Shows at once under a temporary id; the hub's list replaces it when it answers.
        let temp = TodoItem(id: "local-\(UUID().uuidString)", text: text, done: false)
        items = (items ?? []) + [temp]
        save()
        Task { await send("POST", New(text: text)) }
    }

    private func toggle(_ item: TodoItem) {
        guard let i = items?.firstIndex(where: { $0.id == item.id }) else { return }
        items?[i] = TodoItem(id: item.id, text: item.text, done: !item.done)
        save()
        // A to-do the hub hasn't answered for yet has no id there to patch.
        guard !item.id.hasPrefix("local-") else { return }
        Task { await send("PATCH", Change(id: item.id, done: !item.done)) }
    }

    private func remove(_ item: TodoItem) {
        items?.removeAll { $0.id == item.id }
        save()
        guard !item.id.hasPrefix("local-") else { return }
        Task { await send("DELETE", Target(id: item.id)) }
    }

    private func save() {
        if let items { DiskCache.write(items, todoCacheName) }
    }

    private struct New: Encodable { let text: String }
    private struct Change: Encodable { let id: String; let done: Bool }
    private struct Target: Encodable { let id: String }

    /// Every change answers with the whole list.
    private func send(_ method: String, _ body: some Encodable) async {
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            let api = session.api
            let reply: TodoList = try await api.send(api.request("/api/mobile/todos", method: method, body: body))
            error = nil
            if inFlight == 1 {
                items = reply.items
                save()
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            // Put back what the hub really has.
            if let real: TodoList = try? await session.api.get("/api/mobile/todos"), inFlight == 1 {
                items = real.items
                save()
            }
        }
    }
}

struct TodoList: Decodable {
    let items: [TodoItem]
}
