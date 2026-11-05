# Armstrong Hub — launch film

A 57.6 s keynote-style film of the app, built in [Remotion](https://remotion.dev) from real Simulator footage of the app in demo mode.

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

**Copy:** `src/timeline.ts` → `COPY`. Keep each line to 6 words or fewer. The end card's small line is `endCaps`.

**Pacing:** `src/timeline.ts` → `SECTIONS`. Each section is a start bar and a length in bars (one bar is 2.4 s at 100 BPM).
- To make a beat longer, give it more bars and move the later sections back.
- `DURATION` is the film's length. Keep it at the bar after the last section.

**Which part of a clip plays:** `src/timeline.ts`.
- `FITNESS_SHOTS`, `HOME_SHOTS`, `FOCUS_SHOTS`: `trim` is the source second each shot starts at, and `duration` is how many frames it plays.
- The comments next to each shot say when its action happens in the source.

**Montage:** `MONTAGE` in `src/timeline.ts`. There's one entry per beat: a still from `public/stills/`, or a clip and the second to show from it.

**Music:**
1. Put a licensed track at `public/music.mp3`.
2. Set `BPM`, and `FIRST_BEAT_FRAME` if the song has a pickup, in `src/timeline.ts`. Every cut and every word moves to the new grid.
3. Add `<Audio src={staticFile('music.mp3')} />` (from `@remotion/media`) inside `LaunchFilm` in `src/LaunchFilm.tsx`.

**Look:**
- `src/theme.ts`: colors, easing curves, springs.
- `src/LaunchFilm.tsx` → `layout()`: type sizes and phone size, separately for 16:9 and 9:16.
- `src/components/`: one file per piece (`IPhoneFrame`, `HeadlineType`, `AppIconReveal`, `FeatureBeat`, `Montage`, `EndCard`, `Backdrop`).

## Re-recording the footage

1. Run demo mode with `scripts/launch_demo.sh`, or `scripts/rec.sh launch`. It's a Debug build with `-DemoMode YES`: in-app sample data, no network, no Bluetooth, NFC or Screen Time.
2. Record the flows with `scripts/record_flows.sh <flow> <take> [dark|light]`. `raw/CLIPS.md` lists them.
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
