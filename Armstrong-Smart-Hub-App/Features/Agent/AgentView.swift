import SwiftUI

/// Jarvis on the phone: ask about the data the hub keeps (spending, sleep, workouts, habits...)
/// and its trends. The agent writes the SQL itself; the model is yours to pick.
struct AgentView: View {
    @Environment(AppSession.self) private var session
    @State private var store = AgentStore.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .hubPageStyle(backdrop: true)
        .task { await store.loadModels(api: session.api) }
    }

    // MARK: Header

    /// The model picker and the conversation's running cost. The sheet closes with a swipe.
    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                modelMenu
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(store.model?.name ?? "Model").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(HubDesign.ink)
                .padding(.horizontal, 16)
                .frame(minHeight: HubLayout.minHitTarget)
                .glassGlare(.regular.interactive(), in: .capsule)
                .contentShape(.capsule)
            }
            .accessibilityLabel("Model, \(store.model?.name ?? "loading")")
            if !store.messages.isEmpty {
                costPill
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HubLayout.gutter)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .hubAnimation(value: store.messages.isEmpty)
    }

    @ViewBuilder
    private var modelMenu: some View {
        ForEach(groups, id: \.self) { group in
            Section(group) {
                ForEach(models(in: group)) { m in
                    modelButton(m)
                }
            }
        }
        if store.models.isEmpty {
            Text(store.modelsError ?? "Loading models…")
        }
        if !store.messages.isEmpty {
            Section {
                Button("New chat", systemImage: "square.and.pencil") { store.reset() }
            }
        }
    }

    private func models(in group: String) -> [AgentModel] {
        store.models.filter { ($0.group ?? "Models") == group }
    }

    /// A model's name (checked when it's the one in use) over its note and price.
    private func modelButton(_ m: AgentModel) -> some View {
        let selected = m.id == store.model?.id
        let detail = [m.note, m.priceText].compactMap { $0 }.joined(separator: " · ")
        return Button {
            store.modelID = m.id
        } label: {
            modelTitle(m.name, selected: selected)
            Text(detail)
        }
    }

    @ViewBuilder
    private func modelTitle(_ name: String, selected: Bool) -> some View {
        if selected {
            Label(name, systemImage: "checkmark")
        } else {
            Text(name)
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for m in store.models where !seen.contains(m.group ?? "Models") { seen.append(m.group ?? "Models") }
        return seen
    }

    /// What this chat has cost on the AI Gateway so far; "≈" while a figure is still an estimate.
    private var costPill: some View {
        HStack(spacing: 4) {
            if !store.sessionCostIsExact { Text("≈") }
            Text(AgentCost.format(store.sessionCost)).contentTransition(.numericText())
        }
        .font(.subheadline.weight(.medium).monospacedDigit())
        .foregroundStyle(HubDesign.secondary)
        .padding(.horizontal, 14)
        .frame(minHeight: HubLayout.minHitTarget)
        .glassGlare(.regular, in: .capsule)
        .animation(.default, value: store.sessionCost)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(costLabel)
    }

    private var costLabel: String {
        let about = store.sessionCostIsExact ? "" : "about "
        return "This chat has cost " + about + AgentCost.format(store.sessionCost)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.messages.isEmpty { intro }
                    ForEach(store.messages) { m in
                        bubble(m).id(m.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.vertical, 12)
                .containerRelativeFrame(.horizontal)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .onChange(of: store.messages.last?.text) { _, _ in
                if store.sending { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: store.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask about your data").font(.system(size: 34, weight: .light))
                Text("Money, sleep, workouts, habits and more. I write the queries and explain what they show.")
                    .font(.subheadline).foregroundStyle(HubDesign.secondary)
            }
            .padding(.top, 24)
        }
    }

    @ViewBuilder
    private func bubble(_ m: AgentMessage) -> some View {
        switch m.role {
        case .user:
            Text(m.text)
                .font(.body)
                .foregroundStyle(HubDesign.ink)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glassGlare(.regular.tint(HubDesign.action.opacity(0.45)), in: .rect(cornerRadius: 22))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(m.steps) { step in
                    HStack(spacing: 8) {
                        if step.done {
                            Image(systemName: "checkmark.circle").foregroundStyle(HubDesign.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(step.label).foregroundStyle(HubDesign.secondary)
                    }
                    .font(.footnote)
                }
                if m.text.isEmpty {
                    if m.steps.isEmpty, store.sending, m.id == store.messages.last?.id { ThinkingDots() }
                } else {
                    Text(markdown(m.text))
                        .font(.body)
                        .foregroundStyle(m.failed ? HubDesign.danger : HubDesign.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !m.costs.isEmpty {
                    Text(costLine(m))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(HubDesign.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
        }
    }

    /// "≈ $0.0031 · 3 model calls" under an answer.
    private func costLine(_ m: AgentMessage) -> String {
        let prefix = m.costIsExact ? "" : "≈ "
        let calls = m.costs.count == 1 ? "1 model call" : "\(m.costs.count) model calls"
        return prefix + AgentCost.format(m.cost) + " · " + calls
    }

    /// Bold, italics, code and links; line breaks kept. Tables and headings show as plain text.
    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Jarvis", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 18).padding(.vertical, 13)
                .glassGlare(.regular, in: .rect(cornerRadius: 26))
            Button {
                if store.sending { store.stop() } else { send() }
            } label: {
                Image(systemName: store.sending ? "stop.fill" : "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(HubDesign.ink)
                    .frame(width: 50, height: 50)
                    .glassGlare(.regular.tint(HubDesign.action.opacity(0.55)).interactive(), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!store.sending && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(store.sending ? "Stop" : "Send")
        }
        .padding(.horizontal, HubLayout.gutter)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func send() {
        let text = draft
        draft = ""
        store.send(text, api: session.api)
    }
}

/// Three dots that pulse while the agent hasn't said anything yet.
private struct ThinkingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(HubDesign.secondary).frame(width: 7, height: 7)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityLabel("Thinking")
    }
}
