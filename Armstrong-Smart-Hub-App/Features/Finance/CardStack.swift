import SwiftUI

/// The credit cards in the wallet, drawn as tinted liquid-glass cards fanned in a stack:
/// the front card whole, the others peeking above it. Tap the stack to bring the next card forward.
struct CardStack: View {
    struct Card: Identifiable {
        let id: String
        let issuer: String
        let name: String
        let network: String
        let tint: Color
        /// Lowercased words that pick this card's account out of SimpleFIN's names.
        let match: [String]
    }

    static let wallet: [Card] = [
        Card(id: "venturex", issuer: "Capital One", name: "Venture X", network: "VISA",
             tint: Color(red: 0.16, green: 0.20, blue: 0.27), match: ["venture"]),
        Card(id: "csr", issuer: "Chase", name: "Sapphire Reserve", network: "VISA",
             tint: Color(red: 0.07, green: 0.20, blue: 0.45), match: ["sapphire", "reserve"]),
        Card(id: "discover", issuer: "Discover", name: "Discover it", network: "DISCOVER",
             tint: Color(red: 0.95, green: 0.48, blue: 0.10), match: ["discover"]),
        Card(id: "bcp", issuer: "American Express", name: "Blue Cash Preferred", network: "AMEX",
             tint: Color(red: 0.18, green: 0.47, blue: 0.82), match: ["blue cash", "amex", "american express"]),
    ]

    var accounts: [Account]
    @State private var front = 0

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
                    CardFace(card: card, balance: balance(for: card))
                        .frame(width: width, height: height)
                        .scaleEffect(1 - d * 0.06, anchor: .top)
                        .offset(y: -d * peek)
                        .opacity(depth == 0 ? 1 : 0.9)
                        .zIndex(Double(cards.count - depth))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { front = (front + 1) % cards.count }
            }
            .sensoryFeedback(.selection, trigger: front)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cards")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the next card")
        .accessibilityAction { front = (front + 1) % Self.wallet.count }
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

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.issuer).font(.caption.weight(.semibold)).opacity(0.85)
                Spacer()
                if let balance {
                    Text(Fmt.compact(balance, "USD"))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline) {
                Text(card.name).font(.headline)
                Spacer()
                Text(card.network)
                    .font(.system(size: card.network == "VISA" ? 20 : 13, weight: .heavy).italic())
                    .tracking(card.network == "VISA" ? 0 : 1)
                    .opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background {
            // A wash of the card's colour under the glass so each reads as itself.
            shape.fill(LinearGradient(colors: [card.tint.opacity(0.85), card.tint.opacity(0.45)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .glassGlare(.regular.tint(card.tint.opacity(0.35)), in: shape)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }
}
