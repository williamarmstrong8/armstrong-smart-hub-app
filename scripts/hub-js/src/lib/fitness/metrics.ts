import {
  bodyBattery, currentVo2max, type HrvStatus, hrvStatus, loadBalance, type Profile, type Readiness, readiness,
  recoveryRemaining, type StressPoint, sleepScore, stressSeries,
} from "./physiology.ts";
import type { WatchSnapshot } from "./watch-snapshot.ts";

/**
 * Puts the physiology models together over what the hub has stored: the
 * Fitness page's readiness, Body Battery, stress, VO2max, load and HRV.
 * Pure, so it can be tested with made-up days.
 */

export type MetricsInput = {
  now: number;
  /** End of the newest all-day data (defaults to now): "today" for stress and Body Battery is the 24 hours before it. */
  allDayEnd?: number;
  activities: {
    start: number; elapsedSeconds: number | null; load: number | null;
    vo2max: number | null; vo2maxMinutes: number | null; watchVo2max: number | null; profile: Profile | null;
  }[];
  /** Resting heart rate by day, newest first. */
  restingHr: number[];
  heartRate: { at: number; bpm: number }[];
  /** `score` is the watch's sleep score, when it gave one; the hub's is the fallback. */
  nights: { start: number; end: number; deep: number; light: number; rem: number; awake: number; score?: number | null }[];
  hrv: { at: number; value: number }[];
  vitals: { kind: string; at: number; value: number }[];
};

export type Source = "watch" | "hub";

export type FitnessMetrics = {
  profile: Profile | null;
  /** The hub's score stays in `hubScore` when the watch's replaces it. */
  readiness: Readiness & { hubScore?: number | null };
  bodyBattery: { current: number; charged: number; drained: number; series: { at: string; value: number }[] } | null;
  stress: { average: number | null; restMinutes: number; series: { at: string; value: number | null; kind: StressPoint["kind"] }[] } | null;
  vo2max: { value: number; asOf: string; watch: number | null; hub?: number | null; runs: { at: string; value: number; watch: number | null }[] } | null;
  load: { acute: number; chronic: number; ratio: number | null; recoveryHours: number; status: string | null };
  hrv: HrvStatus;
  vitals: { spo2: number | null; respiration: number | null; skinTemp: number | null };
  /** Where each headline number came from: the watch's firmware, or the hub's model. */
  sources?: Record<"readiness" | "recovery" | "vo2max" | "bodyBattery" | "stress", Source>;
};

const DAY = 86_400_000;
const iso = (ms: number) => new Date(ms).toISOString();
const avg = (values: number[]) => (values.length ? values.reduce((a, b) => a + b, 0) / values.length : null);

export function buildMetrics(input: MetricsInput): FitnessMetrics {
  const { now } = input;
  const base = input.activities.find((a) => a.profile)?.profile ?? null;
  // The newest week of daily resting heart rate beats the watch's profile setting.
  const resting = input.restingHr.slice(0, 7);
  const profile: Profile | null = base && {
    ...base,
    restingHr: resting.length ? Math.round(avg(resting)!) : base.restingHr,
  };

  // Load and recovery
  const sessions = input.activities.filter((a) => a.load !== null)
    .map((a) => ({ at: a.start + (a.elapsedSeconds ?? 0) * 1000, load: a.load! }));
  const balance = loadBalance(sessions, now);
  const recovery = recoveryRemaining(sessions, now);
  const status = balance.ratio === null ? null
    : balance.ratio < 0.8 ? "Detraining" : balance.ratio <= 1.3 ? "Optimal" : balance.ratio <= 1.5 ? "High" : "Overreaching";

  // VO2max
  const runs = input.activities.filter((a) => a.vo2max !== null && a.vo2maxMinutes !== null)
    .map((a) => ({ at: a.start, vo2max: a.vo2max!, minutes: a.vo2maxMinutes!, watch: a.watchVo2max }));
  const latestRun = runs.length ? Math.max(...runs.map((r) => r.at)) : null;
  // Measured at the last run: fitness doesn't jump just because no one ran.
  const vo2 = latestRun === null ? null : currentVo2max(runs, latestRun);

  // Sleep
  const nights = [...input.nights].sort((a, b) => b.end - a.end);
  const lastNight = nights[0] && now - nights[0].end < 18 * 3600_000 ? nights[0] : null;
  const scoreOf = (n: (typeof nights)[number]) => n.score ?? sleepScore(n);
  const recentScores = nights.filter((n) => now - n.end < 3 * DAY).map(scoreOf).filter((s): s is number => s !== null);

  // HRV: average each night's 5-minute RMSSD readings
  const hrvNights = nights.map((n) => {
    const values = input.hrv.filter((h) => h.at >= n.start - 3600_000 && h.at <= n.end).map((h) => h.value);
    return values.length ? { at: n.end, rmssd: avg(values)! } : null;
  }).filter((n): n is { at: number; rmssd: number } => n !== null);
  const hrv = hrvStatus(hrvNights, now);

  // Stress and Body Battery over the last 8 days (the battery needs a run-up to settle).
  const activityWindows = input.activities.map((a) => ({ start: a.start, end: a.start + (a.elapsedSeconds ?? 0) * 1000 }));
  const recentHr = input.heartRate.filter((h) => now - h.at < 8 * DAY);
  let stress: FitnessMetrics["stress"] = null;
  let battery: FitnessMetrics["bodyBattery"] = null;
  const dailyStress: number[] = [];
  const end = Math.min(input.allDayEnd ?? now, now);
  if (profile && recentHr.length > 0) {
    const points = stressSeries(recentHr, activityWindows, profile);
    for (let d = 1; d <= 3; d++) {
      const values = points.filter((p) => p.value !== null && end - p.at >= (d - 1) * DAY && end - p.at < d * DAY).map((p) => p.value!);
      // At least 8 hours of readings for the day to count.
      if (values.length >= 160) dailyStress.push(avg(values)!);
    }
    const today = points.filter((p) => end - p.at < DAY && p.at <= end);
    const scored = today.filter((p) => p.value !== null).map((p) => p.value!);
    stress = {
      average: scored.length ? Math.round(avg(scored)!) : null,
      restMinutes: today.filter((p) => p.kind === "rest").length * 3,
      series: today.map((p) => ({ at: iso(p.at), value: p.value, kind: p.kind })),
    };
    const levels = bodyBattery(points, recentHr, nights.map((n) => ({ start: n.start, end: n.end })), profile);
    const day = levels.filter((l) => end - l.at < DAY && l.at <= end);
    // Only trust it once there's most of a day of wear behind it.
    if (levels.length >= 240 && day.length > 0) {
      let charged = 0, drained = 0;
      for (let i = 1; i < day.length; i++) {
        const change = day[i].value - day[i - 1].value;
        if (change > 0) charged += change; else drained -= change;
      }
      battery = {
        current: day[day.length - 1].value, charged, drained,
        series: day.filter((_, i) => i % 5 === 0 || i === day.length - 1).map((l) => ({ at: iso(l.at), value: l.value })),
      };
    }
  }

  const latest = (kind: string) => {
    const reading = input.vitals.filter((v) => v.kind === kind && now - v.at < 2 * DAY).sort((a, b) => b.at - a.at)[0];
    return reading ? Math.round(reading.value * 10) / 10 : null;
  };

  return {
    profile,
    readiness: readiness({
      lastSleepScore: lastNight ? scoreOf(lastNight) : null,
      recoveryHours: recovery,
      hasTraining: sessions.some((s) => now - s.at < 28 * DAY),
      hrv,
      load: balance,
      recentSleepScores: recentScores,
      recentStress: dailyStress,
    }),
    bodyBattery: battery,
    stress,
    vo2max: vo2 === null ? null : {
      value: Math.round(vo2 * 10) / 10,
      asOf: iso(latestRun!),
      watch: runs.find((r) => r.at === latestRun)?.watch ?? null,
      runs: runs.sort((a, b) => a.at - b.at).map((r) => ({ at: iso(r.at), value: r.vo2max, watch: r.watch })),
    },
    load: { ...balance, recoveryHours: Math.round(recovery), status },
    hrv,
    vitals: { spo2: latest("spo2"), respiration: latest("respiration"), skinTemp: latest("skin_temp") },
  };
}

/**
 * The watch's firmware runs Firstbeat's real models with beat-to-beat data the
 * hub never sees, so where it has written a number the Fitness page shows
 * that one, and the hub's model (calibrated against it, see calibrate.ts) is
 * the fallback for anything the watch hasn't written yet. Stress and Body
 * Battery are the watch's 5-minute averages over the last day.
 */
export function preferWatch(
  metrics: FitnessMetrics,
  watch: WatchSnapshot,
  series: { stress: { at: number; value: number }[]; bodyBattery: { at: number; value: number }[] },
  now: number,
): FitnessMetrics {
  const sources: NonNullable<FitnessMetrics["sources"]> = { readiness: "hub", recovery: "hub", vo2max: "hub", bodyBattery: "hub", stress: "hub" };
  let { readiness, load, vo2max, bodyBattery, stress } = metrics;

  if (watch.readiness) {
    const level = watch.readiness.level;
    readiness = {
      ...readiness, hubScore: readiness.score, score: watch.readiness.score,
      level: level === "none" || level === null ? readiness.level : level,
    };
    sources.readiness = "watch";
  }
  if (watch.recovery) {
    load = { ...load, recoveryHours: Math.round(watch.recovery.remainingHours) };
    sources.recovery = "watch";
  }
  if (watch.vo2max) {
    vo2max = {
      value: watch.vo2max.value, asOf: watch.vo2max.at, watch: watch.vo2max.value, hub: vo2max?.value ?? null, runs: vo2max?.runs ?? [],
    };
    sources.vo2max = "watch";
  }

  const day = (points: { at: number; value: number }[]) => points.filter((p) => now - p.at < DAY).sort((a, b) => a.at - b.at);
  const battery = day(series.bodyBattery);
  // Only while the watch is being worn: a reading in the last 6 hours.
  if (battery.length > 1 && now - battery[battery.length - 1].at < 6 * 3600_000) {
    let charged = 0, drained = 0;
    for (let i = 1; i < battery.length; i++) {
      const change = battery[i].value - battery[i - 1].value;
      if (change > 0) charged += change; else drained -= change;
    }
    bodyBattery = {
      current: Math.round(battery[battery.length - 1].value), charged: Math.round(charged), drained: Math.round(drained),
      series: battery.map((p) => ({ at: iso(p.at), value: Math.round(p.value) })),
    };
    sources.bodyBattery = "watch";
  }
  const stressDay = day(series.stress);
  if (stressDay.length > 1 && now - stressDay[stressDay.length - 1].at < 6 * 3600_000) {
    stress = {
      average: Math.round(avg(stressDay.map((p) => p.value))!),
      restMinutes: stressDay.filter((p) => p.value <= 25).length * 5,
      series: stressDay.map((p) => ({ at: iso(p.at), value: Math.round(p.value), kind: p.value <= 25 ? "rest" as const : "stress" as const })),
    };
    sources.stress = "watch";
  }
  return { ...metrics, readiness, load, vo2max, bodyBattery, stress, sources };
}
