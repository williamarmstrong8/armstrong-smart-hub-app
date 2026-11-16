import MapKit
import SwiftUI

/// Type an address (or a place's name) and pick it: sets home, work or the gym
/// without having to be there. Suggestions come from Apple Maps as you type.
struct AddressSearchSheet: View {
    let kind: PlaceMonitor.Kind
    @Environment(\.dismiss) private var dismiss
    @State private var completer = AddressCompleter()
    @State private var query = ""
    @State private var resolving: String?
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(kind == .gym ? "Gym name or address" : "Address", text: $query)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.search)
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
                Section {
                    ForEach(completer.results, id: \.self) { result in
                        Button {
                            Task { await pick(result) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title).foregroundStyle(.primary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if resolving == result.title + result.subtitle { ProgressView() }
                            }
                        }
                        .disabled(resolving != nil)
                    }
                }
            }
            .navigationTitle("Set \(kind.title.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: query) { _, q in completer.search(q) }
            .onAppear { focused = true }
        }
    }

    private func pick(_ result: MKLocalSearchCompletion) async {
        resolving = result.title + result.subtitle
        defer { resolving = nil }
        let request = MKLocalSearch.Request(completion: result)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            problem = "Couldn't find that address on the map. Try another."
            return
        }
        let address = [result.title, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        await PlaceMonitor.shared.set(kind, coordinate: item.location.coordinate, address: address)
        dismiss()
    }
}

/// Apple Maps' type-ahead for addresses and places.
@Observable
final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { results = [] } else { completer.queryFragment = text }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { results = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }
}
