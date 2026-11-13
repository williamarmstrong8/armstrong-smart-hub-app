import SwiftUI

/// Jarvis on the phone: ask about the data the hub keeps (spending, sleep, workouts, habits...)
/// and its trends. The agent writes the SQL itself; the model is yours to pick.
struct AgentView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var store = AgentStore()
    @State private var draft = ""
    @FocusState private var focused: Bool

    private static let suggestions = [
        "How has my spending changed month over month?",
        "Is my sleep score related to my resting heart rate?",
        "Which days do I work out most, and how do I sleep after?",
        "What are my biggest recurring charges?",
        "Show my HRV trend over the last 90 days",
    ]

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

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Model", selection: $store.modelID) {
                    ForEach(store.models) { m in Text("\(m.name) · \(m.note)").tag(m.id) }
                }
                if !store.messages.isEmpty {
                    Divider()
                    Button("New chat", systemImage: "square.and.pencil", role: .destructive) { store.reset() }
                }
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
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HubDesign.ink)
                    .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                    .glassGlare(.regular.interactive(), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, HubLayout.gutter)
        .padding(.top, 16)
        .padding(.bottom, 8)
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
            VStack(spacing: 10) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button { store.send(s, api: session.api) } label: {
                        HStack {
                            Text(s).font(.subheadline).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(HubDesign.secondary)
                        }
                        .foregroundStyle(HubDesign.ink)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget, alignment: .leading)
                        .glassGlare(.regular.interactive(), in: .rect(cornerRadius: HubLayout.cardRadius))
                        .contentShape(.rect(cornerRadius: HubLayout.cardRadius))
                    }
                    .buttonStyle(.plain)
                }
            }
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
                    if m.steps.isEmpty, store.sending { ThinkingDots() }
                } else {
                    Text(markdown(m.text))
                        .font(.body)
                        .foregroundStyle(m.failed ? HubDesign.danger : HubDesign.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
        }
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
            Button(action: store.sending ? store.stop : send) {
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
