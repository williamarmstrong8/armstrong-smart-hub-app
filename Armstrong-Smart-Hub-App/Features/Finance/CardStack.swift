import SwiftUI

/// The credit cards in the wallet, drawn as tinted liquid-glass cards fanned in a stack:
/// the front card whole, the others peeking above it. Tap the stack to bring the next card forward.
struct CardStack: View {
    struct Card: Identifiable {
        let id: String
        let issuer: String
        let name: String
        /// The issuer's card art, in the asset catalog.
        let art: String
        let tint: Color
        /// Lowercased words that pick this card's account out of SimpleFIN's names.
        let match: [String]
    }

    static let wallet: [Card] = [
        Card(id: "venturex", issuer: "Capital One", name: "Venture X", art: "CardVentureX",
             tint: Color(red: 0.16, green: 0.20, blue: 0.27), match: ["venture"]),
        Card(id: "csr", issuer: "Chase", name: "Sapphire Reserve", art: "CardSapphireReserve",
             tint: Color(red: 0.07, green: 0.20, blue: 0.45), match: ["sapphire", "reserve"]),
        Card(id: "discover", issuer: "Discover", name: "Discover it", art: "CardDiscoverIt",
             tint: Color(red: 0.55, green: 0.12, blue: 0.20), match: ["discover"]),
        Card(id: "bcp", issuer: "American Express", name: "Blue Cash Preferred", art: "CardBlueCashPreferred",
             tint: Color(red: 0.18, green: 0.47, blue: 0.82), match: ["blue cash", "amex", "american express"]),
    ]

    var accounts: [Account]
    @State private var front = 0
    /// The front card has slid out and is about to go to the back.
    @State private var lifting = false
    @State private var busy = false

    private let peek: CGFloat = 16
    private let ratio: CGFloat = 1.586

    var body: some View {
        let cards = Self.wallet
        GeometryReader { geo in
            let backs = CGFloat(cards.count - 1)
            let width = min(geo.size.width - 40, (geo.size.height - peek * backs) * ratio)
            let height = width / ratio
            ZStack(alignment: .bottom) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                    // 0 is the front card, larger numbers sit further back.
                    let depth = (i - front + cards.count) % cards.count
                    let d = CGFloat(depth)
                    let out = depth == 0 && lifting
                    CardFace(card: card, balance: balance(for: card))
                        .frame(width: width, height: height)
                        .scaleEffect(1 - d * 0.06 + (out ? 0.04 : 0), anchor: .top)
                        .rotation3DEffect(.degrees(out ? -14 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                        .rotationEffect(.degrees(out ? 2.5 : 0))
                        .offset(y: -d * peek + (out ? height * 0.5 : 0))
                        .opacity(depth == 0 ? 1 : 0.9)
                        .zIndex(Double(cards.count - depth) + (out ? 10 : 0))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .contentShape(.rect)
            .onTapGesture { advance() }
            .sensoryFeedback(.impact(weight: .light), trigger: front)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cards")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the next card")
        .accessibilityAction { advance() }
    }

    /// The front card slides down and out, then the stack springs forward and it tucks in at the back.
    private func advance() {
        guard !busy else { return }
        busy = true
        withAnimation(.easeOut(duration: 0.2)) { lifting = true }
        Task {
            try? await Task.sleep(for: .milliseconds(190))
            withAnimation(.spring(response: 0.62, dampingFraction: 0.68)) {
                front = (front + 1) % Self.wallet.count
                lifting = false
            }
            try? await Task.sleep(for: .milliseconds(320))
            busy = false
        }
    }

    private var accessibilityValue: String {
        let c = Self.wallet[front]
        if let b = balance(for: c) { return "\(c.name), \(Fmt.compact(b, "USD")) balance" }
        return c.name
    }

    /// What is owed on the card, if SimpleFIN has an account that looks like it.
    private func balance(for card: Card) -> Double? {
        accounts.first { a in
            let n = (a.name + " " + a.institution).lowercased()
            return card.match.contains { n.contains($0) }
        }.map { $0.isLiability ? $0.magnitude : abs($0.rawBalance) }
    }
}

private struct CardFace: View {
    let card: CardStack.Card
    let balance: Double?

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: geo.size.width * 0.048, style: .continuous)
            Image(card.art)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipShape(shape)
                // Liquid-glass rim and sheen over the real card.
                .glassGlare(.regular.tint(card.tint.opacity(0.25)), in: shape)
                .overlay(alignment: .bottomTrailing) {
                    if let balance {
                        Text(Fmt.compact(balance, "USD"))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
                            .padding(12)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
        }
    }
}
