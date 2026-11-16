import SwiftUI

/// Account's sections for the phone's own features: Apple Health, the
/// morning and night briefings, and the home / work / gym geofences.
struct PhoneFeaturesSettings: View {
    @State private var health = HealthSync.shared
    @State private var briefing = HealthBriefing.shared
    @State private var places = PlaceMonitor.shared
    /// The place whose address is being typed in.
    @State private var searching: PlaceMonitor.Kind?

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
        } header: {
            Text("Health briefing")
        } footer: {
            Text(briefing.modelAvailable
                 ? "Written on this phone by Apple Intelligence after your morning sync, and from 9:30 pm, and shown on Fitness under This week. Nothing leaves the phone."
                 : "Apple Intelligence isn't on, so the briefing lists the numbers instead of writing them up. Turn it on in Settings › Apple Intelligence & Siri.")
        }

        GlassSection {
            ForEach(PlaceMonitor.Kind.allCases) { kind in
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                            if let place = places.places[kind] {
                                Text(place.address ?? "Set from where you were")
                                    .font(.footnote).foregroundStyle(HubDesign.secondary).lineLimit(2)
                            }
                        }
                    } icon: {
                        Image(systemName: kind.symbol)
                    }
                    Spacer()
                    if places.setting == kind {
                        ProgressView()
                    } else {
                        if places.inside.contains(kind) {
                            Text("Here").font(.footnote).foregroundStyle(HubDesign.secondary)
                        }
                        Menu {
                            Button("Enter an address", systemImage: "magnifyingglass") { searching = kind }
                            Button("Use where I am now", systemImage: "location") { Task { await places.setHere(kind) } }
                            if places.places[kind] != nil {
                                Button("Remove", systemImage: "trash", role: .destructive) { Task { await places.remove(kind) } }
                            }
                        } label: {
                            if places.places[kind] == nil {
                                Text("Set")
                            } else {
                                Image(systemName: "ellipsis.circle").frame(minWidth: HubLayout.minHitTarget, minHeight: HubLayout.minHitTarget)
                            }
                        }
                        .accessibilityLabel(places.places[kind] == nil ? "Set \(kind.title)" : "Change \(kind.title)")
                    }
                }
            }
            if places.places[.home] != nil {
                Toggle("Turn my lamp on when I get home", isOn: $places.homeLamp)
                Toggle("Evening check-in when I get home", isOn: $places.homeCheckin)
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
            Text("Type an address, or set a place while you're there. Getting home turns William's room lamp on and sends the evening check-in (after 3 pm; 9 pm if you were home all along). Arriving at the gym asks to start a workout; time at work and the gym goes in the night briefing. Needs location set to Always. Kept on this phone.")
        }
        .sheet(item: $searching) { kind in AddressSearchSheet(kind: kind) }
    }
}
