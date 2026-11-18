/**
 * The hub's versions of the scores Whoop, Oura, Garmin and Apple build on top
 * of a watch's raw data: strain, recovery, sleep need, recovery index,
 * resilience, training effect, load focus, lactate threshold, race times,
 * fitness and biological age, endurance and hill scores, vitals outliers,
 * effort and sleep consistency.
 *
 * None of those companies publish their math. Each model below follows the
 * published method or research it rests on where there is one, says where it
 * picks its own constants, and where the watch writes its own value
 * (Training Effect) the constants are fitted to it. Everything is personal:
 * baselines come from the person's own last weeks, and a model returns
 * `calibrating` until there is enough of it.
 *
 * Pure functions, no dependencies, so they run under `node --test`.
 */

import { hrr, type Profile, runVo2max, type Sample } from "./physiology.ts";

const DAY = 86_400_000;
const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value));
const mean = (values: number[]) => (values.length ? values.reduce((a, b) => a + b, 0) / values.length : null);
const median = (values: number[]) => {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};
const sd = (values: number[]) => {
  const mu = mean(values);
  return mu === null || values.length < 2 ? null : Math.sqrt(values.reduce((a, v) => a + (v - mu) ** 2, 0) / (values.length - 1));
};
const round1 = (value: number) => Math.round(value * 10) / 10;

/** A score that needs history it doesn't have yet. */
export type Calibrating = { status: "calibrating"; have: number; need: number };
const calibrating = (have: number, need: number): Calibrating => ({ status: "calibrating", have, need });

// MARK: Strain (Whoop)

/**
 * Banister's training impulse (TRIMP): minutes weighted by heart rate reserve
 * and an exponential that grows with intensity, so ten hard minutes count far
 * more than ten easy ones. 0.64·e^(1.92x) for men, 0.86·e^(1.67x) for women
 * (Banister 1991), the average of both when unknown. Gaps over 5 minutes
 * (watch off) don't count. `floor` drops minutes below that share of heart
 * rate reserve (all-day wear uses Whoop's zone 1, 50 % of max).
 */
export function trimp(heartRate: [number, number][], profile: Profile, floor = 0): number {
  const [a, b] = profile.sex === "male" ? [0.64, 1.92] : profile.sex === "female" ? [0.86, 1.67] : [0.75, 1.8];
  let total = 0;
  for (let i = 1; i < heartRate.length; i++) {
    const minutes = (heartRate[i][0] - heartRate[i - 1][0]) / 60;
    if (minutes <= 0 || minutes > 5) continue;
    const x = clamp(hrr((heartRate[i][1] + heartRate[i - 1][1]) / 2, profile), 0, 1);
    if (x < floor) continue;
    total += minutes * x * a * Math.exp(b * x);
  }
  return total;
}

/**
 * Whoop's 0-21 strain is logarithmic in cardiovascular load: each point is
 * harder to earn than the last. Here strain = 4.46·ln(1 + TRIMP/5), set so an
 * easy 45-minute strength session reads about 7, a hard hour's run about 15,
 * and 21 needs a TRIMP near 600 (an all-day event), matching Whoop's
 * published bands (light 0-9, moderate 10-13, strenuous 14-17, all out 18-21).
 */
export function strain(trimpValue: number): number {
  return round1(clamp(4.46 * Math.log(1 + Math.max(0, trimpValue) / 5), 0, 21));
}

export function strainLevel(value: number): "light" | "moderate" | "strenuous" | "all out" {
  return value < 10 ? "light" : value < 14 ? "moderate" : value < 18 ? "strenuous" : "all out";
}

/**
 * A day's strain: workouts from their own heart rate series, the rest of the
 * day from all-day monitoring outside those workouts, counting only time in
 * Whoop's zones (from 50 % of max heart rate), so sitting a few beats over
 * resting all day doesn't add up to a hard day.
 */
export function dayStrain(
  allDay: { at: number; bpm: number }[],
  workouts: { start: number; end: number; trimp: number }[],
  profile: Profile,
): { strain: number; trimp: number; workoutTrimp: number } {
  const outside = allDay
    .filter((s) => !workouts.some((w) => s.at >= w.start && s.at <= w.end))
    .map((s) => [s.at / 1000, s.bpm] as [number, number]);
  const workoutTrimp = workouts.reduce((a, w) => a + w.trimp, 0);
  const zone1 = hrr(0.5 * profile.maxHr, profile);
  const total = trimp(outside, profile, zone1) + workoutTrimp;
  return { strain: strain(total), trimp: Math.round(total), workoutTrimp: Math.round(workoutTrimp) };
}

// MARK: Training Effect (Garmin / Firstbeat)

/**
 * Aerobic Training Effect, 0-5, from the session's EPOC peak (the hub's
 * load). Firstbeat maps EPOC to TE on a log scale; fitted to the TE this watch
 * wrote for 129 workouts: TE = 1.05·ln(EPOC) − 1.71 (r = 0.97).
 */
export function aerobicEffect(load: number | null): number | null {
  if (load === null) return null;
  if (load <= 1) return 0;
  return round1(clamp(1.05 * Math.log(load) - 1.71, 0, 5));
}

export type AnaerobicFeatures = { bursts: number; rises: number; minutesAbove80: number };

/**
 * What drives the anaerobic Training Effect: Firstbeat scores repeated hard
 * efforts above the anaerobic threshold, not total load. From heart rate
 * alone, three signals carry it: bursts (each climb past 88 % of heart rate
 * reserve after dropping below 75 %), minutes of fast rises (heart rate up
 * more than 15 bpm within 10 samples, the signature of a sprint) and
 * minutes above 80 % of reserve.
 */
export function anaerobicFeatures(heartRate: [number, number][], profile: Profile): AnaerobicFeatures {
  const out = { bursts: 0, rises: 0, minutesAbove80: 0 };
  let below = true;
  for (let i = 1; i < heartRate.length; i++) {
    const minutes = (heartRate[i][0] - heartRate[i - 1][0]) / 60;
    if (minutes <= 0 || minutes > 5) continue;
    const x = hrr(heartRate[i][1], profile);
    if (x > 0.8) out.minutesAbove80 += minutes;
    if (x < 0.75) below = true;
    if (x > 0.88 && below) { out.bursts++; below = false; }
    if (i >= 10) {
      const span = heartRate[i][0] - heartRate[i - 10][0];
      if (span > 0 && span < 60 && heartRate[i][1] - heartRate[i - 10][1] > 15) out.rises += minutes;
    }
  }
  return { bursts: out.bursts, rises: round1(out.rises), minutesAbove80: round1(out.minutesAbove80) };
}

/**
 * Anaerobic Training Effect, 0-5: a linear fit on the log of each signal to
 * the anaerobic TE this watch wrote for 135 workouts (r = 0.69, off by 0.66 on
 * average). Firstbeat also uses speed and power, which most of these sports
 * don't record, so it's the least exact of the hub's numbers.
 */
export const ANAEROBIC = { B0: 0.075, BURSTS: 0.746, RISES: 0.742, ABOVE80: 0.316 };

export function anaerobicEffect(f: AnaerobicFeatures): number {
  const te = ANAEROBIC.B0 + ANAEROBIC.BURSTS * Math.log1p(f.bursts) + ANAEROBIC.RISES * Math.log1p(f.rises) + ANAEROBIC.ABOVE80 * Math.log1p(f.minutesAbove80);
  return round1(clamp(te, 0, 5));
}

export function effectLabel(te: number | null): string | null {
  if (te === null) return null;
  return te < 1 ? "No benefit" : te < 2 ? "Minor" : te < 3 ? "Maintaining" : te < 4 ? "Improving" : te < 5 ? "Highly improving" : "Overreaching";
}

/**
 * Apple's 1-10 effort rating (easy 1-3, moderate 4-6, hard 7-8, all out
 * 9-10), from the two training effects: aerobic carries most of it, hard
 * intervals push it up.
 */
export function effortRating(aerobic: number | null, anaerobic: number | null): number | null {
  if (aerobic === null) return null;
  return Math.round(clamp(aerobic * 2 + (anaerobic ?? 0) * 0.6, 1, 10));
}

// MARK: Load focus (Garmin)

export type FocusSplit = { low: number; high: number; anaerobic: number };

/**
 * Splits a session's load into Garmin's three focus buckets by where the
 * training impulse came from: low aerobic below 70 % of heart rate reserve,
 * high aerobic 70-88 %, anaerobic above 88 % (roughly zones 1-3, 4, 5).
 */
export function focusSplit(heartRate: [number, number][], profile: Profile, load: number): FocusSplit {
  const parts = { low: 0, high: 0, anaerobic: 0 };
  for (let i = 1; i < heartRate.length; i++) {
    const minutes = (heartRate[i][0] - heartRate[i - 1][0]) / 60;
    if (minutes <= 0 || minutes > 5) continue;
    const x = clamp(hrr(heartRate[i][1], profile), 0, 1);
    const impulse = minutes * x * Math.exp(1.92 * x);
    if (x < 0.7) parts.low += impulse; else if (x < 0.88) parts.high += impulse; else parts.anaerobic += impulse;
  }
  const total = parts.low + parts.high + parts.anaerobic;
  if (total === 0) return { low: load, high: 0, anaerobic: 0 };
  return { low: Math.round((load * parts.low) / total), high: Math.round((load * parts.high) / total), anaerobic: Math.round((load * parts.anaerobic) / total) };
}

/**
 * Four weeks of focus. Garmin publishes target ranges that scale with
 * fitness but not the numbers; as a rule a balanced block is about half low
 * aerobic, a third high aerobic and a tenth or more anaerobic. Flags the
 * bucket furthest below its share.
 */
export function loadFocus(sessions: { at: number; focus: FocusSplit }[], now: number) {
  const recent = sessions.filter((s) => now - s.at < 28 * DAY && s.at <= now);
  const total = { low: 0, high: 0, anaerobic: 0 };
  for (const s of recent) {
    total.low += s.focus.low;
    total.high += s.focus.high;
    total.anaerobic += s.focus.anaerobic;
  }
  const sum = total.low + total.high + total.anaerobic;
  if (sum === 0) return { ...total, status: null as string | null };
  const targets = { low: 0.45, high: 0.3, anaerobic: 0.1 };
  const gaps = (Object.keys(targets) as (keyof typeof targets)[]).map((k) => ({ k, gap: targets[k] - total[k] / sum }));
  const worst = gaps.sort((a, b) => b.gap - a.gap)[0];
  const names = { low: "Low aerobic shortage", high: "High aerobic shortage", anaerobic: "Anaerobic shortage" };
  return { ...total, status: worst.gap > 0.08 ? names[worst.k] : "Balanced" };
}

// MARK: Lactate threshold (Garmin)

/** Highest 20-minute average heart rate in a session (Friel's threshold test reads the last 20 of a 30-minute effort). */
export function best20MinHr(heartRate: [number, number][]): number | null {
  let best: number | null = null;
  let start = 0, sum = 0, weight = 0;
  for (let end = 1; end < heartRate.length; end++) {
    const dt = heartRate[end][0] - heartRate[end - 1][0];
    if (dt <= 0 || dt > 300) { start = end; sum = 0; weight = 0; continue; }
    sum += heartRate[end][1] * dt;
    weight += dt;
    while (heartRate[end][0] - heartRate[start][0] > 1200 && start < end - 1) {
      const out = heartRate[start + 1][0] - heartRate[start][0];
      sum -= heartRate[start + 1][1] * out;
      weight -= out;
      start++;
    }
    if (heartRate[end][0] - heartRate[start][0] >= 1140 && weight > 0) {
      const avg = sum / weight;
      if (best === null || avg > best) best = avg;
    }
  }
  return best === null ? null : Math.round(best);
}

/**
 * Lactate threshold heart rate: the best 20-minute heart rate of the last 120
 * days, as long as it was a real effort (85-95 % of max). Without one, 87 %
 * of max, the usual ratio for trained people, marked as estimated. Pace at
 * threshold comes from the person's own runs: speed against heart rate over
 * steady minutes, read at that heart rate.
 */
export function lactateThreshold(
  sessions: { at: number; best20: number | null }[],
  steady: [number, number][],
  profile: Profile,
  now: number,
) {
  const recent = sessions.filter((s) => s.best20 !== null && now - s.at < 120 * DAY).map((s) => s.best20!);
  const best = recent.length ? Math.max(...recent) : null;
  const measured = best !== null && best >= 0.85 * profile.maxHr && best <= 0.95 * profile.maxHr;
  const heartRate = measured ? best! : Math.round(0.87 * profile.maxHr);
  let speed: number | null = null;
  if (steady.length >= 10) {
    const n = steady.length;
    const mx = steady.reduce((a, p) => a + p[0], 0) / n;
    const my = steady.reduce((a, p) => a + p[1], 0) / n;
    const sxy = steady.reduce((a, p) => a + (p[0] - mx) * (p[1] - my), 0);
    const sxx = steady.reduce((a, p) => a + (p[0] - mx) ** 2, 0);
    if (sxx > 0 && sxy > 0) speed = round1((my + (sxy / sxx) * (heartRate - mx)) * 100) / 100;
  }
  return { heartRate, measured, speed, percentOfMax: Math.round((100 * heartRate) / profile.maxHr) };
}

// MARK: Race predictor (Garmin)

/**
 * Race times from VO2max with Daniels and Gilbert's running formula: oxygen
 * cost of a pace, VO2 = −4.60 + 0.182258·v + 0.000104·v² (v in m/min), and
 * the share of VO2max a person can hold for t minutes,
 * 0.8 + 0.1894393·e^(−0.012778t) + 0.2989558·e^(−0.1932605t). The predicted
 * time is where cost equals what can be held; found by bisection.
 */
export function raceTime(vo2max: number, meters: number): number {
  const gap = (minutes: number) => {
    const v = meters / minutes;
    const cost = -4.6 + 0.182258 * v + 0.000104 * v * v;
    const share = 0.8 + 0.1894393 * Math.exp(-0.012778 * minutes) + 0.2989558 * Math.exp(-0.1932605 * minutes);
    return cost - vo2max * share;
  };
  let lo = 3, hi = 900;
  for (let i = 0; i < 60; i++) {
    const mid = (lo + hi) / 2;
    if (gap(mid) > 0) lo = mid; else hi = mid;
  }
  return Math.round(((lo + hi) / 2) * 60);
}

export function racePredictions(vo2max: number) {
  return {
    "5k": raceTime(vo2max, 5000),
    "10k": raceTime(vo2max, 10000),
    half: raceTime(vo2max, 21097.5),
    marathon: raceTime(vo2max, 42195),
  };
}

// MARK: Fitness age and cardio fitness (Garmin, Oura, Apple)

/**
 * Average VO2max by age in the HUNT Fitness Study (Loe et al. 2013, about
 * 4,600 healthy Norwegians, treadmill tested): men about 54.4 at 25 falling
 * 0.45 a year, women 43.0 falling 0.37, with a spread of about 7.5.
 */
export function populationVo2max(age: number, sex: Profile["sex"]): { mean: number; sd: number } {
  const men = 54.4 - 0.45 * (age - 25);
  const women = 43.0 - 0.37 * (age - 25);
  return { mean: sex === "male" ? men : sex === "female" ? women : (men + women) / 2, sd: 7.5 };
}

/**
 * Fitness age: the age whose average VO2max matches yours (the HUNT
 * study's definition, the one Garmin and others build on), 18-90.
 */
export function fitnessAge(vo2max: number, sex: Profile["sex"]): number {
  const [at25, slope] = sex === "male" ? [54.4, 0.45] : sex === "female" ? [43.0, 0.37] : [48.7, 0.41];
  return Math.round(clamp(25 + (at25 - vo2max) / slope, 18, 90));
}

/**
 * Where VO2max sits for the person's age and sex, as a percentile and
 * Apple's four levels (low, below average, above average, high). Low, the
 * level Apple notifies on, is the bottom 10 %.
 */
export function cardioFitness(vo2max: number, age: number, sex: Profile["sex"]) {
  const { mean: mu, sd: spread } = populationVo2max(age, sex);
  const z = (vo2max - mu) / spread;
  // Normal CDF (Abramowitz-Stegun 26.2.17).
  const t = 1 / (1 + 0.2316419 * Math.abs(z));
  const tail = 0.3989423 * Math.exp((-z * z) / 2) * t * (0.3193815 + t * (-0.3565638 + t * (1.781478 + t * (-1.821256 + t * 1.330274))));
  const percentile = Math.round(100 * (z > 0 ? 1 - tail : tail));
  const level = percentile < 10 ? "low" : percentile < 50 ? "below average" : percentile < 85 ? "above average" : "high";
  return { percentile, level, lowFitness: percentile < 10 };
}

// MARK: Hub Age and pace of aging (Whoop)

export type AgeInputs = {
  age: number;
  sex: Profile["sex"];
  vo2max: number | null;
  restingHr: number | null;
  /** Average overnight RMSSD over the last 7 nights, ms. */
  hrv: number | null;
  /** Standard deviation of bedtimes over the last 2 weeks, minutes. */
  bedtimeSpread: number | null;
  /** Average sleep, hours. */
  sleepHours: number | null;
  /** Average steps a day over the last 4 weeks. */
  steps?: number | null;
  /** Minutes a week in heart rate zones 1-3 and in zones 4-5, over the last 4 weeks. */
  easyMinutes?: number | null;
  hardMinutes?: number | null;
  /** Minutes of strength training a week, over the last 4 weeks. */
  strengthMinutes?: number | null;
  /** Minutes of exercise a week, used when there is no zone time. */
  activeMinutes?: number | null;
};

/**
 * A biological age built the way Whoop builds Whoop Age: start from your
 * real age and let each habit the research ties to lifespan move it, younger
 * or older. Whoop uses nine inputs (sleep length and consistency, time in
 * zones 1-3 and 4-5, strength training, steps, VO2max, resting heart rate and
 * lean mass); this has the eight a watch can see, plus HRV. The size of each
 * move is the hub's own, set from the size of the effect in the studies:
 *
 * - VO2max, the strongest single predictor of mortality (Mandsager et al.
 *   2018): 0.6 years for every year fitness age (HUNT, Loe et al. 2013) sits
 *   from real age, up to 7 either way.
 * - Resting heart rate: risk rises about 10 % per 10 bpm (Jensen et al.
 *   2013); 0.1 year a beat around 60, from -1.5 to +2.
 * - Sleep length: 7 to 9 hours is the low-risk range (-0.5); short sleep
 *   costs up to +1.5 under 6 hours, very long sleep +0.5.
 * - Sleep consistency: regular sleepers had 20-48 % lower mortality (Windred
 *   et al. 2024); -0.5 when bedtimes hold within half an hour, up to +1.5
 *   past an hour and a half of spread.
 * - Steps: risk falls to about 8,000-10,000 a day (Paluch et al. 2022); from
 *   +1.5 under 2,000 to -1.2 at 10,000.
 * - Zones 1-3: WHO's 150 minutes a week is neutral, 300 gives -1, none +1.2.
 * - Zones 4-5: vigorous time counts double (Wen et al. 2011); none is +0.5,
 *   75 minutes a week -1.
 * - Strength: 30-60 minutes a week is the sweet spot (Momma et al. 2022);
 *   none is +0.7, an hour -0.7.
 * - HRV against the norm for your age (about 45 ms at 25, 1 % less a year):
 *   up to a year either way.
 *
 * Works with whatever inputs are there, and needs at least three.
 */
export function hubAge(input: AgeInputs) {
  const parts: { key: string; label: string; years: number }[] = [];
  const base = input.vo2max === null ? null : fitnessAge(input.vo2max, input.sex);
  if (base !== null) parts.push({ key: "vo2max", label: "VO2max", years: clamp((base - input.age) * 0.6, -7, 7) });
  if (input.restingHr !== null) parts.push({ key: "rhr", label: "Resting heart rate", years: clamp((input.restingHr - 60) * 0.1, -1.5, 2) });
  if (input.sleepHours !== null) {
    const h = input.sleepHours;
    parts.push({ key: "sleep", label: "Sleep length", years: h < 6 ? 1.5 : h < 6.5 ? 1 : h < 7 ? 0.3 : h <= 9 ? -0.5 : h <= 9.5 ? 0 : 0.5 });
  }
  if (input.bedtimeSpread !== null) parts.push({ key: "regularity", label: "Sleep consistency", years: clamp(((input.bedtimeSpread - 45) / 45) * 1.5, -0.5, 1.5) });
  if (input.steps != null) parts.push({ key: "steps", label: "Steps", years: clamp((6000 - input.steps) / 3300, -1.2, 1.5) });
  if (input.easyMinutes != null || input.hardMinutes != null) {
    parts.push({ key: "easy", label: "Zones 1-3", years: clamp((150 - (input.easyMinutes ?? 0)) / 150, -1, 1.2) });
    parts.push({ key: "hard", label: "Zones 4-5", years: clamp(0.5 - (input.hardMinutes ?? 0) / 50, -1, 0.5) });
  } else if (input.activeMinutes != null) {
    parts.push({ key: "activity", label: "Exercise", years: clamp((150 - input.activeMinutes) / 100, -1.5, 1.5) });
  }
  if (input.strengthMinutes != null) parts.push({ key: "strength", label: "Strength training", years: clamp(0.7 - (1.4 * input.strengthMinutes) / 60, -0.7, 0.7) });
  if (input.hrv !== null) {
    const norm = 45 * 0.99 ** (input.age - 25);
    parts.push({ key: "hrv", label: "HRV", years: clamp(-3 * Math.log(input.hrv / norm), -1, 1) });
  }
  if (parts.length < 3) return null;
  const years = round1(input.age + parts.reduce((a, p) => a + p.years, 0));
  return {
    age: years, fitnessAge: base ?? Math.round(input.age), difference: round1(years - input.age),
    parts: parts.map((p) => ({ ...p, years: round1(p.years) })),
  };
}

/**
 * Pace of aging: how many years Hub Age moved per calendar year, from the
 * value 90 days ago to now (Whoop shows −1× to 3×). Null until there's a
 * value from 90 days back.
 */
export function paceOfAging(now: number | null, ninetyDaysAgo: number | null): number | null {
  if (now === null || ninetyDaysAgo === null) return null;
  return round1(clamp((now - ninetyDaysAgo) / (90 / 365.25), -1, 3));
}

// MARK: Nights

export type NightData = {
  start: number;
  end: number;
  asleepSeconds: number;
  /** [seconds from start, level], Garmin levels: 1 awake, 2 light, 3 deep, 4 REM. */
  levels: [number, number][];
  heartRate: { at: number; bpm: number }[];
  hrv: number | null;
  respiration: number | null;
  spo2: number | null;
  score: number | null;
};

/** Average of the lowest 30 minutes of overnight heart rate: Whoop's and Oura's sleeping resting heart rate. */
export function sleepingRestingHr(heartRate: { at: number; bpm: number }[]): { bpm: number; at: number } | null {
  if (heartRate.length < 10) return null;
  let best: { bpm: number; at: number } | null = null;
  let start = 0;
  for (let end = 0; end < heartRate.length; end++) {
    while (heartRate[end].at - heartRate[start].at > 30 * 60_000) start++;
    if (heartRate[end].at - heartRate[start].at < 20 * 60_000) continue;
    const window = heartRate.slice(start, end + 1);
    const avg = mean(window.map((s) => s.bpm))!;
    if (!best || avg < best.bpm) best = { bpm: Math.round(avg), at: window[window.length >> 1].at };
  }
  return best;
}

/**
 * Oura's Recovery Index: how early in the night resting heart rate bottoms
 * out. Oura's guidance is that the lowest point should come in the first half
 * of the night; a late low means the body was still busy recovering (late
 * meals, alcohol, hard evening training). 100 at the very start, 80 at the
 * midpoint, 0 at wake.
 */
export function recoveryIndex(night: Pick<NightData, "start" | "end" | "heartRate">) {
  const low = sleepingRestingHr(night.heartRate.filter((s) => s.at >= night.start && s.at <= night.end));
  if (!low) return null;
  const share = clamp((low.at - night.start) / Math.max(1, night.end - night.start), 0, 1);
  const score = Math.round(share <= 0.5 ? 100 - 40 * share : 80 - 160 * (share - 0.5));
  return { score: clamp(score, 0, 100), lowestHr: low.bpm, lowestAt: low.at, share: Math.round(share * 100) / 100 };
}

/** Times woken for 3 minutes or more, from the stage list. */
export function interruptions(levels: [number, number][], totalSeconds: number): number {
  let count = 0;
  for (let i = 0; i < levels.length; i++) {
    if (levels[i][1] !== 1) continue;
    const until = i + 1 < levels.length ? levels[i + 1][0] : totalSeconds;
    if (until - levels[i][0] >= 180 && levels[i][0] > 0 && i + 1 < levels.length) count++;
  }
  return count;
}

/** Spread of bedtimes in minutes, measured around midnight so 23:50 and 00:10 are 20 minutes apart. */
export function bedtimeSpread(starts: number[], utcOffset: number): number | null {
  if (starts.length < 3) return null;
  const minutes = starts.map((s) => {
    const local = ((s / 60_000 + utcOffset / 60) % 1440 + 1440) % 1440;
    return local > 720 ? local - 1440 : local; // evening is negative, so bedtimes sit together
  });
  return Math.round(sd(minutes)!);
}

/**
 * Apple's Sleep Score: duration (50 points, full at 8 hours and over), bedtime
 * consistency (30, full within 15 minutes of spread, none past 2 hours) and
 * interruptions (20, full with none, none at 6 or more).
 */
export function appleSleepScore(asleepSeconds: number, spread: number | null, wakeups: number) {
  const duration = clamp(asleepSeconds / 3600 / 8, 0, 1) * 50;
  const consistency = spread === null ? 20 : clamp(1 - (spread - 15) / 105, 0, 1) * 30;
  const interrupt = clamp(1 - wakeups / 6, 0, 1) * 20;
  return { score: Math.round(duration + consistency + interrupt), duration: Math.round(duration), consistency: Math.round(consistency), interruptions: Math.round(interrupt) };
}

// MARK: Sleep need (Whoop)

/**
 * Tonight's sleep need, the way Whoop splits it: a baseline (your own median
 * from the last 30 nights, 7-9 hours, 8 until there are 7 nights), plus a
 * share of recent sleep debt (shortfall against need over the last week, the
 * newest night counting most, at most 2 hours), plus strain (up to an hour
 * after an all-out day, growing with the square of strain), minus naps.
 * Performance is last night's sleep against what was needed, capped at 100.
 */
export function sleepNeed(input: {
  history: { asleepSeconds: number }[];
  lastWeek: { asleepSeconds: number }[];
  yesterdayStrain: number | null;
  napSeconds: number;
}) {
  const hours = input.history.map((n) => n.asleepSeconds / 3600);
  const baseline = hours.length >= 7 ? clamp(median(hours)!, 7, 9) : 8;
  let debt = 0;
  input.lastWeek.forEach((n, i) => {
    debt += Math.max(0, baseline - n.asleepSeconds / 3600) * 0.5 * 0.7 ** i;
  });
  debt = Math.min(2, debt);
  const strainAdd = input.yesterdayStrain === null ? 0 : (input.yesterdayStrain / 21) ** 2;
  const naps = input.napSeconds / 3600;
  const total = Math.max(baseline, baseline + debt + strainAdd - naps);
  return { hours: round1(total), baseline: round1(baseline), debt: round1(debt), strain: round1(strainAdd), naps: round1(naps) };
}

export function sleepPerformance(asleepSeconds: number, needHours: number): number {
  return Math.round(clamp((100 * asleepSeconds) / 3600 / needHours, 0, 100));
}

// MARK: Recovery (Whoop)

export type RecoveryInputs = { hrv: number | null; restingHr: number | null; respiration: number | null; performance: number | null; spo2: number | null };

/**
 * Whoop's Recovery, 0-100 %: last night against your own baseline, mostly
 * HRV, then resting heart rate, then sleep and respiration. Each input is a
 * z-score against the 30 nights before (HRV on a log scale); the weighted
 * sum goes through a logistic so an ordinary night lands near 60 % and two
 * standard deviations either way reach the ends. Weights are the hub's (Whoop
 * says HRV dominates): HRV 50 %, resting HR 25 %, sleep performance 15 %,
 * respiration 7 %, SpO2 3 %. Needs 4 baseline nights. Green 67+, yellow
 * 34-66, red 33 and under, Whoop's bands.
 */
export function recovery(last: RecoveryInputs, baseline: RecoveryInputs[]) {
  const usable = baseline.filter((b) => b.hrv !== null && b.restingHr !== null);
  if (last.hrv === null || last.restingHr === null) return null;
  if (usable.length < 4) return calibrating(usable.length, 4);
  const z = (value: number | null, key: keyof RecoveryInputs, floor: number, log = false) => {
    const values = baseline.map((b) => b[key]).filter((v): v is number => v !== null).map((v) => (log ? Math.log(v) : v));
    if (value === null || values.length < 4) return null;
    const x = log ? Math.log(value) : value;
    return (x - mean(values)!) / Math.max(floor, sd(values) ?? floor);
  };
  const parts = [
    { key: "hrv", weight: 0.5, z: z(last.hrv, "hrv", 0.08, true) },
    { key: "restingHr", weight: 0.25, z: -1 * (z(last.restingHr, "restingHr", 2) ?? 0) },
    { key: "sleep", weight: 0.15, z: last.performance === null ? null : (last.performance - 85) / 12 },
    { key: "respiration", weight: 0.07, z: (() => { const v = z(last.respiration, "respiration", 0.5); return v === null ? null : -Math.abs(v); })() },
    { key: "spo2", weight: 0.03, z: z(last.spo2, "spo2", 1) },
  ].filter((p): p is { key: string; weight: number; z: number } => p.z !== null);
  const weight = parts.reduce((a, p) => a + p.weight, 0);
  const s = parts.reduce((a, p) => a + p.weight * clamp(p.z, -3, 3), 0) / weight;
  const score = Math.round(100 / (1 + Math.exp(-1.6 * (s + 0.25))));
  return { status: "ready" as const, score, zone: score >= 67 ? "green" : score >= 34 ? "yellow" : "red", parts: parts.map((p) => ({ ...p, z: round1(p.z) })) };
}

// MARK: Daytime stress and resilience (Oura)

/**
 * Oura's daytime balance: minutes stressed (stress above 50) against minutes
 * restored (25 or under while awake and not exercising). A day reads
 * restored when restored time is at least 1.5× stressed time, stressful when
 * stressed time is twice restored or more, otherwise normal.
 */
export function daytimeStress(points: { at: number; value: number | null; kind: string }[], asleep: (at: number) => boolean, stepMinutes: number) {
  let stressed = 0, restored = 0;
  for (const p of points) {
    if (p.value === null || p.kind === "activity" || asleep(p.at)) continue;
    if (p.value > 50) stressed += stepMinutes;
    else if (p.value <= 25) restored += stepMinutes;
  }
  const summary = stressed + restored < 60 ? null : restored >= stressed * 1.5 ? "restored" : stressed >= restored * 2 ? "stressful" : "normal";
  return { stressedMinutes: stressed, restoredMinutes: restored, summary };
}

/**
 * Oura's Resilience: how well you recover from stress, over 14 days. Half
 * daytime recovery (share of restored against stressed time), half overnight
 * recovery (sleep score). Oura's levels: limited, adequate, solid, strong,
 * exceptional. Needs 5 days.
 */
export function resilience(days: { restored: number; stressed: number }[], sleepScores: number[]) {
  const usable = days.filter((d) => d.restored + d.stressed >= 60);
  if (usable.length < 5) return calibrating(usable.length, 5);
  const daytime = mean(usable.map((d) => d.restored / (d.restored + d.stressed)))!;
  const overnight = sleepScores.length ? mean(sleepScores)! / 100 : daytime;
  const value = 0.5 * daytime + 0.5 * overnight;
  const level = value < 0.35 ? "limited" : value < 0.5 ? "adequate" : value < 0.65 ? "solid" : value < 0.8 ? "strong" : "exceptional";
  return { status: "ready" as const, level, daytime: Math.round(daytime * 100), overnight: Math.round(overnight * 100) };
}

// MARK: Vitals (Apple)

export type VitalKey = "heartRate" | "hrv" | "respiration" | "spo2" | "sleepHours";

/**
 * Apple's Vitals: last night's overnight heart rate, HRV, respiration, SpO2
 * and sleep length against your typical range. Apple needs 7 nights; the
 * range here is the median ± 3 robust standard deviations (MAD × 1.4826) of
 * the last 30 nights, with a minimum width so a very steady baseline doesn't
 * flag noise. A reading outside it is an outlier; two or more at once is
 * what Apple notifies about.
 */
export function vitals(last: Record<VitalKey, number | null>, history: Record<VitalKey, number | null>[]) {
  const minWidth: Record<VitalKey, number> = { heartRate: 4, hrv: 8, respiration: 1, spo2: 2, sleepHours: 1 };
  const out = (Object.keys(minWidth) as VitalKey[]).map((key) => {
    const values = history.map((h) => h[key]).filter((v): v is number => v !== null);
    const value = last[key];
    if (values.length < 7) return { key, value, low: null, high: null, outlier: false, have: values.length };
    const mid = median(values)!;
    const mad = median(values.map((v) => Math.abs(v - mid)))! * 1.4826;
    const width = Math.max(minWidth[key], 3 * mad);
    const low = round1(mid - width), high = round1(mid + width);
    return { key, value, low, high, outlier: value !== null && (value < low || value > high), have: values.length };
  });
  return { readings: out, outliers: out.filter((r) => r.outlier).length, calibrating: out.every((r) => r.low === null) };
}

// MARK: Endurance and hill scores, performance condition (Garmin)

/**
 * Endurance Score: Garmin combines VO2max with the training load built up
 * in long sessions. Here VO2max × 95 plus up to about 3,000 for the load of
 * sessions 45 minutes or longer in the last 4 weeks, on a log scale. Tiers
 * are the hub's own (Garmin's aren't published as numbers): under 4,000
 * recreational, 4,000 intermediate, 6,000 trained, 8,000 well trained,
 * 10,000 expert.
 */
export function enduranceScore(vo2max: number | null, sessions: { at: number; minutes: number; load: number }[], now: number) {
  if (vo2max === null) return null;
  const longLoad = sessions.filter((s) => now - s.at < 28 * DAY && s.minutes >= 45).reduce((a, s) => a + s.load, 0);
  const score = Math.round(vo2max * 95 + 1100 * Math.log(1 + longLoad / 300));
  const tier = score < 4000 ? "Recreational" : score < 6000 ? "Intermediate" : score < 8000 ? "Trained" : score < 10000 ? "Well trained" : "Expert";
  return { score, tier, longLoad: Math.round(longLoad) };
}

/**
 * Hill Score, 1-100: strength (the best sustained climbing rate in the last
 * 8 weeks, metres an hour over 5 minutes; 1,500 m/h scores full) for 60 %, and
 * endurance (metres climbed in the last 4 weeks; 3,000 m scores full) for 40 %.
 */
export function hillScore(sessions: { at: number; bestClimbRate: number | null; ascent: number | null }[], now: number) {
  const rates = sessions.filter((s) => s.bestClimbRate !== null && now - s.at < 56 * DAY).map((s) => s.bestClimbRate!);
  const climbed = sessions.filter((s) => now - s.at < 28 * DAY).reduce((a, s) => a + (s.ascent ?? 0), 0);
  if (!rates.length && climbed === 0) return null;
  const strength = clamp((rates.length ? Math.max(...rates) : 0) / 1500, 0, 1) * 100;
  const endurance = clamp(climbed / 3000, 0, 1) * 100;
  return { score: Math.max(1, Math.round(0.6 * strength + 0.4 * endurance)), strength: Math.round(strength), endurance: Math.round(endurance), climbed: Math.round(climbed) };
}

/** Best 5-minute climbing rate in metres an hour, from altitude samples. */
export function bestClimbRate(samples: Sample[]): number | null {
  const points = samples.filter((s) => s.altitude !== null);
  let best: number | null = null;
  let start = 0;
  for (let end = 0; end < points.length; end++) {
    while (points[end].t - points[start].t > 300) start++;
    const span = points[end].t - points[start].t;
    if (span < 280) continue;
    const rate = ((points[end].altitude! - points[start].altitude!) / span) * 3600;
    if (best === null || rate > best) best = rate;
  }
  return best === null || best < 100 ? null : Math.round(best);
}

/**
 * VO2max over minutes 6-20 of a run, for Performance Condition: Garmin
 * compares how you're running early in a run with your current fitness, -20
 * to +20. Uses the same steady-stretch estimate as VO2max over the shorter
 * window (needs 6 good minutes).
 */
export function earlyVo2max(samples: Sample[], profile: Profile): number | null {
  const window = samples.filter((s) => s.t >= 300 && s.t <= 1200);
  const shifted = window.map((s) => ({ ...s, t: s.t }));
  const estimate = runVo2max(shifted, profile, 6);
  return estimate ? round1(estimate.vo2max) : null;
}

export function performanceCondition(early: number | null, current: number | null): number | null {
  if (early === null || current === null) return null;
  return Math.round(clamp((early / current - 1) * 100, -20, 20));
}

/** Steady minutes from a run as [heart rate, speed m/s], for pace at threshold. */
export function steadyPairs(samples: Sample[]): [number, number][] {
  const points = samples.filter((s) => s.t >= 300 && s.hr !== null && s.speed !== null && s.speed > 1.8);
  const out: [number, number][] = [];
  let start = 0;
  for (let end = 0; end < points.length && out.length < 40; end++) {
    if (points[end].t - points[start].t < 60) continue;
    const window = points.slice(start, end + 1);
    const hrs = window.map((p) => p.hr!), speeds = window.map((p) => p.speed!);
    if (Math.max(...hrs) - Math.min(...hrs) <= 6 && Math.max(...speeds) - Math.min(...speeds) <= 0.2 * mean(speeds)!) {
      out.push([Math.round(mean(hrs)!), round1(mean(speeds)! * 10) / 10]);
    }
    start = end + 1;
  }
  return out;
}
