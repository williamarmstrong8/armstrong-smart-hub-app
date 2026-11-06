import SwiftUI

private struct LightSwatch: Identifiable {
    let name: String
    let rgb: [Int]
    var id: String { name }
}

private let swatches: [LightSwatch] = [
    .init(name: "Red", rgb: [255, 45, 45]),
    .init(name: "Coral", rgb: [255, 92, 72]),
    .init(name: "Orange", rgb: [255, 145, 35]),
    .init(name: "Amber", rgb: [255, 190, 35]),
    .init(name: "Yellow", rgb: [255, 230, 50]),
    .init(name: "Lime", rgb: [185, 235, 45]),
    .init(name: "Green", rgb: [45, 205, 85]),
    .init(name: "Mint", rgb: [45, 215, 145]),
    .init(name: "Teal", rgb: [35, 195, 180]),
    .init(name: "Cyan", rgb: [35, 195, 235]),
    .init(name: "Sky blue", rgb: [45, 145, 255]),
    .init(name: "Blue", rgb: [45, 85, 255]),
    .init(name: "Indigo", rgb: [85, 65, 235]),
    .init(name: "Violet", rgb: [125, 65, 240]),
    .init(name: "Purple", rgb: [170, 65, 235]),
    .init(name: "Magenta", rgb: [220, 55, 215]),
    .init(name: "Pink", rgb: [255, 65, 165]),
    .init(name: "Rose", rgb: [255, 65, 110]),
    .init(name: "Soft red", rgb: [255, 125, 115]),
    .init(name: "Peach", rgb: [255, 175, 120]),
    .init(name: "Soft yellow", rgb: [255, 225, 135]),
    .init(name: "Soft green", rgb: [145, 225, 155]),
    .init(name: "Soft blue", rgb: [135, 195, 255]),
    .init(name: "Lavender", rgb: [195, 155, 255]),
]

/// Brightness, white temperature and color for one light.
struct LightSheet: View {
    let entityID: String
    let store: HomeStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @State private var brightness: Double = 100
    @State private var kelvin: Double = 4000
    /// A drag in progress owns the sliders; polls must not yank them back.
    @State private var dragging = false

    var body: some View {
        if let entity = store.entity(entityID) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 22) {
                        if entity.supportsBrightness {
                            LightControlBar(
                                value: $brightness,
                                dragging: $dragging,
                                range: 1...100,
                                colors: [Color.black.opacity(0.72), .white],
                                thumb: .white,
                                accessibilityName: "Brightness",
                                accessibilityValue: "\(Int(brightness)) percent"
                            ) {
                                send(entity, .init(on: true, brightnessPct: Int(brightness.rounded())))
                            }
                        }

                        if entity.supportsColorTemp {
                            let minK = Double(entity.minKelvin ?? 2000)
                            let maxK = Double(max(entity.maxKelvin ?? 6500, Int(minK) + 1))
                            LightControlBar(
                                value: $kelvin,
                                dragging: $dragging,
                                range: minK...maxK,
                                colors: temperatureGradient(from: Int(minK), through: Int(maxK)),
                                thumb: temperatureColor(Int(kelvin)),
                                accessibilityName: "White temperature",
                                accessibilityValue: "\(Int(kelvin)) kelvin"
                            ) {
                                send(entity, .init(on: true, kelvin: Int(kelvin.rounded())))
                            }
                        }

                        if entity.supportsColor {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                                ForEach(swatches) { swatch in
                                    let active = entity.rgbColor == swatch.rgb
                                    Button {
                                        send(entity, .init(on: true, rgb: swatch.rgb))
                                    } label: {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color(rgb: swatch.rgb))
                                            .aspectRatio(1, contentMode: .fit)
                                            .overlay {
                                                if active {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 16, weight: .bold))
                                                        .foregroundStyle(.white)
                                                        .shadow(color: .black.opacity(0.45), radius: 2)
                                                }
                                            }
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .strokeBorder(.white.opacity(active ? 0.95 : 0.15), lineWidth: active ? 3 : 1)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(swatch.name)
                                    .accessibilityAddTraits(active ? .isSelected : [])
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
                .hubPageStyle()
                .navigationTitle(entity.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(HubDesign.page, for: .navigationBar)
            }
            .presentationBackground(HubDesign.page)
            #if DEBUG
            // Film cue: glide the brightness up like a slow drag, then send it once, as a release would.
            .onAppear {
                DemoCue.on("light.bright") {
                    Task { @MainActor in
                        let from = brightness, to = 85.0, steps = 36
                        for i in 1...steps {
                            let p = Double(i) / Double(steps)
                            brightness = from + (to - from) * (1 - pow(1 - p, 3))
                            try? await Task.sleep(for: .milliseconds(28))
                        }
                        send(entity, .init(on: true, brightnessPct: Int(to)))
                    }
                }
            }
            #endif
            // Show the lamp as it is right now: sync on open, fetch fresh, and follow every poll.
            .onAppear {
                sync(entity)
                Task { await store.refresh(api: session.api) }
            }
            .onChange(of: entity) { _, latest in sync(latest) }
            .sensoryFeedback(.impact(weight: .light), trigger: entity.state)
        }
    }

    private func sync(_ entity: HAEntity) {
        guard !dragging else { return }
        brightness = entity.brightnessPct == 0 ? 100 : Double(entity.brightnessPct)
        let minK = entity.minKelvin ?? 2000, maxK = entity.maxKelvin ?? 6500
        kelvin = Double(entity.colorTempKelvin ?? (minK + maxK) / 2)
    }

    private func send(_ entity: HAEntity, _ change: HomeStore.LightChange) {
        Task { await store.setLight(entity, change, api: session.api, toast: toast) }
    }
}

/// A large custom gradient track. Dragging previews continuously and sends once released.
private struct LightControlBar: View {
    @Binding var value: Double
    @Binding var dragging: Bool
    let range: ClosedRange<Double>
    let colors: [Color]
    let thumb: Color
    let accessibilityName: String
    let accessibilityValue: String
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let progress = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)

            Capsule()
                .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(thumb)
                        .frame(width: 38, height: 38)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                        .offset(x: max(0, min(width - 38, progress * (width - 38))))
                        .allowsHitTesting(false)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            dragging = true
                            let progress = max(0, min(1, gesture.location.x / width))
                            value = range.lowerBound + progress * (range.upperBound - range.lowerBound)
                        }
                        .onEnded { _ in dragging = false; onCommit() }
                )
        }
        .frame(height: 54)
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: return
            }
            onCommit()
        }
    }
}

/// Approximate black-body color, so each point looks like the white temperature it sends.
private func temperatureColor(_ kelvin: Int) -> Color {
    let temperature = Double(max(1000, min(kelvin, 40_000))) / 100
    let red: Double
    let green: Double
    let blue: Double

    if temperature <= 66 {
        red = 255
        green = 99.4708025861 * log(temperature) - 161.1195681661
        blue = temperature <= 19 ? 0 : 138.5177312231 * log(temperature - 10) - 305.0447927307
    } else {
        red = 329.698727446 * pow(temperature - 60, -0.1332047592)
        green = 288.1221695283 * pow(temperature - 60, -0.0755148492)
        blue = 255
    }

    return Color(
        red: max(0, min(red, 255)) / 255,
        green: max(0, min(green, 255)) / 255,
        blue: max(0, min(blue, 255)) / 255
    )
}

private func temperatureGradient(from minimum: Int, through maximum: Int) -> [Color] {
    (0...8).map { step in
        temperatureColor(minimum + (maximum - minimum) * step / 8)
    }
}
