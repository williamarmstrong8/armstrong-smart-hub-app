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
            HStack {
                BrickCaps(text: "To-do").foregroundStyle(BrickLook.soft)
                Spacer()
                if let open = items?.filter({ !$0.done }).count, open > 0 {
                    Text("\(open) open").font(.footnote).foregroundStyle(BrickLook.soft).monospacedDigit()
                }
            }
            BrickCard(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    if let items {
                        ForEach(items) { item in
                            row(item)
                        }
                    } else if error == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    addField
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: items)
    }

    private func row(_ item: TodoItem) -> some View {
        Button {
            Task { await send("PATCH", Change(id: item.id, done: !item.done)) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(item.done ? Color.green : BrickLook.soft)
                    .contentTransition(.symbolEffect(.replace))
                Text(item.text)
                    .font(.system(size: 17))
                    .strikethrough(item.done, color: BrickLook.soft)
                    .foregroundStyle(item.done ? BrickLook.soft : BrickLook.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
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
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(BrickLook.soft)
                .frame(width: 22)
            TextField("Add a to-do", text: $draft)
                .font(.system(size: 17))
                .focused($adding)
                .submitLabel(.done)
                .onSubmit(add)
        }
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
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TodoList: Decodable {
    let items: [TodoItem]
}
