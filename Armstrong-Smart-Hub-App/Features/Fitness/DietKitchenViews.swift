import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

// MARK: Receipt import

/// Importing a grocery receipt: scan a paper one, pick photos or screenshots, open a
/// PDF, or paste an emailed receipt. It's read on the phone, then every line is shown
/// with the food it matched, to tick, untick or correct before it goes in the kitchen.
struct ReceiptImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DietStore.shared
    @State private var stage: Stage = .choose
    @State private var read: ReceiptRead?
    @State private var scanning = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingFile = false
    @State private var pasting = false
    @State private var pasted = ""
    @State private var changing: ReceiptItem?
    @State private var showSkipped = false

    private enum Stage: Equatable { case choose, reading, review, failed(String) }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .choose: choose
                case .reading: reading
                case .review: review
                case let .failed(message): failed(message)
                }
            }
            .hubPageStyle(backdrop: true)
            .navigationTitle("Import a receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner { images in
                    scanning = false
                    if !images.isEmpty { readImages(images.map { ($0, .up) }) }
                }
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pdf, .image, .plainText]) { result in
                if case let .success(url) = result { readFile(url) }
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                readPhotos(items)
                photos = []
            }
            .sheet(item: $changing) { item in
                FoodPickerSheet(title: "What is “\(item.line)”?", custom: item.name) { food in
                    guard var read, let i = read.items.firstIndex(where: { $0.id == item.id }) else { return }
                    read.items[i].foodID = food.id
                    read.items[i].name = food.name
                    read.items[i].isFood = true
                    read.items[i].include = true
                    self.read = read
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground { AmbientBackdrop() }
    }

    // MARK: Choosing

    private var choose: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Whole Foods paper receipts, and the order details or emailed receipt from the Amazon or Whole Foods app, as a screenshot, PDF or pasted text. It's read on this phone; nothing is uploaded.")
                    .font(.subheadline).foregroundStyle(BrickLook.soft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                if VNDocumentCameraViewController.isSupported {
                    option("Scan a paper receipt", "doc.viewfinder", "Long receipts can take a few pages.") { scanning = true }
                }
                PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .images) {
                    optionLabel("Photos or screenshots", "photo.on.rectangle", "Pick several for a long order.")
                }
                .buttonStyle(.plain)
                option("PDF or file", "doc", "An emailed or downloaded receipt.") { choosingFile = true }
                option("Paste text", "doc.on.clipboard", "Copy the items from the receipt email.") { pasting.toggle() }
                if pasting {
                    TextEditor(text: $pasted)
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .glassGlare(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                    DietCardButton(title: "Read it", symbol: "text.viewfinder", primary: true) {
                        readRows(pasted.components(separatedBy: .newlines))
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, HubLayout.gutter)
            .padding(.top, 8).padding(.bottom, HubLayout.bottomInset)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func option(_ title: String, _ symbol: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { optionLabel(title, symbol, detail) }.buttonStyle(.plain)
    }

    private func optionLabel(_ title: String, _ symbol: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Fit.action).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink)
                Text(detail).font(.caption).foregroundStyle(BrickLook.soft)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(BrickLook.soft)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassGlare(.regular.interactive(), in: .rect(cornerRadius: 20, style: .continuous))
        .contentShape(.rect)
    }

    private var reading: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Reading your receipt…").font(.headline).foregroundStyle(BrickLook.ink)
            Text("Matching each item to the low-FODMAP guide.").font(.subheadline).foregroundStyle(BrickLook.soft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark").font(.system(size: 44)).foregroundStyle(BrickLook.soft)
            Text(message).font(.body).foregroundStyle(BrickLook.ink).multilineTextAlignment(.center)
            DietCardButton(title: "Try another way", symbol: "arrow.uturn.backward", primary: true) { stage = .choose }
                .frame(maxWidth: 280)
        }
        .padding(HubLayout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Reviewing

    @ViewBuilder private var review: some View {
        if let read {
            let foods = read.items.filter { $0.isFood || $0.foodID != nil }
            let skipped = read.items.filter { !($0.isFood || $0.foodID != nil) }
            let count = read.items.filter(\.include).count
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(read.store ?? "Receipt").font(.title2.weight(.regular)).foregroundStyle(BrickLook.ink)
                        Text([read.purchasedAt.map { $0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) },
                              "\(foods.count) foods found"].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(BrickLook.soft)
                    }
                    DietSheetSection(title: "Foods", trailing: "Tap a name to correct it") {
                        VStack(spacing: 0) {
                            ForEach(foods) { item in
                                ReceiptItemRow(item: item, onToggle: { toggle(item) }, onChange: { changing = item })
                                if item.id != foods.last?.id { BrickDivider() }
                            }
                        }
                    }
                    if !skipped.isEmpty {
                        DietSheetSection(title: "Not food, or not recognized", trailing: "\(skipped.count)") {
                            Button(showSkipped ? "Hide" : "Show the \(skipped.count) skipped lines") {
                                withAnimation(HubMotion.standard) { showSkipped.toggle() }
                            }
                            .font(.subheadline.weight(.medium)).foregroundStyle(Fit.action)
                            if showSkipped {
                                VStack(spacing: 0) {
                                    ForEach(skipped) { item in
                                        ReceiptItemRow(item: item, onToggle: { toggle(item) }, onChange: { changing = item })
                                        if item.id != skipped.last?.id { BrickDivider() }
                                    }
                                }
                            }
                        }
                    }
                    Text("High-FODMAP foods go in the kitchen too, so it's complete, but meal ideas never use them.")
                        .font(.caption).foregroundStyle(BrickLook.soft)
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.top, 8).padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                DietSaveButton(title: count == 0 ? "Nothing ticked" : "Add \(count) \(count == 1 ? "food" : "foods") to your kitchen",
                               enabled: count > 0) { save(read) }
            }
        }
    }

    private func toggle(_ item: ReceiptItem) {
        guard var read, let i = read.items.firstIndex(where: { $0.id == item.id }) else { return }
        read.items[i].include.toggle()
        self.read = read
    }

    private func save(_ read: ReceiptRead) {
        let additions = read.items.filter(\.include).map { PantryAddition(name: $0.name, line: $0.line, foodID: $0.foodID) }
        store.addToPantry(additions, store: read.store, purchasedAt: read.purchasedAt, source: .receipt)
        dismiss()
    }

    // MARK: Reading

    private func readImages(_ images: [(CGImage, CGImagePropertyOrientation)]) {
        stage = .reading
        let pages = images.map { ImagePage(image: $0.0, orientation: $0.1) }
        Task {
            let rows = await Task.detached(priority: .userInitiated) {
                pages.flatMap { ReceiptReader.rows(in: $0.image, orientation: $0.orientation) }
            }.value
            await finish(rows)
        }
    }

    private func readPhotos(_ items: [PhotosPickerItem]) {
        stage = .reading
        Task {
            var images: [(CGImage, CGImagePropertyOrientation)] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let cg = image.cgImage {
                    images.append((cg, CGImagePropertyOrientation(image.imageOrientation)))
                }
            }
            if images.isEmpty { stage = .failed("Couldn't open those photos.") } else { readImages(images) }
        }
    }

    private func readFile(_ url: URL) {
        stage = .reading
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .pdf) == true {
                let rows = await Task.detached(priority: .userInitiated) { ReceiptReader.rows(inPDF: url) }.value
                await finish(rows)
            } else if type?.conforms(to: .image) == true, let data = try? Data(contentsOf: url), let image = UIImage(data: data), let cg = image.cgImage {
                readImages([(cg, CGImagePropertyOrientation(image.imageOrientation))])
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                await finish(text.components(separatedBy: .newlines))
            } else {
                stage = .failed("Couldn't open that file.")
            }
        }
    }

    private func readRows(_ rows: [String]) {
        stage = .reading
        Task { await finish(rows) }
    }

    private func finish(_ rows: [String]) async {
        let result = await ReceiptReader.read(rows, foods: store.allFoods)
        if result.items.isEmpty {
            stage = .failed("Couldn't find any items. Try a sharper photo, or paste the text from the receipt email.")
        } else {
            read = result
            stage = .review
        }
    }
}

/// A page to read, passed off the main thread.
private nonisolated struct ImagePage: @unchecked Sendable {
    var image: CGImage
    var orientation: CGImagePropertyOrientation
}

/// A receipt line: ticked or not, what it matched, and its rating.
private struct ReceiptItemRow: View {
    var item: ReceiptItem
    var onToggle: () -> Void
    var onChange: () -> Void

    var body: some View {
        let food = item.foodID.flatMap { LowFodmap.byID[$0] }
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.include ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(item.include ? Fit.action : BrickLook.soft)
                    .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.include ? "Included" : "Left out")
            Button(action: onChange) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            if let food { FodmapDot(level: food.level) }
                            Text(item.name.isEmpty ? item.line : item.name).font(.body.weight(.medium)).foregroundStyle(BrickLook.ink).lineLimit(1)
                        }
                        Text(item.line).font(.caption.monospaced()).foregroundStyle(BrickLook.soft).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(food?.level.short ?? "Not rated").font(.caption.weight(.semibold)).foregroundStyle(food?.level.color ?? Fit.muted)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Changes which food this is")
        }
        .padding(.vertical, 6)
        .opacity(item.include ? 1 : 0.6)
    }
}

/// VisionKit's document camera, for paper receipts. Hands back every page it scanned.
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([CGImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([CGImage]) -> Void
        init(onFinish: @escaping ([CGImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onFinish([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onFinish([]) }
    }
}

extension CGImagePropertyOrientation {
    /// The EXIF orientation for a UIImage's, so text in a sideways photo still reads.
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: Food picker

/// Picks a food from the guide or his own; or keeps a name as a food of his own.
struct FoodPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DietStore.shared
    var title: String
    /// A name to offer as his own food.
    var custom: String?
    var onPick: (DietFood) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(BrickLook.soft)
                        TextField("Search foods", text: $query).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 16).frame(minHeight: 50)
                    .glassGlare(.regular, in: .capsule)
                    .padding(.bottom, 12)
                    if let name = ownName {
                        Button { pick(store.addCustomFood(name)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle").font(.title3).foregroundStyle(Fit.action)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("“\(name)”").font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                                    Text("Keep as its own food, not rated").font(.caption).foregroundStyle(BrickLook.soft)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        BrickDivider()
                    }
                    ForEach(results) { food in
                        Button { pick(food) } label: { FoodRow(food: food) }.buttonStyle(.plain)
                        BrickDivider()
                    }
                }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.top, 8).padding(.bottom, HubLayout.bottomInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .hubPageStyle(backdrop: true)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground { AmbientBackdrop() }
    }

    private var results: [DietFood] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.allFoods.sorted { $0.name < $1.name } : store.search(q)
    }

    /// What to offer as his own food: what he typed, else the name it came with.
    private var ownName: String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        let name = q.isEmpty ? custom : q
        guard let name, !name.isEmpty, !store.allFoods.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return name
    }

    private func pick(_ food: DietFood) {
        onPick(food)
        dismiss()
    }
}

// MARK: Kitchen page

/// What's in his kitchen: by rating, with what's probably used up set apart.
struct PantryPage: View {
    @State private var store = DietStore.shared
    @State private var importing = false
    @State private var adding = false
    @State private var changing: PantryItem?

    var body: some View {
        FitPage(title: "Kitchen") {
            HStack(spacing: 10) {
                DietCardButton(title: "Import receipt", symbol: "doc.text.viewfinder", primary: true) { importing = true }
                DietCardButton(title: "Add a food", symbol: "plus", primary: false) { adding = true }
            }
            .padding(.top, 12).padding(.bottom, 24)
            if store.pantry.isEmpty {
                Takeaway(text: "Import a grocery receipt, or add foods by hand. Meal ideas then lean on what you have.")
                    .padding(.bottom, 24)
            }
            ForEach([FodmapLevel.low, .moderate, .high, .unknown]) { level in
                let items = store.freshPantry.filter { level == self.level($0) }
                if !items.isEmpty {
                    FitSection(title: level.title, trailing: "\(items.count)") {
                        if level == .high {
                            Takeaway(text: "Leave these out while you're in elimination.").font(.caption)
                        }
                        rows(items, stale: false)
                    }
                }
            }
            let stale = store.stalePantry
            if !stale.isEmpty {
                FitSection(title: "Might be used up", trailing: "\(stale.count)") {
                    Takeaway(text: "Bought a while ago for how long they keep. Say if you still have them; the rest stay out of meal ideas.").font(.caption)
                    rows(stale, stale: true)
                    Button("Clear all of these", role: .destructive) { withAnimation(HubMotion.standard) { store.clearStale() } }
                        .font(.subheadline.weight(.medium))
                }
            }
            if !store.receipts.isEmpty {
                FitSection(title: "Receipts") {
                    VStack(spacing: 0) {
                        ForEach(store.receipts.prefix(6)) { r in
                            DetailRow(label: r.title, value: "\(r.items) foods", last: r.id == store.receipts.prefix(6).last?.id)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $importing) { ReceiptImportSheet() }
        .sheet(isPresented: $adding) {
            FoodPickerSheet(title: "Add to your kitchen") { store.addToPantry($0) }
        }
        .sheet(item: $changing) { item in
            FoodPickerSheet(title: "What is “\(item.name)”?") { food in store.setFood(item, food) }
        }
    }

    private func level(_ item: PantryItem) -> FodmapLevel { item.foodID.flatMap(store.food)?.level ?? .unknown }

    private func rows(_ items: [PantryItem], stale: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    FodmapDot(level: level(item))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.body.weight(.medium)).foregroundStyle(BrickLook.ink)
                        Text(detail(item)).font(.caption).foregroundStyle(BrickLook.soft).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if stale {
                        Button("Have it") { withAnimation(HubMotion.standard) { store.keep(item) } }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Fit.action)
                    }
                    Menu {
                        Button("Used up", systemImage: "checkmark.circle") { withAnimation(HubMotion.standard) { store.markGone(item) } }
                        if !stale { Button("Still have it", systemImage: "arrow.clockwise") { store.keep(item) } }
                        Button("Change food…", systemImage: "pencil") { changing = item }
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(BrickLook.soft)
                            .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget).contentShape(.rect)
                    }
                    .accessibilityLabel("Options for \(item.name)")
                }
                .padding(.vertical, 4)
                if item.id != items.last?.id { BrickDivider() }
            }
        }
    }

    private func detail(_ item: PantryItem) -> String {
        let when = item.since.formatted(.relative(presentation: .named))
        let verb = item.checkedAt != nil ? "Checked" : item.source == .receipt ? "Bought" : "Added"
        return [item.line, "\(verb) \(when)"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: Meal ideas

/// Ideas for a meal, from what he has: on the Diet page, with a slot picker.
struct IdeasSection: View {
    var store: DietStore
    @Binding var sheet: DietSheet?
    @State private var slot: MealSlot?
    @State private var importing = false

    var body: some View {
        let now = Date.now
        let upcoming = DietIdeas.upcoming(store, now: now)
        let chosen = slot ?? upcoming
        let picks = DietIdeas.suggest(store, slot: chosen, now: now)
        FitSection(title: "What to eat", trailing: chosen == upcoming ? "Next up: \(chosen.title.lowercased())" : chosen.title) {
            HStack(spacing: 8) {
                ForEach(MealSlot.allCases) { s in
                    DietChip(title: s.title, symbol: nil, selected: s == chosen) { slot = s }
                }
            }
            Takeaway(text: DietIdeas.tip(for: chosen, now: now)).font(.caption)
            if store.pantry.isEmpty {
                Button { importing = true } label: {
                    Label("Import a receipt to see ideas from what you have", systemImage: "doc.text.viewfinder")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Fit.action)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(picks) { pick in
                    IdeaCard(pick: pick, showsHave: !store.pantry.isEmpty) {
                        sheet = .draft(DietIdeas.draft(pick, slot: chosen))
                    }
                    if pick.id != picks.last?.id { BrickDivider() }
                }
            }
        }
        .sheet(isPresented: $importing) { ReceiptImportSheet() }
    }
}

/// One idea: its name, whether he has it all, its foods, portions and tip, and Log this.
struct IdeaCard: View {
    var pick: IdeaPick
    var showsHave = true
    var onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(pick.idea.name).font(.headline).foregroundStyle(BrickLook.ink)
                Spacer(minLength: 8)
                if showsHave {
                    Text(pick.complete ? "You have it all" : "Need \(pick.missing.count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(pick.complete ? Fit.positive : BrickLook.soft)
                }
            }
            FlowLayout(spacing: 6) {
                ForEach(pick.foods + pick.extras) { food in
                    let missing = showsHave && pick.missing.contains(food)
                    HStack(spacing: 5) {
                        FodmapDot(level: food.level, size: 7)
                        Text(food.name).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(missing ? BrickLook.soft : BrickLook.ink)
                    .padding(.horizontal, 10).frame(minHeight: 28)
                    .overlay {
                        if missing { Capsule().strokeBorder(BrickLook.soft.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                    }
                    .glassGlare(missing ? .clear : .regular, in: .capsule)
                    .accessibilityLabel(missing ? "\(food.name), need to buy" : food.name)
                }
            }
            ForEach(pick.portions) { food in
                if let tip = food.tip {
                    Text("\(food.name): \(tip)").font(.caption).foregroundStyle(FodmapLevel.moderate.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let tip = pick.idea.tip {
                Text(tip).font(.caption).foregroundStyle(BrickLook.soft).fixedSize(horizontal: false, vertical: true)
            }
            if !pick.agreeable.isEmpty {
                Text("Sat well before: \(pick.agreeable.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(Fit.positive)
            }
            Button(action: onLog) {
                Label("Log this", systemImage: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(Fit.action)
                    .frame(minHeight: HubLayout.minHitTarget)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }
}

/// The card's short version: the top ideas for the next meal, one line each.
struct IdeaLine: View {
    var pick: IdeaPick
    var showsHave: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb").font(.body).foregroundStyle(Fit.energy).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(pick.idea.name).font(.body.weight(.semibold)).foregroundStyle(BrickLook.ink).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(pick.complete && showsHave ? Fit.positive : BrickLook.soft).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(BrickLook.soft)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    private var caption: String {
        guard showsHave else { return pick.foods.map(\.name).joined(separator: ", ") }
        if pick.complete { return "You have it all" }
        return "Need " + pick.missing.map { $0.name.lowercased() }.joined(separator: ", ")
    }
}
