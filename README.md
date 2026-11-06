# Armstrong Hub (iOS / iPad)

The native app for [Armstrong Hub](https://github.com/williamarmstrong8/armstrong-smart-hub). It signs in to the hub
(`armstrong-smart-hub.vercel.app`) and uses its `/api/mobile` API; every secret stays on the hub.

- **iPhone:** tabs for the agent, home, finance, calendar and habits.
- **iPad:** an always-on dashboard with "Hey Jarvis", a hands-free voice agent.

## Hey Jarvis

- Wake word runs on-device with [openWakeWord](https://github.com/dscripka/openWakeWord) (ONNX Runtime). The models in
  `Features/Voice/WakeWordModels` are from its v0.5.1 release; the pretrained models are licensed CC BY-NC-SA 4.0
  (non-commercial).
- After the wake word, the app opens a realtime WebSocket to the AI Gateway with a short-lived secret minted by the hub
  (`/api/mobile/voice/session`), streams mic audio, and plays the reply as it streams back.
- Tool calls run on the hub (`/api/mobile/voice/tool`), which returns the card to show. Jev
  (`/api/mobile/voice/intent`) guesses the screen early so the UI can morph before the tool finishes.

## Fitness (Garmin watch, no Garmin cloud)

The Fitness tab talks straight to a Garmin watch (built against a Forerunner 965) over Bluetooth, in place of Garmin
Connect. iOS handles bonding: the system pairing prompt appears the first time the app subscribes to the watch. The
app then opens Garmin's GFDI channel (`CLOSE_ALL`, a multi-link handle per service, COBS-framed messages) and streams
live heart rate and steps. It never archives, deletes or changes anything on the watch.

- **History.** "Sync from watch" reads the watch's legacy directory first (so it flushes pending data, as Gadgetbridge
  does), then lists its files over protobuf file sync and streams each one on service `0x2018` as deflate data. It
  copies up to 10 of the newest activity, sleep and monitoring FIT files per sync to Application Support/Fitness
  (excluded from backups). Nothing on the watch is archived, deleted or marked synced.
- **One pairing.** The watch pairs with one phone or computer at a time. Remove it from Garmin Connect (and from the
  Pi: `bluetoothctl remove <address>`) first, then open Settings → Connectivity → Phone → Pair Phone on the watch.
- **Background limits.** iOS only keeps Bluetooth sessions going in the background for apps that declare it, and
  never for an app the user force-quits from the app switcher: after a force-quit nothing syncs until the app is
  opened again.
- **License.** `Features/Fitness/Garmin` is a port of protocol code from
  [garmin-ble](https://github.com/gwerneckp/garmin-ble) (AGPL-3.0) and
  [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0-or-later). Keeping the app for personal
  use is fine; distributing it (TestFlight to others, the App Store) would require releasing the app's source under
  the AGPL, which also conflicts with App Store terms. Review this before sharing builds.

## Workouts

The Fitness tab also logs strength workouts, Hevy style: routines, an exercise library (plus custom exercises), a set
grid showing last session's numbers, warm-up/drop/failure sets, supersets, a rest timer and PRs. The workout in
progress is saved on the phone as you go, and a finished one waits there until the hub (`/api/mobile/workouts`) takes it.

Checking off a set stamps it with the time and the watch's live heart rate. The hub maps heart rate onto every set
(average, peak, how far it fell a minute later, rest before the next set). It uses the watch's own activity file when
one overlaps the workout, otherwise the live readings the phone recorded. For second-by-second data, start a Strength
activity on the watch as well.

Built-in exercises show a picture (and a two-frame loop of the movement on their page) plus how-to steps from
[free-exercise-db](https://github.com/yuhonas/free-exercise-db), which is public domain (Unlicense). The app maps each
hub library id to an entry in `Features/Workouts/ExerciseMedia.swift` and loads the files from GitHub, caching them on
the phone. Hevy's own illustrations are licensed to Hevy, so they aren't used. An exercise's page also needs the hub's
`GET /api/mobile/workouts/exercises?id=` for its history, chart and records.

## Music (Spotify)

The Music tab is a hero like Fitness's with a Walkman floating on it: what's playing shows in its cassette window
(tape reels that turn and wind from one side to the other as the track goes on), then the recent plays and the
week's podcasts-versus-music mix. Pull the page down and let go to press PLAY (shuffle play), swipe the Walkman for
FF and REW, or tap the window to play or pause; the round buttons under it do the same.

The hub holds the Spotify link (`/api/mobile/spotify`, `/now`, `/control`, `/connect`, and the sign-in callback at
`/api/spotify/callback`); the phone never sees a Spotify token. Spotify has no podcast history, so the hub logs an
episode whenever the app sees it playing, and the mix counts those plus recently-played tracks. Controls need
Spotify Premium and a device with Spotify open.

The Walkman is a Sony WM-41, photo by Dillan Payne,
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), via
[Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Sony_Walkman_WM-41.jpg); the background was removed and
the four top keys cut into their own layers (`Walkman*` image sets).

## Design

See [design.md](design.md) for shared UI tokens, layout and motion conventions, accessibility requirements,
regression checks, and the on-device acceptance checklist.

## Mac app

`desktop/` is a small native Mac app (AppKit + WKWebView) that opens the hub's web app, which follows this app's
design system and tabs. It keeps the hub's session cookie between launches, opens outside links in the default
browser, and maps the tabs to ⌘1–⌘7. `./desktop/build.sh` compiles it with `swiftc` (no Xcode project) and installs
`Armstrong Hub.app` in `~/Applications`.

## Build

Open `Armstrong-Smart-Hub-App.xcodeproj` in Xcode and run. ONNX Runtime comes in through Swift Package Manager.
