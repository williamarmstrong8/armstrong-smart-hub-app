import { bodyBattery, currentVo2max, type Profile, recoveryRemaining, sleepScore, stressSeries } from "./physiology.ts";
import type { FitSummary } from "./summarize.ts";

/**
 * How close the hub's models come to the numbers the watch works out itself.
 * Every pair is (hub, watch) for the same moment, from the same stored files,
 * so a model change can be checked against the watch before it ships.
 *
 * Covered: training load, aerobic and anaerobic Training Effect, VO2max and
 * recovery time per activity; sleep score per night; stress and Body Battery
 * every 3 minutes of all-day wear. Pure, so it runs under `node --test`.
 */

export type Pair = { at: number; hub: number; watch: number };

export type Agreement = {
  n: number;
  /** Pearson correlation; null with fewer than 3 pairs or no spread. */
  r: number | null;
  /** Mean absolute error, in the metric's units. */
  mae: number | null;
  /** Mean of hub − watch: positive when the hub reads high. */
  bias: number | null;
};

export function agreement(pairs: Pair[]): Agreement {
  const n = pairs.length;
  if (n === 0) return { n, r: null, mae: null, bias: null };
  const mean = (values: number[]) => values.reduce((a, b) => a + b, 0) / values.length;
  const hub = pairs.map((p) => p.hub), watch = pairs.map((p) => p.watch);
  const mh = mean(hub), mw = mean(watch);
  let cov = 0, vh = 0, vw = 0;
  for (let i = 0; i < n; i++) {
    cov += (hub[i] - mh) * (watch[i] - mw);
    vh += (hub[i] - mh) ** 2;
    vw += (watch[i] - mw) ** 2;
  }
  const r = n >= 3 && vh > 0 && vw > 0 ? cov / Math.sqrt(vh * vw) : null;
  const round = (value: number, digits = 2) => Math.round(value * 10 ** digits) / 10 ** digits;
  return {
    n,
    r: r === null ? null : round(r, 3),
    mae: round(mean(pairs.map((p) => Math.abs(p.hub - p.watch)))),
    bias: round(mh - mw),
  };
}

export type CalibrationFile = { kind: string; summary: FitSummary };

export const METRICS = [
  "load", "aerobicEffect", "anaerobicEffect", "vo2max", "recoveryHours", "sleepScore", "stress", "bodyBattery",
] as const;
export type Metric = (typeof METRICS)[number];

const STEP = 180_000;

/** Pairs for every metric, from a set of summarized files. */
export function calibrationPairs(files: CalibrationFile[]): Record<Metric, Pair[]> {
  const pairs = Object.fromEntries(METRICS.map((m) => [m, [] as Pair[]])) as Record<Metric, Pair[]>;
  const add = (metric: Metric, at: number, hub: number | null | undefined, watch: number | null | undefined) => {
    if (hub !== null && hub !== undefined && watch !== null && watch !== undefined && Number.isFinite(hub) && Number.isFinite(watch)) {
      pairs[metric].push({ at, hub, watch });
    }
  };

  // Activities: the watch writes its own values into each activity file.
  const activities = files.map((f) => f.summary.activity).filter((a) => a !== null)
    .sort((a, b) => Date.parse(a.startTime) - Date.parse(b.startTime));
  const sessions: { at: number; load: number }[] = [];
  const runs: { at: number; vo2max: number; minutes: number }[] = [];
  for (const activity of activities) {
    const at = Date.parse(activity.startTime);
    const end = at + (activity.elapsedSeconds ?? 0) * 1000;
    const m = activity.metrics;
    add("load", at, m.load, m.watch.load);
    add("aerobicEffect", at, m.aerobicEffect, m.watch.trainingEffect);
    add("anaerobicEffect", at, m.anaerobicEffect, m.watch.anaerobicEffect);
    // The watch's VO2max moves slowly across runs, so compare it with the
    // hub's current value (recent runs weighted), not one run's estimate.
    if (m.vo2max !== null && m.vo2maxMinutes !== null) runs.push({ at, vo2max: m.vo2max, minutes: m.vo2maxMinutes });
    if (m.vo2max !== null) add("vo2max", at, currentVo2max(runs, at), m.watch.vo2max);
    // Recovery stacks across sessions on the watch too; loads are the watch's,
    // as metrics.ts uses them, so this scores the recovery model alone.
    const load = m.watch.load ?? m.load;
    if (load !== null) {
      sessions.push({ at: end, load });
      add("recoveryHours", at, recoveryRemaining(sessions, end + 1), m.watch.recoveryHours);
    }
  }

  // Sleep: the watch's own score sits next to the stages.
  for (const file of files) {
    const night = file.summary.sleep;
    if (!night) continue;
    add("sleepScore", Date.parse(night.end), sleepScore({
      start: Date.parse(night.start), end: Date.parse(night.end),
      deep: night.deepSeconds, light: night.lightSeconds, rem: night.remSeconds, awake: night.awakeSeconds,
    }), night.score);
  }

  // Stress and Body Battery: rerun the hub's models over the same heart rate
  // the watch scored, with the newest activity's heart profile.
  const profile = latestProfile(files);
  if (profile) {
    const windows = activities.map((a) => {
      const start = Date.parse(a.startTime);
      return { start, end: start + (a.elapsedSeconds ?? 0) * 1000 };
    });
    const sleeps = files.flatMap((f) => (f.summary.sleep ? [{ start: Date.parse(f.summary.sleep.start), end: Date.parse(f.summary.sleep.end) }] : []));
    const heartRate = dedupe(files.filter((f) => !f.summary.activity).flatMap((f) => f.summary.heartRate)
      .map((h) => ({ at: Date.parse(h.at), bpm: h.bpm })));
    const watchStress = buckets(files, "stress");
    const watchBattery = buckets(files, "body_battery");
    const points = stressSeries(heartRate, windows, profile, STEP);
    for (const p of points) if (p.value !== null) add("stress", p.at, p.value, watchStress.get(p.at));

    // The battery is a running level, so start the hub's at the watch's first
    // reading and score each wear stretch separately (gaps leave it stale).
    for (const stretch of stretches(points)) {
      const first = stretch.find((p) => watchBattery.has(p.at));
      if (!first) continue;
      const from = stretch.slice(stretch.indexOf(first));
      for (const level of bodyBattery(from, heartRate, sleeps, profile, watchBattery.get(first.at)!)) {
        add("bodyBattery", level.at, level.value, watchBattery.get(level.at));
      }
    }
  }
  return pairs;
}

export function calibrate(files: CalibrationFile[]): Record<Metric, Agreement> {
  const pairs = calibrationPairs(files);
  return Object.fromEntries(METRICS.map((m) => [m, agreement(pairs[m])])) as Record<Metric, Agreement>;
}

function latestProfile(files: CalibrationFile[]): Profile | null {
  let best: { at: number; profile: Profile } | null = null;
  for (const f of files) {
    const a = f.summary.activity;
    if (!a?.metrics.profile) continue;
    const at = Date.parse(a.startTime);
    if (!best || at > best.at) best = { at, profile: a.metrics.profile };
  }
  return best?.profile ?? null;
}

function dedupe(samples: { at: number; bpm: number }[]) {
  const seen = new Map<number, number>();
  for (const s of samples) seen.set(s.at, s.bpm);
  return [...seen].sort((a, b) => a[0] - b[0]).map(([at, bpm]) => ({ at, bpm }));
}

/** The watch's minute readings of one kind, averaged into the hub's 3-minute steps. */
function buckets(files: CalibrationFile[], kind: "stress" | "body_battery") {
  const sums = new Map<number, { total: number; count: number }>();
  for (const f of files) {
    for (const v of f.summary.vitals) {
      // Negative stress values are the watch's "couldn't measure" codes.
      if (v.kind !== kind || v.value < 0) continue;
      const key = Math.floor(Date.parse(v.at) / STEP) * STEP;
      const sum = sums.get(key) ?? { total: 0, count: 0 };
      sum.total += v.value;
      sum.count++;
      sums.set(key, sum);
    }
  }
  return new Map([...sums].map(([at, s]) => [at, s.total / s.count]));
}

/** Splits a series where there is more than 30 minutes without readings. */
function stretches<T extends { at: number }>(points: T[]): T[][] {
  const out: T[][] = [];
  for (const p of points) {
    const current = out[out.length - 1];
    if (current && p.at - current[current.length - 1].at <= 30 * 60_000) current.push(p);
    else out.push([p]);
  }
  return out;
}
