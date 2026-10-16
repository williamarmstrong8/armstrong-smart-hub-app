# Armstrong watch faces (Connect IQ, Forerunner 965)

Two faces that share code in `shared/`:

- **Armstrong Minimal** (`ArmstrongFace/`): date, big time, the workout week with the next split and streak, steps bar, heart rate and resting heart rate.
- **Armstrong Data** (`ArmstrongData/`): the same, plus bezel gauges (left = steps toward the goal, right = body battery), stress, this week's intensity minutes and watch battery.

Everything comes from the watch itself (activity history, ActivityMonitor, SensorHistory), because the app doesn't relay web requests from the watch the way Garmin Connect does. The workout rules match the hub's glance feed: a day counts when any activity started on it, push / pull / legs follows the number of strength sessions in the watch's history, and five days without a workout means "Ease back in".

Always-on mode shows only the dim time, moved a few pixels each minute against burn-in.

## Build and publish
One-time setup:
1. `brew install openjdk@17`
2. Install the Connect IQ SDK Manager from https://developer.garmin.com/connect-iq/sdk/, sign in, download the latest SDK and the **Forerunner 965** device.

Then:

```bash
watch/build.sh --publish
```

This compiles both faces into `watch/build/`, signs them with a developer key at `~/.garmin/developer_key.der` (created on the first run; keep it, since the watch ties an installed app to the key that signed it), and uploads them to the hub with the hub's `WATCH_TOKEN`. In the app, open Fitness, then the watch sheet, then Install to watch, and pick a face.

Without `--publish` it only builds. To try a face in the simulator, open its folder in VS Code with the Monkey C extension and run "Monkey C: Build Current Project".

## Sideload by cable instead
Quit Garmin Express, install OpenMTP, plug in the watch, copy a `.prg` from `watch/build/` to `GARMIN/APPS`. Eject, then on the watch: long-press Up > Watch Face > pick it.
