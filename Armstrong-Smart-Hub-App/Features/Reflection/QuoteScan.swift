import AVFoundation
import PhotosUI
import SwiftUI
import Vision

// Quote capture in as few taps as possible:
//   Scan → shutter → tap the paragraph → Save.
// Trimming is optional: tap where the quote starts and ends, or drag the handles.

// MARK: - Camera

/// A bare photo camera: one shutter press, no review step.
nonisolated private final class PageCamera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "quote-scan.camera")
    private var configured = false
    private var pending: (@Sendable (Data?) -> Void)?

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            if (try? device.lockForConfiguration()) != nil {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                // Pages are held close; favour near focus.
                if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
                device.unlockForConfiguration()
            }
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    /// Takes a photo and hands back its data on the main queue (nil if the camera isn't running).
    func capture(_ done: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard session.isRunning, pending == nil else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            pending = done
            // The app is portrait only; 90° keeps the photo upright.
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        queue.async { [self] in
            let done = pending
            pending = nil
            DispatchQueue.main.async { done?(data) }
        }
    }
}

private final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {}
}

/// Full-screen viewfinder with one big shutter. A photo from the library works too.
private struct PageCameraView: View {
    let onPhoto: (UIImage) -> Void
    let onClose: () -> Void

    @State private var camera = PageCamera()
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var capturing = false
    @State private var flash = false
    @State private var libraryItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if access == .authorized {
                CameraPreview(session: camera.session).ignoresSafeArea()
            } else if access == .denied || access == .restricted {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("Camera access is off").font(.headline)
                    Text("Turn it on in Settings, or pick a photo of the page.")
                        .font(.subheadline).multilineTextAlignment(.center).opacity(0.8)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.headline)
                    .padding(.top, 8)
                }
                .foregroundStyle(.white)
                .padding(32)
            }
            Color.white.opacity(flash ? 0.7 : 0).ignoresSafeArea().allowsHitTesting(false)
            controls
        }
        .task {
            if access == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                access = granted ? .authorized : .denied
            }
            if access == .authorized { camera.start() }
        }
        .onDisappear { camera.stop() }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    onPhoto(image)
                }
                libraryItem = nil
            }
        }
        .statusBarHidden()
    }

    private var controls: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                        .glassEffect(.clear.interactive(), in: .circle)
                }
                .accessibilityLabel("Cancel")
                Spacer()
            }
            .padding(.horizontal, HubLayout.gutter)
            Spacer()
            if access == .authorized {
                Text("Fit the page in the frame")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.clear, in: .capsule)
                    .padding(.bottom, 20)
            }
            HStack {
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .glassEffect(.clear.interactive(), in: .circle)
                }
                .accessibilityLabel("Choose a photo of the page")
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 82, height: 82)
                        Circle().fill(.white).frame(width: 66, height: 66)
                            .scaleEffect(capturing ? 0.85 : 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(access != .authorized || capturing)
                .opacity(access == .authorized ? 1 : 0.4)
                .accessibilityLabel("Take photo")
                Spacer()
                Color.clear.frame(width: 56, height: 56)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    private func shoot() {
        capturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.25).delay(0.08)) { flash = false }
        camera.capture { data in
            Task { @MainActor in
                capturing = false
                if let data, let image = UIImage(data: data) { onPhoto(image) }
            }
        }
    }
}

// MARK: - Reading the page

/// A paragraph found on the page, already joined across line breaks.
nonisolated struct ScanParagraph: Identifiable, Hashable, Sendable {
    let id: Int
    let text: String
    var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
}

nonisolated private enum QuoteOCR {
    private struct Line {
        var text: String
        var rect: CGRect // pixels, origin top-left
    }

    /// Reads the page and groups its lines into paragraphs by spacing, indents, short last lines
    /// and changes in type size.
    static func paragraphs(in image: CGImage) -> [ScanParagraph] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)

        let raw: [Line] = (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let b = obs.boundingBox
            return Line(text: text, rect: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
        let lines = mergeRows(raw).filter { !isPageNoise($0.text) }
        guard !lines.isEmpty else { return [] }

        let lineHeight = median(lines.map(\.rect.height))
        let left = median(lines.map(\.rect.minX))
        let right = percentile(lines.map(\.rect.maxX), 0.9)
        let gaps = zip(lines, lines.dropFirst()).map { $1.rect.minY - $0.rect.maxY }
        let typicalGap = gaps.isEmpty ? 0 : median(gaps)

        var groups: [[Line]] = []
        for line in lines {
            guard let prev = groups.last?.last else { groups.append([line]); continue }
            let gap = line.rect.minY - prev.rect.maxY
            let bigGap = gap > typicalGap + 0.6 * lineHeight
            let indented = line.rect.minX - left > 0.8 * lineHeight && prev.rect.minX - left < 0.5 * lineHeight
            let ender = prev.text.last.map { ".!?\"”’:)".contains($0) } ?? false
            let shortEnd = ender && prev.rect.maxX < right - 2.5 * lineHeight
            let sizeChange = abs(line.rect.height - prev.rect.height) > 0.45 * lineHeight
            if bigGap || indented || shortEnd || sizeChange {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }

        return groups.map { join($0.map(\.text)) }
            .filter { $0.count > 3 }
            .enumerated()
            .map { ScanParagraph(id: $0.offset, text: $0.element) }
    }

    /// Vision sometimes splits one printed line into pieces; put them back together, top to bottom.
    private static func mergeRows(_ lines: [Line]) -> [Line] {
        var rows: [Line] = []
        for line in lines.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = rows.last,
               abs(line.rect.midY - last.rect.midY) < 0.5 * min(line.rect.height, last.rect.height) {
                let (a, b) = line.rect.minX < last.rect.minX ? (line, last) : (last, line)
                rows[rows.count - 1] = Line(text: a.text + " " + b.text, rect: a.rect.union(b.rect))
            } else {
                rows.append(line)
            }
        }
        return rows
    }

    /// Page numbers and lone symbols.
    private static func isPageNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 2 || t.allSatisfy { $0.isNumber || $0.isWhitespace }
    }

    /// Lines joined with spaces; a word split by a hyphen at a line end is put back together.
    static func join(_ pieces: [String]) -> String {
        var result = ""
        for raw in pieces {
            let piece = raw.trimmingCharacters(in: .whitespaces)
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

    private static func median(_ values: [CGFloat]) -> CGFloat { percentile(values, 0.5) }

    private static func percentile(_ values: [CGFloat], _ p: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(CGFloat(sorted.count - 1) * p))]
    }

    /// Redraws the photo upright at a size Vision reads quickly.
    @MainActor static func normalised(_ source: UIImage) -> UIImage {
        let longest = max(source.size.width, source.size.height)
        let scale = longest > 2400 ? 2400 / longest : 1
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Flow

/// Quick quote capture: camera, then the page's paragraphs to pick from, then optional trimming.
struct QuoteScanFlow: View {
    let store: ReflectionStore
    /// The book to file the quote under; nil lets the reader choose.
    let bookID: UUID?
    let onClose: () -> Void

    @State private var photo: UIImage?
    @State private var paragraphs: [ScanParagraph]?

    var body: some View {
        Group {
            if let photo {
                ParagraphPickView(store: store, bookID: bookID, photo: photo, paragraphs: paragraphs,
                                  onRetake: retake, onClose: onClose)
            } else {
                PageCameraView(onPhoto: read, onClose: onClose)
            }
        }
        .animation(HubMotion.standard, value: photo == nil)
    }

    private func retake() {
        photo = nil
        paragraphs = nil
    }

    private func read(_ image: UIImage) {
        let upright = QuoteOCR.normalised(image)
        photo = upright
        paragraphs = nil
        let cg = upright.cgImage
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [ScanParagraph] in
                guard let cg else { return [] }
                return QuoteOCR.paragraphs(in: cg)
            }.value
            guard photo === upright else { return }
            paragraphs = found
        }
    }
}

/// The page's paragraphs as cards. Tap one to open it for trimming and saving.
private struct ParagraphPickView: View {
    let store: ReflectionStore
    let bookID: UUID?
    let photo: UIImage
    /// nil while the page is still being read.
    let paragraphs: [ScanParagraph]?
    let onRetake: () -> Void
    let onClose: () -> Void

    @State private var picked: ScanParagraph?
    @State private var typing = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pick a paragraph")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: onRetake) { Label("Retake", systemImage: "camera") }
                    }
                }
                .hubPageStyle()
                .navigationDestination(item: $picked) { p in
                    QuoteTrimView(store: store, bookID: bookID, paragraphs: paragraphs ?? [], first: p, onSaved: onClose)
                }
        }
        .sheet(isPresented: $typing) {
            ManualQuoteSheet(store: store, bookID: bookID, onSaved: onClose)
        }
        .onChange(of: paragraphs) { _, found in
            // One paragraph on the page: skip straight to it.
            if let found, found.count == 1 { picked = found[0] }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let paragraphs {
            if paragraphs.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(HubDesign.secondary)
                    Text("No text found on that photo.").font(.headline)
                    HStack(spacing: 12) {
                        pill("Retake", systemImage: "camera", action: onRetake)
                        pill("Type it", systemImage: "square.and.pencil") { typing = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(paragraphs) { p in
                            Button {
                                UISelectionFeedbackGenerator().selectionChanged()
                                picked = p
                            } label: {
                                Text(p.text)
                                    .font(.system(.body, design: .serif))
                                    .lineSpacing(3)
                                    .lineLimit(9)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(HubDesign.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(HubLayout.cardPadding - 4)
                                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: HubLayout.cardRadius - 4))
                                    .contentShape(.rect(cornerRadius: HubLayout.cardRadius - 4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens this paragraph to save it as a quote")
                        }
                        Button { typing = true } label: {
                            Label("Type it instead", systemImage: "square.and.pencil")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(HubDesign.action)
                                .frame(minHeight: HubLayout.minHitTarget)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, HubLayout.gutter)
                    .padding(.vertical, 12)
                }
            }
        } else {
            ZStack {
                Image(uiImage: photo)
                    .resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: HubLayout.controlRadius))
                    .padding(HubLayout.gutter)
                    .opacity(0.6)
                ProgressView("Reading the page")
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(HubDesign.ink)
                .padding(.horizontal, 20)
                .frame(minHeight: HubLayout.minHitTarget)
                .glassGlare(.regular, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trimming

/// The chosen paragraph, word by word, all highlighted. Tap a word to move the nearer end of the
/// highlight there, or drag the handles. Save keeps what's highlighted.
private struct QuoteTrimView: View {
    let store: ReflectionStore
    let bookID: UUID?
    let paragraphs: [ScanParagraph]
    let onSaved: () -> Void

    @State private var words: [String]
    /// Index of the last paragraph included, for "Add next paragraph".
    @State private var lastParagraph: Int
    @State private var start = 0
    @State private var end: Int
    @State private var frames: [Int: CGRect] = [:]
    @State private var editing = false
    @State private var editedText = ""
    @State private var chosenBook: UUID?
    @FocusState private var editorFocused: Bool

    private static let space = "quote-words"

    init(store: ReflectionStore, bookID: UUID?, paragraphs: [ScanParagraph], first: ScanParagraph, onSaved: @escaping () -> Void) {
        self.store = store
        self.bookID = bookID
        self.paragraphs = paragraphs
        self.onSaved = onSaved
        let w = first.words
        _words = State(initialValue: w)
        _end = State(initialValue: max(0, w.count - 1))
        _lastParagraph = State(initialValue: paragraphs.firstIndex(of: first) ?? 0)
        _chosenBook = State(initialValue: bookID ?? store.books.first?.id)
    }

    private var trimmed: Bool { start > 0 || end < words.count - 1 }
    private var hasNext: Bool { lastParagraph + 1 < paragraphs.count }

    private var quoteText: String {
        let raw = editing ? editedText : words[start...end].joined(separator: " ")
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A quote cut mid-sentence shouldn't end on a comma or dash.
        while let last = t.last, ",;:–—-".contains(last) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if editing {
                    TextField("Quote", text: $editedText, axis: .vertical)
                        .font(.system(.title3, design: .serif))
                        .lineSpacing(4)
                        .focused($editorFocused)
                        .padding(14)
                        .background(HubDesign.track.opacity(0.5), in: .rect(cornerRadius: HubLayout.controlRadius))
                } else {
                    Text(trimmed ? "Tap or drag the handles to trim" : "Tap where the quote starts or ends to trim")
                        .font(.footnote)
                        .foregroundStyle(HubDesign.secondary)
                    wordsView
                }
            }
            .padding(.horizontal, HubLayout.gutter)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle(editing ? "Edit quote" : "Trim quote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editing ? "Done" : "Edit") { toggleEditing() }
            }
        }
        .hubPageStyle()
    }

    // MARK: Words

    private var wordsView: some View {
        WordFlow(lineSpacing: 6) {
            ForEach(words.indices, id: \.self) { i in
                let on = i >= start && i <= end
                Text(words[i])
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(on ? HubDesign.ink : HubDesign.secondary.opacity(0.55))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 3)
                    .background(on ? Color.yellow.opacity(0.42) : .clear)
                    .contentShape(.rect)
                    .onTapGesture { tap(i) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[i] = $0 }
            }
        }
        .overlay { handles }
        .coordinateSpace(.named(Self.space))
        .animation(HubMotion.quick, value: start)
        .animation(HubMotion.quick, value: end)
        .sensoryFeedback(.selection, trigger: start)
        .sensoryFeedback(.selection, trigger: end)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quoteText)
        .accessibilityHint("The highlighted words are saved. Use Edit to change the text.")
    }

    @ViewBuilder
    private var handles: some View {
        if let a = frames[start], let b = frames[end] {
            ZStack(alignment: .topLeading) {
                handle(at: CGPoint(x: a.minX, y: a.minY), height: a.height, knobOnTop: true) { i in start = min(i, end) }
                handle(at: CGPoint(x: b.maxX, y: b.minY), height: b.height, knobOnTop: false) { i in end = max(i, start) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// An iOS-style selection handle: a bar the height of the word with a round knob.
    private func handle(at origin: CGPoint, height: CGFloat, knobOnTop: Bool, move: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 0) {
            if knobOnTop { Circle().fill(HubDesign.action).frame(width: 12, height: 12) }
            Capsule().fill(HubDesign.action).frame(width: 3, height: height)
            if !knobOnTop { Circle().fill(HubDesign.action).frame(width: 12, height: 12) }
        }
        .frame(width: HubLayout.minHitTarget, height: height + 12 + 20)
        .contentShape(.rect)
        .position(x: origin.x, y: origin.y + height / 2 + (knobOnTop ? -6 : 6))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { v in if let i = nearestWord(to: v.location) { move(i) } }
        )
        .accessibilityHidden(true)
    }

    /// The word under a point, or the closest one, favouring the same line.
    private func nearestWord(to p: CGPoint) -> Int? {
        func score(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return dy * 4 + dx
        }
        return frames.filter { $0.key < words.count }.min { score($0.value) < score($1.value) }?.key
    }

    /// Moves whichever end of the highlight is nearer to the tapped word.
    private func tap(_ i: Int) {
        if i < start { start = i }
        else if i > end { end = i }
        else if i - start <= end - i { start = i }
        else { end = i }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if trimmed && !editing {
                    smallButton("Whole paragraph", systemImage: "arrow.left.and.right") {
                        start = 0
                        end = words.count - 1
                    }
                }
                if hasNext && !editing {
                    smallButton("Add next paragraph", systemImage: "plus") { addNext() }
                }
                Spacer(minLength: 0)
                if bookID == nil, !store.books.isEmpty {
                    Picker("Book", selection: $chosenBook) {
                        ForEach(store.books) { b in Text(b.title).tag(Optional(b.id)) }
                    }
                    .labelsHidden()
                }
            }
            Button(action: save) {
                Label("Save quote", systemImage: "quote.opening")
                    .font(.headline)
                    .foregroundStyle(HubDesign.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .glassGlare(.regular.tint(HubDesign.action.opacity(0.55)), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(quoteText.isEmpty)
            .opacity(quoteText.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, HubLayout.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func smallButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(HubDesign.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .glassGlare(.regular, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func addNext() {
        guard hasNext else { return }
        lastParagraph += 1
        let extendsToEnd = end == words.count - 1
        words += paragraphs[lastParagraph].words
        if extendsToEnd { end = words.count - 1 }
    }

    private func toggleEditing() {
        if editing {
            editorFocused = false
            editing = false
        } else {
            editedText = words[start...end].joined(separator: " ")
            editing = true
            editorFocused = true
        }
    }

    private func save() {
        let book = chosenBook.flatMap { store.book($0) }
        store.addQuote(text: quoteText, author: book?.author ?? "", bookID: book?.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSaved()
    }
}

/// Words laid out like a paragraph, flush against each other so a run of highlights reads as one.
private struct WordFlow: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += row + lineSpacing; x = 0; row = 0 }
            x += s.width
            row = max(row, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += row + lineSpacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width
            row = max(row, s.height)
        }
    }
}

// MARK: - Typing a quote

/// Type a quote in by hand, with an optional note. Opens with the keyboard up.
struct ManualQuoteSheet: View {
    let store: ReflectionStore
    let bookID: UUID?
    /// Called after saving, in place of dismissing (used when shown inside the scan flow).
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var note = ""
    @FocusState private var focused: Bool

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("The quote", text: $text, axis: .vertical)
                        .font(.system(.body, design: .serif))
                        .lineLimit(3...12)
                        .focused($focused)
                }
                Section {
                    TextField("Your note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                }
            }
            .hubListStyle()
            .navigationTitle("Type a quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    private func save() {
        let book = bookID.flatMap { store.book($0) }
        store.addQuote(text: text, author: book?.author ?? "", bookID: book?.id, note: note)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let onSaved { onSaved() } else { dismiss() }
    }
}
