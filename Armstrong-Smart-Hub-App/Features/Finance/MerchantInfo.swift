import SwiftUI

/// What we can work out about a transaction's merchant from the bank's raw
/// descriptor: a cleaner name, a website (for the logo), a plain-English note,
/// the payment processor and roughly where it happened.
struct MerchantInfo: Equatable {
    var name: String
    var domain: String?
    var note: String?
    var processor: String?
    var location: String?
    /// For a transfer: the account the money came from, when we can tell.
    var fromAccount: String?

    /// Logo for the merchant's website. Only the merchant's domain is sent.
    var logoURL: URL? {
        guard let domain else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128")
    }

    /// `history` lets a transfer find its other half, so it can show the logo of the account the money left.
    static func resolve(_ t: Transaction, history: [Transaction] = []) -> MerchantInfo {
        let raw = t.description.uppercased()
        let haystack = "\(t.payee.uppercased()) \(raw)"
        var info = MerchantInfo(name: t.payee)

        let match = known.first(where: { entry in entry.patterns.contains { haystack.contains($0) } })
        if let known = match {
            info.name = known.name
            info.domain = known.domain
            info.note = known.note
        }
        // Card payments and plain transfers between your own accounts wear the logo of the account the
        // money came from: this one when it is the outflow, the matching outflow's when it is the inflow.
        // Venmo, Zelle and the like keep their own logo.
        if match?.cardPayment == true || (t.category == "Transfers" && match == nil),
           let from = source(of: t, in: history),
           let domain = BankLogo.domain(for: from.institution) {
            info.domain = domain
            info.fromAccount = from.accountName
        }
        if let p = processors.first(where: { raw.hasPrefix($0.prefix) || raw.contains(" \($0.prefix)") }) {
            info.processor = p.label
        }
        info.location = location(in: raw)
        return info
    }

    /// Where a transfer's money came from. An outflow came from its own account; an inflow came from the
    /// account with the same amount going out within a few days.
    private static func source(of t: Transaction, in history: [Transaction]) -> (institution: String, accountName: String)? {
        if t.netEffect < 0 { return (t.institution, t.accountName) }
        let window: Double = 5 * 86_400
        let pair = history
            .filter { $0.accountId != t.accountId && abs($0.netEffect + t.netEffect) < 0.01 && abs($0.posted - t.posted) <= window }
            .min { abs($0.posted - t.posted) < abs($1.posted - t.posted) }
        return pair.map { ($0.institution, $0.accountName) }
    }

    // MARK: Known merchants

    private struct Known {
        let patterns: [String]
        let name: String
        let domain: String?
        let note: String?
        var cardPayment = false
    }

    private static func k(_ patterns: [String], _ name: String, _ domain: String?, _ note: String? = nil) -> Known {
        Known(patterns: patterns, name: name, domain: domain, note: note)
    }

    private static func card(_ patterns: [String], _ name: String, _ domain: String?, _ note: String) -> Known {
        Known(patterns: patterns, name: name, domain: domain, note: note, cardPayment: true)
    }

    /// Order matters: more specific patterns first (Uber Eats before Uber).
    private static let known: [Known] = [
        // Transport
        k(["UBER EATS", "UBEREATS"], "Uber Eats", "ubereats.com", "Food delivery through Uber Eats."),
        k(["UBER"], "Uber", "uber.com", "Uber ride."),
        k(["LYFT"], "Lyft", "lyft.com", "Lyft ride. A $1 \"temp auth hold\" is a card check that drops off."),
        k(["WAYMO"], "Waymo", "waymo.com", "Driverless Waymo ride."),
        k(["NYCT PAYGO", "MTA OMNY", "OMNY"], "MTA subway / bus", "mta.info", "OMNY tap fare on the NYC subway or bus."),
        k(["CLIPPER"], "Clipper", "clippercard.com", "Bay Area transit card fare (BART, Muni, Caltrain)."),
        k(["CITI BIKE", "CITIBIKE"], "Citi Bike", "citibikenyc.com", "Citi Bike ride or membership."),
        k(["AMTRAK"], "Amtrak", "amtrak.com", "Train ticket."),
        k(["UNITED"], "United Airlines", "united.com", "United flight, seat or bag fee."),
        k(["DELTA AIR"], "Delta", "delta.com", "Delta flight, seat or bag fee."),
        k(["JETBLUE"], "JetBlue", "jetblue.com", "JetBlue flight, seat or bag fee."),
        k(["AMERICAN AIR", "AA.COM"], "American Airlines", "aa.com", "American Airlines flight, seat or bag fee."),
        k(["SOUTHWEST"], "Southwest", "southwest.com", "Southwest flight."),
        k(["AIRBNB"], "Airbnb", "airbnb.com", "Airbnb stay."),
        k(["MTA*LIRR", "LIRR"], "LIRR", "mta.info", "Long Island Rail Road ticket."),
        k(["NJ TRANSIT"], "NJ Transit", "njtransit.com", "NJ Transit ticket."),

        // Food & groceries
        k(["WHOLEFDS", "WHOLE FOODS"], "Whole Foods", "wholefoodsmarket.com", "Grocery store."),
        k(["TRADER JOE"], "Trader Joe's", "traderjoes.com", "Grocery store."),
        k(["INSTACART"], "Instacart", "instacart.com", "Grocery delivery."),
        k(["DOORDASH", "DD *"], "DoorDash", "doordash.com", "Food delivery through DoorDash."),
        k(["SEAMLESS"], "Seamless", "seamless.com", "Food delivery."),
        k(["GRUBHUB"], "Grubhub", "grubhub.com", "Food delivery."),
        k(["SHAKE SHACK"], "Shake Shack", "shakeshack.com"),
        k(["STARBUCKS"], "Starbucks", "starbucks.com"),
        k(["DUNKIN"], "Dunkin'", "dunkindonuts.com"),
        k(["SWEETGREEN"], "Sweetgreen", "sweetgreen.com"),
        k(["CHIPOTLE"], "Chipotle", "chipotle.com"),
        k(["MCDONALD"], "McDonald's", "mcdonalds.com"),
        k(["BLUE BOTTLE"], "Blue Bottle Coffee", "bluebottlecoffee.com"),
        k(["EQUATOR COFFEE"], "Equator Coffees", "equatorcoffees.com", "Coffee shop (Bay Area)."),
        k(["83 PROOF"], "83 Proof", nil),
        k(["JOE COFFEE"], "Joe Coffee", "joecoffeecompany.com"),

        // Shopping
        k(["AMAZON", "AMZN"], "Amazon", "amazon.com", "Amazon order. A positive Amazon line is a refund."),
        k(["TARGET"], "Target", "target.com"),
        k(["COSTCO"], "Costco", "costco.com"),
        k(["CVS"], "CVS", "cvs.com", "Pharmacy."),
        k(["WALGREENS"], "Walgreens", "walgreens.com", "Pharmacy."),
        k(["DUANE READE"], "Duane Reade", "walgreens.com", "Pharmacy."),
        k(["UNIQLO"], "Uniqlo", "uniqlo.com"),
        k(["BEST BUY"], "Best Buy", "bestbuy.com"),
        k(["IKEA"], "IKEA", "ikea.com"),
        k(["ETSY"], "Etsy", "etsy.com"),

        // Subscriptions & software
        k(["APPLE.COM/BILL", "APPLE.COM BILL"], "Apple", "apple.com", "App Store, iCloud or Apple subscription. Check Settings › Apple ID › Subscriptions."),
        k(["APPLE STORE", "APPLE ONLINE"], "Apple Store", "apple.com", "Apple hardware or accessories."),
        k(["GOOGLE *WORKSPACE", "GOOGLE WORKSPACE"], "Google Workspace", "workspace.google.com", "Google Workspace subscription (custom-domain email)."),
        k(["GOOGLE *YOUTUBE", "YOUTUBE"], "YouTube", "youtube.com", "YouTube Premium or rental."),
        k(["GOOGLE *GOOGLE ONE", "GOOGLE ONE"], "Google One", "one.google.com", "Google storage plan."),
        k(["GOOGLE"], "Google", "google.com", "Google purchase or subscription."),
        k(["CURSOR"], "Cursor", "cursor.com", "Cursor AI editor subscription."),
        k(["OPENAI", "CHATGPT"], "OpenAI", "openai.com", "ChatGPT / OpenAI subscription."),
        k(["ANTHROPIC", "CLAUDE.AI"], "Anthropic", "anthropic.com", "Claude subscription."),
        k(["GITHUB"], "GitHub", "github.com", "GitHub subscription."),
        k(["VERCEL INC PAYROLL", "VERCEL PAYROLL"], "Vercel payroll", "vercel.com", "Your paycheck."),
        k(["VERCEL"], "Vercel", "vercel.com"),
        k(["SQUARESPACE", "SQSP*"], "Squarespace", "squarespace.com", "Website or domain renewal on Squarespace."),
        k(["SPOTIFY"], "Spotify", "spotify.com", "Spotify subscription."),
        k(["NETFLIX"], "Netflix", "netflix.com", "Netflix subscription."),
        k(["HULU"], "Hulu", "hulu.com", "Hulu subscription."),
        k(["DISNEY"], "Disney+", "disneyplus.com", "Disney+ subscription."),
        k(["NYTIMES", "NY TIMES"], "New York Times", "nytimes.com", "NYT subscription."),
        k(["CLASSPASS"], "ClassPass", "classpass.com", "Fitness class credits."),
        k(["EQUINOX"], "Equinox", "equinox.com", "Gym membership."),

        // Bills
        k(["CON ED", "CECONY", "CONED"], "Con Edison", "coned.com", "Electricity / gas bill."),
        k(["VERIZON"], "Verizon", "verizon.com", "Phone or internet bill."),
        k(["T-MOBILE", "TMOBILE"], "T-Mobile", "t-mobile.com", "Phone bill."),
        k(["AT&T", "ATT*"], "AT&T", "att.com", "Phone or internet bill."),
        k(["SPECTRUM"], "Spectrum", "spectrum.com", "Internet bill."),
        k(["SABET MANAGE"], "Sabet Management", "appfolio.com", "Rent paid to your landlord through their AppFolio portal."),

        // Money movement
        k(["VENMO"], "Venmo", "venmo.com", "Money moved between Venmo and the bank, not spending."),
        k(["ZELLE"], "Zelle", "zellepay.com", "Zelle payment to or from a person."),
        k(["PAYPAL"], "PayPal", "paypal.com"),
        card(["CHASE CREDIT CRD", "CHASE CREDIT CARD"], "Chase card payment", "chase.com", "Paying off the Chase card from the bank. Not new spending."),
        card(["AMEX EPAYMENT", "AMERICAN EXPRESS ACH", "AMEX ACH"], "Amex card payment", "americanexpress.com", "Paying off the Amex card from the bank. Not new spending."),
        card(["CAPITAL ONE MOBILE", "CAPITAL ONE ONLINE", "CAPITAL ONE CRCARDPMT", "CAPITAL ONE PMT"], "Capital One card payment", "capitalone.com", "Paying off the Capital One card from the bank. Not new spending."),
        card(["DISCOVER"], "Discover card payment", "discover.com", "Paying off the Discover card. Not new spending."),
        card(["AUTOMATIC PAYMENT", "AUTOPAY PAYMENT", "DIRECTPAY", "CREDIT CARD PAYMENT", "MOBILE PAYMENT", "PAYMENT THANK YOU", "ONLINE PAYMENT"], "Card payment received", nil, "The card being paid off. The matching outflow is on your bank account."),
        k(["ATM WITHDRAWAL", "NON-WF ATM"], "ATM withdrawal", nil, "Cash taken out at an ATM."),
        k(["ATM TRANSACTION FEE", "ATM FEE"], "ATM fee", nil, "Fee for using another bank's ATM."),
        k(["FIDELITY", "SPAXX", "DIVIDEND RECEIVED"], "Fidelity", "fidelity.com", "Brokerage activity: buys, dividends and cash sweeps."),
        k(["BANK DEPOSIT SWEEP", "SWEEP TRANSACTION"], "Cash sweep", nil, "Brokerage moving idle cash in or out of its bank sweep. Not spending."),
        k(["STATE STREET SPDR", "SPDR"], "SPY ETF", "ssga.com", "S&P 500 ETF trade or dividend."),
    ]

    // MARK: Payment processors (descriptor prefixes)

    private static let processors: [(prefix: String, label: String)] = [
        ("TST*", "Toast, a restaurant/café till"),
        ("SQ *", "Square, a small-shop till"),
        ("SQ*", "Square, a small-shop till"),
        ("BT*", "Braintree online checkout"),
        ("APF*", "AppFolio rent portal"),
        ("PP*", "PayPal"),
        ("PAYPAL *", "PayPal"),
        ("SP ", "a Shopify store"),
        ("DD *", "DoorDash"),
        ("SQSP*", "Squarespace"),
        ("APLPAY", "Apple Pay"),
    ]

    // MARK: Location

    private static let cities = [
        "NEW YORK", "BROOKLYN", "QUEENS", "JERSEY CITY", "HOBOKEN", "SAN FRANCISCO", "OAKLAND", "BERKELEY",
        "MOUNTAIN VIEW", "PALO ALTO", "SAN JOSE", "LOS ANGELES", "STINSON BEACH", "MILL VALLEY", "SAUSALITO",
        "BOSTON", "CHICAGO", "SEATTLE", "AUSTIN", "MIAMI", "WASHINGTON", "PHILADELPHIA", "DENVER",
    ]

    private static let states: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "DC": "Washington, DC", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii",
        "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky",
        "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
        "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire",
        "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York", "NC": "North Carolina", "ND": "North Dakota",
        "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island",
        "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
        "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
    ]

    /// Card descriptors usually end "<city> <ST>". Pull that out when present.
    private static func location(in raw: String) -> String? {
        let words = raw.split(separator: " ")
        guard let last = words.last, last.count == 2, let state = states[String(last)] else { return nil }
        if let city = cities.first(where: { raw.contains($0) }) {
            return "\(city.capitalized), \(last)"
        }
        return state
    }
}

/// Round merchant logo; falls back to the category symbol.
struct MerchantLogo: View {
    let info: MerchantInfo
    let category: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(CategoryStyle.color(category).opacity(0.16))
            if let url = info.logoURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high).scaledToFit()
                            .padding(size * 0.18)
                            .background(Circle().fill(.white))
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var fallback: some View {
        Image(systemName: CategoryStyle.symbol(category))
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(CategoryStyle.color(category))
    }
}
