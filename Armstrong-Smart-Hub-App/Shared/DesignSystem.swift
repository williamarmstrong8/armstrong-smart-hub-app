import SwiftUI

/// Shared visual language for the iPhone hub and its detail pages.
/// Feature palettes may add semantic chart colors, not another set of surfaces.
enum HubDesign {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let page = adaptive(0xF2F0EE, 0x161414)
    static let surface = adaptive(0xFAF9F8, 0x211F1E)
    static let raised = adaptive(0xFFFFFF, 0x2C2928)
    static let ink = adaptive(0x262322, 0xF3EFED)
    static let secondary = adaptive(0x68615D, 0xB8B0AB)
    static let separator = adaptive(0xD8D2CE, 0x433D39)
    static let track = adaptive(0xE5E0DC, 0x393330)
    static let action = adaptive(0x005DB8, 0x75B8FF)
    static let positive = adaptive(0x236E34, 0x7FC990)
    static let warning = adaptive(0x925000, 0xFFB75C)
    static let danger = adaptive(0xBC2832, 0xFF8288)
}

enum HubLayout {
    static let gutter: CGFloat = 20
    static let sectionGap: CGFloat = 24
    static let cardPadding: CGFloat = 20
    static let topInset: CGFloat = 12
    static let bottomInset: CGFloat = 32
    static let cardRadius: CGFloat = 24
    static let controlRadius: CGFloat = 12
    static let minHitTarget: CGFloat = 44
}

enum HubMotion {
    static let quick = Animation.easeOut(duration: 0.16)
    static let standard = Animation.easeInOut(duration: 0.24)

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : standard
    }
}

/// Keep feedback local to the control that changed; never attach to an entire page.
private struct HubAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(HubMotion.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func hubAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(HubAnimation(value: value))
    }

    func hubPageStyle() -> some View {
        background(HubDesign.page.ignoresSafeArea())
            .foregroundStyle(HubDesign.ink)
            .tint(HubDesign.action)
    }

    func hubListStyle() -> some View {
        scrollContentBackground(.hidden)
            .hubPageStyle()
            .listRowSeparatorTint(HubDesign.separator)
    }
}

/// Hit area belongs to the button label, not an outer frame around the button.
struct HubToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A stable header and one vertical scroll owner. Lazy sections avoid constructing
/// offscreen charts and images; identity belongs to the feature's data, not its index.
struct HubTabPage<TopBar: View, Content: View>: View {
    @ViewBuilder var topBar: TopBar
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                topBar
                LazyVStack(alignment: .leading, spacing: HubLayout.sectionGap) {
                    content
                }
            }
            .padding(.horizontal, HubLayout.gutter)
            .padding(.top, HubLayout.topInset)
            .padding(.bottom, HubLayout.bottomInset)
            .containerRelativeFrame(.horizontal, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .hubPageStyle()
    }
}
