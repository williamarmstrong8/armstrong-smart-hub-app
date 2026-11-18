#if DEBUG
import UIKit

/// Made-up films for Home's shelf in demo mode. Their posters are drawn here and handed over as
/// `data:` URLs, so the shelf looks real without any network or anyone else's artwork.
@MainActor
enum DemoMovies {
    private struct Film {
        let id: Int
        let title: String
        let year: String
        let genres: [String]
        let minutes: Int
        let rating: Double
        let overview: String
        let colors: (UInt32, UInt32)
        /// Shelf state: "available", "downloading" or "approved".
        let stage: String
        var progress: Double? = nil
        var eta: Double? = nil
    }

    private static let films: [Film] = [
        Film(id: 910_001, title: "Northbound", year: "2025", genres: ["Drama", "Adventure"], minutes: 118, rating: 7.8,
             overview: "Two estranged brothers drive a failing truck from Texas to the Arctic Circle to scatter their father's ashes.",
             colors: (0x0E3B43, 0xE8743B), stage: "downloading", progress: 0.62, eta: 840),
        Film(id: 910_002, title: "The Glass Orchard", year: "2024", genres: ["Mystery"], minutes: 104, rating: 7.1,
             overview: "A botanist inherits a greenhouse where nothing has died in forty years, and starts to find out why.",
             colors: (0x1F4D3A, 0xD9C27A), stage: "approved"),
        Film(id: 910_003, title: "Saltwater Hours", year: "2025", genres: ["Romance", "Drama"], minutes: 112, rating: 7.4,
             overview: "One summer on a Maine island, a ferry captain and a visiting cellist keep missing the last boat home.",
             colors: (0x173A5E, 0x8FD3E8), stage: "available"),
        Film(id: 910_004, title: "Paper Lanterns", year: "2023", genres: ["Animation", "Family"], minutes: 96, rating: 8.2,
             overview: "A girl who folds lanterns for her grandmother's shop discovers each one carries a memory into the sky.",
             colors: (0x3A1E4D, 0xF2A65A), stage: "available"),
        Film(id: 910_005, title: "Signal Lost", year: "2025", genres: ["Thriller", "Science Fiction"], minutes: 109, rating: 6.9,
             overview: "The crew of a deep-sea research station hears a voice on a frequency nobody has used since 1962.",
             colors: (0x0B0F1A, 0x3FB8AF), stage: "available"),
        Film(id: 910_006, title: "Last Light on Elm Street", year: "2024", genres: ["Comedy"], minutes: 101, rating: 7.0,
             overview: "The last family on a street marked for demolition throws one final block party, whether anyone comes or not.",
             colors: (0x4A2511, 0xF6D365), stage: "available"),
    ]

    /// Home's shelf, as the hub's `requests`.
    static var requests: [[String: Any]] {
        films.enumerated().map { i, f in
            let progress: Any = f.progress.map { $0 as Any } ?? (f.stage == "available" ? 1.0 as Any : NSNull())
            let eta: Any = f.eta.map { $0 as Any } ?? NSNull()
            return ["id": i + 1, "tmdbId": f.id, "title": f.title, "mediaType": "movie", "posterURL": poster(f),
             "stage": f.stage, "progress": progress, "etaSeconds": eta, "updatedAt": DemoHub.iso(DemoHub.daysAgo(i)), "statusMessage": NSNull()]
        }
    }

    /// Search and suggestions.
    static var results: [[String: Any]] {
        films.map { f in
            ["id": f.id, "title": f.title, "overview": f.overview, "mediaType": "movie", "year": f.year, "posterURL": poster(f),
             "status": f.stage == "available" ? 5 : 2]
        }
    }

    /// A title's card.
    static func detail(_ id: Int) -> [String: Any]? {
        guard let f = films.first(where: { $0.id == id }) else { return nil }
        let available = f.stage == "available"
        return ["id": f.id, "title": f.title, "overview": f.overview, "mediaType": "movie", "year": f.year,
                "posterURL": poster(f), "backdropURL": NSNull(), "runtimeMinutes": f.minutes, "genres": f.genres,
                "voteAverage": f.rating, "seasons": NSNull(), "alreadyRequested": true, "available": available,
                "jellyfinItemId": available ? "demo-\(f.id)" as Any : NSNull(), "playerOnline": true, "canLaunchPlayer": true,
                "resumeSeconds": NSNull(), "runtimeSeconds": Double(f.minutes * 60), "episodeLabel": NSNull()]
    }

    // MARK: Posters

    private static var cache: [Int: String] = [:]

    /// A 2:3 poster: a two-colour gradient with a soft sun, the title in a large serif and the year.
    private static func poster(_ f: Film) -> String {
        if let hit = cache[f.id] { return hit }
        let size = CGSize(width: 400, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let top = color(f.colors.0), bottom = color(f.colors.1)
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            // A soft sun, placed a little differently for each film.
            let x = size.width * (0.3 + 0.4 * Double(f.id % 5) / 4)
            let sun = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [UIColor.white.withAlphaComponent(0.55).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1])!
            cg.drawRadialGradient(sun, startCenter: CGPoint(x: x, y: 230), startRadius: 0,
                                  endCenter: CGPoint(x: x, y: 230), endRadius: 170, options: [])

            // A dark band at the bottom for the title.
            let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.65).cgColor] as CFArray,
                                  locations: [0, 1])!
            cg.drawLinearGradient(fade, start: CGPoint(x: 0, y: 330), end: CGPoint(x: 0, y: size.height), options: [])

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let serif = UIFont.systemFont(ofSize: 50, weight: .bold).fontDescriptor.withDesign(.serif)
                .map { UIFont(descriptor: $0, size: 50) } ?? .systemFont(ofSize: 50, weight: .bold)
            let title = NSAttributedString(string: f.title.uppercased(), attributes: [
                .font: serif, .foregroundColor: UIColor.white, .paragraphStyle: paragraph, .kern: 2,
            ])
            let box = title.boundingRect(with: CGSize(width: 340, height: 300), options: [.usesLineFragmentOrigin], context: nil)
            title.draw(with: CGRect(x: 30, y: 520 - box.height, width: 340, height: box.height),
                       options: [.usesLineFragmentOrigin], context: nil)
            let year = NSAttributedString(string: f.year, attributes: [
                .font: UIFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: UIColor.white.withAlphaComponent(0.8),
                .paragraphStyle: paragraph, .kern: 4,
            ])
            year.draw(in: CGRect(x: 0, y: 540, width: size.width, height: 30))
        }
        let url = "data:image/jpeg;base64," + (image.jpegData(compressionQuality: 0.82) ?? Data()).base64EncodedString()
        cache[f.id] = url
        return url
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
