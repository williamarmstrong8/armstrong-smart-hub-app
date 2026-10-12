import SwiftUI

private let swatches: [(name: String, rgb: [Int])] = [
    ("Warm white", [255, 197, 143]),
    ("Daylight", [255, 244, 229]),
    ("Red", [255, 59, 48]),
    ("Orange", [255, 149, 0]),
    ("Yellow", [255, 214, 10]),
    ("Green", [52, 199, 89]),
    ("Cyan", [50, 173, 230]),
    ("Blue", [0, 122, 255]),
    ("Purple", [175, 82, 222]),
    ("Pink", [255, 45, 85]),
]

/// Brightness, white temperature and color for one light.
struct LightSheet: View {
    let entityID: String
    let store: HomeStore
    let toast: Toast

    @Environment(AppSession.self) private var session
    @State private var brightness: Double = 100
    @State private var kelvin: Double = 4000

    var body: some View {
        if let entity = store.entity(entityID) {
            NavigationStack {
                Form {
                    Section {
                        Toggle(isOn: Binding(get: { entity.isOn }, set: { on in send(entity, .init(on: on)) })) {
                            Label(entity.stateLabel, systemImage: entity.symbol)
                        }
                    }
                    if entity.supportsBrightness {
                        Section("Brightness") {
                            HStack {
                                Image(systemName: "sun.min")
                                Slider(value: $brightness, in: 1...100, step: 1) { editing in
                                    if !editing { send(entity, .init(on: true, brightnessPct: Int(brightness))) }
                                }
                                Image(systemName: "sun.max")
                                Text("\(Int(brightness))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    if entity.supportsColorTemp {
                        let minK = Double(entity.minKelvin ?? 2000)
                        let maxK = Double(entity.maxKelvin ?? 6500)
                        Section("White") {
                            HStack {
                                Slider(value: $kelvin, in: minK...max(maxK, minK + 1), step: 50) { editing in
                                    if !editing { send(entity, .init(on: true, kelvin: Int(kelvin))) }
                                }
                                .tint(LinearGradient(colors: [.orange, .white, .cyan], startPoint: .leading, endPoint: .trailing))
                                Text("\(Int(kelvin))K").monospacedDigit().frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                    if entity.supportsColor {
                        Section("Color") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                                ForEach(swatches, id: \.name) { s in
                                    let active = entity.rgbColor == s.rgb
                                    Button {
                                        send(entity, .init(on: true, rgb: s.rgb))
                                    } label: {
                                        Circle()
                                            .fill(Color(rgb: s.rgb))
                                            .frame(width: 40, height: 40)
                                            .overlay(Circle().strokeBorder(.primary.opacity(active ? 0.9 : 0.1), lineWidth: active ? 3 : 1))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(s.name)
                                    .accessibilityAddTraits(active ? .isSelected : [])
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .navigationTitle(entity.name)
                .navigationBarTitleDisplayMode(.inline)
            }
            .onAppear {
                brightness = Double(max(entity.brightnessPct, 1))
                if entity.brightnessPct == 0 { brightness = 100 }
                let minK = entity.minKelvin ?? 2000, maxK = entity.maxKelvin ?? 6500
                kelvin = Double(entity.colorTempKelvin ?? (minK + maxK) / 2)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: entity.state)
        }
    }

    private func send(_ entity: HAEntity, _ change: HomeStore.LightChange) {
        Task { await store.setLight(entity, change, api: session.api, toast: toast) }
    }
}
