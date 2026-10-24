# Armstrong watch faces (Connect IQ, Forerunner 965)

Two faces that share code in `shared/`:

- **Armstrong Minimal** (`ArmstrongFace/`): an analog dial in the style of Apple's Meridian, with hollow hands, a red seconds hand that sweeps while the screen is awake, and four stat circles: training readiness (a watch complication labelled readiness when there is one, else pushed from the hub), heart rate, calories and watch battery.
- **Armstrong Data** (`ArmstrongData/`): the same, plus bezel gauges (left = steps toward the goal, right = body battery), stress, this week's intensity minutes and watch battery.

Everything comes from the watch itself (activity history, ActivityMonitor, SensorHistory), because the app doesn't relay web requests from the watch the way Garmin Connect does. The workout rules match the hub's glance feed: a day counts when any activity started on it, push / pull / legs follows the number of strength sessions in the watch's history, and five days without a workout means "Ease back in".

Always-on mode shows only the dim time, moved a few pixels each minute against burn-in.

## Glances (the swipe-up loop)
Six apps in `glances/`, each a compact row with a live chart in the loop and a full screen when you tap it:

- **Heart**: now, last 4h in the row; 24h with resting line, low / resting / high, 7-day resting average.
- **Body Battery** (`Energy/`): now and today's charge / drain; 24h curve, high and low.
- **Stress**: now and level; 24h curve and today's split across rest / low / medium / high.
- **Last Night** (`Night/`): body battery gained over your bed-to-wake window; overnight heart rate, lowest HR, SpO2, stress, breathing rate.
- **Training**: streak and next split with the week; recovery time, VO2max, intensity minutes and the last three workouts.
- **Today**: steps and 7-day bars; rings for steps, floors and intensity minutes, calories, distance.

Garmin's own glances are firmware and can't be restyled, so these replace them: install them from the app, then on the watch swipe up, scroll to the bottom, Edit, add the Armstrong ones and remove or move down the built-in ones.

Apps can't read Garmin's sleep score, training status, HRV or race predictions (those are only exposed to watch faces), so the phone pushes the hub's versions into Last Night and Training after each sync (next section). Until a push arrives, or once it's stale, Last Night reads the physiology over the sleep window set on the watch and Training shows the watch's own recovery time and VO2max. New glances: `glances/new.sh <Folder> <EntryClass> "<Name>"`, then add a line to `build.sh`.

## Hub values on the glances (app settings over Bluetooth)
The watch can't fetch from the hub (the app doesn't relay Connect IQ web requests), so the phone writes the values into the glances' **app settings**, the same way Garmin Connect saves settings you edit for a Connect IQ app. The glance reads them with `Application.Properties.getValue` (`shared/Pushed.mc`).

Flow, after every sync (`WatchFiles.sync` → `WatchSettings.push`, also "Send hub values to the glances" in the watch sheet):
1. The app fetches `GET /api/mobile/fitness/watch` from the hub (session auth; `lib/fitness/watch-settings.ts` there). It returns `{ v: 1, night: {...}, training: {...} }`, flat 32-bit integers and short strings, -1 or `""` for "no value".
2. For each glance it sends one GFDI `PROTOBUF_REQUEST` (5043) on the existing GFDI handle and waits up to 8 s for the answer.
3. The watch saves the values (the `.SET` file under `GARMIN/APPS/SETTINGS/` that Garmin Connect would write) and answers.

**The message**, ported from Gadgetbridge (`AppConfigHandler.kt`, `GarminJson.java`, `gdi_app_config_service.proto`):

```
GFDI 5043 payload: requestId LE16 | offset LE32 (0) | total LE32 | length LE32 | protobuf
protobuf Smart {
  4: AppConfigService {
    3: appConfigSet { 1: appId (16 bytes: the manifest id as a big-endian UUID), 2: appConfig (Garmin JSON) }
  }
}
```

The watch first answers with a RESPONSE (5000): `5043 LE16 | status | requestId LE16 | offset LE32 | chunk status | error` (all-zero status bytes = kept, no error). Then it sends a protobuf (request or response) `Smart { 4: { 4: appConfigSetStatus { 1: appId, 2: status } } }`: **1 = saved**, 2 = app not installed or it has no settings. The app ACKs that and logs the outcome per glance in the connection log. A message over 375 bytes would have to be chunked; these are about 200.

**Garmin JSON** (Monkey C's serialized-object format, big-endian): an optional string section `AB CD AB CD | length u32 | (length u16 incl. NUL | UTF-8 | 00)*`, then a data section `DA 7A DA 7A | length u32 | values`. A value is a type byte plus payload: `01` sint32, `02` float, `03` string (u32 offset into the string section), `05` array (u32 count), `09` bool (1 byte), `0B` map (u32 count), `0E` sint64, `0F` double, `00` null. A map's keys and values follow it, breadth-first. `GarminJSON` in `WatchSettings.swift` writes one flat map of sint32, string and bool.

**What the glances need for it to work:** every pushed key is a property in `resources/settings/properties.xml` *and* has a setting in `resources/settings/settings.xml` (the watch refuses a settings write for an app without settings), with the same type as the hub sends (`number` ↔ sint32, `string` ↔ string). Add a key in three places: `lib/fitness/watch-settings.ts` in the hub, `properties.xml`, `settings.xml`. App ids are the manifest ids, listed in `WatchSettings.targets`.

| Glance | Keys | Shown when |
| --- | --- | --- |
| Last Night | `at`, `sStart`, `sEnd` (epoch s), `score`, `deep` / `light` / `rem` / `awake` (min), `hrv`, `hrvWk` (ms), `hrvSt` | `sEnd` is under 20 h old: score in the row, stage bar, HRV and status, and the overnight charts use the detected sleep instead of the bed/wake setting |
| Training | `at`, `ready`, `readyLv`, `acute`, `chronic`, `loadSt`, `recH` (h), `vo2` (VO2max × 10) | `at` is under 36 h old: readiness in the row, a readiness / load line, and the hub's recovery and VO2max instead of the watch's |
| Armstrong Minimal (face) | the Training keys | `at` is under 36 h old: readiness in the top circle |

Sleep score is the watch's own when its sleep file has one, else the hub's; overnight HRV is the watch's hrv_status summary when there is one for that morning, else the hub's estimate.

**Verified so far:** the app and glances compile; the Garmin JSON bytes decode cleanly with a port of Gadgetbridge's decoder; the hub endpoint answers from the real database (training values only so far, since the hub has no sleep or HRV rows yet; the night path was checked with sample nights); both glances run in the Connect IQ simulator with sample values as property defaults. **Not yet verified on the Forerunner 965:** that it accepts the settings write for a sideloaded app and answers status 1, and how the glances look with pushed values. If it doesn't, the connection log shows "Glance settings: Last Night: …" with the status or "no answer".

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
