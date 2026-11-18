import type { FitnessMetrics } from "./metrics.ts";
import { sleepScore } from "./physiology.ts";

/**
 * What the iPhone pushes into the Connect IQ glances' app settings after a
 * sync: the hub-only numbers (sleep score and stages, overnight HRV, load,
 * readiness, VO2max) that a Connect IQ app can't read on the watch.
 *
 * Every value is a 32-bit integer or a short string, because each key is a
 * Monkey C property with a fixed type (watch/glances/<App>/resources/
 * properties.xml). "No value" is -1 or "", never null, so a push always
 * overwrites the last one. Pure, so it can be tested with made-up nights.
 */

export type WatchNight = {
  /** When the hub built this, epoch seconds. */
  at: number;
  /** Last night's sleep window, epoch seconds; -1 without a recent night. */
  sStart: number;
  sEnd: number;
  /** The watch's sleep score when it gave one, else the hub's; -1 when unknown. */
  score: number;
  /** Minutes per stage. */
  deep: number;
  light: number;
  rem: number;
  awake: number;
  /** Overnight average RMSSD and its 7-night average, ms. */
  hrv: number;
  hrvWk: number;
  /** "balanced" | "unbalanced" | "low" | "poor" | "building" | "". */
  hrvSt: string;
};

export type WatchTraining = {
  at: number;
  /** Training readiness 1-100 and its band ("prime" ... "poor"); -1 / "" until there's enough data. */
  ready: number;
  readyLv: string;
  /** 7-day and 28-day-equivalent load, and "Optimal" | "High" | ... */
  acute: number;
  chronic: number;
  loadSt: string;
  /** Hours until recovered. */
  recH: number;
  /** VO2max × 10, so it fits an integer property; -1 without a qualifying run. */
  vo2: number;
};

export type WatchSettings = { v: 1; night: WatchNight; training: WatchTraining };

export type WatchSleepRow = {
  start: string; end: string;
  deepSeconds: number | null; lightSeconds: number | null; remSeconds: number | null; awakeSeconds: number | null;
  watchScore: number | null;
};

/** The watch's own HRV summary (an hrv_status FIT file), when one covers last night. */
export type WatchHrvRow = { day: string; lastNightAverage: number | null; weeklyAverage: number | null; status: string | null };

/** A night older than this isn't "last night" any more. */
const NIGHT_MAX_AGE = 20 * 3600_000;

const int = (value: number | null | undefined) => (value === null || value === undefined || !Number.isFinite(value) ? -1 : Math.round(value));
const minutes = (seconds: number | null) => (seconds === null ? -1 : Math.round(seconds / 60));

export function buildWatchSettings(input: {
  now: number;
  /** Newest night first. */
  sleep: WatchSleepRow[];
  /** Newest day first. */
  hrv: WatchHrvRow[];
  metrics: FitnessMetrics;
}): WatchSettings {
  const { now, metrics } = input;
  const at = Math.floor(now / 1000);
  const last = input.sleep.find((n) => now - Date.parse(n.end) < NIGHT_MAX_AGE && Date.parse(n.end) <= now + 3600_000);

  const score = last
    ? last.watchScore ?? sleepScore({
      start: 0, end: 0, deep: last.deepSeconds ?? 0, light: last.lightSeconds ?? 0, rem: last.remSeconds ?? 0, awake: last.awakeSeconds ?? 0,
    })
    : null;

  // Garmin's own overnight HRV beats the hub's estimate when the watch wrote one for the morning of last night.
  const wakeDay = last ? last.end.slice(0, 10) : null;
  const garmin = input.hrv.find((h) => h.lastNightAverage !== null && wakeDay !== null && Math.abs(Date.parse(h.day) - Date.parse(wakeDay)) <= 86_400_000);
  const hrv = garmin
    ? { last: garmin.lastNightAverage, week: garmin.weeklyAverage ?? metrics.hrv.weekly, status: (garmin.status ?? metrics.hrv.status).toLowerCase() }
    : { last: metrics.hrv.lastNight, week: metrics.hrv.weekly, status: metrics.hrv.lastNight === null && metrics.hrv.weekly === null ? "" : metrics.hrv.status };

  const hasLoad = metrics.load.acute > 0 || metrics.load.chronic > 0;
  return {
    v: 1,
    night: {
      at,
      sStart: last ? Math.floor(Date.parse(last.start) / 1000) : -1,
      sEnd: last ? Math.floor(Date.parse(last.end) / 1000) : -1,
      score: int(score),
      deep: last ? minutes(last.deepSeconds) : -1,
      light: last ? minutes(last.lightSeconds) : -1,
      rem: last ? minutes(last.remSeconds) : -1,
      awake: last ? minutes(last.awakeSeconds) : -1,
      hrv: int(hrv.last),
      hrvWk: int(hrv.week),
      hrvSt: hrv.status.slice(0, 12),
    },
    training: {
      at,
      ready: int(metrics.readiness.score),
      readyLv: metrics.readiness.level ?? "",
      acute: hasLoad ? int(metrics.load.acute) : -1,
      chronic: hasLoad ? int(metrics.load.chronic) : -1,
      loadSt: metrics.load.status ?? "",
      recH: int(metrics.load.recoveryHours),
      vo2: metrics.vo2max ? Math.round(metrics.vo2max.value * 10) : -1,
    },
  };
}
