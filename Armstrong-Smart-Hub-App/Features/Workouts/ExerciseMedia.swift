import SwiftUI
import UIKit

/// Pictures and how-to steps for the built-in exercises, from free-exercise-db
/// (github.com/yuhonas/free-exercise-db, public domain under the Unlicense).
/// Each entry has two frames, the start and the end of a rep, which the
/// exercise page plays back as a loop. Custom exercises have no media.
enum ExerciseMedia {
    private static let base = "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/"

    /// Hub library id → free-exercise-db id.
    private static let ids: [String: String] = [
        "bench-press-barbell": "Barbell_Bench_Press_-_Medium_Grip",
        "bench-press-dumbbell": "Dumbbell_Bench_Press",
        "incline-bench-press-barbell": "Barbell_Incline_Bench_Press_-_Medium_Grip",
        "incline-bench-press-dumbbell": "Incline_Dumbbell_Press",
        "decline-bench-press-barbell": "Decline_Barbell_Bench_Press",
        "chest-press-machine": "Leverage_Chest_Press",
        "chest-fly-dumbbell": "Dumbbell_Flyes",
        "chest-fly-machine": "Butterfly",
        "cable-crossover": "Cable_Crossover",
        "push-up": "Pushups",
        "chest-dip": "Dips_-_Chest_Version",
        "deadlift-barbell": "Barbell_Deadlift",
        "pull-up": "Pullups",
        "chin-up": "Chin-Up",
        "lat-pulldown-cable": "Wide-Grip_Lat_Pulldown",
        "bent-over-row-barbell": "Bent_Over_Barbell_Row",
        "dumbbell-row": "One-Arm_Dumbbell_Row",
        "seated-cable-row": "Seated_Cable_Rows",
        "t-bar-row": "T-Bar_Row_with_Handle",
        "chest-supported-row-machine": "Leverage_Iso_Row",
        "pullover-cable": "Straight-Arm_Pulldown",
        "back-extension": "Hyperextensions_Back_Extensions",
        "shrug-dumbbell": "Dumbbell_Shrug",
        "overhead-press-barbell": "Standing_Military_Press",
        "shoulder-press-dumbbell": "Dumbbell_Shoulder_Press",
        "shoulder-press-machine": "Machine_Shoulder_Military_Press",
        "arnold-press-dumbbell": "Arnold_Dumbbell_Press",
        "lateral-raise-dumbbell": "Side_Lateral_Raise",
        "lateral-raise-cable": "Cable_Seated_Lateral_Raise",
        "front-raise-dumbbell": "Front_Incline_Dumbbell_Raise",
        "rear-delt-fly-dumbbell": "Seated_Bent-Over_Rear_Delt_Raise",
        "rear-delt-fly-machine": "Reverse_Machine_Flyes",
        "face-pull-cable": "Face_Pull",
        "upright-row-barbell": "Upright_Barbell_Row",
        "bicep-curl-barbell": "Barbell_Curl",
        "bicep-curl-dumbbell": "Dumbbell_Bicep_Curl",
        "hammer-curl-dumbbell": "Hammer_Curls",
        "preacher-curl-ez": "Preacher_Curl",
        "bicep-curl-cable": "Standing_Biceps_Cable_Curl",
        "incline-curl-dumbbell": "Incline_Dumbbell_Curl",
        "triceps-pushdown-cable": "Triceps_Pushdown",
        "overhead-triceps-extension-cable": "Cable_Rope_Overhead_Triceps_Extension",
        "skull-crusher-ez": "EZ-Bar_Skullcrusher",
        "close-grip-bench-press": "Close-Grip_Barbell_Bench_Press",
        "triceps-dip": "Dips_-_Triceps_Version",
        "wrist-curl-dumbbell": "Seated_Dumbbell_Palms-Up_Wrist_Curl",
        "squat-barbell": "Barbell_Squat",
        "front-squat-barbell": "Front_Barbell_Squat",
        "hack-squat-machine": "Hack_Squat",
        "leg-press-machine": "Leg_Press",
        "goblet-squat": "Goblet_Squat",
        "bulgarian-split-squat": "Split_Squat_with_Dumbbells",
        "lunge-dumbbell": "Dumbbell_Lunges",
        "leg-extension-machine": "Leg_Extensions",
        "romanian-deadlift-barbell": "Romanian_Deadlift",
        "romanian-deadlift-dumbbell": "Stiff-Legged_Dumbbell_Deadlift",
        "lying-leg-curl-machine": "Lying_Leg_Curls",
        "seated-leg-curl-machine": "Seated_Leg_Curl",
        "hip-thrust-barbell": "Barbell_Hip_Thrust",
        "glute-bridge": "Butt_Lift_Bridge",
        "hip-abduction-machine": "Thigh_Abductor",
        "hip-adduction-machine": "Thigh_Adductor",
        "standing-calf-raise-machine": "Standing_Calf_Raises",
        "seated-calf-raise-machine": "Seated_Calf_Raise",
        "plank": "Plank",
        "crunch": "Crunches",
        "hanging-leg-raise": "Hanging_Leg_Raise",
        "cable-crunch": "Cable_Crunch",
        "ab-wheel": "Ab_Roller",
        "russian-twist": "Russian_Twist",
        "kettlebell-swing": "One-Arm_Kettlebell_Swings",
        "clean-barbell": "Power_Clean",
        "farmers-walk": "Farmers_Walk",
        "burpee": "Mountain_Climbers",
        "rowing-machine": "Rowing_Stationary",
        "treadmill": "Running_Treadmill",
        "stair-climber": "Stairmaster",
        "assault-bike": "Air_Bike",
    ]

    static func has(_ exerciseId: String) -> Bool { ids[exerciseId] != nil }

    /// Frame 0 is the start of the rep, frame 1 the end.
    static func frame(_ exerciseId: String, _ index: Int = 0) -> URL? {
        ids[exerciseId].flatMap { URL(string: "\(base)\($0)/\(index).jpg") }
    }

    static func detailsURL(_ exerciseId: String) -> URL? {
        ids[exerciseId].flatMap { URL(string: "\(base)\($0).json") }
    }

    /// free-exercise-db's entry: the steps and the muscles it lists.
    struct Details: Decodable {
        var instructions: [String]
        var primaryMuscles: [String]
        var secondaryMuscles: [String]
    }

    private static var detailsCache: [String: Details] = [:]

    static func details(_ exerciseId: String) async -> Details? {
        if let cached = detailsCache[exerciseId] { return cached }
        guard let url = detailsURL(exerciseId),
              let data = try? await ExerciseImages.session.data(from: url).0,
              let details = try? JSONDecoder().decode(Details.self, from: data) else { return nil }
        detailsCache[exerciseId] = details
        return details
    }
}

/// Downloads exercise pictures once: kept in memory for scrolling and in a
/// disk cache across launches.
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
        guard let data = try? await session.data(from: url).0, let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
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

/// The round picture beside an exercise's name, white like the photos' backdrop.
struct ExerciseThumb: View {
    var exerciseId: String
    var muscle: String?
    var size: CGFloat = 48

    var body: some View {
        RemoteImage(url: ExerciseMedia.frame(exerciseId)) {
            Image(systemName: ExerciseThumb.symbol(muscle))
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.55))
        }
        .padding(ExerciseMedia.has(exerciseId) ? size * 0.06 : 0)
        .frame(width: size, height: size)
        .background(Color.white)
        .clipShape(.circle)
        .overlay(Circle().stroke(Fit.hairline, lineWidth: 1))
    }

    static func symbol(_ muscle: String?) -> String {
        switch muscle {
        case "cardio": "figure.run"
        case "core": "figure.core.training"
        case "full_body": "figure.mixed.cardio"
        case "quads", "hamstrings", "glutes", "calves": "figure.strengthtraining.functional"
        default: "figure.strengthtraining.traditional"
        }
    }
}

/// The exercise played back: the start and end of a rep, alternating.
struct ExerciseAnimation: View {
    var exerciseId: String
    var muscle: String?
    @State private var playing = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.white
            if ExerciseMedia.has(exerciseId) {
                TimelineView(.periodic(from: .now, by: 0.9)) { context in
                    let index = playing ? Int(context.date.timeIntervalSinceReferenceDate / 0.9) % 2 : 0
                    ZStack {
                        // Both frames stay loaded so the swap never flashes the placeholder.
                        frame(0).opacity(index == 0 ? 1 : 0)
                        frame(1).opacity(index == 1 ? 1 : 0)
                    }
                    .animation(.easeInOut(duration: 0.25), value: index)
                }
                .padding(16)
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.25), in: .circle)
                }
                .padding(14)
                .accessibilityLabel(playing ? "Pause" : "Play")
            } else {
                Image(systemName: ExerciseThumb.symbol(muscle))
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(Color.black.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }

    private func frame(_ index: Int) -> some View {
        RemoteImage(url: ExerciseMedia.frame(exerciseId, index)) {
            ProgressView().tint(.gray)
        }
    }
}
