/**
 * Every timing in the film, in one place. Change pacing here, not in the components.
 *
 * The film sits on a beat grid. With no licensed track yet it runs at 100 BPM, 4/4:
 * a beat is 0.6 s (18 frames at 30 fps), a bar 2.4 s (72 frames). To fit a song,
 * set BPM (and FIRST_BEAT_FRAME if the song has a pickup) and everything moves with it.
 *
 * Structure: one phone stays on screen from the first second to the montage, playing a
 * run of shots; the left column (top, in the vertical cut) carries the words for each
 * section and a small caption for each shot.
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

/** Length in frames of n bars, or of n beats. */
export const bars = (n: number) => Math.round(n * BAR);
export const beats = (n: number) => Math.round(n * BEAT);

// ─── Copy (keep each line to 6 words or fewer) ─────────────────────────────
export const COPY = {
  cold1: 'Five apps for one morning.',
  cold2: 'So I built one.',
  appName: 'Armstrong Hub',
  tagline: 'Everything I care about. One app.',
  endCaps: 'A PERSONAL PROJECT · 2026',
};

// ─── The phone's shots, in order ───────────────────────────────────────────
// `trim` is the source second (public/clips, 30 fps) the shot starts at; `duration` is frames.
// `caption` is the small line under the section's headline while the shot plays.
export type Shot = { src: string; trim: number; duration: number; caption?: string };

export type Section = {
  id: string;
  /** The words beside the phone. Omit for none (the cold open and reveal draw their own). */
  headline?: string;
  /** A word or phrase in the headline to tint with the section's color. */
  accent?: string;
  /** Glow behind the phone. */
  color: string;
  /** Phone tilt toward the words, in degrees at the section's start (eases to 40 % of it). */
  tilt: number;
  shots: Shot[];
};

export const SECTIONS: Section[] = [
  {
    id: 'open',
    color: '#75B8FF',
    tilt: -12,
    // Every tab, one per beat-and-a-bit: the app is on screen from the first second.
    shots: [{ src: 'clips/tab-tour.mp4', trim: 2.4, duration: bars(2) }],
  },
  {
    id: 'reveal',
    color: '#75B8FF',
    tilt: -10,
    // The Fitness tab waits with empty rings; they fill on the next section's first beat.
    shots: [{ src: 'clips/fitness-hero.mp4', trim: 11.1, duration: bars(1) }],
  },
  {
    id: 'fitness',
    headline: 'Straight from the watch.',
    accent: 'watch.',
    color: '#3DDC6E',
    tilt: -10,
    shots: [
      { src: 'clips/fitness-hero.mp4', trim: 13.5, duration: beats(3), caption: 'GARMIN · NO CLOUD' },
      { src: 'clips/fitness-sync.mp4', trim: 3.2, duration: beats(3), caption: 'SYNCED OVER BLUETOOTH' },
      { src: 'clips/fitness-scroll2.mp4', trim: 2.6, duration: beats(7), caption: 'EVERY METRIC' },
      { src: 'clips/fitness-pages.mp4', trim: 4.7, duration: beats(3.33), caption: 'SLEEP' },
      { src: 'clips/fitness-pages.mp4', trim: 8.9, duration: beats(4.67), caption: 'HEART RATE' },
      { src: 'clips/fitness-pages.mp4', trim: 14.8, duration: beats(4.67), caption: 'VO2 MAX · RACE TIMES' },
      { src: 'clips/fitness-workout.mp4', trim: 4.7, duration: beats(5.33), caption: 'EVERY SET, WITH HEART RATE' },
      { src: 'clips/fitness-workout.mp4', trim: 10.9, duration: beats(5), caption: 'LIVE WORKOUTS' },
    ],
  },
  {
    id: 'home',
    headline: 'Every light. One tap.',
    accent: 'One tap.',
    color: '#75B8FF',
    tilt: -9,
    shots: [
      { src: 'clips/home-lights.mp4', trim: 3.4, duration: beats(10.67), caption: 'LIGHTS, DIMMED BY HAND' },
      { src: 'clips/home-lock.mp4', trim: 3.2, duration: beats(4), caption: 'AND THE FRONT DOOR' },
      { src: 'clips/home-scroll.mp4', trim: 1.6, duration: beats(5.33), caption: "TODAY'S HABITS" },
    ],
  },
  {
    id: 'finance',
    headline: 'Every dollar, tagged.',
    accent: 'tagged.',
    color: '#7FC990',
    tilt: -10,
    shots: [
      { src: 'clips/finance-tour.mp4', trim: 2.6, duration: beats(9.33), caption: 'TAG IN ONE TAP' },
      { src: 'clips/finance-tour.mp4', trim: 11.6, duration: beats(4.67), caption: 'BUDGETS · ACCOUNTS' },
      { src: 'clips/finance-tour.mp4', trim: 15.0, duration: beats(6), caption: 'EVERY TRANSACTION' },
    ],
  },
  {
    id: 'calendar',
    headline: 'The week, at a glance.',
    accent: 'week,',
    color: '#8B6CFF',
    tilt: -9,
    shots: [{ src: 'clips/calendar-tour.mp4', trim: 1.2, duration: bars(3), caption: 'TO-DOS · HABITS · AGENDA' }],
  },
  {
    id: 'focus',
    headline: 'Put the phone down.',
    accent: 'down.',
    color: '#F3EFED',
    tilt: 0,
    shots: [
      { src: 'clips/focus-tour.mp4', trim: 2.2, duration: beats(5.67), caption: 'TAP YOUR TAG' },
      { src: 'clips/focus-tour.mp4', trim: 7.8, duration: beats(3), caption: "TODAY'S FOCUS" },
      { src: 'clips/focus-tour.mp4', trim: 10.7, duration: beats(3), caption: 'YOUR WEEK' },
      { src: 'clips/focus-tour.mp4', trim: 15.4, duration: beats(4.33), caption: 'TAP AGAIN TO END' },
    ],
  },
];

/** A section's length in frames. */
export const sectionLength = (s: Section) => s.shots.reduce((n, shot) => n + shot.duration, 0);

/** When each section starts (frame), in order. */
export const SECTION_STARTS: Record<string, number> = (() => {
  const out: Record<string, number> = {};
  let at = 0;
  for (const s of SECTIONS) {
    out[s.id] = at;
    at += sectionLength(s);
  }
  return out;
})();

/** Where the phone's run ends and the montage begins. */
export const PHONE_END = SECTIONS.reduce((n, s) => n + sectionLength(s), 0);

/** Montage: one cut per beat. A still from public/stills, or a clip and its source second. */
export const MONTAGE: ({ still: string } | { clip: string; at: number })[] = [
  { still: 'stills/fitness-dark.jpg' },
  { clip: 'clips/finance-tour.mp4', at: 13.4 },
  { clip: 'clips/calendar-tour.mp4', at: 6.4 },
  { still: 'stills/home-light-sheet-dark.jpg' },
  { clip: 'clips/focus-tour.mp4', at: 11.6 },
  { clip: 'clips/fitness-pages.mp4', at: 10.4 },
  { clip: 'clips/fitness-workout.mp4', at: 14.0 },
  { still: 'stills/home-light.jpg' },
];
export const MONTAGE_START = PHONE_END;
export const MONTAGE_LENGTH = MONTAGE.length * BEAT;

export const END_START = MONTAGE_START + MONTAGE_LENGTH;
export const END_LENGTH = bars(2.5);
export const DURATION = END_START + END_LENGTH;

/** Within the Home section: when the brightness glide starts (the glow warms) and when the door locks. */
export const HOME_BRIGHTNESS_AT = Math.round((7.0 - 3.4) * FPS);
export const HOME_LOCK_AT = beats(10.67) + Math.round((4.2 - 3.2) * FPS);
