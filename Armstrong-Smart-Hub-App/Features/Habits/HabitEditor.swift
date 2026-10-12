import SwiftUI

struct HabitEditor: View {
    enum Result { case saved(Habit), archived(String) }

    let habit: Habit?
    let colors: [String]
    let onDone: (Result) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = ""
    @State private var color = ""
    @State private var working = false
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().strokeBorder(Color(hex: color.isEmpty ? colors[0] : color), lineWidth: 5)
                            Text(String(icon.prefix(2))).font(.system(size: 40))
                        }
                        .frame(width: 96, height: 96)
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Name", text: $name)
                    TextField("Emoji (optional)", text: $icon)
                } footer: {
                    Text("Shows as a circle you tap once it's done for the day.")
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(colors, id: \.self) { c in
                            Button {
                                color = c
                            } label: {
                                Circle().fill(Color(hex: c)).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: color == c ? 2.5 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if let error { Section { Text(error).foregroundStyle(.red) } }

                if habit != nil {
                    Section {
                        Button("Remove habit", role: .destructive) { confirmRemove = true }
                    } footer: {
                        Text("Its history is kept.")
                    }
                }
            }
            .navigationTitle(habit == nil ? "New habit" : "Edit habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Remove \(habit?.name ?? "")?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive, action: archive)
            }
            .onAppear {
                name = habit?.name ?? ""
                icon = habit?.icon ?? ""
                color = habit?.color ?? (colors.count > 3 ? colors[3] : colors[0])
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        working = true
        Task {
            defer { working = false }
            let input: JSONValue = ["name": .string(name), "icon": .string(icon), "color": .string(color)]
            do {
                let saved: Habit?
                if let habit {
                    saved = try await session.api.run("updateHabit", [.string(habit.id), input])
                } else {
                    saved = try await session.api.run("createHabit", [input])
                }
                if let saved { onDone(.saved(saved)) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func archive() {
        guard let habit else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let _: Empty? = try await session.api.run("archiveHabit", [.string(habit.id)])
                onDone(.archived(habit.id))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
