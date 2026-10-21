import AppIntents
import SwiftUI
import WidgetKit

/// The home screen widget: the workout in progress with a check button and the
/// rest timer, or a prompt to start one.
struct WorkoutHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WorkoutSnapshot.widgetKind, provider: Provider()) { entry in
            WorkoutWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Workout")
        .description("Check off sets and run the rest timer for the workout in progress.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WorkoutEntry: TimelineEntry {
    var date: Date
    var snapshot: WorkoutSnapshot?
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WorkoutEntry { WorkoutEntry(date: .now, snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (WorkoutEntry) -> Void) {
        completion(WorkoutEntry(date: .now, snapshot: WorkoutSnapshot.read()))
    }

    /// The app reloads the widget on every change. When a rest is running, a
    /// second entry at its end flips the widget back to the next set.
    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkoutEntry>) -> Void) {
        let snapshot = WorkoutSnapshot.read()
        var entries = [WorkoutEntry(date: .now, snapshot: snapshot)]
        if let end = snapshot?.state.restEndsAt, end > .now {
            entries.append(WorkoutEntry(date: end, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

private struct WorkoutWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WorkoutEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            let resting = (snapshot.state.restEndsAt ?? .distantPast) > entry.date
            if family == .systemSmall {
                small(snapshot, resting: resting)
            } else {
                medium(snapshot, resting: resting)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "dumbbell.fill").font(.title2).foregroundStyle(WidgetColor.blue)
                Spacer()
                Text("No workout").font(.headline)
                Text("Start one in Fitness").font(.caption).foregroundStyle(WidgetColor.muted)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func small(_ snapshot: WorkoutSnapshot, resting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if resting, let end = snapshot.state.restEndsAt {
                Text("Rest").font(.caption).foregroundStyle(WidgetColor.muted)
                Text(timerInterval: entry.date...max(end, entry.date), countsDown: true)
                    .font(.system(size: 30, weight: .medium)).monospacedDigit()
                Spacer(minLength: 0)
                Button(intent: SkipRestIntent()) {
                    Text("Skip").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(WidgetColor.blue, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else if let name = snapshot.state.exerciseName {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(snapshot.state.setLabel).font(.caption).foregroundStyle(WidgetColor.muted)
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    Text(snapshot.state.target).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 4)
                    CompleteSetButton(size: 40)
                }
            } else {
                NextSetText(state: snapshot.state)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ snapshot: WorkoutSnapshot, resting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(snapshot.name, systemImage: "dumbbell.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(WidgetColor.muted).lineLimit(1)
                Spacer()
                Text(snapshot.startedAt, style: .timer)
                    .font(.caption.weight(.semibold)).monospacedDigit().multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70, alignment: .trailing)
            }
            if resting, let end = snapshot.state.restEndsAt {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Rest").font(.caption).foregroundStyle(WidgetColor.muted)
                        Text(timerInterval: entry.date...max(end, entry.date), countsDown: true)
                            .font(.system(size: 30, weight: .medium)).monospacedDigit()
                    }
                    RestButtons(height: 34)
                }
            } else {
                HStack(alignment: .center) {
                    NextSetText(state: snapshot.state)
                    Spacer(minLength: 8)
                    if snapshot.state.exerciseName != nil { CompleteSetButton(size: 46) }
                }
            }
            Spacer(minLength: 0)
            RepsBar(state: snapshot.state)
        }
        .foregroundStyle(.white)
    }
}
