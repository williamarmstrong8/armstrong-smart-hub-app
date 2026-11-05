# Storyboard — "Armstrong Hub" (personal-project film)

**Framing:** the film shows something I built for my own life, not a store listing. It's honest and personal, aimed at non-technical builders, and the subtext is "you could build yours."
**Length:** 57.6 s, which is 24 bars at 100 BPM. A beat is 0.6 s (18 frames at 30 fps) and a bar is 2.4 s (72 frames). Every cue in `timeline.ts` is written as `b(bar, beat)`.
**Music:** none is licensed yet. I'll build to the 100 BPM grid with a silent master. A track you drop in later gets beat-detected, and the grid snaps to it.
**Rules** (from STYLE_GUIDE.md):
- pure black stage, Inter 600, at most 6 words on screen
- one idea per beat
- `weighted` spring (`damping: 200`) for big moves, `land` curve `cubic-bezier(0.22,1,0.36,1)` for words
- hard cuts only on bars
- the glow takes each feature's data color

## Beat sheet

| # | Time | Bars | On-screen text | Visual | Camera / motion | Transition out |
|---|---|---|---|---|---|---|
| 1 | 0.0 – 2.4 | 1 | **Five apps for one morning.** | Black. The words land one per beat on the 8ths, blurring in from 16 px and rising 36 px each. | Static. The text layer drifts up 12 px over the bar. | Words blur out, ease-in, 0.25 s |
| 2 | 2.4 – 4.8 | 2 | **So I built one.** | Black with a faint radial glow in `#75B8FF` (8 %) that blooms behind the words | Speed-ramp feel: words arrive fast and settle slow | Hard cut on the bar |
| 3 | 4.8 – 7.2 | 3 | — | **Icon reveal.** The white "A" tile materializes at the center: scale 0.6 → 1 on `weighted` with the 1.5× → 0.5× speed remap. Four ghost echo rings, 3 f apart, fade from 8 % to 0. A soft blue glow sits behind it. | Push 1.00 → 1.04 | The icon glides up and shrinks into the lockup |
| 4 | 7.2 – 9.6 | 4 | **Armstrong Hub** | The wordmark at 168 px sits under the icon. Letters keep their slots and land on beats 1–2. | Slow push continues | Blur-swap to black, then cut |
| 5 | 9.6 – 12.0 | 5 | **Straight from the watch.** | Headline only, with a green `#3DDC6E` glow rising from below | Text parallax 0.4× | The headline slides up and off as the phone rises |
| 6 | 12.0 – 16.8 | 6–7 | small caps: *GARMIN · NO CLOUD* | **Phone** (my CSS iPhone 18 Pro frame) plays `fitness-hero` from the moment the empty rings fill to 86 / 91 / 78. The phone rises from y +240 on `weighted`. | `rotateY −14° → −6°`, `rotateX 6° → 2°`, push 1.00 → 1.06, soft reflection underneath | Hard cut on bar 8 |
| 7 | 16.8 – 19.2 | 8 | — | Same phone, now playing `fitness-sync`: the ring sweeps the watch face | The phone holds its pose while the push keeps going | Match cut |
| 8 | 19.2 – 21.6 | 9 | — | Same phone, now playing `fitness-sleep`: the Sleep page pushes in (91, Optimal) | Slight drift right | Blur-swap |
| 9 | 21.6 – 24.0 | 10 | **Every light. One tap.** | Headline with a blue `#75B8FF` glow. "One tap." lands on beat 3, accent-colored. | — | Headline lifts away |
| 10 | 24.0 – 31.2 | 11–13 | — | **Phone** (tilted the opposite way, from the right) plays `home-lights`: Living Room turns on, the sheet opens, brightness glides up, and the card reads 85 % | `rotateY +14° → +6°`, push 1.00 → 1.06. At the brightness glide the glow warms toward orange `#FF990A`. | Hard cut on bar 14 |
| 11 | 31.2 – 33.6 | 14 | small caps: *AND THE FRONT DOOR* | Same phone, now playing `home-lock`: red Unlocked → grey Locked | Quick push 1.06 → 1.10 on the lock moment | Cut to black |
| 12 | 33.6 – 36.0 | 15 | **Put the phone down.** | Headline in warm white with a colorless glow | Very slow, the calmest beat in the film | Blur-swap |
| 13 | 36.0 – 43.2 | 16–18 | — | **Phone** centered and dead straight (no tilt, on purpose) plays `focus-start`: the circle becomes a ring, "Deep Work" appears, and the timer starts | Push 1.00 → 1.05 only. The quiet is the point. | Hard cut on bar 19 |
| 14 | 43.2 – 50.4 | 19–21 | — | **Montage:** 12 cuts, one per beat (0.6 s each), from stills and clips in dark and light: rings → sleep → metrics list → light sheet → lock → habits → focus ring → watch sync → light-mode Home → light-mode Fitness → steps → Deep Work. Each is a full-bleed screen in a flat (no-tilt) phone, alternating 0.9× and 1.0× scale. | A 2 % scale pop on every cut | The last cut holds into bar 22 |
| 15 | 50.4 – 57.6 | 22–24 | **Armstrong Hub** / *Everything I care about. One app.* / small caps: *A PERSONAL PROJECT · 2026* | End card: the icon above the wordmark, the tagline in `#B8B0AB` at 56 px, and the small-caps line at the bottom. The film's neutral close, with no App Store badge. | Icon and wordmark drift up 8 px over 3 bars. The glow fades to 0 over the last bar. | Fade to black over the final 0.5 s |

## Copy (all lines, max 6 words)
1. Five apps for one morning.
2. So I built one.
3. Armstrong Hub
4. Straight from the watch. *(caps: GARMIN · NO CLOUD)*
5. Every light. One tap. *(caps: AND THE FRONT DOOR)*
6. Put the phone down.
7. Everything I care about. One app.
8. *(caps)* A PERSONAL PROJECT · 2026

I chose these lines because they're true of the app and need no explaining:
- **Fitness:** it reads the watch directly, with no Garmin Connect in between.
- **Home:** lights and locks are tap-to-toggle.
- **Focus:** the copy describes the outcome and never names the feature ("Brick" doesn't appear anywhere).

## Device and depth
- **Phone frame:** my own CSS/SVG iPhone 18 Pro. It has a titanium edge gradient, a black bezel, a Dynamic Island pill, side buttons, and a screen corner radius of 13.6 % of its width.
- **Screen:** the 1206×2622 clip, scaled to fit.
- **Phone size:** about 820 px tall in 1080p, so plenty of black around it.
- **Depth:** an accent glow behind each phone (14–18 %), a drop shadow `0 60px 120px rgba(0,0,0,.6)`, and a 10 % reflection.
- **Finish:** a vignette, plus 3 % seeded grain that's frame-pure.

## Vertical cut (1080×1920)
- Same timeline and copy.
- Headlines sit in the top third, at 112 px.
- The phone is larger (about 1250 px tall), centered in the lower two-thirds, with the tilt halved.
- The montage uses full-bleed screens without the frame.

## App Store preview
Dropped, per your note. This is a personal film, not a store listing.

## Things that would change the feel
- **A track with a clear drop:** I'd move the icon reveal (beat 3) onto it, and the montage would cut on its hi-hats.
- **Your own name on the end card:** the small-caps line could read "Built by William Armstrong" instead of "A personal project".
