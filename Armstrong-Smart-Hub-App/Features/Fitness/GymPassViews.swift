import SwiftUI
import UIKit

// MARK: Barcode

/// A Code 39 barcode, black on white, each bar snapped to whole pixels so the
/// wide-to-narrow ratio survives the screen.
struct BarcodeView: View {
    var code: String
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let runs = Code39.runs(code) ?? []
        let modules = CGFloat(Code39.modules(runs))
        let bars = CGFloat(runs.reduce(0, +))
        let pixel = 1 / displayScale
        Canvas { context, size in
            guard !runs.isEmpty else { return }
            let narrow = max(pixel, (size.width / modules / pixel).rounded(.down) * pixel)
            var x = ((size.width - narrow * bars) / 2 / pixel).rounded() * pixel
            for (i, run) in runs.enumerated() {
                let width = narrow * CGFloat(run)
                if i.isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(.black))
                }
                x += width
            }
        }
        .background(.white)
        .accessibilityElement()
        .accessibilityLabel("Barcode")
        .accessibilityValue(code)
    }
}

/// The white label from the key tag: the bars, and the number under them.
struct PassTag: View {
    var code: String
    var barHeight: CGFloat
    var numberFont: Font = .body

    var body: some View {
        VStack(spacing: 8) {
            BarcodeView(code: code).frame(height: barHeight)
            Text(code)
                .font(numberFont.monospaced().weight(.medium))
                .foregroundStyle(.black)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: HubLayout.controlRadius, style: .continuous))
    }
}

// MARK: Fitness card

/// The gym pass on Fitness. Tapping it puts the pass up full screen, brighter, for the scanner.
struct GymPassCard: View {
    @State private var pass = GymPass.shared
    @State private var places = PlaceMonitor.shared
    @State private var adding = false

    var body: some View {
        if Demo.isOn {
            EmptyView()
        } else if let code = pass.code {
            Button { pass.show() } label: {
                BrickCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "barcode").font(.system(size: 20, weight: .light))
                            Text("Gym pass").font(.headline)
                            Spacer(minLength: 8)
                            Text(places.inside.contains(.gym) ? "At the gym" : "Show")
                                .font(.subheadline)
                                .foregroundStyle(HubDesign.action)
                        }
                        .foregroundStyle(BrickLook.ink)
                        PassTag(code: code, barHeight: 54, numberFont: .subheadline)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Gym pass, \(code)")
            .accessibilityHint("Shows the pass full screen for the scanner")
        } else {
            Button { adding = true } label: {
                BrickCard {
                    HStack(spacing: 12) {
                        Image(systemName: "barcode").font(.system(size: 20, weight: .light))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add your gym pass").font(.headline)
                            Text("It opens by itself when you get to the gym.")
                                .font(.subheadline).foregroundStyle(BrickLook.soft)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).foregroundStyle(BrickLook.soft)
                    }
                    .foregroundStyle(BrickLook.ink)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $adding) { GymPassEditor() }
        }
    }
}

// MARK: Full screen

/// The pass, big, with the screen at full brightness while it's up (put back after).
struct GymPassSheet: View {
    var close: () -> Void
    @State private var pass = GymPass.shared
    @State private var editing = false
    /// The brightness before the pass raised it.
    @State private var brightness: CGFloat?

    var body: some View {
        NavigationStack {
            VStack(spacing: HubLayout.sectionGap) {
                Spacer(minLength: 0)
                if let code = pass.code {
                    PassTag(code: code, barHeight: 150, numberFont: .title3)
                    Text("Hold it under the scanner.")
                        .font(.subheadline)
                        .foregroundStyle(HubDesign.secondary)
                }
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HubLayout.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .hubPageStyle(backdrop: true)
            .navigationTitle("Gym pass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Edit") { editing = true } }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
            }
            .sheet(isPresented: $editing) { GymPassEditor() }
        }
        .onAppear(perform: brighten)
        .onDisappear(perform: restore)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in restore() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in brighten() }
    }

    private var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }

    private func brighten() {
        guard brightness == nil, let screen else { return }
        brightness = screen.brightness
        screen.brightness = 1
    }

    private func restore() {
        guard let previous = brightness else { return }
        screen?.brightness = previous
        brightness = nil
    }
}

// MARK: Editing

/// Type the number from the tag. Kept on this phone; empty goes back to the one the build came with.
struct GymPassEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pass = GymPass.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    private var cleaned: String { text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private var valid: Bool { Code39.canEncode(cleaned) }

    var body: some View {
        NavigationStack {
            GlassForm {
                GlassSection {
                    TextField("Number under the barcode", text: $text)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit(save)
                    if valid {
                        PassTag(code: cleaned, barHeight: 48, numberFont: .footnote)
                    }
                } footer: {
                    Text(cleaned.isEmpty || valid
                         ? "The number printed on your gym's key tag. It stays on this phone."
                         : "Code 39 takes letters, numbers, spaces and - . $ / + % only.")
                }
                if pass.isTyped, let bundled = GymPass.bundled {
                    GlassSection {
                        Button("Use \(bundled) again") {
                            pass.set("")
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Gym pass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!valid) }
            }
            .onAppear { text = pass.code ?? "" }
            .focusAfterPresenting($focused)
        }
    }

    private func save() {
        guard valid else { return }
        pass.set(cleaned)
        dismiss()
    }
}
