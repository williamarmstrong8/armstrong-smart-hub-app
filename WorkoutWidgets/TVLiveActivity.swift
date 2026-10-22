import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// What's playing on the TV, on the lock screen and in the Dynamic Island: the
/// poster, how far in, and the TV's controls (back 10, play/pause, forward 30,
/// volume).
struct TVLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TVActivityAttributes.self) { context in
            TVLockScreenView(state: context.state, ended: context.isStale)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "armstronghub://home"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TVPoster(file: state.posterFile).frame(width: 44, height: 66)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.headline).lineLimit(1)
                        if let label = state.episodeLabel {
                            Text(label).font(.caption).foregroundStyle(WidgetColor.muted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "tv").foregroundStyle(WidgetColor.blue)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        TVProgress(state: state, ended: context.isStale)
                        TVButtons(isPaused: state.isPaused, height: 36)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: state.isPaused ? "pause.fill" : "tv").foregroundStyle(WidgetColor.blue)
            } compactTrailing: {
                if !state.isPaused, !context.isStale, let end = state.endsAt, end > .now {
                    Text(timerInterval: Date.now...end, countsDown: true)
                        .monospacedDigit().frame(maxWidth: 52)
                } else {
                    Text(TVTime.clock(state.position(at: .now))).monospacedDigit()
                }
            } minimal: {
                Image(systemName: state.isPaused ? "pause.fill" : "tv").foregroundStyle(WidgetColor.blue)
            }
            .keylineTint(WidgetColor.blue)
            .widgetURL(URL(string: "armstronghub://home"))
        }
    }
}

private struct TVLockScreenView: View {
    var state: TVActivityState
    var ended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TVPoster(file: state.posterFile).frame(width: 48, height: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Label(ended ? "Finished" : state.isPaused ? "Paused" : "Playing on the TV", systemImage: "tv")
                        .font(.caption.weight(.semibold)).foregroundStyle(WidgetColor.blue)
                    Text(state.title).font(.headline).lineLimit(1)
                    if let label = state.episodeLabel {
                        Text(label).font(.subheadline).foregroundStyle(WidgetColor.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    TVProgress(state: state, ended: ended)
                }
            }
            .frame(height: 72)
            TVButtons(isPaused: state.isPaused)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// A bar and the times either side of it. While playing they tick on their own.
private struct TVProgress: View {
    var state: TVActivityState
    var ended: Bool

    var body: some View {
        VStack(spacing: 3) {
            if !state.isPaused, !ended, let end = state.endsAt, end > .now {
                ProgressView(timerInterval: state.startedAt...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(WidgetColor.blue)
                HStack {
                    Text(timerInterval: state.startedAt...end, countsDown: false)
                    Spacer()
                    Text("-\(Text(timerInterval: Date.now...end, countsDown: true))")
                }
            } else {
                ProgressView(value: ended ? 1 : state.fraction).tint(WidgetColor.blue)
                HStack {
                    Text(TVTime.clock(state.position(at: .now)))
                    Spacer()
                    if let runtime = state.runtime { Text("-" + TVTime.clock(max(0, runtime - state.position(at: .now)))) }
                }
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(WidgetColor.muted)
        .monospacedDigit()
    }
}

/// Back 10, play/pause and forward 30, then volume.
private struct TVButtons: View {
    var isPaused: Bool
    var height: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            key(.back, "gobackward.10", "Back 10 seconds")
            key(.playPause, isPaused ? "play.fill" : "pause.fill", isPaused ? "Play" : "Pause", fill: WidgetColor.blue)
            key(.forward, "goforward.30", "Forward 30 seconds")
            key(.volumeDown, "speaker.wave.1.fill", "Volume down")
            key(.volumeUp, "speaker.wave.3.fill", "Volume up")
        }
    }

    private func key(_ command: TVCommand, _ symbol: String, _ label: String, fill: Color = WidgetColor.track) -> some View {
        Button(intent: TVControlIntent(command)) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(fill, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The poster the app saved to the app group, or a plain TV tile.
private struct TVPoster: View {
    var file: String?

    var body: some View {
        if let file, let url = SharedHub.file(file), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                .clipShape(.rect(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(WidgetColor.track)
                .overlay { Image(systemName: "film").foregroundStyle(WidgetColor.muted) }
        }
    }
}

enum TVTime {
    /// "1:02:03" or "2:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
