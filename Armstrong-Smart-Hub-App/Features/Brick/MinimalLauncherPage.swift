import SwiftUI
import UIKit
import WidgetKit

#if os(iOS)
@MainActor @Observable
final class MinimalLauncherStore {
    var settings = MinimalLauncherSettings.read() {
        didSet {
            settings.save()
            WidgetCenter.shared.reloadTimelines(ofKind: MinimalLauncherSettings.widgetKind)
        }
    }
}

@MainActor @Observable
final class MinimalLauncherNavigation {
    static let shared = MinimalLauncherNavigation()
    var requested = false
}

/// Configure the Home Screen launcher without changing Brick's blocking rules.
struct MinimalLauncherPage: View {
    @State private var store = MinimalLauncherStore()
    @State private var editor: LauncherItem?
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        BrickPage(title: "Minimal Launcher") {
            VStack(alignment: .leading, spacing: 12) {
                BrickCaps(text: "YOUR HOME SCREEN")
                    .foregroundStyle(BrickLook.soft)
                preview
                Text("A quieter way to open your essentials. This changes the launcher, not which apps Brick blocks.")
                    .font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            .padding(.bottom, 8)

            BrickCard {
                VStack(spacing: 16) {
                    Toggle("Dark background", isOn: $store.settings.dark)
                    BrickDivider()
                    Toggle("Larger text", isOn: $store.settings.largeText)
                }
                .font(.system(size: 17))
            }

            HStack {
                BrickCaps(text: "ESSENTIAL APPS")
                Spacer()
                Text("\(store.settings.items.count) / 6").monospacedDigit()
            }
            .font(.caption).foregroundStyle(BrickLook.soft).padding(.top, 16)

            if store.settings.items.isEmpty {
                BrickCard {
                    Text("Start with the apps you actually need.").font(.headline)
                    Text("Add up to six. Tap a name in the preview to test it.")
                        .font(.subheadline).foregroundStyle(BrickLook.soft).padding(.top, 6)
                }
            } else {
                BrickCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.settings.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { BrickDivider() }
                            itemRow(item, index: index)
                        }
                    }.padding(.horizontal, 20)
                }
            }
            if store.settings.items.count < MinimalLauncherSettings.maximumItems {
                Button { adding = true } label: {
                    Label("Add app", systemImage: "plus")
                        .font(.system(size: 18)).frame(maxWidth: .infinity).padding(.vertical, 18)
                }
                .buttonStyle(.plain)
                .background(BrickLook.pill, in: RoundedRectangle(cornerRadius: 22))
            }

            setup.padding(.top, 16)
        }
        .sheet(isPresented: $adding) {
            LauncherItemEditor(item: nil) { store.settings.items.append($0) }
        }
        .sheet(item: $editor) { item in
            LauncherItemEditor(item: item) { updated in
                if let i = store.settings.items.firstIndex(where: { $0.id == updated.id }) {
                    store.settings.items[i] = updated
                }
            }
        }
        .alert("Couldn't open app", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.settings.items.isEmpty {
                Text("Your essentials").foregroundStyle(.gray).padding(.vertical, 20)
            }
            ForEach(store.settings.items) { item in
                Button { open(item) } label: {
                    Text(item.name)
                        .font(.system(size: store.settings.largeText ? 30 : 25, weight: .regular))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Test opening \(item.name)")
            }
        }
        .padding(24).frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .foregroundStyle(store.settings.dark ? Color.white : Color.black)
        .background(store.settings.dark ? Color.black : Color.white,
                    in: RoundedRectangle(cornerRadius: BrickLook.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Launcher preview")
    }

    private func itemRow(_ item: LauncherItem, index: Int) -> some View {
        HStack(spacing: 10) {
            Button { editor = item } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 18))
                    Text(item.usesShortcut ? "Shortcut · \(item.destination)" : "App link")
                        .font(.caption).foregroundStyle(BrickLook.soft).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            }.buttonStyle(.plain).accessibilityLabel("Edit \(item.name)")
            Menu {
                Button("Move up", systemImage: "arrow.up") { store.settings.items.swapAt(index, index - 1) }
                    .disabled(index == 0)
                Button("Move down", systemImage: "arrow.down") { store.settings.items.swapAt(index, index + 1) }
                    .disabled(index == store.settings.items.count - 1)
                Button("Remove", systemImage: "trash", role: .destructive) {
                    store.settings.items.removeAll { $0.id == item.id }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Options for \(item.name)")
        }
    }

    private var setup: some View {
        BrickCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Set up your Home Screen").font(.system(size: 21))
                instruction("1", "Test each app above", "For a shortcut, create one in Apple Shortcuts with an Open App action. Its name must match exactly.")
                instruction("2", "Add the widget", "Hold your Home Screen, choose Edit → Add Widget, find Armstrong Hub, then add the large Minimal Launcher widget.")
                instruction("3", "Make room", "Move app icons off this page with Remove from Home Screen, not Delete App. The apps stay in App Library. Clear the Dock manually if you want.")
                instruction("4", "Match the background", "Set a plain black or white Home Screen wallpaper to match. iOS may still add margins, tinting or glass; this is not a replacement for the system Home Screen.")
                Text("Some launches briefly open Armstrong Hub or Shortcuts. The launcher doesn't bypass Brick or Screen Time restrictions. Your list stays on this device and its widget.")
                    .font(.footnote).foregroundStyle(BrickLook.soft)
            }
        }
    }

    private func instruction(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.subheadline.monospacedDigit()).foregroundStyle(BrickLook.soft).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(BrickLook.soft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func open(_ item: LauncherItem) {
        guard let url = item.url else { error = "Edit this app's link and try again."; return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success { Task { @MainActor in error = "Check that the app is installed and its link is correct. For a shortcut, check its exact name in Shortcuts." } }
        }
    }
}

private struct LauncherItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let original: LauncherItem?
    private let onSave: (LauncherItem) -> Void
    @State private var name: String
    @State private var destination: String
    @State private var usesShortcut: Bool

    init(item: LauncherItem?, onSave: @escaping (LauncherItem) -> Void) {
        original = item
        self.onSave = onSave
        _name = State(initialValue: item?.name ?? "")
        _destination = State(initialValue: item?.destination ?? "")
        _usesShortcut = State(initialValue: item?.usesShortcut ?? true)
    }

    private var candidate: LauncherItem {
        LauncherItem(id: original?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                     destination: destination.trimmingCharacters(in: .whitespacesAndNewlines), usesShortcut: usesShortcut)
    }
    private var valid: Bool { !candidate.name.isEmpty && !candidate.destination.isEmpty && candidate.url != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Home Screen label") {
                    TextField("e.g. Messages", text: $name).onChange(of: name) { _, value in
                        if value.count > 30 { name = String(value.prefix(30)) }
                    }
                }
                Section {
                    Picker("Open using", selection: $usesShortcut) {
                        Text("Shortcut").tag(true)
                        Text("App link").tag(false)
                    }.pickerStyle(.segmented)
                    TextField(usesShortcut ? "Exact shortcut name" : "e.g. maps://", text: $destination)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(usesShortcut ? .default : .URL)
                } footer: {
                    Text(usesShortcut
                         ? "In Apple Shortcuts, create a shortcut with the Open App action and choose your app. Enter that shortcut's exact name here. Saving here does not create the shortcut."
                         : "Use a URL scheme supported by the app, or an https link. A website link may open Safari instead. File links and links back into Armstrong Hub are not supported.")
                }
                if original == nil {
                    Section("Quick app links") {
                        Button("Messages") { name = "Messages"; destination = "sms:"; usesShortcut = false }
                        Button("Maps shortcut") { name = "Maps"; destination = "Open Maps"; usesShortcut = true }
                    }
                }
            }
            .brickList()
            .navigationTitle(original == nil ? "Add app" : "Edit app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(candidate); dismiss() }.disabled(!valid)
                }
            }
        }
    }
}
#endif
