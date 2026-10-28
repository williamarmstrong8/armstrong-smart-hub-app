import SwiftUI

/// A movie or show's poster, front and center, with where it stands: waiting
/// for a yes, requested, already in the library, or playing.
struct MovieCard: View {
    let movie: MovieCardData
    let stage: MovieStage

    @State private var shown = false
    @State private var width: CGFloat = 900

    /// Side by side on a landscape iPad; poster over the text when portrait.
    private var wide: Bool { width >= 760 }
    private var posterWidth: CGFloat { wide ? min(340, width * 0.36) : min(280, width * 0.55) }

    var body: some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 48)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        layout {
            AsyncImage(url: movie.posterURL.flatMap(URL.init(string:)), transaction: SwiftUI.Transaction(animation: .easeOut(duration: 0.4))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().transition(.opacity)
                } else {
                    ZStack {
                        Color(.tertiarySystemFill)
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: posterWidth, height: posterWidth * 1.5)
            .clipShape(.rect(cornerRadius: 28))
            .shadow(color: .white.opacity(0.12), radius: 40)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
            .rotation3DEffect(.degrees(shown ? 0 : 12), axis: (x: 0, y: 1, z: 0))
            .scaleEffect(shown ? 1 : 0.9)

            VStack(alignment: .leading, spacing: 14) {
                Text(movie.title)
                    .font(.system(size: wide ? 56 : 44, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(meta).font(.title2).foregroundStyle(.secondary).lineLimit(2)
                if let overview = movie.overview {
                    Text(overview).font(.title3).foregroundStyle(.secondary).lineLimit(wide ? 5 : 3)
                }
                if wide { Spacer(minLength: 12) }
                StageBadge(stage: stage)
                    .id(stage)
                    .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity), removal: .opacity))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: wide ? posterWidth * 1.5 : nil)
            .opacity(shown ? 1 : 0)
            .offset(x: shown ? 0 : 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.spring(duration: 0.5, bounce: 0.25), value: stage)
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.2)) { shown = true }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let year = movie.year { parts.append(year) }
        if let m = movie.runtimeMinutes, m > 0 { parts.append(m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m") }
        if movie.mediaType == "tv" { parts.append("Series") }
        parts.append(contentsOf: movie.genres.prefix(2))
        return parts.joined(separator: " · ")
    }
}

private struct StageBadge: View {
    let stage: MovieStage

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.system(size: 40, weight: .semibold))
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title.weight(.semibold))
                if let subtitle { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
            }
        }
        .foregroundStyle(tint == .secondary ? .primary : tint)
    }

    @ViewBuilder private var icon: some View {
        switch stage {
        case .confirm:
            Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
        case .requested:
            Image(systemName: "checkmark.circle.fill").symbolEffect(.bounce, options: .nonRepeating)
        case .alreadyRequested:
            Image(systemName: "clock.fill")
        case .available:
            Image(systemName: "play.circle.fill")
        case .playing:
            Image(systemName: "tv.fill").symbolEffect(.pulse, options: .repeating)
        }
    }

    private var title: String {
        switch stage {
        case .confirm: "Download this?"
        case .requested: "Requested"
        case .alreadyRequested: "Already requested"
        case .available: "In your library"
        case .playing: "Playing on the TV"
        }
    }

    private var subtitle: String? {
        switch stage {
        case .confirm: "Say “yes” or “that's it” to download"
        case .requested: "It'll start downloading shortly"
        case .alreadyRequested: "It's on its way"
        case .available: "Say “play it” to watch"
        case .playing: nil
        }
    }

    private var tint: Color {
        switch stage {
        case .confirm: .accentColor
        case .requested: .green
        case .alreadyRequested: .orange
        case .available: .accentColor
        case .playing: .indigo
        }
    }
}
