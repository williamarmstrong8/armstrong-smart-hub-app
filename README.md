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

## Build

Open `Armstrong-Smart-Hub-App.xcodeproj` in Xcode and run. ONNX Runtime comes in through Swift Package Manager.
