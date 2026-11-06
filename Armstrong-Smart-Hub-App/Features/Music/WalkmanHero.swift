import SwiftUI

/// The Walkman, cut out and floating on the hero (a Sony WM-41, photo by Dillan Payne,
/// CC BY-SA 4.0, via Wikimedia Commons). What's playing shows in the cassette window,
/// warped onto it in perspective, and each of the four top keys is its own layer so
/// it can sink into the body when pressed.
struct WalkmanHero: View {
    var playing: SpotifyTrack?
    /// 0...1 per key: how far down it is.
    var depth: [WalkmanKey: Double]
    /// A key just pressed: its word shows across the window for a moment.
    var flash: WalkmanKey?
    /// Reels run fast forward or back while that key is held.
    var winding: WalkmanKey?
    var onKey: (WalkmanKey) -> Void

    /// Width over height of the cutout.
    static let aspect: CGFloat = 1200 / 1018

    /// Each key's layer, in fractions of the body: x, y, width, height.
    static let keyBoxes: [WalkmanKey: CGRect] = [
        .rew: CGRect(x: 0.4270, y: 0.0022, width: 0.1171, height: 0.0364),
        .ff: CGRect(x: 0.5416, y: 0.0097, width: 0.1259, height: 0.0846),
        .stop: CGRect(x: 0.3892, y: 0.0252, width: 0.2431, height: 0.0839),
        .play: CGRect(x: 0.6662, y: 0.0252, width: 0.1297, height: 0.0713),
    ]
    /// Back to front, so the long front key covers the two behind it.
    private static let keyOrder: [WalkmanKey] = [.rew, .ff, .stop, .play]

    /// The cassette window's corners, in fractions: top-left, top-right, bottom-right, bottom-left.
    /// The body is turned a few degrees and seen a little from the right, so it's not a rectangle.
    static let window: [CGPoint] = [
        CGPoint(x: 0.0768, y: 0.3734), CGPoint(x: 0.8401, y: 0.4974),
        CGPoint(x: 0.8350, y: 0.7238), CGPoint(x: 0.0901, y: 0.5731),
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let quad = Self.window.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            let flat = CGSize(width: hypot(quad[1].x - quad[0].x, quad[1].y - quad[0].y),
                              height: hypot(quad[3].x - quad[0].x, quad[3].y - quad[0].y))
            ZStack(alignment: .topLeading) {
                Image("Walkman").resizable().frame(width: size.width, height: size.height)
                ForEach(Self.keyOrder, id: \.self) { key in
                    keyLayer(key, in: size)
                }
                WalkmanLCD(playing: playing, flash: flash, winding: winding)
                    .frame(width: flat.width, height: flat.height)
                    .projectionEffect(Self.projection(from: flat, to: quad))
                    .allowsHitTesting(false)
                keyTargets(in: size, window: quad)
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
    }

    // MARK: Keys

    /// A pressed key: its slot goes dark, and the key drops into it, clipped to
    /// its own outline so the bottom disappears into the body instead of sliding over it.
    @ViewBuilder
    private func keyLayer(_ key: WalkmanKey, in size: CGSize) -> some View {
        let box = Self.keyBoxes[key]!
        let d = depth[key] ?? 0
        if d > 0.001 {
            let frame = CGSize(width: box.width * size.width, height: box.height * size.height)
            let travel = 0.016 * size.height * d
            let image = Image("WalkmanKey\(key.imageName)").resizable()
            ZStack {
                image.renderingMode(.template).foregroundStyle(Color(white: 0.04))
                image
                    .brightness(-0.14 * d)
                    .offset(y: travel)
                    .mask(image)
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: box.minX * size.width, y: box.minY * size.height)
            .allowsHitTesting(false)
        }
    }

    /// Big enough to hit: columns over the top keys reaching up past the body, and the
    /// cassette window for play/pause (the long front key). Buttons with labels, so
    /// VoiceOver can press them too.
    @ViewBuilder
    private func keyTargets(in size: CGSize, window quad: [CGPoint]) -> some View {
        let top: CGFloat = -24
        let bottom = 0.13 * size.height
        let columns: [(WalkmanKey, CGFloat, CGFloat)] = [(.rew, 0.40, 0.54), (.ff, 0.54, 0.666), (.play, 0.666, 0.80)]
        ForEach(columns, id: \.0) { key, from, to in
            Button { onKey(key) } label: {
                Color.clear.contentShape(.rect)
                    .frame(width: (to - from) * size.width, height: bottom - top)
            }
            .buttonStyle(.plain)
            .offset(x: from * size.width, y: top)
            .accessibilityLabel(key.label)
        }
        let minX = min(quad[0].x, quad[3].x), maxX = max(quad[1].x, quad[2].x)
        let minY = min(quad[0].y, quad[1].y), maxY = max(quad[2].y, quad[3].y)
        Button { onKey(.stop) } label: {
            Color.clear.contentShape(.rect).frame(width: maxX - minX, height: maxY - minY)
        }
        .buttonStyle(.plain)
        .offset(x: minX, y: minY)
        .accessibilityLabel(playing?.isPlaying == true ? "Pause" : "Play")
    }

    // MARK: Perspective

    /// Maps a flat rect of `size` onto the quad (top-left, top-right, bottom-right,
    /// bottom-left): the square-to-quad homography, scaled down to the rect.
    static func projection(from size: CGSize, to q: [CGPoint]) -> ProjectionTransform {
        let (x0, y0, x1, y1, x2, y2, x3, y3) = (q[0].x, q[0].y, q[1].x, q[1].y, q[2].x, q[2].y, q[3].x, q[3].y)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let den = dx1 * dy2 - dx2 * dy1
        let g = (dx3 * dy2 - dx2 * dy3) / den
        let h = (dx1 * dy3 - dx3 * dy1) / den
        let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3
        let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3
        var t = ProjectionTransform()
        t.m11 = a / size.width; t.m12 = d / size.width; t.m13 = g / size.width
        t.m21 = b / size.height; t.m22 = e / size.height; t.m23 = h / size.height
        t.m31 = x0; t.m32 = y0; t.m33 = 1
        return t
    }
}

private extension WalkmanKey {
    var imageName: String {
        switch self {
        case .rew: "Rew"
        case .ff: "FF"
        case .stop: "Stop"
        case .play: "Play"
        }
    }
}

// MARK: The cassette window

/// What shows through the window: two tape reels that turn while it plays (the left one
/// emptying into the right as the track goes on), the title, a tape counter and the flags.
struct WalkmanLCD: View {
    var playing: SpotifyTrack?
    var flash: WalkmanKey?
    var winding: WalkmanKey?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let glow = Color(red: 1.0, green: 0.72, blue: 0.32)
    private static let dim = Color(red: 1.0, green: 0.72, blue: 0.32).opacity(0.28)

    var body: some View {
        let running = (playing?.isPlaying == true || winding != nil || flash != nil) && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { context in
            let now = context.date
            GeometryReader { geo in
                let h = geo.size.height
                let progress = playing?.progress(at: now) ?? 0
                ZStack {
                    LinearGradient(colors: [Color(white: 0.07), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
                    HStack(spacing: h * 0.14) {
                        TapeReel(fill: 1 - progress, angle: angle(at: now, direction: 1))
                            .frame(width: h * 0.78, height: h * 0.78)
                        readout(h: h, now: now, progress: progress)
                        TapeReel(fill: progress, angle: angle(at: now, direction: 1))
                            .frame(width: h * 0.78, height: h * 0.78)
                    }
                    .padding(.horizontal, h * 0.14)
                    flashText(h: h, now: now)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func readout(h: CGFloat, now: Date, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: h * 0.06) {
            Text(playing?.title.uppercased() ?? "NO TAPE")
                .font(.system(size: h * 0.2, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(Self.glow)
                .id(playing?.id)
                .transition(reduceMotion ? .identity : .push(from: .trailing))
            Text(playing?.subtitle.uppercased() ?? "PULL DOWN TO PLAY")
                .font(.system(size: h * 0.13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(Self.glow.opacity(0.7))
            HStack(spacing: h * 0.08) {
                Text(clock(playing?.elapsed(at: now) ?? 0))
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Self.dim)
                        Capsule().fill(Self.glow).frame(width: max(2, bar.size.width * progress))
                    }
                }
                .frame(height: h * 0.05)
                Text(clock(Double(playing?.durationMs ?? 0) / 1000))
            }
            .font(.system(size: h * 0.12, weight: .medium, design: .monospaced))
            .foregroundStyle(Self.glow.opacity(0.85))
            HStack(spacing: h * 0.1) {
                flag(playing?.isPlaying == true ? "▶ PLAY" : "■ STOP", on: playing != nil)
                flag("SHUF", on: playing?.shuffle == true)
                flag(playing?.isEpisode == true ? "TALK" : "MUSIC", on: playing != nil)
            }
            .font(.system(size: h * 0.1, weight: .bold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: playing?.id)
    }

    private func flag(_ text: String, on: Bool) -> some View {
        Text(text).foregroundStyle(on ? Self.glow : Self.dim)
    }

    /// A word across the window for a moment after a key, like an old deck's display.
    @ViewBuilder
    private func flashText(h: CGFloat, now: Date) -> some View {
        if flash != nil || winding != nil {
            let word = switch winding ?? flash ?? .stop {
            case .play: "SHUFFLE"
            case .ff: "▶▶ FF"
            case .rew: "◀◀ REW"
            case .stop: playing?.isPlaying == true ? "▶ PLAY" : "■ PAUSE"
            }
            Text(word)
                .font(.system(size: h * 0.36, weight: .heavy, design: .monospaced))
                .foregroundStyle(Self.glow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.82))
                .transition(.opacity)
        }
    }

    /// Reels turn about one revolution every two seconds, much faster while winding.
    private func angle(at now: Date, direction: Double) -> Angle {
        let speed: Double = switch winding {
        case .ff, .play: 6
        case .rew: -6
        default: 1
        }
        return .degrees(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) * 180 * speed * direction)
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var accessibilityText: String {
        guard let playing else { return "Nothing playing" }
        let state = playing.isPlaying ? "Playing" : "Paused"
        return "\(state): \(playing.title), \(playing.subtitle)"
    }
}

/// A cassette hub with tape wound around it: `fill` 0...1 of a full reel.
private struct TapeReel: View {
    var fill: Double
    var angle: Angle

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            let hub = r * 0.36
            let tape = hub + (r - hub) * fill
            ZStack {
                Circle().fill(Color(red: 0.24, green: 0.15, blue: 0.1)).frame(width: tape * 2, height: tape * 2)
                Circle().fill(Color(white: 0.85)).frame(width: hub * 2, height: hub * 2)
                ForEach(0..<6) { i in
                    Capsule().fill(Color(white: 0.2))
                        .frame(width: hub * 0.22, height: hub * 0.55)
                        .offset(y: -hub * 0.55)
                        .rotationEffect(.degrees(Double(i) * 60))
                }
                .rotationEffect(angle)
                Circle().fill(Color(white: 0.2)).frame(width: hub * 0.5, height: hub * 0.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
