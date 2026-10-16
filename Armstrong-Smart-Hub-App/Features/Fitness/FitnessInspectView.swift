import SwiftUI

/// Shows what the hub found inside the newest stored file of each kind: which
/// FIT messages it holds and a sample value for each field. For checking what
/// the watch really sends when sleep, HRV or heart rate don't show up.
struct FitnessInspectView: View {
    @Environment(AppSession.self) private var session
    @State private var files: [InspectedFile] = []
    @State private var state: String? = "Loading…"

    struct InspectedFile: Decodable, Identifiable {
        var kind: String
        var fileId: String
        var size: Int
        var recordedAt: String?
        var error: String?
        var messages: [Message]?
        var id: String { fileId }

        struct Message: Decodable, Identifiable {
            var num: Int
            var count: Int
            var fields: [String: Sample]
            var id: Int { num }
        }
    }

    /// One sample field value, whatever type the hub sent.
    enum Sample: Decodable, CustomStringConvertible {
        case number(Double), text(String), list([Sample]), none

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let s = try? c.decode(String.self) { self = .text(s) }
            else if let l = try? c.decode([Sample].self) { self = .list(l) }
            else { self = .none }
        }

        var description: String {
            switch self {
            case let .number(n): n == n.rounded() ? String(Int(n)) : String(n)
            case let .text(s): "\"\(s)\""
            case let .list(l): "[" + l.prefix(4).map(\.description).joined(separator: ",") + (l.count > 4 ? ",…" : "") + "]"
            case .none: "–"
            }
        }
    }

    private struct Response: Decodable { var files: [InspectedFile] }

    private var report: String {
        files.map { file in
            let head = "\(file.kind)  \(file.size) bytes  \(file.recordedAt ?? "")"
            if let error = file.error { return head + "\n  error: \(error)" }
            return head + "\n" + (file.messages ?? []).map { "  msg \($0.num) x\($0.count): " + line($0) }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func line(_ message: InspectedFile.Message) -> String {
        message.fields.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    var body: some View {
        List {
            if let state { Text(state).foregroundStyle(.secondary) }
            ForEach(files) { file in
                Section {
                    if let error = file.error {
                        Text(error).foregroundStyle(.red)
                    }
                    ForEach(file.messages ?? []) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("message \(message.num)  x\(message.count)").font(.caption.weight(.semibold))
                            Text(line(message)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(file.kind) · \(file.size) bytes")
                }
            }
        }
        .navigationTitle("File layout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !files.isEmpty { ToolbarItem(placement: .topBarTrailing) { ShareLink(item: report) } }
        }
        .task {
            do {
                let request = session.api.request("/api/mobile/fitness/inspect", timeout: 120)
                let response: Response = try await session.api.send(request)
                files = response.files
                state = files.isEmpty ? "The hub has no stored files yet." : nil
            } catch {
                state = "\(error.localizedDescription). The hub needs the latest update deployed."
            }
        }
    }
}
