import SwiftUI

extension View {
    /// Native Liquid Glass plus the glare it needs on a calm background: a bright specular rim,
    /// a soft one opposite it, and a faint sheen across the top.
    ///
    /// The rim catches a light that hangs up and to the left of the screen and stays put while the
    /// page moves. Low on the screen a card catches it along its top edge; as the card scrolls up,
    /// the bright edge slides over the top-left corner and down the left side, with the soft one
    /// opposite turning to match. Swiping a card left along a carousel turns it back towards the
    /// top. Glass that isn't in a scroll view keeps the resting rim, bright at the top left.
    func glassGlare<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        glassEffect(glass, in: shape)
            .overlay {
                // A conic gradient round the card's centre, turned to face the light, then cut down
                // to a thin stroke. The square is wide enough to cover every edge at any turn, and
                // the turn happens in `visualEffect`, so scrolling redraws the rim without running
                // any view body.
                // The clear frame keeps the card's own size, so the mask draws the card's outline and
                // not the oversized square's (which turned capsules into big circles).
                Color.clear
                    .overlay {
                        Rectangle()
                            .fill(AngularGradient(stops: GlassLight.rim, center: .center))
                            .aspectRatio(1, contentMode: .fill)
                            .scaleEffect(1.42)
                            .visualEffect { content, proxy in
                                content.rotationEffect(GlassLight.angle(for: proxy))
                            }
                    }
                    .mask { shape.stroke(lineWidth: 1.4) }
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
    }
}

/// Where the light sits for `glassGlare`, and how the rim reads it.
nonisolated enum GlassLight {
    /// The rim round the full turn from its brightest point: a bright lobe, a soft one opposite
    /// (where the light comes back off the far edge), and nothing on the two sides between.
    static let rim: [Gradient.Stop] = [
        .init(color: .white.opacity(0.95), location: 0),
        .init(color: .white.opacity(0.70), location: 0.05),
        .init(color: .white.opacity(0.32), location: 0.12),
        .init(color: .white.opacity(0.10), location: 0.20),
        .init(color: .white.opacity(0.0), location: 0.30),
        .init(color: .white.opacity(0.0), location: 0.38),
        .init(color: .white.opacity(0.22), location: 0.45),
        .init(color: .white.opacity(0.45), location: 0.5),
        .init(color: .white.opacity(0.22), location: 0.55),
        .init(color: .white.opacity(0.0), location: 0.62),
        .init(color: .white.opacity(0.0), location: 0.70),
        .init(color: .white.opacity(0.10), location: 0.80),
        .init(color: .white.opacity(0.32), location: 0.88),
        .init(color: .white.opacity(0.70), location: 0.95),
        .init(color: .white.opacity(0.95), location: 1),
    ]

    /// The bright point for glass at the middle of the screen, or not scrolling at all: top left.
    static let resting = -135.0
    /// How far the bright point turns as a card crosses the visible area: anticlockwise as it
    /// rises, clockwise as it moves left, the way a fixed light up and to the left would.
    static let verticalSweep = 110.0
    static let horizontalSweep = 50.0

    /// Which way the bright point faces for the glass this proxy measures: 0° is the right-hand
    /// edge, turning clockwise.
    static func angle(for proxy: GeometryProxy) -> Angle {
        let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
        var degrees = resting
        // How far down the visible area the card's centre is: 0 at the top, 1 at the bottom. Held
        // a little past the edges so glass taller than the screen doesn't spin as it goes by.
        if let page = proxy.bounds(of: .scrollView(axis: .vertical)), page.height > 0 {
            let y = (center.y - page.minY) / page.height
            degrees += (min(max(y, -0.25), 1.25) - 0.5) * verticalSweep
        }
        if let row = proxy.bounds(of: .scrollView(axis: .horizontal)), row.width > 0 {
            let x = (center.x - row.minX) / row.width
            degrees += (0.5 - min(max(x, -0.25), 1.25)) * horizontalSweep
        }
        return .degrees(degrees)
    }
}
