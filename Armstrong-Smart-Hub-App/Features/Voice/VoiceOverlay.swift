import SwiftUI

/// The layer over the dashboard while Jarvis is up. First just the orb, big and
/// centered; once there's something to show, the orb tucks into a header with
/// the conversation and the card takes the stage.
struct VoiceOverlay: View {
    let agent: VoiceAgent

    @Namespace private var space

    var body: some View {
        ZStack {
            if agent.presented {
                // Tap anywhere outside the card to dismiss.
                // Darken what's behind so everything can float without cards.
                Color.black.opacity(0.62)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { agent.end() }
                    .transition(.opacity)

                content
                    // Always light-on-dark over the darkened dashboard.
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 56)
                    .padding(.vertical, 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.5), value: agent.presented)
    }

    private var hasStage: Bool { agent.view != nil || agent.hint != nil }

    @ViewBuilder private var content: some View {
        if hasStage {
            // The card gets the screen; Jarvis shrinks to a small badge up top.
            VStack(spacing: 20) {
                HStack(alignment: .center, spacing: 14) {
                    orb.frame(width: 52, height: 52)
                    Captions(agent: agent, compact: true)
                    Spacer(minLength: 0)
                }

                // Centered when it fits; scrolls only when a card runs long (a busy day).
                GeometryReader { geo in
                    ScrollView {
                        stage
                            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 36) {
                Spacer()
                orb.frame(width: 380, height: 380)
                Captions(agent: agent, compact: false)
                    .frame(maxWidth: 720)
                Spacer()
                if let notice = agent.notice { NoticePill(text: notice) }
            }
        }
    }

    private var orb: some View {
        Orb(phase: agent.phase, levels: agent.levels)
            .matchedGeometryEffect(id: "orb", in: space)
            .onTapGesture { agent.end() }
    }

    @ViewBuilder private var stage: some View {
        ZStack {
            if let view = agent.view {
                card(view)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(view.kind)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94)).combined(with: .offset(y: 30)),
                        removal: .opacity.combined(with: .scale(scale: 1.02))
                    ))
            } else if let hint = agent.hint {
                PlaceholderCard(kind: hint)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("hint-\(hint.rawValue)")
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .contentShape(.rect)
        .onTapGesture {} // Taps on the card don't dismiss.
    }

    @ViewBuilder private func card(_ view: VoiceView) -> some View {
        switch view {
        case .lights(let lights, let changed): LightsCard(lights: lights, changed: changed)
        case .movie(let movie, let stage): MovieCard(movie: movie, stage: stage)
        case .finance(let data): FinanceCard(data: data).id(agent.viewToken)
        // Kept alive across updates, so a new event animates into the day already on screen.
        case .calendar(let data): CalendarCard(data: data)
        case .habits(let data): HabitsCard(data: data)
        }
    }
}

/// What you said, and what Jarvis is saying.
private struct Captions: View {
    let agent: VoiceAgent
    let compact: Bool

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: compact ? 4 : 12) {
            if !agent.heard.isEmpty {
                Text(agent.heard)
                    .font(compact ? .subheadline : .title2)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 3)
                    .transition(.opacity)
            }
            if !agent.reply.isEmpty {
                Text(agent.reply)
                    .font(compact ? .headline : .system(size: 30, weight: .semibold, design: .rounded))
                    .lineLimit(compact ? 1 : 4)
                    .transition(.opacity)
            } else if agent.heard.isEmpty || !compact {
                Text(status)
                    .font(compact ? .headline : .title3.weight(.medium))
                    .foregroundStyle(compact ? .primary : .secondary)
                    .contentTransition(.opacity)
            }
        }
        .multilineTextAlignment(compact ? .leading : .center)
        .animation(.easeOut(duration: 0.25), value: agent.heard)
        .animation(.easeOut(duration: 0.2), value: agent.reply)
        .animation(.easeOut(duration: 0.25), value: agent.phase)
    }

    private var status: String {
        switch agent.phase {
        case .idle: ""
        case .connecting: "Hey"
        case .listening: agent.heard.isEmpty ? "Listening…" : ""
        case .thinking: "One sec…"
        case .speaking: ""
        }
    }
}

/// While Jev has guessed the screen but the data is still coming.
private struct PlaceholderCard: View {
    let kind: VoiceView.Kind
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CardHeader(title: title, detail: "Working on it…", symbol: symbol)
            switch kind {
            case .movie:
                HStack(spacing: 36) {
                    block(width: 380, height: 570, radius: 28)
                    VStack(alignment: .leading, spacing: 14) {
                        block(width: 320, height: 40, radius: 10)
                        block(width: 200, height: 22, radius: 8)
                        block(width: 420, height: 18, radius: 6)
                        block(width: 380, height: 18, radius: 6)
                    }
                }
            default:
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in block(width: nil, height: 160, radius: 28) }
                }
                block(width: nil, height: 340, radius: 28)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { shimmer = true }
        }
    }

    private func block(width: CGFloat?, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.white.opacity(0.08))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .opacity(shimmer ? 0.5 : 1)
    }

    private var title: String {
        switch kind {
        case .lights: "Lights"
        case .movie: "Finding it"
        case .finance: "Money"
        case .calendar: "Calendar"
        case .habits: "Habits"
        }
    }

    private var symbol: String {
        switch kind {
        case .lights: "lightbulb.2"
        case .movie: "film"
        case .finance: "chart.bar.xaxis"
        case .calendar: "calendar"
        case .habits: "checkmark.circle"
        }
    }
}

/// A card's title row: floating text, no chrome.
struct CardHeader: View {
    let title: String
    let detail: String
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(detail)
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
}

private struct NoticePill: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect()
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The dashboard's mic button: shows whether "Hey Jarvis" is listening, and
/// starts a conversation on tap.
struct VoiceButton: View {
    let agent: VoiceAgent

    var body: some View {
        Button { agent.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: agent.presented ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: agent.presented)
                Text(agent.wakeReady ? "Hey Jarvis" : "Jarvis")
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(agent.setupError != nil ? Color.orange : agent.wakeReady ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
                .offset(x: -2, y: 2)
        }
        .accessibilityLabel(agent.wakeReady ? "Talk to Jarvis. Listening for Hey Jarvis." : "Talk to Jarvis")
        .help(agent.setupError ?? "")
    }
}
