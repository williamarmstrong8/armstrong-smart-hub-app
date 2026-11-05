/**
 * Every timing in the film, in one place. Change pacing here, not in the components.
 *
 * The film sits on a beat grid. With no licensed track yet it runs at 100 BPM, 4/4:
 * a beat is 0.6 s (18 frames at 30 fps), a bar 2.4 s (72 frames). To fit a song,
 * set BPM (and FIRST_BEAT_FRAME if the song has a pickup) and everything moves with it.
 */
export const FPS = 30;
export const BPM = 100;
export const BEATS_PER_BAR = 4;
/** Frame of the song's first downbeat (bar 1, beat 1). */
export const FIRST_BEAT_FRAME = 0;

export const BEAT = (60 / BPM) * FPS; // frames per beat (18 at 100 BPM)
export const BAR = BEAT * BEATS_PER_BAR; // frames per bar (72)

/** Frame at bar (1-based), beat (1-based) and a fraction of a beat: b(5, 3) is bar 5's third beat. */
export const b = (bar: number, beat = 1, fraction = 0) =>
  Math.round(FIRST_BEAT_FRAME + ((bar - 1) * BEATS_PER_BAR + (beat - 1) + fraction) * BEAT);

/** Length in frames of n bars. */
export const bars = (n: number) => Math.round(n * BAR);

// ─── Sections (start bar, length in bars) ──────────────────────────────────
export const SECTIONS = {
  coldOpen: { from: b(1), duration: bars(2) },
  reveal: { from: b(3), duration: bars(2) },
  fitnessTitle: { from: b(5), duration: bars(1) },
  fitness: { from: b(6), duration: bars(4) },
  homeTitle: { from: b(10), duration: bars(1) },
  home: { from: b(11), duration: bars(4) },
  focusTitle: { from: b(15), duration: bars(1) },
  focus: { from: b(16), duration: bars(3) },
  montage: { from: b(19), duration: bars(3) },
  endCard: { from: b(22), duration: bars(3) },
} as const;

export const DURATION = b(25); // 24 bars: 1728 frames, 57.6 s

// ─── Copy (keep each line to 6 words or fewer) ─────────────────────────────
export const COPY = {
  cold1: 'Five apps for one morning.',
  cold2: 'So I built one.',
  appName: 'Armstrong Hub',
  fitness: 'Straight from the watch.',
  fitnessCaps: 'GARMIN · NO CLOUD',
  home: 'Every light. One tap.',
  homeAccent: 'One tap.',
  homeCaps: 'AND THE FRONT DOOR',
  focus: 'Put the phone down.',
  tagline: 'Everything I care about. One app.',
  endCaps: 'A PERSONAL PROJECT · 2026',
};

// ─── Footage (public/clips, 30 fps). `trim` is the source second each shot starts at. ──
export type Shot = { src: string; trim: number; duration: number };

export const FITNESS_SHOTS: Shot[] = [
  { src: 'clips/fitness-hero.mp4', trim: 12.0, duration: bars(2) }, // rings fill at ~13.5 s
  { src: 'clips/fitness-sync.mp4', trim: 3.2, duration: bars(1) }, // ring sweeps the watch face
  { src: 'clips/fitness-sleep.mp4', trim: 2.6, duration: bars(1) }, // Sleep page pushes in at 3.0 s
];

export const HOME_SHOTS: Shot[] = [
  { src: 'clips/home-lights.mp4', trim: 2.8, duration: bars(3) }, // on 5.0, sheet 6.5, close 9.5
  { src: 'clips/home-lock.mp4', trim: 3.2, duration: bars(1) }, // locks at ~4.2 s
];

export const FOCUS_SHOTS: Shot[] = [
  { src: 'clips/focus-start.mp4', trim: 0.5, duration: bars(3) }, // tap at 2.5 s
];

/** Montage: one cut per beat, 12 beats. Images from public/stills, or a clip and its source second. */
export const MONTAGE: ({ still: string } | { clip: string; at: number })[] = [
  { still: 'stills/fitness-dark.jpg' },
  { still: 'stills/fitness-sleep-dark.jpg' },
  { still: 'stills/fitness-overview-dark.jpg' },
  { still: 'stills/home-light-sheet-dark.jpg' },
  { clip: 'clips/home-lock.mp4', at: 4.6 },
  { still: 'stills/home-habits-dark.jpg' },
  { still: 'stills/focus-on-dark.jpg' },
  { clip: 'clips/fitness-sync.mp4', at: 4.4 },
  { still: 'stills/home-light.jpg' },
  { still: 'stills/fitness-light.jpg' },
  { still: 'stills/fitness-metrics-dark.jpg' },
  { still: 'stills/focus-light.jpg' },
];

/** Frame within the Home section where the brightness glide starts; the glow warms toward orange there. */
export const HOME_BRIGHTNESS_AT = Math.round((7.0 - 2.8) * FPS);
/** Frame within the Home section where the door locks (shot 2 starts at bars(3)). */
export const HOME_LOCK_AT = bars(3) + Math.round((4.2 - 3.2) * FPS);
