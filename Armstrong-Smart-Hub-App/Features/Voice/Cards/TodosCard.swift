import SwiftUI

/// The to-do list, minimal and centered: a check box and the item, one per row, open ones first.
/// An item just added slides in; one just checked off fills its box and fades back.
struct TodosCard: View {
    let items: [TodoItem]
    let changed: [String]

    var body: some View {
        VStack(spacing: 22) {
            if items.isEmpty {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 96, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Nothing to do").font(.system(size: 56, weight: .light))
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    TodoRow(item: item, changed: changed.contains(item.id), delay: Double(i) * 0.05)
                }
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.5, bounce: 0.2), value: items)
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let changed: Bool
    let delay: Double

    @State private var done = false
    @State private var shown = false

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(done ? Color.green : .secondary, lineWidth: 3)
                    .background(done ? Color.green : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 44, height: 44)
            Text(item.text)
                .font(.system(size: 34, weight: .light))
                .strikethrough(done, color: .secondary)
                .foregroundStyle(done ? .secondary : .primary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 16)
        .sensoryFeedback(.success, trigger: done) { old, new in changed && new && !old }
        .onAppear(perform: play)
        .onChange(of: item) { play() }
    }

    private func play() {
        // A just-checked item starts empty, then fills; a just-added one only slides in.
        done = changed && item.done ? false : item.done
        withAnimation(.spring(duration: 0.45, bounce: 0.2).delay(delay)) { shown = true }
        if changed, done != item.done {
            withAnimation(.spring(duration: 0.45, bounce: 0.3).delay(delay + 0.45)) { done = item.done }
        }
    }
}
