/**
 * Every timing in the film, in one place. Change pacing here, not in the components.
 *
 * One phone stays on screen from the first second to the end card. Each section is one
 * continuous take of one tab, explored top to bottom and into its pages, and sections
 * crossfade into each other inside the phone. The words sit beside the phone.
 *
 * The takes in public/clips/*-tight.mp4 are the raw Simulator recordings with every pause
 * longer than 0.9 s shortened to 0.9 s (scripts/tighten.py); all motion is kept.
 *
 * Beat grid: 100 BPM, 4/4 (a beat is 0.6 s = 18 frames, a bar 2.4 s = 72 frames). To fit a
 * song, set BPM (and FIRST_BEAT_FRAME for a pickup).
 */
export const FPS = 30;
export const BPM = 100;
export const BEATS_PER_BAR = 4;
export const FIRST_BEAT_FRAME = 0;

export const BEAT = (60 / BPM) * FPS;
export const BAR = BEAT * BEATS_PER_BAR;

export const b = (bar: number, beat = 1, fraction = 0) =>
  Math.round(FIRST_BEAT_FRAME + ((bar - 1) * BEATS_PER_BAR + (beat - 1) + fraction) * BEAT);
export const bars = (n: number) => Math.round(n * BAR);
export const beats = (n: number) => Math.round(n * BEAT);
/** Frames for a number of seconds. */
export const sec = (s: number) => Math.round(s * FPS);

/** Playback speed of the shorter takes: a touch slower reads calmer. */
export const SLOW = 0.8;
/** Playback speed of the Fitness take. */
export const FIT = 0.9;

/** Crossfade between sections, inside the phone (frames). */
export const CROSSFADE = 15;

// ─── Copy (keep each line to 6 words or fewer) ─────────────────────────────
export const COPY = {
  cold1: 'Five apps for one morning.',
  cold2: 'So I built one.',
  appName: 'Armstrong Hub',
  tagline: 'Everything I care about. One app.',
  endCaps: 'A PERSONAL PROJECT · 2026',
};

// ─── Sections ──────────────────────────────────────────────────────────────
export type Section = {
  id: string;
  /** The words beside the phone. Omit for none (the open and reveal draw their own). */
  headline?: string;
  /** Part of the headline tinted with `color`. */
  accent?: string;
  /** Glow behind the phone, and the accent and caption color. */
  color: string;
  /** Phone tilt toward the words, in degrees (eases to 40 % through the section). */
  tilt: number;
  /** The take: a clip in public/clips, the source second to start at, how many frames to play, at what speed. */
  src: string;
  trim: number;
  duration: number;
  rate?: number;
  /** Small lines under the headline: [frame within the section, text]. Each holds until the next. */
  captions?: [number, string][];
};

export const SECTIONS: Section[] = [
  {
    id: 'open',
    color: '#75B8FF',
    tilt: -12,
    // Every tab, about one a second: the app is on screen from the first frame.
    src: 'clips/tab-tour.mp4',
    trim: 2.4,
    duration: bars(2),
  },
  {
    id: 'reveal',
    color: '#75B8FF',
    tilt: -10,
    // Fitness waits with empty rings; they fill as the next section starts.
    src: 'clips/fitness-hero.mp4',
    trim: 11.1,
    duration: bars(1),
  },
  {
    id: 'fitness',
    headline: 'Straight from the watch.',
    accent: 'watch.',
    color: '#3DDC6E',
    tilt: -10,
    // Rings fill → watch sync → every metric → a workout's sets → a live workout.
    src: 'clips/fitness-one-tight.mp4',
    trim: 3.0,
    rate: FIT,
    duration: sec(17.6 / FIT),
    captions: [
      [0, 'GARMIN · NO CLOUD'],
      [sec(2.6 / FIT), 'SYNCED OVER BLUETOOTH'],
      [sec(4.4 / FIT), 'EVERY METRIC'],
      [sec(7.6 / FIT), 'EVERY SET, WITH HEART RATE'],
      [sec(12.9 / FIT), 'LIVE WORKOUTS'],
    ],
  },
  {
    id: 'home',
    headline: 'Every light. One tap.',
    accent: 'One tap.',
    color: '#75B8FF',
    tilt: -9,
    // Light on → brightness → the front door locks → today's habits.
    src: 'clips/home-one-tight.mp4',
    trim: 0.5,
    rate: SLOW,
    duration: sec(5.1 / SLOW),
    captions: [
      [0, 'LIGHTS, DIMMED BY HAND'],
      [sec(3.0 / SLOW), "THE FRONT DOOR · TODAY'S HABITS"],
    ],
  },
  {
    id: 'finance',
    headline: 'Every dollar, tagged.',
    accent: 'tagged.',
    color: '#7FC990',
    tilt: -10,
    // Tag two in one tap → budgets and accounts → every transaction.
    src: 'clips/finance-one-tight.mp4',
    trim: 0.5,
    rate: SLOW,
    duration: sec(6.1 / SLOW),
    captions: [
      [0, 'TAG IN ONE TAP'],
      [sec(1.9 / SLOW), 'BUDGETS · ACCOUNTS'],
      [sec(4.2 / SLOW), 'EVERY TRANSACTION'],
    ],
  },
  {
    id: 'calendar',
    headline: 'The week, at a glance.',
    accent: 'week,',
    color: '#8B6CFF',
    tilt: -9,
    src: 'clips/calendar-one-tight.mp4',
    trim: 0.5,
    rate: SLOW,
    duration: sec(4.5 / SLOW),
    captions: [[0, 'TO-DOS · HABITS · AGENDA']],
  },
  {
    id: 'focus',
    headline: 'Put the phone down.',
    accent: 'down.',
    color: '#F3EFED',
    tilt: 0,
    // Tap the tag → Deep Work → today → the week.
    src: 'clips/focus-one-tight.mp4',
    trim: 0.5,
    rate: SLOW,
    duration: sec(5.3 / SLOW),
    captions: [
      [0, 'TAP YOUR TAG'],
      [sec(2.4 / SLOW), "TODAY'S FOCUS"],
      [sec(3.9 / SLOW), 'YOUR WEEK'],
    ],
  },
];

/** When each section starts: sections overlap by CROSSFADE so the next fades in over the last. */
export const SECTION_STARTS: Record<string, number> = (() => {
  const out: Record<string, number> = {};
  let at = 0;
  SECTIONS.forEach((s, i) => {
    out[s.id] = at;
    at += s.duration - (i < SECTIONS.length - 1 ? CROSSFADE : 0);
  });
  return out;
})();

const last = SECTIONS[SECTIONS.length - 1];
/** Where the phone's run ends and the end card begins. */
export const PHONE_END = SECTION_STARTS[last.id] + last.duration;

export const END_START = PHONE_END;
export const END_LENGTH = bars(3);
export const DURATION = END_START + END_LENGTH;
