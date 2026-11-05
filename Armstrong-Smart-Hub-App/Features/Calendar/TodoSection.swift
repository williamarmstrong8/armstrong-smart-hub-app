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
            Task { await send("PATCH", Change(id: item.id, done: !item.done)) }
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
                Task { await send("DELETE", Target(id: item.id)) }
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
        Task { await send("POST", New(text: text)) }
    }

    private struct New: Encodable { let text: String }
    private struct Change: Encodable { let id: String; let done: Bool }
    private struct Target: Encodable { let id: String }

    /// Every change answers with the whole list.
    private func send(_ method: String, _ body: some Encodable) async {
        do {
            let api = session.api
            let reply: TodoList = try await api.send(api.request("/api/mobile/todos", method: method, body: body))
            items = reply.items
            error = nil
            DiskCache.write(reply, todoCacheName)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TodoList: Codable {
    let items: [TodoItem]
}
