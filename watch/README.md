# Armstrong watch faces (Connect IQ, Forerunner 965)

Status: v1 "Armstrong Minimal", local data only. **Not compiled and not tested on a watch.**
Written without the Connect IQ SDK, so expect a few compile fixes on first build.

## Build (Mac)
1. Install the Connect IQ SDK Manager from https://developer.garmin.com/connect-iq/sdk/ and download the latest SDK and the fr965 device.
2. Install VS Code + the "Monkey C" extension. Command Palette > "Monkey C: Verify Installation" (creates the developer key).
3. Open `watch/ArmstrongFace`. Run "Monkey C: Build Current Project" (target fr965) to try it in the simulator.
4. "Monkey C: Build For Device" produces `ArmstrongFace.prg`.

## Sideload
Newer Garmin watches use MTP, so Finder can't see them. Quit Garmin Express, install OpenMTP, plug in the watch, copy the `.prg` to `GARMIN/APPS`. Eject, then on the watch: long-press Up > Watch Face > pick "Armstrong Minimal".

## What v1 shows
Time, date, 7 week circles (v1: filled = that day met the step goal; becomes workouts once the hub feed exists), steps + goal bar, current HR, resting HR. Always-on mode shows only the dim time, moved a few pixels each minute for burn-in.
