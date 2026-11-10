import SwiftUI

extension View {
    /// Native Liquid Glass plus the glare it needs on a calm background: a bright specular rim
    /// catching light at the top-left, a soft one at the bottom-right, and a faint sheen across the top.
    func glassGlare<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        glassEffect(glass, in: shape)
            .overlay {
                shape
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.95), location: 0),
                                .init(color: .white.opacity(0.12), location: 0.28),
                                .init(color: .white.opacity(0.0), location: 0.55),
                                .init(color: .white.opacity(0.45), location: 1),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.4
                    )
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
