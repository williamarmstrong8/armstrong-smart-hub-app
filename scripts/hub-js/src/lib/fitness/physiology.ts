/**
 * The hub's own physiology models, computed from what the watch records
 * instead of the numbers Garmin's firmware works out. Garmin licenses these
 * from Firstbeat and publishes the inputs and score bands but not the math, so
 * each model here follows the published method where there is one and is
 * calibrated against the values the watch writes into its own files.
 *
 * Pure functions, no dependencies, so they run under `node --test`.
 */

export type Profile = {
  maxHr: number;
  restingHr: number;
  /** "male" or "female", for the TRIMP weighting; null uses the average. */
  sex: "male" | "female" | null;
  /** From the watch's user profile, when it has them. */
  age?: number | null;
  heightCm?: number | null;
  weightKg?: number | null;
};

/** One second-ish sample from an activity: seconds from start, bpm, m/s, metres. */
export type Sample = { t: number; hr: number | null; speed: number | null; altitude: number | null; distance: number | null };

/** Share of heart rate reserve: 0 at resting, 1 at max. */
export function hrr(hr: number, profile: Profile): number {
  return (hr - profile.restingHr) / Math.max(1, profile.maxHr - profile.restingHr);
}

const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value));
const median = (values: number[]) => {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};
const mean = (values: number[]) => (values.length ? values.reduce((a, b) => a + b, 0) / values.length : null);

// MARK: VO2max

/**
 * VO2max from one outdoor run, the way Firstbeat describes it: compare heart
 * rate with speed at many points of the run, keep only steady, reliable
 * stretches, and extrapolate the relationship to maximal heart rate.
 *
 * Each 60 s window where pace and heart rate are steady, the ground is
 * roughly flat and effort is solidly aerobic (60-95 % of heart rate reserve,
 * where the heart rate/oxygen relationship is most linear) gives one
 * estimate: oxygen cost from the ACSM running equation
 * (VO2 = 3.5 + 0.2·v + 0.9·v·grade, v in m/min), divided by the share of
 * VO2 reserve in use, which tracks the share of heart rate reserve
 * (Swain & Leutholtz 1997). The first 5 minutes are skipped while heart rate
 * catches up. Needs 8 good minutes; returns the median and how many minutes
 * backed it.
 */
export function runVo2max(samples: Sample[], profile: Profile, minMinutes = 8): { vo2max: number; minutes: number } | null {
  const points = samples.filter((s) => s.t >= 300 && s.hr !== null && s.speed !== null);
  if (points.length < 15 * minMinutes) return null;
  const estimates: number[] = [];
  let start = 0;
  for (let end = 0; end < points.length; end++) {
    while (points[end].t - points[start].t > 60) start++;
    if (points[end].t - points[start].t < 55) continue;
    const window = points.slice(start, end + 1);
    const speeds = window.map((p) => p.speed!);
    const hrs = window.map((p) => p.hr!);
    const speed = mean(speeds)!;
    const hr = mean(hrs)!;
    if (speed < 1.8 || speed > 7) continue;
    if (Math.max(...speeds) - Math.min(...speeds) > 0.25 * speed) continue;
    if (Math.max(...hrs) - Math.min(...hrs) > 8) continue;
    const share = hrr(hr, profile);
    if (share < 0.6 || share > 0.95) continue;
    let grade = 0;
    const first = window[0], last = window[window.length - 1];
    if (first.altitude !== null && last.altitude !== null && first.distance !== null && last.distance !== null && last.distance - first.distance > 50) {
      grade = (last.altitude - first.altitude) / (last.distance - first.distance);
    }
    if (Math.abs(grade) > 0.04) continue;
    const v = speed * 60;
    const vo2 = 3.5 + 0.2 * v + 0.9 * v * Math.max(grade, 0);
    estimates.push(3.5 + (vo2 - 3.5) / share);
    // Step to the next non-overlapping window.
    start = end + 1;
  }
  if (estimates.length < minMinutes) return null;
  return { vo2max: median(estimates)!, minutes: estimates.length };
}

/**
 * Current VO2max from recent runs: each run's estimate weighted by the
 * minutes behind it, halving every 30 days. Runs older than 120 days don't count.
 */
export function currentVo2max(runs: { at: number; vo2max: number; minutes: number }[], now: number): number | null {
  let weight = 0, total = 0;
  for (const run of runs) {
    const days = (now - run.at) / 86_400_000;
    if (days < 0 || days > 120) continue;
    const w = run.minutes * 0.5 ** (days / 30);
    weight += w;
    total += w * run.vo2max;
  }
  return weight > 0 ? total / weight : null;
}

// MARK: Training load (EPOC)

/**
 * Exercise load as an EPOC estimate (excess post-exercise oxygen
 * consumption, ml/kg), the quantity Garmin's training load sums. Firstbeat
 * models EPOC second by second from intensity (%VO2max) and its own previous
 * value, and takes the session's peak; it rises fast at high intensity and
 * stops growing, then falls, when effort eases.
 *
 * Here intensity is the share of heart rate reserve and EPOC follows
 * dE/dt = A·e^(B·i) − E/τ (per minute), so a steady effort settles at a level
 * set by its intensity and easy stretches let it fall back. A, B and τ were
 * fitted to the loads this watch wrote for 115 activities (r = 0.91) (see the test file
 * for the check).
 */
export const EPOC = { A: 0.074, B: 6.5, TAU: 18 };

export function epocPeak(heartRate: [number, number][], profile: Profile): number {
  let epoc = 0, peak = 0;
  for (let i = 1; i < heartRate.length; i++) {
    const dt = (heartRate[i][0] - heartRate[i - 1][0]) / 60;
    if (dt <= 0 || dt > 5) continue;
    const intensity = clamp(hrr((heartRate[i][1] + heartRate[i - 1][1]) / 2, profile), 0, 1.05);
    const growth = EPOC.A * Math.exp(EPOC.B * intensity);
    // Exact step of the linear ODE, stable for any dt.
    const settle = growth * EPOC.TAU;
    epoc = settle + (epoc - settle) * Math.exp(-dt / EPOC.TAU);
    peak = Math.max(peak, epoc);
  }
  return peak;
}

/**
 * Hours until recovered from one session: about 0.3 h per load point (a
 * 100-load run, about a day), capped at 96 like Garmin's. Refit 2026-10-19 on
 * 135 activities with sessions stacked as in recoveryRemaining and the
 * watch's own loads: r = 0.93 against the watch's recovery time, off by 6 h
 * on average (calibrate.ts).
 */
export const RECOVERY = { PER_LOAD: 0.3, CARRY: 0.8 };

export function recoveryHours(load: number): number {
  return clamp(RECOVERY.PER_LOAD * load, 0, 96);
}

/**
 * Recovery still to go at `now`: sessions stack, with a new session adding
 * its own recovery on top of most of what was left (Garmin adds, it doesn't take the max).
 */
export function recoveryRemaining(sessions: { at: number; load: number }[], now: number): number {
  let remaining = 0;
  let last: number | null = null;
  for (const session of [...sessions].sort((a, b) => a.at - b.at)) {
    if (session.at > now) break;
    if (last !== null) remaining = Math.max(0, remaining - (session.at - last) / 3_600_000);
    remaining = Math.min(96, remaining * RECOVERY.CARRY + recoveryHours(session.load));
    last = session.at;
  }
  if (last === null) return 0;
  return Math.max(0, remaining - (now - last) / 3_600_000);
}

/**
 * Acute load: the last 7 days of EPOC, each day weighted so yesterday counts
 * more than a week ago (exponential, like Garmin's 7-day acute load).
 * Chronic load: the same over 28 days, scaled to a week. Their ratio is the
 * acute:chronic workload ratio; 0.8-1.5 is the usual safe band.
 */
export function loadBalance(sessions: { at: number; load: number }[], now: number) {
  const ewma = (days: number) => {
    const lambda = 2 / (days + 1);
    let acc = 0;
    for (let d = days * 2; d >= 0; d--) {
      const dayEnd = now - d * 86_400_000;
      const dayLoad = sessions.filter((s) => s.at <= dayEnd && s.at > dayEnd - 86_400_000).reduce((a, s) => a + s.load, 0);
      acc = lambda * dayLoad + (1 - lambda) * acc;
    }
    return acc * 7; // daily average, scaled to a week
  };
  const acute = ewma(7);
  const chronic = ewma(28);
  return { acute: Math.round(acute), chronic: Math.round(chronic), ratio: chronic > 20 ? acute / chronic : null };
}

// MARK: Sleep score

export type Night = {
  start: number; end: number; deep: number; light: number; rem: number; awake: number;
  /** The watch's average stress over the night (0-100), when the hub has it. */
  stress?: number | null;
};

/**
 * A 0-100 sleep score, the fallback for nights the watch gives none. Garmin's
 * score weighs duration, stage balance, time awake and how restful the night
 * was (its "recovery" part follows overnight stress). Here each part is
 * scored 0-100 and the weights are fitted to the 27 scores this watch wrote
 * (2026-11-13, after the stage fix in summarize.ts):
 *
 * - duration: 13 points an hour from 1 hour, then 22 an hour from 7, full at 8;
 * - deep and REM: share of sleep against the bottom of Garmin's healthy
 *   ranges (16 % and 21 %);
 * - awake: full marks under 5 minutes, none past an hour;
 * - stress: full marks at an overnight average of 15 or under, none at 50.
 *
 * With overnight stress: r = 0.99 against the watch, off by 1.6 on average
 * (2.2 leaving each night out in turn). Without it (no all-day file for the
 * night): r = 0.97, off by 3.8.
 */
export const SLEEP_SCORE = {
  withStress: { duration: 0.344, deep: 0.131, rem: 0.158, awake: 0.019, stress: 0.261 },
  stagesOnly: { duration: 0.551, deep: 0.021, rem: 0.064, awake: 0.263 },
};

export function sleepScore(night: Night): number | null {
  const asleep = night.deep + night.light + night.rem;
  if (asleep < 3600) return null;
  const hours = asleep / 3600;
  const duration = hours < 7 ? clamp(13 * (hours - 1), 0, 78) : clamp(78 + 22 * (hours - 7), 0, 100);
  const deep = clamp(night.deep / asleep / 0.16, 0, 1) * 100;
  const rem = clamp(night.rem / asleep / 0.21, 0, 1) * 100;
  const awake = 100 * (1 - clamp((night.awake / 60 - 5) / 55, 0, 1));
  if (night.stress !== null && night.stress !== undefined) {
    const w = SLEEP_SCORE.withStress;
    const stress = 100 * (1 - clamp((night.stress - 15) / 35, 0, 1));
    return Math.round(clamp(w.duration * duration + w.deep * deep + w.rem * rem + w.awake * awake + w.stress * stress, 0, 100));
  }
  const w = SLEEP_SCORE.stagesOnly;
  return Math.round(clamp(w.duration * duration + w.deep * deep + w.rem * rem + w.awake * awake, 0, 100));
}

// MARK: HRV status

export type HrvStatus = {
  /** Last night's average RMSSD, ms. */
  lastNight: number | null;
  /** The last 7 nights' average, ms. */
  weekly: number | null;
  /** The balanced range from the 3 weeks before, ms. */
  baseline: { low: number; high: number } | null;
  status: "balanced" | "unbalanced" | "low" | "building";
  /** How far the weekly average sits from baseline, in baseline SDs (log scale). */
  z: number | null;
};

/**
 * HRV status from overnight RMSSD, the way the research it rests on does it
 * (Plews et al., Kiviniemi et al.): average ln RMSSD over 7 nights and compare
 * it with the person's own baseline from the 21 nights before. Within half a
 * standard deviation is balanced; further out is unbalanced; more than 1.5
 * below is low. Garmin needs about 3 weeks before it shows a status, as here
 * (14 baseline nights).
 */
export function hrvStatus(nights: { at: number; rmssd: number }[], now: number): HrvStatus {
  const day = 86_400_000;
  const sorted = nights.filter((n) => n.rmssd > 0 && n.at <= now).sort((a, b) => b.at - a.at);
  const last = sorted[0] && now - sorted[0].at < 2 * day ? sorted[0].rmssd : null;
  const week = sorted.filter((n) => now - n.at < 7 * day).map((n) => Math.log(n.rmssd));
  const base = sorted.filter((n) => now - n.at >= 7 * day && now - n.at < 28 * day).map((n) => Math.log(n.rmssd));
  const weekly = week.length >= 3 ? mean(week)! : null;
  if (weekly === null || base.length < 14) {
    return { lastNight: last, weekly: weekly === null ? null : Math.exp(weekly), baseline: null, status: "building", z: null };
  }
  const mu = mean(base)!;
  const sd = Math.max(0.05, Math.sqrt(mean(base.map((v) => (v - mu) ** 2))!));
  const z = (weekly - mu) / sd;
  return {
    lastNight: last,
    weekly: Math.exp(weekly),
    baseline: { low: Math.exp(mu - 0.5 * sd), high: Math.exp(mu + 0.5 * sd) },
    status: z < -1.5 ? "low" : Math.abs(z) <= 0.5 ? "balanced" : "unbalanced",
    z,
  };
}

// MARK: Stress

export type StressPoint = { at: number; kind: "rest" | "stress" | "activity"; value: number | null };

/**
 * All-day stress, 0-100 in 3-minute steps, on Garmin's bands (0-25 rest,
 * 26-50 low, 51-75 medium, 76-100 high).
 *
 * Firstbeat's method classifies each stretch of the day first as physical
 * activity (oxygen use above 30 % of VO2max), then recovery (heart rate
 * individually low, HRV high) or stress (heart rate raised above the
 * person's resting level without the movement to explain it, HRV low). The
 * watch doesn't hand over beat-to-beat intervals outside of logged
 * activities, so this uses the heart rate half of that test: stretches during
 * or within 20 minutes of an activity, or above 25 % of heart rate reserve,
 * count as activity; otherwise stress is how far heart rate sits above
 * resting + 3 bpm, as a share of 40 % of heart rate reserve (fitted to the
 * watch, see STRESS). For someone at 55 resting and 198 max, 70 bpm reads
 * about 21 (rest), 85 about 47 (low).
 */
/**
 * SPAN refit 2026-10-19 on 1,122 three-minute steps of the watch's own stress
 * (calibrate.ts): at 0.22 the hub read 23 points high; at 0.40 it's off by 6
 * on average with no bias (r = 0.86, the most heart rate alone can explain).
 */
export const STRESS = { OFFSET: 3, SPAN: 0.4, ACTIVE: 0.25 };

export function stressSeries(
  heartRate: { at: number; bpm: number }[],
  activities: { start: number; end: number }[],
  profile: Profile,
  step = 180_000,
): StressPoint[] {
  const buckets = new Map<number, number[]>();
  for (const sample of heartRate) {
    const key = Math.floor(sample.at / step) * step;
    const list = buckets.get(key) ?? [];
    list.push(sample.bpm);
    buckets.set(key, list);
  }
  const reserve = profile.maxHr - profile.restingHr;
  return [...buckets.keys()].sort((a, b) => a - b).map((at) => {
    const hr = mean(buckets.get(at)!)!;
    const exercising = activities.some((a) => at + step > a.start && at < a.end + 20 * 60_000);
    if (exercising || hrr(hr, profile) > STRESS.ACTIVE) return { at, kind: "activity", value: null };
    const value = Math.round(clamp((100 * (hr - profile.restingHr - STRESS.OFFSET)) / (STRESS.SPAN * reserve), 0, 100));
    return { at, kind: value <= 25 ? "rest" : "stress", value };
  });
}

// MARK: Body Battery

/**
 * Body Battery, 5-100: an energy reserve that recovery fills and stress and
 * exercise drain (Firstbeat's "body resources"). Garmin publishes the
 * drivers, not the rates; these are set so a typical day matches Garmin's own
 * population numbers (wake near 70, end the day near 20) and a hard hour of
 * exercise costs about 30.
 *
 * Every 3-minute step: asleep and restful, it charges toward 100, faster the
 * lower the stress (about +50 over a calm 8-hour night from 20); awake and
 * restful, it charges at about 60 % of that rate; awake under stress it drains
 * 0.02-0.16 a minute with stress level; exercise drains 0.78·(share of heart
 * rate reserve)² a minute. Gaps in wear leave it where it was.
 */
/**
 * Rates refit 2026-10-19 against 1,657 three-minute readings of the watch's
 * own Body Battery over 4 days (calibrate.ts): r 0.77 → 0.95, off by 3.6 on
 * average. Charging came out about half as fast as first set. Only 4 days
 * of all-day wear so far: refit once there are more (scripts/fitness-calibrate.ts).
 */
export const BATTERY = { SLEEP_CHARGE: 0.00225, AWAKE_CHARGE: 0.00133, SLEEP_DRAIN: 0.00125, STRESS_DRAIN: 0.02, STRESS_DRAIN_SPAN: 0.14, EXERCISE: 0.78 };

export function bodyBattery(
  stress: StressPoint[],
  heartRate: { at: number; bpm: number }[],
  sleep: { start: number; end: number }[],
  profile: Profile,
  start = 50,
): { at: number; value: number }[] {
  const step = 3;
  const hrByBucket = new Map<number, number[]>();
  for (const s of heartRate) {
    const key = Math.floor(s.at / 180_000) * 180_000;
    const list = hrByBucket.get(key) ?? [];
    list.push(s.bpm);
    hrByBucket.set(key, list);
  }
  let level = start;
  const out: { at: number; value: number }[] = [];
  for (const point of stress) {
    const asleep = sleep.some((s) => point.at >= s.start && point.at < s.end);
    if (point.kind === "activity") {
      const hr = mean(hrByBucket.get(point.at) ?? []);
      const intensity = hr === null ? 0.3 : clamp(hrr(hr, profile), 0, 1);
      level -= BATTERY.EXERCISE * intensity ** 2 * step;
    } else {
      const value = point.value ?? 25;
      if (value <= 25) {
        const quality = clamp(1 - value / 50, 0, 1);
        level += (asleep ? BATTERY.SLEEP_CHARGE : BATTERY.AWAKE_CHARGE) * quality * (100 - level) * step;
      } else {
        level -= (asleep ? BATTERY.SLEEP_DRAIN : BATTERY.STRESS_DRAIN + (BATTERY.STRESS_DRAIN_SPAN * (value - 25)) / 75) * step;
      }
    }
    level = clamp(level, 5, 100);
    out.push({ at: point.at, value: Math.round(level) });
  }
  return out;
}

// MARK: Training Readiness

export type ReadinessFactor = {
  key: "sleep" | "recovery" | "hrv" | "load" | "sleepHistory" | "stressHistory";
  label: string;
  /** 0-100, or null when the data for it isn't there yet. */
  score: number | null;
  weight: number;
  detail: string;
};

export type Readiness = {
  score: number | null;
  level: "prime" | "high" | "moderate" | "low" | "poor" | null;
  factors: ReadinessFactor[];
};

/**
 * Training Readiness, 1-100, from Garmin's six published inputs. Garmin
 * doesn't publish weights, so these are the hub's: last night's sleep 25 %,
 * recovery time 20 %, HRV status 20 %, acute load 15 %, sleep history 10 %,
 * stress history 10 %. Factors without data drop out and the rest are
 * re-weighted. Like Garmin's, one very poor factor holds the score down: it
 * can't sit more than 40 above the weakest factor. Bands are Garmin's:
 * prime 95+, high 75-94, moderate 50-74, low 25-49, poor under 25.
 */
export function readiness(input: {
  lastSleepScore: number | null;
  recoveryHours: number;
  hasTraining: boolean;
  hrv: HrvStatus;
  load: { acute: number; chronic: number; ratio: number | null };
  recentSleepScores: number[];
  recentStress: number[];
}): Readiness {
  const { hrv, load } = input;
  const factors: ReadinessFactor[] = [
    {
      key: "sleep", label: "Sleep", weight: 0.25, score: input.lastSleepScore,
      detail: input.lastSleepScore === null ? "No sleep last night" : `Score ${input.lastSleepScore}`,
    },
    {
      key: "recovery", label: "Recovery time", weight: 0.2,
      score: input.hasTraining ? Math.round(100 * (1 - clamp(input.recoveryHours / 72, 0, 1))) : null,
      detail: input.recoveryHours < 1 ? "Recovered" : `${Math.round(input.recoveryHours)} h to go`,
    },
    {
      key: "hrv", label: "HRV status", weight: 0.2,
      score: hrv.z === null ? null : Math.round(hrv.z < 0 ? clamp(90 + 30 * hrv.z, 0, 100) : clamp(90 + 10 * hrv.z, 0, 100)),
      detail: hrv.status === "building" ? "Building a baseline" : `${hrv.status[0].toUpperCase()}${hrv.status.slice(1)}`,
    },
    {
      key: "load", label: "Acute load", weight: 0.15,
      score: load.ratio === null ? (input.hasTraining ? 100 : null)
        : Math.round(load.ratio <= 1 ? 100 : load.ratio <= 1.5 ? 100 - 100 * (load.ratio - 1) : clamp(50 - 100 * (load.ratio - 1.5), 0, 50)),
      detail: load.ratio === null ? `${load.acute} this week` : `${load.acute} vs ${load.chronic} usual (${load.ratio.toFixed(1)}×)`,
    },
    {
      key: "sleepHistory", label: "Sleep history", weight: 0.1,
      score: input.recentSleepScores.length ? Math.round(mean(input.recentSleepScores)!) : null,
      detail: input.recentSleepScores.length ? `${input.recentSleepScores.length}-night average` : "No recent nights",
    },
    {
      key: "stressHistory", label: "Stress history", weight: 0.1,
      score: input.recentStress.length ? Math.round(100 - clamp((mean(input.recentStress)! - 20) * 2, 0, 100)) : null,
      detail: input.recentStress.length ? `Average ${Math.round(mean(input.recentStress)!)} over ${input.recentStress.length} days` : "No all-day data",
    },
  ];
  const present = factors.filter((f) => f.score !== null);
  if (present.length < 2) return { score: null, level: null, factors };
  const weight = present.reduce((a, f) => a + f.weight, 0);
  const weighted = present.reduce((a, f) => a + f.weight * f.score!, 0) / weight;
  const weakest = Math.min(...present.map((f) => f.score!));
  const score = Math.round(clamp(Math.min(weighted, weakest + 40), 1, 100));
  const level = score >= 95 ? "prime" : score >= 75 ? "high" : score >= 50 ? "moderate" : score >= 25 ? "low" : "poor";
  return { score, level, factors };
}
