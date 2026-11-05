# Armstrong Hub — App Brief (for the launch film)

## The app in one line
A personal home-and-life hub for iPhone: your Garmin watch, your smart home and a focus mode, in one calm native app.
Audience for the film: **non-technical builders**, so the film sells the feeling (one app, everything in reach), not the protocol.

## Project facts
| | |
|---|---|
| Xcode project | `Armstrong-Smart-Hub-App.xcodeproj` (file-system–synchronized groups: new `.swift` files in the app folder are picked up automatically) |
| Targets / schemes | `Armstrong-Smart-Hub-App` (app), `WorkoutWidgets`, `BrickReport` (Screen Time report ext.), `BrickMonitor`, `BrickShield` |
| Bundle ID | `com.paularmstrong.ArmstrongSmartHubApp` |
| Minimum iOS | **27.0** (iOS 27.0 simulator runtime is installed; newest Pro sim = **iPhone 17 Pro**) |
| UI | SwiftUI, `TabView` with 5 tabs on iPhone; iPad shows an always-on dashboard instead |
| Packages | ONNX Runtime (SPM) for the "Hey Jarvis" wake word |

## Navigation / screen inventory (iPhone)
`HubApp` → `RootView` → `LoginView` (signed out) or `MainTabView` (signed in).

| Tab | Root view | Key screens |
|---|---|---|
| Home | `HomeView` | Device cards grouped Lights / Entertainment / Climate / Locks / Switches, `LightSheet` (brightness + color), `RemoteSheet` (TV remote), Automations sheet, habits, media shelf + `MediaDetailCard`, `DisplayModeView` |
| Finance | `FinanceView` | balances, budget, `TransactionsView` |
| Calendar | `CalendarView` | events, `TodoSection`, `HabitMonth` |
| Fitness | `FitnessView` | Watch hero (`GarminHero` render, sync ring on the watch face), date + "Forerunner 965", `TodayScores` rings (readiness / sleep / body battery), `MorningCheckin`, `WeekStrip`, `OverviewList` tiles → `FitnessPages` (readiness, recovery, strain, sleep, heart, energy, training, health), `ActivityPage`, Workouts carousel → `ActiveWorkoutView` |
| Brick → **"Focus" in the film** | `BrickView` | Top sheet (device image, mode name, live timer, Today / Sessions / Daily avg, big capsule button), Screen Time section, today's day card, Modes / Schedules / Tags / Emergency pages |

## Data model & persistence (why demo mode works the way it will)
Almost everything is **fetched from the user's hub** (`APIClient` → `/api/mobile/*`, `/api/home`, Server Actions via `/api/mobile/action`):
- `FitnessStore` ← `GET /api/mobile/fitness` → `FitnessSnapshot` (days, activities, sleep, heart rate, HRV, metrics, insights, watch scores). Cached to `Application Support/Fitness/snapshot.json`.
- `HomeStore` ← `GET /api/home` → `HomeState` (`HAEntity` list, media requests, automations); toggles go through actions `toggleEntity`, `setLight`, `setAutomationEnabled`.
- `HabitsStore`, `CheckinStore`, `WorkoutStore`, `FinanceStore` — same pattern.
- `DiskCache` (`Application Support/PageCache`) paints last-known pages on cold launch.
- **Local-only:** `BrickStore` (profiles, sessions, schedules, NFC tags in UserDefaults / app group), `WatchLink` (saved watch UUID in UserDefaults, live HR via CoreBluetooth), `LiveStore`.
- Session: server URL in UserDefaults, token in Keychain.

**Hardware the simulator can't provide:** Bluetooth watch, NFC tags, Screen Time / FamilyControls shields.

### Demo-mode design (Phase 2 proposal)
`-DemoMode YES` will:
1. Install an **in-process fake hub** inside `APIClient.data(_:)`: every request is answered from `DemoData.swift` fixtures — no network, no real hub, no real token. Actions (`toggleEntity`, `setLight`…) mutate an in-memory demo state so taps stick.
2. Point every on-disk cache (fitness snapshot, `DiskCache`, Brick state, watch UUID) at a **throwaway in-memory / `demo` suite**, so nothing of yours is read or written.
3. Present as signed in (fake user "Alex Rivera"), skip login, and never request Bluetooth / NFC / Screen Time / notification permission.
4. Fake the watch: a "Forerunner 965" that is "connected", streams a deterministic heart-rate curve, and runs a scripted 2.5 s sync ring on pull-to-refresh.
5. Fake the focus tag: tapping the circle or the button starts/stops the mode directly (no NFC sheet).
6. All values fixed (no `random()`), "now" pinned so timers and charts render identically across takes.
7. **Brick rebrand (demo only):** the `BrickDevice` PNG is replaced with a plain circle, and every user-visible "Brick" string becomes "Focus" — tab label **Focus** (SF Symbol `circle`), "Tap to Focus", "Focused for 1:12:04", "Avg Focus Time", "My Tags", "Emergency Unlock". Mode names: "Deep Work", "Evenings", "Sunday Reset".

## Hero features → flows to record (in order)

### 1. Garmin fitness, straight from the watch
| Clip | What happens (3–8 s each) |
|---|---|
| `fitness-hero` | Fitness tab opens: watch render floats in, "THURSDAY, NOVEMBER 5" / "Forerunner 965", three rings fill — Readiness 86, Sleep 91, Body Battery 78. |
| `fitness-sync` | Pull to refresh → progress ring sweeps around the watch's face → "Synced just now". |
| `fitness-overview` | Slow scroll through the week strip ("5-day streak"), overview tiles and this morning's 10K run. |
| `fitness-sleep` | Tap the sleep tile → sleep page: 7h 48m, stage chart, score 91. |

### 2. Smart Hub controls
| Clip | What happens |
|---|---|
| `home-overview` | Home tab: device cards — Living Room lamps, Kitchen pendants, TV, Thermostat 70°, Front Door. |
| `home-lights` | Tap "Living Room" → it turns on; open its sheet and drag brightness 40% → 80%. |
| `home-lock-climate` | Tap Front Door → Locked; tap thermostat card. |
| `home-scene` (optional) | Automations sheet: "Good Morning" toggles on. |

### 3. Focus (Brick, unnamed in the film)
| Clip | What happens |
|---|---|
| `focus-start` | Focus tab: plain circle, "Ready to focus". Tap "Tap to Focus" → circle greys, title becomes "Deep Work", "Focused for 0:00:01…" ticks. |
| `focus-stats` | Stats: Today 2h 30m · 3 sessions · Daily avg 1h 54m; scroll to today's timeline card. |

Also stills of each hero screen in dark + light for the montage.

## Brand tokens
**App icon:** black, fluid "A" monogram on a white squircle (1024 px, `Assets.xcassets/AppIcon.appiconset/AppIcon.png`). Strong for a reveal on black — it'll read as a white tile.

**Accent:** `AccentColor` is empty; the real accent is `HubDesign.action`.

| Token | Light | Dark |
|---|---|---|
| page | `#F2F0EE` | `#161414` |
| surface (hero sheets) | `#FAF9F8` | `#211F1E` |
| raised (cards) | `#FFFFFF` | `#2C2928` |
| ink | `#262322` | `#F3EFED` |
| secondary | `#68615D` | `#B8B0AB` |
| separator | `#D8D2CE` | `#433D39` |
| track | `#E5E0DC` | `#393330` |
| **action (accent)** | `#005DB8` | **`#75B8FF`** |
| positive / warning / danger | `#236E34` / `#925000` / `#BC2832` | `#7FC990` / `#FFB75C` / `#FF8288` |
| Fitness: readiness · sleep · energy | `#1E9E4A` · `#4B23C2` · `#D9A300` | `#3DDC6E` · `#8B6CFF` · `#FFD60A` |
| Fitness: activity · heart · health | `#A35200` · `#CB2A2F` · `#8E44AD` | `#FF990A` · `#FF6166` · `#C58AF9` |

Character: warm neutrals (not cold grey), light-weight large titles, calm.

**Fonts:** app uses the system font (SF Pro) only, no custom fonts. Icons: SF Symbols + Tabler SVGs.

**Radii:** cards 24 pt continuous · controls/banners 12 pt · hero sheet bottom corners 52 pt (`64/2 + 20`) · capsules for pills/buttons.
**Spacing:** gutter 20 · section gap 24 · card padding 20 · top inset 12 · bottom inset 32 · inner gaps 4/8/12/16 · 44 pt hit targets.
**Motion:** quick 160 ms ease-out, standard 240 ms ease-in-out; restrained, Reduce-Motion aware.

## Film palette (proposed)
Pure black `#000` stage, warm off-white type `#F3EFED`, glow from accent `#75B8FF`, with each feature beat picking up its own data color for the glow: readiness green `#3DDC6E` (Fitness), accent blue (Home), warm white / neutral (Focus).

## Things to flag now
1. **Building.** Your saved preference is that I never run `xcodebuild` / simulator launches — but Phases 2–3 need me to build and record the simulator. I'd like a one-time exception for this project (Debug, simulator only).
2. **App Store slot.** The README says the Garmin code is AGPL, which conflicts with App Store distribution. The "Download on the App Store" end card and the optional `AppStorePreview` composition are fine as a placeholder, but you may not be able to ship it there. I'd suggest a neutral end line instead.
3. **Font licensing.** SF Pro isn't installed as a font on this Mac, and Apple's license limits it to UI mockups — not marketing video. I'll use **Inter** (SIL OFL), which is free for this.
4. **Music.** No track is provided. I'll build the timeline at a fixed BPM (e.g. 100) with beat markers; drop a licensed track in `demo-video/assets/music/` and I'll sync to it.
5. **Remotion license.** Free for individuals and companies of up to 3 people; nothing here needs a company license unless this is made for a larger company.
