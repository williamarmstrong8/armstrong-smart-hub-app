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
    static let ink = adaptive(0x262322, 0xFFFFFF)
    static let secondary = adaptive(0x68615D, 0xE6E1DE)
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
    /// A page hero below its top bar: Fitness's watch, date, title and three rings, which Home,
    /// Finance and Reflection match so every top sheet is the same height.
    static let heroHeight: CGFloat = 484
    /// Fitness and Brick's sheet content, top inset to hero, so their glass sheets are exactly as
    /// tall as the HubTabPage ones (top inset + 44pt top bar + 8pt gap + hero).
    static let deviceSheetHeight: CGFloat = topInset + minHitTarget + 8 + heroHeight
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

    /// Backdrop pages render in the dark scheme so Liquid Glass goes dark and all text,
    /// including the system's secondary styles, stays white.
    func hubPageStyle(backdrop: Bool = true) -> some View {
        background {
            if backdrop { AmbientBackdrop() } else { HubDesign.page.ignoresSafeArea() }
        }
        .modifier(HubPageForeground(dark: backdrop))
        .tint(HubDesign.action)
    }

    func hubListStyle() -> some View {
        scrollContentBackground(.hidden)
            .hubPageStyle()
            .listRowSeparatorTint(HubDesign.separator)
    }
}

private struct HubPageForeground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let dark: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, dark ? .dark : scheme)
            .toolbarColorScheme(dark ? .dark : nil, for: .navigationBar)
            .foregroundStyle(HubDesign.ink, HubDesign.secondary, HubDesign.secondary)
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

/// A stable header and one vertical scroll owner. The top bar and hero sit together on a glass
/// sheet over the backdrop, as on Fitness and Brick. Lazy sections avoid constructing
/// offscreen charts and images; identity belongs to the feature's data, not its index.
struct HubTabPage<Hero: View, Content: View>: View {
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content
    /// An ambient gradient behind the page, for screens built from Liquid Glass.
    var mountains = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: HubLayout.sectionGap) {
                VStack(spacing: 8) {
                    // Where the page's buttons used to sit; kept so every top sheet stays one height.
                    Color.clear.frame(height: HubLayout.minHitTarget)
                    hero
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.top, HubLayout.topInset)
                .padding(.bottom, HubLayout.sectionGap)
                .frame(maxWidth: .infinity)
                .background {
                    if mountains {
                        Color.clear
                            .glassGlare(.regular, in: UnevenRoundedRectangle(bottomLeadingRadius: BrickLook.sheetRadius, bottomTrailingRadius: BrickLook.sheetRadius, style: .continuous))
                            .padding(.top, -600)
                    }
                }
                LazyVStack(alignment: .leading, spacing: HubLayout.sectionGap) {
                    content
                }
                .padding(.horizontal, HubLayout.gutter)
            }
            .padding(.bottom, HubLayout.bottomInset)
            .containerRelativeFrame(.horizontal, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .demoScroll()
        .hubPageStyle(backdrop: mountains)
    }
}

/// A settings-style page: sections grouped into glass cards on the ambient backdrop.
struct GlassForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: HubLayout.sectionGap) { content }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.top, HubLayout.topInset)
                .padding(.bottom, HubLayout.bottomInset)
                .containerRelativeFrame(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .hubPageStyle(backdrop: true)
    }
}

/// One glass card holding a section's rows, split by hairlines, with an optional header and footer.
struct GlassSection<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.font(.footnote.weight(.medium)).foregroundStyle(HubDesign.secondary).textCase(.uppercase).padding(.horizontal, 8)
            BrickCard(padding: 0) {
                Group(subviews: content) { rows in
                    VStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { i in
                            rows[i]
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget, alignment: .leading)
                            if i < rows.count - 1 { BrickDivider().padding(.leading, 16) }
                        }
                    }
                }
            }
            footer.font(.footnote).foregroundStyle(HubDesign.secondary).padding(.horizontal, 8)
        }
    }
}

extension GlassSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { EmptyView() }) }
}
extension GlassSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(title) }, footer: { EmptyView() }) }
}
extension GlassSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.init(content: content, header: { EmptyView() }, footer: footer) }
}

extension View {
    /// A list on the ambient backdrop.
    func hubGlassList() -> some View { hubListStyle() }
}
