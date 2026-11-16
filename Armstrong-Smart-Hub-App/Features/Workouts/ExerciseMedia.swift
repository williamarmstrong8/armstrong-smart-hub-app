import ImageIO
import SwiftUI
import UIKit

/// Animations, thumbnails and how-to steps for the built-in exercises, from
/// exercises-dataset (github.com/hasaneyldrm/exercises-dataset). The steps and
/// muscle data are MIT; the GIFs and thumbnails are © Gym visual
/// (gymvisual.com), served at 180×180 and shown with their credit. The table
/// itself is generated into ExerciseMediaData.swift. Custom exercises have no media.
enum ExerciseMedia {
    private static let base = "https://raw.githubusercontent.com/hasaneyldrm/exercises-dataset/main/"
    static let credit = "© Gym visual"
    static let creditURL = URL(string: "https://gymvisual.com/")!

    struct Entry {
        var file: String
        var target: String
        var secondary: [String]
        var steps: [String]
    }

    static func has(_ exerciseId: String) -> Bool { entries[exerciseId] != nil }

    /// A still of the exercise, for the round thumbnails.
    static func thumbnail(_ exerciseId: String) -> URL? {
        entries[exerciseId].flatMap { URL(string: "\(base)images/\($0.file).jpg") }
    }

    /// The looping animation of one rep.
    static func animation(_ exerciseId: String) -> URL? {
        entries[exerciseId].flatMap { URL(string: "\(base)videos/\($0.file).gif") }
    }

    /// The steps and the muscles the dataset lists.
    struct Details {
        var instructions: [String]
        var primaryMuscles: [String]
        var secondaryMuscles: [String]
    }

    static func details(_ exerciseId: String) async -> Details? {
        entries[exerciseId].map { Details(instructions: $0.steps, primaryMuscles: [$0.target], secondaryMuscles: $0.secondary) }
    }
}

/// Downloads exercise pictures once: kept in memory for scrolling and in a
/// disk cache across launches. GIFs come back as animated images.
enum ExerciseImages {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 150 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private static let memory = NSCache<NSURL, UIImage>()

    static func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let data = try? await session.data(from: url).0, let image = decode(data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    /// A still image, or every frame of a GIF with its timing.
    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: frame))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            // Browsers treat near-zero delays as 0.1s; do the same.
            duration += delay < 0.02 ? 0.1 : delay
        }
        return frames.isEmpty ? nil : UIImage.animatedImage(with: frames, duration: duration)
    }
}

/// One remote picture, with a placeholder while it loads or when there is none.
private struct RemoteImage<Placeholder: View>: View {
    var url: URL?
    @ViewBuilder var placeholder: Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? url.flatMap({ ExerciseImages.cached($0) }) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ExerciseImages.load(url)
        }
    }
}

/// Plays an animated UIImage; SwiftUI's Image only shows the first frame.
private struct AnimatedImageView: UIViewRepresentable {
    var image: UIImage
    var playing: Bool

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        // Paused shows the first frame, the start of the rep.
        let shown = playing ? image : (image.images?.first ?? image)
        if view.image !== shown { view.image = shown }
    }
}

/// The round picture beside an exercise's name, white like the media's backdrop.
struct ExerciseThumb: View {
    var exerciseId: String
    var muscle: String?
    var size: CGFloat = 48

    var body: some View {
        RemoteImage(url: ExerciseMedia.thumbnail(exerciseId)) {
            Image(systemName: ExerciseThumb.symbol(muscle, exerciseId: exerciseId))
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.55))
        }
        .frame(width: size, height: size)
        .background(Color.white)
        .clipShape(.circle)
        .overlay(Circle().stroke(Fit.hairline, lineWidth: 1))
    }

    static func symbol(_ muscle: String?, exerciseId: String? = nil) -> String {
        if exerciseId == "rowing-machine" { return "figure.rower" }
        switch muscle {
        case "cardio": return "figure.run"
        case "core": return "figure.core.training"
        case "full_body": return "figure.mixed.cardio"
        case "quads", "hamstrings", "glutes", "calves": return "figure.strengthtraining.functional"
        default: return "figure.strengthtraining.traditional"
        }
    }
}

/// The exercise played back as a looping animation, with its media credit.
struct ExerciseAnimation: View {
    var exerciseId: String
    var muscle: String?
    @State private var playing = true
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.white
            if let url = ExerciseMedia.animation(exerciseId) {
                Group {
                    if let image = image ?? ExerciseImages.cached(url) {
                        AnimatedImageView(image: image, playing: playing)
                    } else {
                        ProgressView().tint(.gray)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .task(id: url) { image = await ExerciseImages.load(url) }
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.25), in: .circle)
                }
                .padding(14)
                .accessibilityLabel(playing ? "Pause" : "Play")
                Link(ExerciseMedia.credit, destination: ExerciseMedia.creditURL)
                    .font(.caption2)
                    .foregroundStyle(Color.black.opacity(0.4))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            } else {
                Image(systemName: ExerciseThumb.symbol(muscle, exerciseId: exerciseId))
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(Color.black.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }
}
