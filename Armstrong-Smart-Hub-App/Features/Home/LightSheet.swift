import SwiftUI
import UIKit

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
    @State private var hue: Double = 0.08
    @State private var saturation: Double = 0.8
    /// A drag in progress owns the sliders; polls must not yank them back.
    @State private var dragging = false

    var body: some View {
        if let entity = store.entity(entityID) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 22) {
                        LightOrb(color: currentColor(entity), on: entity.isOn)

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
                            ColorPad(hue: $hue, saturation: $saturation, dragging: $dragging) {
                                let c = UIColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1)
                                var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
                                c.getRed(&r, green: &g, blue: &bl, alpha: nil)
                                send(entity, .init(on: true, rgb: [Int(r * 255), Int(g * 255), Int(bl * 255)]))
                            }

                            GlassEffectContainer(spacing: 10) {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                                    ForEach(swatches) { swatch in
                                        let active = entity.rgbColor == swatch.rgb
                                        Button {
                                            send(entity, .init(on: true, rgb: swatch.rgb))
                                        } label: {
                                            Circle()
                                                .fill(.clear)
                                                .aspectRatio(1, contentMode: .fit)
                                                .glassEffect(.regular.tint(Color(rgb: swatch.rgb).opacity(0.9)).interactive(), in: .circle)
                                                .overlay {
                                                    if active {
                                                        Image(systemName: "checkmark")
                                                            .font(.system(size: 15, weight: .bold))
                                                            .foregroundStyle(.white)
                                                            .shadow(color: .black.opacity(0.4), radius: 2)
                                                    }
                                                }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(swatch.name)
                                        .accessibilityAddTraits(active ? .isSelected : [])
                                    }
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
        if let rgb = entity.rgbColor {
            var h: CGFloat = 0, sat: CGFloat = 0
            UIColor(Color(rgb: rgb)).getHue(&h, saturation: &sat, brightness: nil, alpha: nil)
            hue = h; saturation = max(sat, 0.05)
        }
    }

    private func currentColor(_ entity: HAEntity) -> Color {
        if let rgb = entity.rgbColor { return Color(rgb: rgb) }
        if entity.colorTempKelvin != nil { return temperatureColor(Int(kelvin)) }
        return .orange
    }

    private func send(_ entity: HAEntity, _ change: HomeStore.LightChange) {
        Task { await store.setLight(entity, change, api: session.api, toast: toast) }
    }
}

/// A glass track with a glass knob. Dragging previews continuously and sends once released.
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
                .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing).opacity(0.9))
                .glassEffect(.regular, in: .capsule)
                .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1) }
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.clear)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(thumb.opacity(0.7)).interactive(), in: .circle)
                        .padding(5)
                        .offset(x: max(0, min(width - 54, progress * (width - 54))))
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
        .frame(height: 56)
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

/// A glowing glass orb that shows the lamp's color right now.
private struct LightOrb: View {
    let color: Color
    let on: Bool

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(on ? 0.85 : 0.1)).blur(radius: 34).frame(width: 150, height: 150)
            Circle()
                .fill(.clear)
                .frame(width: 96, height: 96)
                .glassEffect(.regular.tint(on ? color.opacity(0.8) : .clear), in: .circle)
                .overlay {
                    Image(systemName: on ? "lightbulb.max.fill" : "lightbulb")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(on ? .white : .secondary)
                }
        }
        .frame(height: 140)
        .animation(.easeOut(duration: 0.3), value: color)
    }
}

/// Hue across, saturation down: drag the glass bead anywhere on the pane to pick a color.
private struct ColorPad: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var dragging: Bool
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let color = Color(hue: hue, saturation: saturation, brightness: 1)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
                .opacity(0.9)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1) }
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(.clear)
                        .frame(width: 46, height: 46)
                        .glassEffect(.regular.tint(color).interactive(), in: .circle)
                        .offset(x: hue * size.width - 23, y: (1 - saturation) * size.height - 23)
                        .allowsHitTesting(false)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            hue = max(0, min(0.999, g.location.x / max(size.width, 1)))
                            saturation = max(0.05, min(1, 1 - g.location.y / max(size.height, 1)))
                        }
                        .onEnded { _ in dragging = false; onCommit() }
                )
        }
        .frame(height: 190)
        .accessibilityLabel("Color")
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
