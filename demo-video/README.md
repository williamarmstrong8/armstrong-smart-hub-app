# Armstrong Hub — launch film

An 80 s keynote-style film of the app, built in [Remotion](https://remotion.dev) from real Simulator footage of the app in demo mode.

| File | What |
|---|---|
| `out/launch-film-1080p.mp4` | 1920×1080, 30 fps, H.264 (the main cut) |
| `out/launch-film-vertical.mp4` | 1080×1920 for social |
| `APP_BRIEF.md`, `STYLE_GUIDE.md`, `STORYBOARD.md` | the brief, the motion/type rules, the beat sheet |
| `raw/CLIPS.md` | every recorded clip, its take and the moments in it |

## Preview, render

```bash
cd demo-video
npm i
npm run studio          # Remotion Studio at http://localhost:3000
npm run render          # both MP4s into out/
```

## Change things yourself

Almost everything is in `src/timeline.ts`.

- **What the phone plays:** `SECTIONS`, one entry per part of the film (open, reveal, fitness, home, finance, calendar, focus). Each section has:
  - `headline`, the words beside the phone (6 words at most), and `accent`, the part tinted in the section's `color`
  - `color`, which also tints the glow behind the phone
  - `tilt`, the phone's angle in degrees
  - `shots`, played in order. Each shot has:
    - `src`, the clip in `public/clips/`
    - `trim`, the second of the clip to start at
    - `duration`, in frames; `beats(n)` and `bars(n)` help (one beat is 0.6 s)
    - `caption`, the small line under the headline
- **Making a part longer or shorter:** change its shots' `duration`. Every later section, and the film's length, follows automatically.
- **Cold open, name, end card:** `COPY`.
- **Montage:** `MONTAGE`. There's one cut per beat: a still from `public/stills/`, or a clip and the second to show from it.
- **Music:**
  1. Put a licensed track at `public/music.mp3`.
  2. Set `BPM`, and `FIRST_BEAT_FRAME` if the song has a pickup.
  3. Add `<Audio src={staticFile('music.mp3')} />` (from `@remotion/media`) inside `LaunchFilm` in `src/LaunchFilm.tsx`.
- **Look:**
  - `src/theme.ts`: colors, easing curves, springs.
  - `src/LaunchFilm.tsx` → `layout()`: where the phone and the words sit, and type sizes, separately for 16:9 and 9:16.
  - `src/components/`: `PhoneStage` (the one phone and its glow), `IPhoneFrame`, `HeadlineType`, `Montage`, `EndCard`, `Backdrop`.

## Re-recording the footage

1. Run demo mode with `scripts/launch_demo.sh`, or `scripts/rec.sh launch`. It's a Debug build with `-DemoMode YES`: in-app sample data, no network, no Bluetooth, NFC or Screen Time.
2. Record the flows with `scripts/record_flows.sh <flow> <take> [dark|light]`. `raw/CLIPS.md` lists them.
   - Each flow drives the app with cues (`scripts/cue.sh`): `tab`, `nav`, `back`, `scroll <y> <seconds>`, `sync`, `focus`, `tag`, `workout.start`, …
   - The Focus tag's NFC sheet is a stand-in drawn by the app in demo mode, because the Simulator has no NFC.
3. Convert the chosen takes to 30 fps into `public/clips/`:

```bash
ffmpeg -i raw/<take>.mp4 -vf "fps=30,scale=660:-2" -c:v libx264 -crf 16 -pix_fmt yuv420p -an public/clips/<name>.mp4
```

## Licenses
- **Remotion:** free for individuals and companies of up to 3 people, which covers this.
- **Font:** Inter (SIL Open Font License), loaded through `@remotion/google-fonts`.
- **Music:** none is bundled.
- **Footage:** all screens are the app's own UI, with made-up demo data.
- **Watch image:** the Garmin watch render (`GarminHero`) inside the app's Fitness screen is the app's own asset. Check you're comfortable showing it before sharing the film widely.
