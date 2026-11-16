import SwiftUI

/// The watch faces and glances on the hub as a carousel of drawn previews: swipe
/// left and right to browse, tap Send to put one on the watch over Bluetooth.
struct WatchFacesCarousel: View {
    @Environment(AppSession.self) private var session
    @Environment(WatchLink.self) private var watch
    @State private var faces: [Face] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var sending: String?
    @State private var shown: String?

    struct Face: Decodable, Identifiable {
        var id: String
        var name: String
        var version: Int
        var size: Int
    }

    private struct Catalog: Decodable { var faces: [Face] }
    private struct Download: Decodable { var data: String }

    var body: some View {
        VStack(spacing: 14) {
            if loading && faces.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else if let loadError, faces.isEmpty {
                Text(loadError).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 120)
            } else if faces.isEmpty {
                Text("No faces on the hub yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(ordered) { face in card(face).id(face.id) }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $shown)
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, 48, for: .scrollContent)
                // The card's own padding is 16; the carousel runs edge to edge inside it.
                .padding(.horizontal, -16)

                HStack(spacing: 6) {
                    ForEach(ordered) { face in
                        Circle().fill(face.id == (shown ?? ordered.first?.id) ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                status
            }
        }
        .padding(.vertical, 6)
        .task { await load() }
        .sensoryFeedback(.success, trigger: watch.installer.lastResult)
    }

    /// Faces first, then the glances.
    private var ordered: [Face] {
        faces.filter { !$0.id.hasPrefix("glance-") } + faces.filter { $0.id.hasPrefix("glance-") }
    }

    private var status: some View {
        VStack(spacing: 6) {
            let installer = watch.installer
            if let fraction = installer.fraction { ProgressView(value: fraction).padding(.horizontal, 24) }
            if let text = installer.status ?? installer.lastResult ?? (watch.state == .connected ? nil : "Connect your watch to send a face") {
                Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ face: Face) -> some View {
        VStack(spacing: 12) {
            WatchFacePreview(id: face.id, name: face.name)
                .frame(width: 200, height: 200)
                .overlay {
                    if sending == face.id && watch.installer.isInstalling {
                        Circle().trim(from: 0, to: watch.installer.fraction ?? 0)
                            .stroke(Fit.action, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(-6)
                    }
                }
                .padding(.top, 8)
            VStack(spacing: 2) {
                Text(face.name.replacingOccurrences(of: "Glance: ", with: ""))
                    .font(.subheadline.weight(.semibold))
                Text("\(face.id.hasPrefix("glance-") ? "Glance" : "Watch face") · v\(face.version) · \(max(face.size / 1024, 1)) KB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                sending = face.id
                Task { await install(face) }
            } label: {
                Label(sending == face.id && watch.installer.isInstalling ? "Sending…" : "Send to watch",
                      systemImage: "arrow.down.to.line.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Fit.action)
            .disabled(!canInstall)
        }
        .frame(width: 220)
        .accessibilityElement(children: .contain)
    }

    private var canInstall: Bool {
        watch.state == .connected && !watch.installer.isInstalling && !watch.files.isSyncing
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let catalog: Catalog = try await session.api.get("/api/mobile/watch/faces")
            faces = catalog.faces
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load the faces. The hub may need the latest update."
        }
    }

    private func install(_ face: Face) async {
        do {
            let download: Download = try await session.api.get("/api/mobile/watch/faces/\(face.id)")
            guard let data = Data(base64Encoded: download.data) else { throw GarminUpload.Failure.notPRG }
            await watch.installer.install([UInt8](data), name: face.name, busy: watch.files.isSyncing)
        } catch {
            watch.installer.report(error)
        }
    }
}

// MARK: Previews of what's on the watch

/// A face or glance drawn the way the watch draws it (watch/ArmstrongFace, watch/ArmstrongData,
/// watch/glances), with live values from the watch where the phone has them.
struct WatchFacePreview: View {
    @Environment(WatchLink.self) private var watch
    var id: String
    var name: String

    var body: some View {
        let values = PreviewValues(watch: watch)
        ZStack {
            Circle().fill(.black)
            switch id {
            case "armstrong-minimal": MinimalFace(values: values)
            case "armstrong-data": DataFace(values: values)
            default: GlancePreview(id: id, name: name, values: values)
            }
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 2)
        }
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .accessibilityLabel("\(name) preview")
    }
}

/// Live where the phone has the value, typical otherwise.
private struct PreviewValues {
    var heart: Int
    var bodyBattery: Int
    var temp: Int
    var sky: String
    var calories = 1840
    var steps = 8412
    var stepGoal = 10000
    var battery = 82
    var stress = 24
    var intensity = 96
    var week = [true, false, true, true, false, true, false]

    @MainActor init(watch: WatchLink) {
        heart = watch.heartRate?.bpm ?? 58
        bodyBattery = watch.bodyBattery ?? 72
        if let weather: WeatherData = DiskCache.read("weather") {
            temp = weather.current.temp
            sky = WatchSettings.sky(weather.current.code)
        } else {
            temp = 54
            sky = "sun"
        }
    }
}

/// Colors from watch/shared/Draw.mc.
private enum WatchInk {
    static let green = Color(watchHex: 0x34C759)
    static let red = Color(watchHex: 0xFF453A)
    static let indigo = Color(watchHex: 0x5E5CE6)
    static let teal = Color(watchHex: 0x64D2FF)
    static let orange = Color(watchHex: 0xFF9F0A)
    static let gray = Color(watchHex: 0x8E8E93)
    static let faint = Color(watchHex: 0x3A3A3C)
    static let disc = Color(watchHex: 0x1C1C1E)
    static let second = Color(watchHex: 0xFF3B30)
    static let sun = Color(watchHex: 0xFFD60A)
    static let cloud = Color(watchHex: 0xAEAEB2)
}

private extension Color {
    init(watchHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Point at `dist` from the center along a clock angle (degrees, 0 = 12 o'clock, clockwise).
private func clockPoint(_ c: CGPoint, _ angle: Double, _ dist: Double) -> CGPoint {
    let a = angle * .pi / 180
    return CGPoint(x: c.x + dist * sin(a), y: c.y - dist * cos(a))
}

/// Armstrong Minimal: hour bars, four stat circles, hollow hands and a sweeping red seconds hand.
private struct MinimalFace: View {
    var values: PreviewValues

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2
            let k = size / 454
            let off = r * 0.42
            let disc = r * 0.21
            ZStack {
                Canvas { ctx, _ in
                    let c = CGPoint(x: r, y: r)
                    for i in 0..<12 {
                        var bar = Path()
                        bar.move(to: clockPoint(c, Double(i) * 30, r * 0.81))
                        bar.addLine(to: clockPoint(c, Double(i) * 30, r * 0.96))
                        ctx.stroke(bar, with: .color(.white), lineWidth: 7 * k)
                    }
                }
                stat(icon: skyIcon, tint: skyTint, value: "\(values.temp)°", k: k, disc: disc).position(x: r, y: r - off)
                stat(icon: "heart.fill", tint: WatchInk.red, value: "\(values.heart)", k: k, disc: disc).position(x: r - off, y: r)
                stat(icon: "flame.fill", tint: WatchInk.orange, value: values.calories.formatted(), k: k, disc: disc).position(x: r + off, y: r)
                stat(icon: "battery.75percent", tint: values.battery <= 15 ? WatchInk.red : WatchInk.green,
                     value: "\(values.battery)%", k: k, disc: disc).position(x: r, y: r + off)
                TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                    Canvas { ctx, _ in hands(ctx, at: timeline.date, r: r, k: k) }
                }
            }
            .frame(width: size, height: size)
        }
    }

    private var skyIcon: String {
        switch values.sky {
        case "sun": "sun.max.fill"
        case "rain": "cloud.rain.fill"
        case "snow": "cloud.snow.fill"
        default: "cloud.fill"
        }
    }

    private var skyTint: Color {
        switch values.sky {
        case "sun": WatchInk.sun
        case "rain": WatchInk.teal
        case "snow": .white
        default: WatchInk.cloud
        }
    }

    private func stat(icon: String, tint: Color, value: String, k: CGFloat, disc: CGFloat) -> some View {
        ZStack {
            Circle().fill(WatchInk.disc)
            VStack(spacing: 3 * k) {
                Image(systemName: icon).font(.system(size: 22 * k, weight: .semibold)).foregroundStyle(tint, WatchInk.cloud)
                Text(value).font(.system(size: 24 * k, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 6 * k)
        }
        .frame(width: disc * 2, height: disc * 2)
    }

    private func hands(_ ctx: GraphicsContext, at date: Date, r: CGFloat, k: CGFloat) {
        let c = CGPoint(x: r, y: r)
        let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let sec = Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1e9
        let minute = Double(parts.minute ?? 0) * 6 + sec * 0.1
        let hour = Double((parts.hour ?? 0) % 12) * 30 + Double(parts.minute ?? 0) * 0.5

        func hand(_ angle: Double, _ length: Double) {
            let stem = 26 * k
            var line = Path()
            line.move(to: c)
            line.addLine(to: clockPoint(c, angle, stem))
            ctx.stroke(line, with: .color(.white), lineWidth: 4 * k)
            var capsule = Path()
            capsule.move(to: clockPoint(c, angle, stem))
            capsule.addLine(to: clockPoint(c, angle, length))
            ctx.stroke(capsule, with: .color(.white), style: StrokeStyle(lineWidth: 14 * k, lineCap: .round))
            ctx.stroke(capsule, with: .color(.black), style: StrokeStyle(lineWidth: 8 * k, lineCap: .round))
        }
        hand(hour, r * 0.50)
        hand(minute, r * 0.80)
        ctx.fill(Path(ellipseIn: CGRect(x: r - 8 * k, y: r - 8 * k, width: 16 * k, height: 16 * k)), with: .color(.white))

        var second = Path()
        second.move(to: clockPoint(c, sec * 6, -r * 0.12))
        second.addLine(to: clockPoint(c, sec * 6, r * 0.92))
        ctx.stroke(second, with: .color(WatchInk.second), lineWidth: 3 * k)
        ctx.fill(Path(ellipseIn: CGRect(x: r - 5 * k, y: r - 5 * k, width: 10 * k, height: 10 * k)), with: .color(WatchInk.second))
        ctx.fill(Path(ellipseIn: CGRect(x: r - 2 * k, y: r - 2 * k, width: 4 * k, height: 4 * k)), with: .color(.black))
    }
}

/// Armstrong Data: bezel gauges for steps and body battery, digital time, the workout week and stats.
private struct DataFace: View {
    var values: PreviewValues

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let k = size / 454
            let cx = size / 2
            TimelineView(.everyMinute) { timeline in
                ZStack {
                    Canvas { ctx, _ in
                        let c = CGPoint(x: cx, y: cx)
                        let r = cx - 8 * k
                        // Screen angles, 0 = 3 o'clock, clockwise: left gauge runs bottom-left up to top-left.
                        gauge(ctx, c, r, from: 135, to: 225, fraction: Double(values.steps) / Double(values.stepGoal), WatchInk.green, k)
                        gauge(ctx, c, r, from: 45, to: -45, fraction: Double(values.bodyBattery) / 100, WatchInk.teal, k)
                    }
                    Text(timeline.date.formatted(.dateTime.weekday(.abbreviated).day()).uppercased())
                        .font(.system(size: 22 * k, weight: .medium)).foregroundStyle(WatchInk.gray)
                        .position(x: cx, y: size * 0.12 + 12 * k)
                    Text(timeline.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                        .font(.system(size: 104 * k, weight: .medium)).monospacedDigit().foregroundStyle(.white)
                        .position(x: cx, y: size * 0.17 + 58 * k)
                    Text("PULL  ·  3 DAYS").font(.system(size: 22 * k, weight: .semibold)).foregroundStyle(WatchInk.green)
                        .position(x: cx, y: size * 0.465 + 12 * k)
                    week(k).position(x: cx, y: size * 0.575)
                    HStack(spacing: 0) {
                        stat("\(values.steps)", "STEPS", .white, k)
                        stat("\(values.heart)", "BPM", WatchInk.red, k)
                        stat("\(values.bodyBattery)", "BODY", WatchInk.teal, k)
                    }
                    .frame(width: 300 * k).position(x: cx, y: size * 0.63 + 30 * k)
                    HStack(spacing: 0) {
                        stat("\(values.stress)", "STRESS", WatchInk.orange, k)
                        stat("\(values.intensity)/150", "INT MIN", WatchInk.indigo, k)
                    }
                    .frame(width: 210 * k).position(x: cx, y: size * 0.76 + 30 * k)
                    Text("\(values.battery)%").font(.system(size: 22 * k)).foregroundStyle(WatchInk.gray)
                        .position(x: cx, y: size * 0.89 + 12 * k)
                }
            }
            .frame(width: size, height: size)
        }
    }

    private func gauge(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat, from: Double, to: Double,
                       fraction: Double, _ color: Color, _ k: CGFloat) {
        func arc(_ end: Double) -> Path {
            var path = Path()
            let steps = 40
            for i in 0...steps {
                let a = (from + (end - from) * Double(i) / Double(steps)) * .pi / 180
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }
        ctx.stroke(arc(to), with: .color(WatchInk.faint), lineWidth: 6 * k)
        let f = min(max(fraction, 0), 1)
        if f > 0 { ctx.stroke(arc(from + (to - from) * f), with: .color(color), lineWidth: 6 * k) }
    }

    private func week(_ k: CGFloat) -> some View {
        HStack(spacing: 32 * k - 18 * k) {
            ForEach(0..<7, id: \.self) { i in
                if values.week[i] {
                    Circle().fill(WatchInk.green).frame(width: 18 * k, height: 18 * k)
                        .overlay { Image(systemName: "checkmark").font(.system(size: 9 * k, weight: .black)).foregroundStyle(.black) }
                } else {
                    Circle().stroke(i == 6 ? WatchInk.gray : WatchInk.faint, lineWidth: 2 * k).frame(width: 18 * k, height: 18 * k)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color, _ k: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.system(size: 30 * k, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 18 * k, weight: .medium)).foregroundStyle(WatchInk.gray)
        }
        .lineLimit(1).minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity)
    }
}

/// A glance as it sits in the swipe-up loop: title and value over a small chart, with the
/// neighbouring rows dimmed above and below.
private struct GlancePreview: View {
    var id: String
    var name: String
    var values: PreviewValues

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let k = size / 454
            VStack(spacing: 18 * k) {
                ghost(k)
                VStack(alignment: .leading, spacing: 6 * k) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(size: 24 * k, weight: .semibold)).foregroundStyle(tint)
                        Spacer()
                        Text(value).font(.system(size: 40 * k, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    }
                    Sparkline(seed: id.utf8.reduce(5381) { $0 &* 33 &+ Int($1) }, color: tint).frame(height: 54 * k)
                }
                .padding(.horizontal, 26 * k).padding(.vertical, 20 * k)
                .background(RoundedRectangle(cornerRadius: 26 * k).fill(WatchInk.disc))
                .frame(width: 360 * k)
                ghost(k)
            }
            .frame(width: size, height: size)
        }
    }

    private func ghost(_ k: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 22 * k).fill(WatchInk.disc.opacity(0.6)).frame(width: 260 * k, height: 60 * k)
    }

    private var title: String { name.replacingOccurrences(of: "Glance: ", with: "").uppercased() }

    private var tint: Color {
        switch id {
        case "glance-heart": WatchInk.red
        case "glance-energy": WatchInk.teal
        case "glance-stress": WatchInk.orange
        case "glance-night": WatchInk.indigo
        default: WatchInk.green
        }
    }

    private var value: String {
        switch id {
        case "glance-heart": "\(values.heart)"
        case "glance-energy": "\(values.bodyBattery)"
        case "glance-stress": "\(values.stress)"
        case "glance-night": "+58"
        case "glance-training": "4d"
        default: values.steps.formatted()
        }
    }
}

/// A gentle made-up line, stable for each glance.
private struct Sparkline: View {
    var seed: Int
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            var rng = UInt64(truncatingIfNeeded: seed) | 1
            var path = Path()
            var y = 0.5
            for i in 0..<24 {
                rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                y = min(max(y + (Double(rng % 1000) / 1000 - 0.5) * 0.35, 0.1), 0.9)
                let p = CGPoint(x: size.width * Double(i) / 23, y: size.height * y)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}
