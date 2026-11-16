import SwiftUI

/// Account's sections for the phone's own features: Apple Health, the
/// morning and night briefings, and the home / work / gym geofences.
struct PhoneFeaturesSettings: View {
    @State private var health = HealthSync.shared
    @State private var briefing = HealthBriefing.shared
    @State private var places = PlaceMonitor.shared
    @State private var preview: String?
    @State private var previewing = false

    var body: some View {
        if health.available {
            GlassSection {
                Toggle("Write to Apple Health", isOn: Binding(get: { health.enabled }, set: { on in
                    Task {
                        await health.setEnabled(on)
                        if on { await BackgroundRefresh.shared.run() }
                    }
                }))
                if let at = health.lastSync {
                    LabeledContent("Last written", value: at.formatted(.relative(presentation: .named)))
                }
                if let error = health.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Apple Health")
            } footer: {
                Text("Adds the watch's workouts, sleep stages, overnight HRV and resting heart rate, your drinks, and each check-in as a mood. Garmin's HRV is RMSSD; Health files it as HRV (SDNN).")
            }
        }

        GlassSection {
            Toggle("Morning", isOn: $briefing.morningOn)
            Toggle("Night", isOn: $briefing.nightOn)
            Button(previewing ? "Writing…" : "Write one now", systemImage: "text.badge.star") {
                previewing = true
                Task {
                    let hour = Calendar.current.component(.hour, from: .now)
                    preview = await briefing.preview(hour < 15 ? .morning : .night)
                    previewing = false
                }
            }
            .disabled(previewing)
            if let preview {
                Text(preview).font(.subheadline)
            }
        } header: {
            Text("Health briefing")
        } footer: {
            Text(briefing.modelAvailable
                 ? "Written on this phone by Apple Intelligence after your morning sync, and from 9:30 pm. Nothing leaves the phone."
                 : "Apple Intelligence isn't on, so the briefing lists the numbers instead of writing them up. Turn it on in Settings › Apple Intelligence & Siri.")
        }

        GlassSection {
            ForEach(PlaceMonitor.Kind.allCases) { kind in
                HStack {
                    Label(kind.title, systemImage: kind.symbol)
                    Spacer()
                    if places.setting == kind {
                        ProgressView()
                    } else if places.places[kind] != nil {
                        if places.inside.contains(kind) {
                            Text("Here").font(.footnote).foregroundStyle(HubDesign.secondary)
                        }
                        Menu {
                            Button("Set to where I am", systemImage: "location") { Task { await places.setHere(kind) } }
                            Button("Remove", systemImage: "trash", role: .destructive) { Task { await places.remove(kind) } }
                        } label: {
                            Image(systemName: "ellipsis.circle").frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                        }
                        .accessibilityLabel("Change \(kind.title)")
                    } else {
                        Button("Set to here") { Task { await places.setHere(kind) } }
                    }
                }
            }
            if places.places[.gym] != nil {
                Toggle("Ask to start a workout at the gym", isOn: $places.gymPrompts)
            }
            if let problem = places.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Places")
        } footer: {
            Text("Set each place while you're there. Arriving at the gym asks to start a workout; time at work and the gym goes in the night briefing. Needs location set to Always. Kept on this phone.")
        }
    }
}
