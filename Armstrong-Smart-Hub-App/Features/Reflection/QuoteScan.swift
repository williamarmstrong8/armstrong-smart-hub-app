import SwiftUI
import Vision
import VisionKit

/// Apple's document scanner: the camera finds the page, flattens it and hands back the photos.
private struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}

/// One line of text found in a scan; `box` is Vision's normalised rectangle, origin bottom-left.
nonisolated private struct ScanLine: Identifiable, Sendable {
    let id: Int
    let text: String
    let box: CGRect
}

nonisolated private enum QuoteOCR {
    static func lines(in image: CGImage) -> [ScanLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return [] }
        let found = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let top = observation.topCandidates(1).first else { return nil }
            return (top.string, observation.boundingBox)
        }
        // Top of the page first.
        return found.sorted { $0.1.midY > $1.1.midY }
            .enumerated()
            .map { ScanLine(id: $0.offset, text: $0.element.0, box: $0.element.1) }
    }
}

/// Quick quote capture: the document camera, then a page to drag over to pick the quote.
struct QuoteScanFlow: View {
    let store: ReflectionStore
    /// The book to file the quote under; nil lets the reader choose after scanning.
    let bookID: UUID?
    let onClose: () -> Void

    @State private var pages: [UIImage] = []

    var body: some View {
        if !pages.isEmpty {
            QuoteSelectView(store: store, pages: pages, bookID: bookID, onClose: onClose)
        } else if VNDocumentCameraViewController.isSupported {
            DocumentScanner { images in
                if images.isEmpty { onClose() } else { pages = images }
            }
            .ignoresSafeArea()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "camera.metering.unknown").font(.largeTitle).foregroundStyle(HubDesign.secondary)
                Text("Scanning isn't available on this device.").font(.headline)
                Button("Close", action: onClose)
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .frame(minHeight: HubLayout.minHitTarget)
                    .glassGlare(.regular, in: .capsule)
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .hubPageStyle()
        }
    }
}

/// The scanned page with its text found. Drag over the lines of the quote; they highlight and
/// their words appear below, where they can be fixed before saving.
private struct QuoteSelectView: View {
    let store: ReflectionStore
    let pages: [UIImage]
    let bookID: UUID?
    let onClose: () -> Void

    @State private var pageIndex = 0
    @State private var lines: [ScanLine] = []
    @State private var reading = true
    @State private var selected: Set<Int> = []
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var text = ""
    @State private var chosenBook: UUID?
    @FocusState private var focused: Bool

    init(store: ReflectionStore, pages: [UIImage], bookID: UUID?, onClose: @escaping () -> Void) {
        self.store = store
        self.pages = pages
        self.bookID = bookID
        self.onClose = onClose
        _chosenBook = State(initialValue: bookID ?? store.books.first?.id)
    }

    private var image: UIImage { pages[pageIndex] }
    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if pages.count > 1 { pager }
                pageView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if reading { ProgressView("Reading the page").padding(16).glassEffect(.regular, in: .rect(cornerRadius: 16)) }
                    }
                panel
            }
            .padding(.horizontal, HubLayout.gutter)
            .padding(.bottom, 12)
            .navigationTitle("Select a quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .hubPageStyle()
        }
        .task(id: pageIndex) { await read() }
    }

    // MARK: Pieces

    private var pager: some View {
        HStack {
            Button { pageIndex -= 1 } label: {
                Image(systemName: "chevron.left").frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                    .contentShape(.rect)
            }
            .disabled(pageIndex == 0)
            .accessibilityLabel("Previous page")
            Spacer()
            Text("Page \(pageIndex + 1) of \(pages.count)").font(.subheadline).monospacedDigit()
            Spacer()
            Button { pageIndex += 1 } label: {
                Image(systemName: "chevron.right").frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                    .contentShape(.rect)
            }
            .disabled(pageIndex == pages.count - 1)
            .accessibilityLabel("Next page")
        }
        .buttonStyle(.plain)
    }

    private var pageView: some View {
        GeometryReader { geo in
            let fit = fittedRect(image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                ForEach(lines.filter { selected.contains($0.id) }) { line in
                    let r = rect(of: line.box, in: fit)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.yellow.opacity(0.45))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                if let drag = dragRect {
                    Rectangle()
                        .strokeBorder(HubDesign.action, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(HubDesign.action.opacity(0.12))
                        .frame(width: drag.width, height: drag.height)
                        .position(x: drag.midX, y: drag.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(.rect(cornerRadius: HubLayout.controlRadius))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        focused = false
                        dragStart = v.startLocation
                        dragEnd = v.location
                        select(in: fit)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        dragEnd = nil
                    }
            )
            .accessibilityLabel("Scanned page. Drag over the quote to select it.")
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            TextField(lines.isEmpty && !reading ? "No text found. Type the quote." : "Drag over the page to pick the quote",
                      text: $text, axis: .vertical)
                .lineLimit(2...5)
                .focused($focused)
                .padding(12)
                .background(HubDesign.track.opacity(0.5), in: .rect(cornerRadius: HubLayout.controlRadius))
            if store.books.isEmpty {
                Text("Add a book to file quotes under it. This one saves on its own.")
                    .font(.footnote).foregroundStyle(HubDesign.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Label("Book", systemImage: "book.closed").font(.subheadline).foregroundStyle(HubDesign.secondary)
                    Spacer()
                    Picker("Book", selection: $chosenBook) {
                        ForEach(store.books) { b in Text(b.title).tag(Optional(b.id)) }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: Geometry

    private var dragRect: CGRect? {
        guard let a = dragStart, let b = dragEnd else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Where an aspect-fit image sits inside its container.
    private func fittedRect(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Vision's boxes start at the bottom left; the screen's start at the top left.
    private func rect(of box: CGRect, in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + box.minX * fit.width,
               y: fit.minY + (1 - box.maxY) * fit.height,
               width: box.width * fit.width,
               height: box.height * fit.height)
    }

    // MARK: Actions

    /// A line is picked when the drag, a few points wider all round, covers most of its height.
    private func select(in fit: CGRect) {
        guard let drag = dragRect?.insetBy(dx: -4, dy: -4) else { return }
        var picked: Set<Int> = []
        for line in lines {
            let r = rect(of: line.box, in: fit)
            let overlap = r.intersection(drag)
            if !overlap.isNull, overlap.width > 0, overlap.height >= r.height * 0.4 { picked.insert(line.id) }
        }
        guard picked != selected else { return }
        selected = picked
        text = join(lines.filter { picked.contains($0.id) })
    }

    /// Lines read top to bottom; a word split across lines by a hyphen is joined back up.
    private func join(_ picked: [ScanLine]) -> String {
        var result = ""
        for line in picked {
            let piece = line.text.trimmingCharacters(in: .whitespaces)
            if result.hasSuffix("-"), let first = piece.first, first.isLowercase {
                result.removeLast()
                result += piece
            } else if result.isEmpty {
                result = piece
            } else {
                result += " " + piece
            }
        }
        return result
    }

    private func read() async {
        reading = true
        selected = []
        text = ""
        lines = []
        let cg = normalised(image).cgImage
        let found = await Task.detached(priority: .userInitiated) { () -> [ScanLine] in
            guard let cg else { return [] }
            return QuoteOCR.lines(in: cg)
        }.value
        guard !Task.isCancelled else { return }
        lines = found
        reading = false
    }

    /// Redraws the photo upright at a size Vision reads quickly, so its boxes line up with what's shown.
    private func normalised(_ source: UIImage) -> UIImage {
        let longest = max(source.size.width, source.size.height)
        let scale = longest > 2400 ? 2400 / longest : 1
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func save() {
        let book = chosenBook.flatMap { store.book($0) }
        store.addQuote(text: text, author: book?.author ?? "", bookID: book?.id)
        onClose()
    }
}
