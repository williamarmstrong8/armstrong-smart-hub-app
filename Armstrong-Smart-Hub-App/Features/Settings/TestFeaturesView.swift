import SwiftUI

/// Account › Test features: sets off each of the phone's automatic features on
/// demand, to see how they look and work without waiting for 8 am, getting
/// home or the next background refresh.
///
/// Notifications come 5 seconds after the tap, so there's time to lock the
/// phone and see them on the lock screen (long-press for the buttons).
/// Test check-ins don't save an answer; the lamp, Apple Health and a workout
/// started from the gym prompt are real.
struct TestFeaturesView: View {
    @State private var results: [String: String] = [:]
    @State private var running: String?
    @State private var places = PlaceMonitor.shared
    @State private var health = HealthSync.shared
    @State private var briefing = HealthBriefing.shared

    var body: some View {
        GlassForm {
            GlassSection {
                test("morning", "Morning check-in", "sun.max",
                     detail: CheckinStore.shared.likely.isEmpty ? "No guess from the hub today, so it's the plain question." : nil) {
                    await CheckinReminders.shared.sendTest(.morning)
                    return "Arrives in 5 seconds."
                }
                test("sample", "Morning check-in with a sample guess", "questionmark.bubble") {
                    await CheckinReminders.shared.sendTest(.sampleGuess)
                    return "Arrives in 5 seconds: \"Run down?\" with made-up numbers."
                }
                test("evening", "Evening check-in", "moon") {
                    await CheckinReminders.shared.sendTest(.evening)
                    return "Arrives in 5 seconds."
                }
            } header: {
                Text("Check-ins")
            } footer: {
                Text("Long-press the notification for its buttons. In a test, a button only tells you what it would have saved.")
            }

            GlassSection {
                test("briefMorning", "Send the morning briefing", "sunrise") {
                    await briefing.sendTest(.morning)
                }
                test("briefNight", "Send the night briefing", "moon.stars") {
                    await briefing.sendTest(.night)
                }
            } header: {
                Text("Health briefing")
            } footer: {
                Text("Writes it now from the phone's data, shows it on the Fitness card, and sends the notification in 5 seconds.")
            }

            GlassSection {
                test("health", "Write to Apple Health now", "heart.text.square") {
                    await briefing.syncHealthNow()
                }
            } header: {
                Text("Apple Health")
            } footer: {
                Text(health.enabled ? "Writes anything new: workouts, sleep, HRV, resting heart rate, drinks." : "Turn on Write to Apple Health in Account first.")
            }

            GlassSection {
                test("lamp", "Turn my lamp on", "lamp.table") {
                    await places.testLamp()
                }
                test("home", "Pretend I got home", "house") {
                    await places.simulate(.home, arriving: true)
                }
                test("gymIn", "Pretend I got to the gym", "dumbbell") {
                    await places.simulate(.gym, arriving: true)
                }
                test("gymOut", "Pretend I left the gym", "figure.walk.departure") {
                    await places.simulate(.gym, arriving: false)
                }
            } header: {
                Text("Places")
            } footer: {
                Text(places.places.isEmpty
                     ? "These work before any place is set; set Home, Work and Gym in Account so real arrivals happen too."
                     : "Real arrivals also need location set to Always. Recent: \(recentVisits)")
            }

            GlassSection {
                test("refresh", "Run a background refresh now", "arrow.triangle.2.circlepath") {
                    await BackgroundRefresh.shared.run()
                    return "Done: sent anything waiting for the hub, loaded Fitness and the check-in guess, wrote to Health, sent a briefing if one was due."
                }
            } header: {
                Text("Background")
            } footer: {
                Text("The same pass iOS runs while the app is closed.")
            }

            GlassSection {
                Text("Open Reflection and tap ✨ next to New entry to pick a moment from your day. Needs a real iPhone.")
                    .font(.subheadline)
            } header: {
                Text("Journaling Suggestions")
            }
        }
        .navigationTitle("Test features")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The last few arrivals and departures the geofences saw.
    private var recentVisits: String {
        let recent = places.visits.suffix(3).reversed().map { v in
            "\(v.kind.title) \(v.arrived.formatted(date: .omitted, time: .shortened))" + (v.left.map { "–\($0.formatted(date: .omitted, time: .shortened))" } ?? " (still there)")
        }
        return recent.isEmpty ? "none yet." : recent.joined(separator: ", ")
    }

    /// One test: a button, and underneath it what happened last time.
    private func test(_ id: String, _ title: String, _ symbol: String, detail: String? = nil,
                      _ action: @escaping () async -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                running = id
                results[id] = nil
                Task {
                    results[id] = await action()
                    running = nil
                }
            } label: {
                HStack {
                    Label(title, systemImage: symbol)
                    Spacer()
                    if running == id { ProgressView() }
                }
            }
            .disabled(running != nil)
            if let text = results[id] ?? detail {
                Text(text).font(.footnote).foregroundStyle(HubDesign.secondary)
            }
        }
    }
}
