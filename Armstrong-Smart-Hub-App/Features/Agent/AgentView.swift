import SwiftUI

private let suggestions = [
    "Turn off every light that's on",
    "What did I spend on food in the last 30 days?",
    "What's downloading right now?",
    "How has my net worth changed?",
]

struct AgentView: View {
    let switchTab: (HubTab) -> Void

    @Environment(AppSession.self) private var session
    @State private var chat = ChatStore()
    @State private var input = ""
    @State private var glance: [GlanceCell] = []
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if chat.messages.isEmpty {
                        welcome
                    } else {
                        transcript
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(chat.messages.isEmpty ? .top : .bottom)
                .onChange(of: chat.messages) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                if !chat.messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New chat", systemImage: "square.and.pencil") { chat.reset() }
                            .disabled(chat.isBusy)
                    }
                }
            }
            .task { await loadGlance() }
            .refreshable { await loadGlance() }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = (5..<12).contains(hour) ? "Good morning" : (12..<17).contains(hour) ? "Good afternoon" : "Good evening"
        let first = session.user?.firstName ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(.largeTitle.bold())
                Text("Ask anything, or tell me what to change around the house.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        chat.send(s, api: session.api)
                    } label: {
                        HStack {
                            Text(s).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !glance.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(glance) { cell in
                        Button { open(cell) } label: { GlanceTile(cell: cell) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(chat.messages) { message in
                MessageRow(message: message)
            }
            if chat.isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if let error = chat.error {
                ErrorBanner(message: error) { chat.retry(api: session.api) }
            }
            Color.clear.frame(height: 1).id("bottom")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your home or money…", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .onSubmit(submit)
            Group {
                if chat.isBusy {
                    Button("Stop", systemImage: "stop.fill") { chat.stop() }
                } else {
                    Button("Send", systemImage: "arrow.up") { submit() }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .padding(6)
        }
        .glassEffect(in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func submit() {
        let text = input
        input = ""
        chat.send(text, api: session.api)
    }

    private func open(_ cell: GlanceCell) {
        switch cell.href {
        case "/home": switchTab(.home)
        case "/finance": switchTab(.finance)
        case "/calendar": switchTab(.calendar)
        case "/habits": switchTab(.habits)
        default: break
        }
    }

    private func loadGlance() async {
        guard let me: MeResponse = try? await session.api.get("/api/mobile/me") else { return }
        glance = me.glance
        session.updateUser(me.user)
    }
}

private struct GlanceTile: View {
    let cell: GlanceCell

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cell.label).font(.footnote).foregroundStyle(.secondary)
            Text(cell.value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1)
            if let detail = cell.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 18))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.parts) { part in
                    switch part {
                    case .text(_, let text):
                        MarkdownText(text)
                    case .tool(let step):
                        ToolRow(step: step)
                    }
                }
            }
        }
    }
}

private struct ToolRow: View {
    let step: ToolStep

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch step.state {
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle.fill")
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 16)
            Text(step.label)
            if step.state == .failed { Text("failed").foregroundStyle(.red) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// Renders the agent's markdown: block structure (headings, bullets, tables as
/// monospaced text) line by line, inline styling via AttributedString.
struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [AnyView] {
        var views: [AnyView] = []
        var table: [String] = []
        func flushTable() {
            guard !table.isEmpty else { return }
            let rows = table.filter { !$0.replacingOccurrences(of: "|", with: "").allSatisfy { "-: ".contains($0) } }
            views.append(AnyView(MarkdownTable(rows: rows)))
            table = []
        }
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") { table.append(line); continue }
            flushTable()
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                views.append(AnyView(Text(inline(text)).font(.headline).padding(.top, 4)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                views.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(inline(String(line.dropFirst(2))))
                }))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                views.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line[...dot]).monospacedDigit()
                    Text(inline(line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
                }))
            } else {
                views.append(AnyView(Text(inline(line))))
            }
        }
        flushTable()
        return views
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

private struct MarkdownTable: View {
    let rows: [String]

    var body: some View {
        let cells = rows.map { row in
            row.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(cells.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
                                .fontWeight(i == 0 ? .semibold : .regular)
                                .monospacedDigit()
                        }
                    }
                    if i == 0 { Divider() }
                }
            }
            .font(.subheadline)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        }
    }
}
