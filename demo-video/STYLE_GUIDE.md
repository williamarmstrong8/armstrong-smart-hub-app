# Style Guide: the visual rules for the film

Sources:
- `_reference/apple-wow-tutorial`: Remotion's Apple "Wow!" recreation. Every number marked **[wow]** below is copied from its code.
- The product-film skill kit. Numbers marked **[pf]**.
- The app's own design tokens (see APP_BRIEF.md). Marked **[app]**.

Where they disagree, the app's taste wins on color and surfaces, and the user's brief wins on glow/device/tilt.

## 1. Canvas & timing
| | Value |
|---|---|
| Primary | 1920×1080, **30 fps** [wow: `fps={30} width={1920} height={1080}`] |
| Vertical | 1080×1920, 30 fps |
| Background | Pure `#000000`. The reference uses `linear-gradient(to bottom, #000021, #110024)` [wow]. We use a much subtler version: `#000` → `#06070B` at the bottom, plus a radial accent glow behind the subject at ≤ 18 % opacity. |
| Grid | 100 BPM → beat 0.6 s = 18 frames, bar (4/4) 2.4 s = 72 frames. Every cue is `b(bar, beat, fraction)`, never a literal frame [pf]. |

## 2. Motion: easing & springs
**Rule: nothing is linear, nothing overshoots cheaply.** The only linear thing in the reference is its "Shrinking" scale-out (`interpolate(frame,[60,90],[1,0])` [wow]). We replace that with an ease-in.

| Name | Config | Use | Source |
|---|---|---|---|
| `weighted` | `spring({ damping: 200, durationInFrames: 120 })` (critically damped, no bounce, 4 s settle) | big object moves: phone rise, icon materialize, camera push | [wow] `Move.tsx` |
| `glide` | `{ stiffness: 150, damping: 20, mass: 1 }` (ζ≈0.82, a hint of settle, no visible bounce) | magic moves / travelers | [pf] `move.ts` |
| `critical(r)` | `stiffness r², damping 2r` | retargeting tracks (camera keys), r≈6 for slow, 10 for brisk | [pf] `spring.ts` |
| `land` | `cubic-bezier(0.22, 1, 0.36, 1)` over **0.3 s (9 f)** | each headline word: blur 16 px → 0, rise 36 px → 0 | [pf] punchlines |
| `exit` | ease-in `cubic-bezier(0.55, 0, 1, 0.45)` over 0.25 s, blur 0 → 12 px, opacity → 0 | words and phones leaving | [pf] (leave blur 12 px) |

**Time remap (the "wow" move).** `Slowed` integrates a speed curve: `interpolate(f, [0, 20, 21], [1.5, 1.5, 0.5])`, so the scene runs at 1.5× for 20 frames, then drops to 0.5× [wow]. It's a burst, then a slow-motion float. We use it on the icon reveal and the opening of each feature phone: a fast rise in, then a long slow drift.

**Trails / echoes.** `Trail` stacks 4 copies, each started 3 frames later (`Sequence from={i*3}`) and scaled `1 - i/amount` [wow]. Used once, on the icon reveal: 4 ghost rings at 8 % → 2 % opacity. Never on text.

**Radial burst.** `Explosion` rotates N=10 copies by `i/N·2π` [wow]. Used at most once (the reveal), as 10 soft accent particles that drift outward on `weighted` and fade. Optional; drop it if it reads cheap.

## 3. Camera
- **Push-in** on every feature phone: scale 1.00 → 1.06 over the whole beat on `weighted` (no end stop: the push is still moving at the cut).
- **3D tilt:** `perspective: 2400px`, `rotateY` from −14° → −6° and `rotateX` from 6° → 2° over the beat. It alternates side per feature (left phone tilts right, right phone tilts left).
- **Parallax:** headline layer moves 0.4× the phone's vertical drift; glow layer 0.2×.
- Hard cuts only on bars; within a bar, blur-swaps.

## 4. Typography
- **Font: Inter** (SIL OFL), Display optical size via `font-variation-settings: "opsz" 32`. SF Pro is not installed here and its license doesn't cover marketing video.
- Weights: 600 headline, 500 sub, 400 small caps label.
- Tracking: −0.035em at 140 px+, −0.02em at 64–120 px, +0.12em for caps labels.
- Line height 1.02 for headlines.

| Role | 1080p size | Vertical (1080w) |
|---|---|---|
| Cold-open line | 120 px | 104 px |
| Feature headline (2–5 words) | 140 px | 112 px |
| App name in reveal | 168 px | 132 px |
| Tagline / end line | 56 px, `#B8B0AB` | 48 px |
| Caps label | 24 px, +0.12em, `#B8B0AB` | 24 px |

- Color: ink `#F3EFED` [app dark ink]. Secondary `#B8B0AB` [app]. One accent word per line is allowed, in that beat's data color.
- Max ~6 words on screen. Each word keeps its slot, so lines never re-center while building [pf].

## 5. Color
| Token | Hex | Use |
|---|---|---|
| stage | `#000000` | background |
| ink | `#F3EFED` | type |
| soft | `#B8B0AB` | secondary type |
| accent | `#75B8FF` | app accent (dark `action`), reveal glow, Home beat |
| fitness | `#3DDC6E` | readiness green: Fitness beat glow |
| sleep | `#8B6CFF` | montage accents |
| focus | `#F3EFED` | Focus beat: warm white glow, deliberately colorless |

Glow = a radial gradient, color at 14–18 % alpha → transparent at 60 % radius, behind the phone. No other effects: no particles beyond the one optional burst, no lens flares.

**Grain/vignette:** vignette radial `rgba(0,0,0,0)` 55 % → `rgba(0,0,0,0.55)` 100 %. Grain is a per-frame noise texture (seeded by frame) at 3 % opacity, blend `overlay`. It's frame-pure.

## 6. iPhone frame (built in CSS/SVG)
iPhone 17 Pro proportions: screen 1206×2622 px (402×874 pt).
- Outer body corner radius ≈ **13.6 % of width**; screen radius = body radius − bezel.
- Bezel (black) 2.6 % of width; titanium edge = 3-stop linear gradient `#8A8D93 → #D9DBDF → #6E7177` at 1.1 % of width, with a 1 px inner highlight `rgba(255,255,255,.35)`.
- **Dynamic Island:** pill 31 % of screen width × 3.9 % of height, top offset 1.3 % of height, `#000`.
- Side buttons as 3 thin rounded rects on the titanium edge.
- Shadow: `0 60px 120px rgba(0,0,0,.6)`, plus the glow behind. Reflection: a copy flipped vertically below, 10 % opacity, masked by a linear fade over 18 % of its height.

## 7. Pacing rules
- One idea per beat. Every bar must have something moving [pf].
- Words land on beats (eighth-note spacing at fastest).
- Hold each finished headline ≥ 1 beat before the phone arrives.
- Every frame is a pure function of `frame`: no CSS transitions, no `Date.now()`, no timers [pf].
