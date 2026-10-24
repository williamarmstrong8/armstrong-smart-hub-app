import AppIntents

#if os(iOS)
// Lets a Shortcuts automation stand in for the in-app scan: "When NFC tag is scanned" → "Tap Brick tag",
// set to Run Immediately, bricks or unbricks without opening the app.

/// A registered tag, as Shortcuts sees it.
struct BrickTagEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Brick tag"
    static let defaultQuery = BrickTagQuery()

    var id: String
    var name: String
    var mode: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(mode)")
    }

    @MainActor init(_ tag: BrickTag, store: BrickStore) {
        id = tag.id
        name = tag.name
        mode = tag.profileID == nil ? "Any mode" : store.profile(for: tag)?.name ?? "Any mode"
    }
}

struct BrickTagQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [BrickTagEntity] {
        let store = BrickStore.shared
        return store.tags.filter { identifiers.contains($0.id) }.map { BrickTagEntity($0, store: store) }
    }

    @MainActor func suggestedEntities() async throws -> [BrickTagEntity] {
        let store = BrickStore.shared
        return store.tags.map { BrickTagEntity($0, store: store) }
    }
}

/// Does what tapping the tag in the app does: starts its mode, or ends the Brick if it's allowed to.
struct TapBrickTagIntent: AppIntent {
    static let title: LocalizedStringResource = "Tap Brick tag"
    static let description = IntentDescription("Starts the tag's mode, or unbricks if that tag can end the running Brick.")

    @Parameter(title: "Tag") var tag: BrickTagEntity

    static var parameterSummary: some ParameterSummary { Summary("Tap \(\.$tag)") }

    init() {}

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let (_, text) = BrickStore.shared.handleTag(tag.id)
        return .result(dialog: "\(text)")
    }
}

struct BrickShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TapBrickTagIntent(),
                    phrases: ["Tap \(\.$tag) in \(.applicationName)", "Brick with \(\.$tag) in \(.applicationName)"],
                    shortTitle: "Tap Brick tag",
                    systemImageName: "wave.3.right")
    }
}
#endif
