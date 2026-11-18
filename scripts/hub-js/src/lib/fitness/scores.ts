/**
 * More of the scores Whoop, Oura, Garmin, Fitbit, Apple and the training
 * platforms build on a watch's raw data, next to the ones in insights.ts:
 * sleep efficiency, stage balance, sleep debt, chronotype and social jet lag,
 * the Sleep Regularity Index, overnight breathing disturbances, an Oura style
 * readiness with contributors, fitness / fatigue / form, training monotony,
 * training status, heart rate zones and Active Zone Minutes, a strain target,
 * cardio recovery, HRV stability and a health monitor.
 *
 * As in insights.ts: where there is a published method it is followed and
 * named, and where the constants are the hub's own the comment says so.
 * Baselines are the person's own, and a score that needs history returns
 * `calibrating` until it has it.
 *
 * Pure functions, no dependencies, so they run under `node --test`.
 */

import { hrr, type Profile } from "./physiology.ts";

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

export type Calibrating = { status: "calibrating"; have: number; need: number };
const calibrating = (have: number, need: number): Calibrating => ({ status: "calibrating", have, need });

// MARK: Sleep efficiency and stages (Whoop, Oura, Fitbit)

/** Share of the time in bed spent asleep, percent. 85 % and over is the usual mark of good sleep. */
export function sleepEfficiency(asleepSeconds: number, start: number, end: number): number | null {
  const inBed = (end - start) / 1000;
  if (inBed < 1800) return null;
  return Math.round(clamp((100 * asleepSeconds) / inBed, 0, 100));
}

export type StageShare = { key: "deep" | "light" | "rem"; minutes: number; share: number; low: number; high: number; status: "low" | "typical" | "high" };

/**
 * Each stage as a share of sleep against Garmin's published healthy ranges
 * (deep 16-33 %, light 30-64 %, REM 21-31 %), the comparison Fitbit's
 * benchmark and Garmin's stage bars make.
 */
export function stageBalance(night: { deep: number; light: number; rem: number }): StageShare[] | null {
  const asleep = night.deep + night.light + night.rem;
  if (asleep < 3600) return null;
  const bands = { deep: [16, 33], light: [30, 64], rem: [21, 31] } as const;
  return (Object.keys(bands) as (keyof typeof bands)[]).map((key) => {
    const share = Math.round((100 * night[key]) / asleep);
    const [low, high] = bands[key];
    return { key, minutes: Math.round(night[key] / 60), share, low, high, status: share < low ? "low" : share > high ? "high" : "typical" };
  });
}

// MARK: Sleep debt (Oura, Whoop, Garmin sleep coach)

/**
 * Sleep debt over the last 14 nights: every hour short of need adds to it,
 * and an hour over need pays back half an hour (extra sleep recovers a debt
 * more slowly than it was run up; Kitamura et al. 2016 found about four days
 * to clear one hour). Oura's bands: none under 1 hour, low under 2, moderate
 * under 5, high from 5.
 */
export function sleepDebt(nights: { end: number; asleepSeconds: number }[], needHours: number, now: number) {
  const recent = nights.filter((n) => now - n.end < 14 * DAY && n.end <= now).sort((a, b) => a.end - b.end);
  if (recent.length < 3) return calibrating(recent.length, 3);
  let debt = 0;
  for (const night of recent) {
    const gap = needHours - night.asleepSeconds / 3600;
    debt = Math.max(0, debt + (gap > 0 ? gap : gap / 2));
  }
  const hours = round1(debt);
  const level = hours < 1 ? "none" : hours < 2 ? "low" : hours < 5 ? "moderate" : "high";
  return { status: "ready" as const, hours, level, nights: recent.length, averageHours: round1(mean(recent.map((n) => n.asleepSeconds / 3600))!) };
}

// MARK: Chronotype and social jet lag (Oura, Roenneberg)

/** Minutes after local midnight, wrapped so times before noon and after stay together around the night. */
function nightMinutes(ms: number, utcOffset: number): number {
  const local = ((ms / 60_000 + utcOffset / 60) % 1440 + 1440) % 1440;
  return local > 720 ? local - 1440 : local;
}

/**
 * Chronotype from the midpoint of sleep, the Munich Chronotype
 * Questionnaire's measure (Roenneberg et al. 2003): the median midpoint of
 * the last 4 weeks' nights, read as early (before 03:00), intermediate
 * (03:00 to 04:30) or late. Social jet lag is the gap between midpoints on
 * nights before free days (Friday and Saturday night) and before work days;
 * an hour or more is tied to worse health. Needs 7 nights.
 */
export function chronotype(nights: { start: number; end: number }[], utcOffset: number) {
  if (nights.length < 7) return calibrating(nights.length, 7);
  const rows = nights.map((n) => {
    const mid = nightMinutes((n.start + n.end) / 2, utcOffset);
    // The local weekday the night ended on: Saturday and Sunday mornings follow free evenings.
    const weekday = new Date(n.end + utcOffset * 1000).getUTCDay();
    return { mid, free: weekday === 0 || weekday === 6, bed: nightMinutes(n.start, utcOffset), wake: nightMinutes(n.end, utcOffset) };
  });
  const midpoint = Math.round(median(rows.map((r) => r.mid))!);
  const free = rows.filter((r) => r.free).map((r) => r.mid);
  const work = rows.filter((r) => !r.free).map((r) => r.mid);
  const jetlag = free.length >= 2 && work.length >= 3 ? Math.round(Math.abs(median(free)! - median(work)!)) : null;
  const type = midpoint < 180 ? "early" : midpoint < 270 ? "intermediate" : "late";
  return {
    status: "ready" as const, type,
    /** Minutes after midnight (negative before it). */
    midpoint, bedtime: Math.round(median(rows.map((r) => r.bed))!), wake: Math.round(median(rows.map((r) => r.wake))!),
    socialJetlagMinutes: jetlag,
  };
}

// MARK: Sleep Regularity Index (Phillips et al. 2017)

/**
 * The Sleep Regularity Index: the chance of being in the same state (asleep
 * or awake) at any two moments 24 hours apart, scaled so 100 is the same
 * schedule every day and 0 is random. It is the measure behind the finding
 * that regular sleepers live longer (Windred et al. 2024, where the median
 * was 81 and the most regular fifth scored over 87). Worked out in 5-minute
 * steps over every pair of consecutive days in the last 2 weeks that both
 * have sleep; needs 5 such pairs.
 */
export function sleepRegularity(windows: { start: number; end: number }[], now: number) {
  const step = 5 * 60_000;
  const from = now - 14 * DAY;
  const sleeps = windows.filter((w) => w.end > from - DAY && w.start < now);
  const asleep = (at: number) => sleeps.some((w) => at >= w.start && at < w.end);
  const covered = (dayStart: number) => sleeps.some((w) => w.end > dayStart && w.start < dayStart + DAY);
  let same = 0, total = 0, pairs = 0;
  for (let day = Math.floor(from / DAY) * DAY; day + 2 * DAY <= now; day += DAY) {
    if (!covered(day) || !covered(day + DAY)) continue;
    pairs++;
    for (let at = day; at < day + DAY; at += step) {
      if (asleep(at) === asleep(at + DAY)) same++;
      total++;
    }
  }
  if (pairs < 5) return calibrating(pairs, 5);
  const score = Math.round(clamp(-100 + (200 * same) / total, 0, 100));
  const level = score >= 87 ? "very regular" : score >= 75 ? "regular" : score >= 60 ? "somewhat irregular" : "irregular";
  return { status: "ready" as const, score, level, days: pairs };
}

// MARK: Breathing disturbances (Apple, Fitbit's oxygen variation, Garmin Pulse Ox)

/**
 * Overnight breathing disturbances from the watch's minute-by-minute SpO2,
 * the idea behind the oxygen desaturation index sleep labs use (events an
 * hour where saturation falls 3 points or more below where it had been). The
 * baseline is the median of the 10 minutes before; a fall counts once until
 * saturation is back within a point of it. Under 5 an hour reads normal, 5 to
 * 15 elevated, over 15 high, the cut-offs used for the apnea-hypopnea index.
 * A wrist sensor is far noisier than a finger clip, so this is a trend to
 * watch, not a diagnosis. Needs 3 hours of readings.
 */
export function breathingDisturbances(samples: { at: number; value: number }[]) {
  const points = [...samples].sort((a, b) => a.at - b.at);
  if (points.length < 2) return null;
  let measured = 0;
  for (let i = 1; i < points.length; i++) {
    const gap = points[i].at - points[i - 1].at;
    if (gap > 0 && gap <= 5 * 60_000) measured += gap;
  }
  const hours = measured / 3_600_000;
  if (hours < 3) return null;
  let events = 0, inEvent = false, below90 = 0;
  for (let i = 0; i < points.length; i++) {
    const before = points.slice(Math.max(0, i - 10), i).filter((p) => points[i].at - p.at <= 12 * 60_000).map((p) => p.value);
    if (points[i].value < 90) below90++;
    if (before.length < 3) continue;
    const baseline = median(before)!;
    if (!inEvent && points[i].value <= baseline - 3) { events++; inEvent = true; }
    else if (inEvent && points[i].value >= baseline - 1) inEvent = false;
  }
  const index = round1(events / hours);
  return {
    index, events, hours: round1(hours),
    level: index < 5 ? "normal" : index <= 15 ? "elevated" : "high",
    average: round1(mean(points.map((p) => p.value))!), lowest: Math.min(...points.map((p) => p.value)),
    minutesBelow90: below90,
  };
}

// MARK: Readiness with contributors (Oura)

export type Contributor = { key: string; label: string; score: number | null; weight: number; detail: string };

/**
 * A readiness score the way Oura lays its out: named contributors, each
 * 0-100 against your own baseline, so the score says why. Oura doesn't
 * publish weights; these are the hub's, heaviest on the two signals the
 * research trusts most for recovery (HRV and resting heart rate). Oura's
 * body temperature contributor is left out: this watch has no skin sensor.
 * Bands are Oura's: optimal 85+, good 70-84, fair 60-69, pay attention below.
 *
 * - Resting heart rate: last night's lowest half hour against the 2-week
 *   average; each beat above costs 8 points.
 * - HRV balance: the last 3 nights' ln RMSSD against the month's, 80 at
 *   baseline, 20 points per standard deviation.
 * - Recovery index: how early in the night heart rate bottomed out (insights.ts).
 * - Sleep: last night's sleep score.
 * - Sleep balance: the 2-week average against need; full marks at need, none at 60 %.
 * - Previous day: yesterday's strain, best between 6 and 14 (rested but not idle).
 * - Activity balance: this week's load against the usual; full marks from 0.8 to 1.3.
 */
export function contributorReadiness(input: {
  lowestHr: number | null; baselineLowestHr: number | null;
  hrvRecent: number[]; hrvBaseline: number[];
  recoveryIndex: number | null;
  sleepScore: number | null;
  sleepAverageHours: number | null; needHours: number;
  yesterdayStrain: number | null;
  loadRatio: number | null;
}) {
  const hrvScore = (() => {
    if (input.hrvRecent.length < 1 || input.hrvBaseline.length < 5) return null;
    const base = input.hrvBaseline.map(Math.log);
    const spread = Math.max(0.08, sd(base) ?? 0.08);
    const z = (mean(input.hrvRecent.map(Math.log))! - mean(base)!) / spread;
    return { score: Math.round(clamp(80 + 20 * z, 0, 100)), z };
  })();
  const strain = input.yesterdayStrain;
  const ratio = input.loadRatio;
  const contributors: Contributor[] = [
    {
      key: "restingHr", label: "Resting heart rate", weight: 0.2,
      score: input.lowestHr === null || input.baselineLowestHr === null ? null
        : Math.round(clamp(100 - 8 * Math.max(0, input.lowestHr - input.baselineLowestHr), 0, 100)),
      detail: input.lowestHr === null ? "No overnight heart rate"
        : input.baselineLowestHr === null ? `${input.lowestHr} bpm` : `${input.lowestHr} bpm, usually ${Math.round(input.baselineLowestHr)}`,
    },
    {
      key: "hrvBalance", label: "HRV balance", weight: 0.25, score: hrvScore?.score ?? null,
      detail: hrvScore === null ? "Building a baseline" : hrvScore.z >= 0.5 ? "Above your baseline" : hrvScore.z <= -0.5 ? "Below your baseline" : "At your baseline",
    },
    {
      key: "recoveryIndex", label: "Recovery index", weight: 0.1, score: input.recoveryIndex,
      detail: input.recoveryIndex === null ? "No overnight heart rate" : input.recoveryIndex >= 80 ? "Heart rate settled early" : "Heart rate settled late",
    },
    {
      key: "sleep", label: "Sleep", weight: 0.2, score: input.sleepScore,
      detail: input.sleepScore === null ? "No sleep last night" : `Score ${input.sleepScore}`,
    },
    {
      key: "sleepBalance", label: "Sleep balance", weight: 0.1,
      score: input.sleepAverageHours === null ? null : Math.round(clamp((input.sleepAverageHours / input.needHours - 0.6) / 0.4, 0, 1) * 100),
      detail: input.sleepAverageHours === null ? "Not enough nights" : `${round1(input.sleepAverageHours)} h a night over 2 weeks`,
    },
    {
      key: "previousDay", label: "Previous day", weight: 0.075,
      score: strain === null ? null : Math.round(strain < 6 ? 75 + (25 * strain) / 6 : strain <= 14 ? 100 : clamp(100 - 12 * (strain - 14), 20, 100)),
      detail: strain === null ? "No data yesterday" : strain < 6 ? "A quiet day" : strain <= 14 ? "A balanced day" : "A hard day",
    },
    {
      key: "activityBalance", label: "Activity balance", weight: 0.075,
      score: ratio === null ? null : Math.round(ratio < 0.8 ? clamp(100 - 100 * (0.8 - ratio), 40, 100) : ratio <= 1.3 ? 100 : clamp(100 - 150 * (ratio - 1.3), 0, 100)),
      detail: ratio === null ? "No training history" : ratio < 0.8 ? "Less than usual" : ratio <= 1.3 ? "In your usual range" : "More than usual",
    },
  ];
  const present = contributors.filter((c) => c.score !== null);
  // The night has to be there: the score is about how you woke up.
  if (present.length < 3 || (hrvScore === null && input.lowestHr === null && input.sleepScore === null)) return { score: null, level: null, contributors };
  const weight = present.reduce((a, c) => a + c.weight, 0);
  const score = Math.round(present.reduce((a, c) => a + c.weight * c.score!, 0) / weight);
  const level = score >= 85 ? "optimal" : score >= 70 ? "good" : score >= 60 ? "fair" : "pay attention";
  return { score, level, contributors };
}

// MARK: Fitness, fatigue and form (Banister; TrainingPeaks, Strava, COROS)

/**
 * The impulse-response model every training platform's "fitness and
 * freshness" chart comes from (Banister 1975): fitness is the 42-day
 * exponential average of daily training impulse (chronic load, TrainingPeaks'
 * CTL), fatigue the 7-day one (ATL), and form is yesterday's fitness minus
 * yesterday's fatigue (TSB). Load here is TRIMP from each workout's heart
 * rate. Form reads fresh above 5, neutral from -10, building from -30 and
 * overreaching below (TrainingPeaks' zones); the ramp is how much fitness
 * rose over the last week (more than 8 a week is a known injury risk).
 */
export function fitnessFatigueForm(sessions: { at: number; load: number }[], now: number, utcOffset = 0) {
  const offset = utcOffset * 1000;
  const dayOf = (ms: number) => Math.floor((ms + offset) / DAY);
  const loads = new Map<number, number>();
  for (const s of sessions) if (s.at <= now) loads.set(dayOf(s.at), (loads.get(dayOf(s.at)) ?? 0) + s.load);
  if (loads.size === 0) return null;
  const today = dayOf(now);
  const first = Math.max(Math.min(...loads.keys()), today - 365);
  let fitness = 0, fatigue = 0;
  const series: { day: string; fitness: number; fatigue: number; form: number }[] = [];
  for (let day = first; day <= today; day++) {
    const form = fitness - fatigue;
    const load = loads.get(day) ?? 0;
    fitness += (load - fitness) / 42;
    fatigue += (load - fatigue) / 7;
    if (today - day < 90) series.push({ day: new Date(day * DAY).toISOString().slice(0, 10), fitness: round1(fitness), fatigue: round1(fatigue), form: round1(form) });
  }
  const last = series[series.length - 1];
  const weekAgo = series[series.length - 8];
  const label = last.fitness < 3 ? "No recent training" : last.form > 5 ? "Fresh" : last.form >= -10 ? "Neutral" : last.form >= -30 ? "Building" : "Overreaching";
  return { fitness: last.fitness, fatigue: last.fatigue, form: last.form, label, ramp: weekAgo ? round1(last.fitness - weekAgo.fitness) : null, series };
}

/**
 * Training monotony and strain (Foster 1998): the week's average daily load
 * over its standard deviation, and the week's load times that. A monotony
 * over 2 (every day the same, no easy days) with a high load is the pattern
 * that came before illness and overtraining in Foster's athletes.
 */
export function monotony(sessions: { at: number; load: number }[], now: number, utcOffset = 0) {
  const offset = utcOffset * 1000;
  const today = Math.floor((now + offset) / DAY);
  const days = Array.from({ length: 7 }, (_, i) => {
    const day = today - 6 + i;
    return sessions.filter((s) => Math.floor((s.at + offset) / DAY) === day).reduce((a, s) => a + s.load, 0);
  });
  const total = days.reduce((a, b) => a + b, 0);
  const trained = days.filter((d) => d > 0).length;
  if (trained < 2) return null;
  const spread = sd(days)!;
  const value = spread > 0 ? round1(clamp(mean(days)! / spread, 0, 9.9)) : 9.9;
  return { monotony: value, strain: Math.round(total * value), weekLoad: Math.round(total), level: value >= 2 ? "high" : value >= 1.5 ? "moderate" : "varied" };
}

// MARK: Training status (Garmin)

export type TrainingStatusKey = "productive" | "maintaining" | "peaking" | "recovery" | "unproductive" | "strained" | "overreaching" | "detraining" | "no status";

/**
 * Garmin's Training Status in its own words, from the three things Garmin
 * says it weighs: the VO2max trend, acute load against chronic, and HRV
 * status. The rules are the hub's reading of Garmin's descriptions:
 * - detraining: nothing for a week or more and load well under usual;
 * - overreaching: load over 1.5 times usual;
 * - strained: HRV low or unbalanced with fitness not improving;
 * - recovery: load well under usual after training recently;
 * - peaking: load easing (under usual) with fitness holding or rising;
 * - productive / maintaining / unproductive: load in range with VO2max
 *   rising, steady or falling (half a point against 4 weeks ago counts as a move).
 */
export function trainingStatus(input: {
  /** VO2max readings, oldest first. */
  vo2max: { at: number; value: number }[];
  acute: number; chronic: number; ratio: number | null;
  hrvStatus: string | null;
  lastWorkout: number | null;
  now: number;
}): { key: TrainingStatusKey; label: string; detail: string; vo2maxTrend: number | null } {
  const { now, ratio } = input;
  // The watch only writes VO2max when it moves, so a reading holds until the next one.
  const asOf = (at: number) => input.vo2max.filter((p) => p.at <= at).at(-1) ?? null;
  const current = asOf(now), before = asOf(now - 28 * DAY);
  const trend = current && before ? round1(current.value - before.value) : null;
  const direction = trend === null ? 0 : trend >= 0.5 ? 1 : trend <= -0.5 ? -1 : 0;
  const idleDays = input.lastWorkout === null ? Infinity : (now - input.lastWorkout) / DAY;
  const out = (key: TrainingStatusKey, label: string, detail: string) => ({ key, label, detail, vo2maxTrend: trend });
  if (input.lastWorkout === null || (input.chronic < 20 && input.acute < 20)) return out("no status", "No status", "Not enough training in the last 4 weeks to say.");
  if (idleDays >= 7 && (ratio === null || ratio < 0.8)) return out("detraining", "Detraining", `No workout for ${Math.floor(idleDays)} days; fitness is starting to fade.`);
  if (ratio !== null && ratio > 1.5) return out("overreaching", "Overreaching", "Load is well above what you're used to. Ease off before it costs you.");
  const hrvDown = input.hrvStatus === "low" || input.hrvStatus === "unbalanced" || input.hrvStatus === "poor";
  if (hrvDown && direction <= 0) return out("strained", "Strained", "HRV is off its baseline: your body is struggling to recover. Prioritize rest.");
  if (ratio !== null && ratio < 0.8) {
    return direction >= 0 && idleDays < 4 && ratio >= 0.6
      ? out("peaking", "Peaking", "Load is easing while fitness holds: ideal race condition, for a short while.")
      : out("recovery", "Recovery", "A lighter load is letting your body recover.");
  }
  if (direction > 0) return out("productive", "Productive", "Fitness is rising with a load you can absorb.");
  if (direction < 0) return out("unproductive", "Unproductive", "Load is fine but fitness is slipping. Look at sleep, stress and recovery.");
  return out("maintaining", "Maintaining", "Load is enough to hold your fitness. Add variety or volume to improve.");
}

// MARK: Heart rate zones and Active Zone Minutes (Garmin, Whoop, Fitbit)

/** Seconds in each of the five zones by share of max heart rate (50, 60, 70, 80, 90 %), Garmin's default. */
export function zoneSeconds(heartRate: [number, number][], maxHr: number): number[] {
  const zones = [0, 0, 0, 0, 0];
  for (let i = 1; i < heartRate.length; i++) {
    const dt = heartRate[i][0] - heartRate[i - 1][0];
    if (dt <= 0 || dt > 300) continue;
    const share = (heartRate[i][1] + heartRate[i - 1][1]) / 2 / maxHr;
    if (share < 0.5) continue;
    zones[Math.min(4, Math.floor((share - 0.5) * 10))] += dt;
  }
  return zones.map(Math.round);
}

/**
 * Where the training time went: minutes per zone over a period, and the
 * intensity distribution coaches read from it (Seiler): low is zones 1-2,
 * moderate zone 3, high zones 4-5. Polarized is the 80/20 pattern (at least
 * 70 % low with more high than moderate), pyramidal is mostly low with more
 * moderate than high, threshold is a third or more in zone 3, and high
 * intensity is over 35 % in zones 4-5. Needs an hour in the zones.
 */
export function zoneDistribution(sessions: { zones?: number[] | null }[]) {
  const total = [0, 0, 0, 0, 0];
  for (const s of sessions) (s.zones ?? []).slice(0, 5).forEach((seconds, i) => { total[i] += seconds; });
  const sum = total.reduce((a, b) => a + b, 0);
  const minutes = total.map((s) => Math.round(s / 60));
  if (sum < 3600) return { minutes, low: null, moderate: null, high: null, pattern: null as string | null };
  const low = (total[0] + total[1]) / sum, moderate = total[2] / sum, high = (total[3] + total[4]) / sum;
  const pattern = high > 0.35 ? "High intensity" : moderate >= 0.33 ? "Threshold" : low >= 0.7 && high >= moderate ? "Polarized"
    : low >= 0.9 ? "Base" : low >= 0.6 ? "Pyramidal" : "Mixed";
  return { minutes, low: Math.round(low * 100), moderate: Math.round(moderate * 100), high: Math.round(high * 100), pattern };
}

/**
 * Fitbit's Active Zone Minutes from all-day heart rate: a minute in the fat
 * burn zone (40-59 % of heart rate reserve) earns one, a minute in cardio
 * (60-84 %) or peak (85 %+) earns two. The weekly goal is 150, the WHO and
 * AHA guideline (150 moderate minutes, vigorous counting double).
 */
export function activeZoneMinutes(heartRate: { at: number; bpm: number }[], profile: Profile) {
  let fatBurn = 0, cardio = 0, peak = 0;
  for (let i = 1; i < heartRate.length; i++) {
    const minutes = (heartRate[i].at - heartRate[i - 1].at) / 60_000;
    if (minutes <= 0 || minutes > 5) continue;
    const x = hrr(heartRate[i].bpm, profile);
    if (x >= 0.85) peak += minutes; else if (x >= 0.6) cardio += minutes; else if (x >= 0.4) fatBurn += minutes;
  }
  return { minutes: Math.round(fatBurn + 2 * (cardio + peak)), fatBurn: Math.round(fatBurn), cardio: Math.round(cardio), peak: Math.round(peak) };
}

// MARK: Strain target (Whoop's Strain Coach)

/**
 * How much strain today can take, from this morning's recovery: Whoop's
 * guidance is 14-18 on a green recovery, 10-14 on yellow and under 10 on red.
 * Here the range slides with the score inside each band rather than jumping
 * at the edges.
 */
export function strainTarget(recoveryScore: number | null, todayStrain: number | null) {
  if (recoveryScore === null) return null;
  const r = clamp(recoveryScore, 0, 100);
  const centre = r <= 33 ? 5 + (r / 33) * 4 : r <= 66 ? 10 + ((r - 34) / 32) * 3.5 : 14.5 + ((r - 67) / 33) * 2.5;
  const low = round1(Math.max(0, centre - 1.5)), high = round1(Math.min(21, centre + 1.5));
  const state = todayStrain === null ? null : todayStrain < low ? "below" : todayStrain <= high ? "in range" : "above";
  return { low, high, state, advice: r >= 67 ? "Recovered: a good day to push." : r >= 34 ? "Keep it moderate." : "Take it easy: active recovery or rest." };
}

// MARK: Cardio recovery (Apple, Garmin)

/**
 * Heart rate recovery: how far heart rate falls in the two minutes after a
 * workout stops (the watch measures it when you stay on the summary screen).
 * A faster fall means a fitter, better recovered heart; a 2-minute drop of 22
 * beats or less predicted mortality in Shetler et al. 2001. The bands above
 * that are the hub's: 23-39 fair, 40-54 good, 55 and over excellent. The
 * average is over the last five hard finishes in 6 months.
 */
export function cardioRecovery(sessions: { at: number; recoveryHr: number | null; endHr: number | null }[], maxHr: number, now: number) {
  // Only after a real effort: stopping from under 70 % of max, there isn't far to fall.
  const recent = sessions
    .filter((s) => s.recoveryHr !== null && s.recoveryHr > 0 && s.endHr !== null && s.endHr >= 0.7 * maxHr && now - s.at < 180 * DAY && s.at <= now)
    .sort((a, b) => b.at - a.at);
  if (!recent.length) return null;
  const average = Math.round(mean(recent.slice(0, 5).map((s) => s.recoveryHr!))!);
  return {
    latest: recent[0].recoveryHr!, at: new Date(recent[0].at).toISOString(), average, sessions: recent.length,
    level: average <= 22 ? "low" : average < 40 ? "fair" : average < 55 ? "good" : "excellent",
  };
}

// MARK: HRV stability and the health monitor (Whoop, Oura's Symptom Radar)

/**
 * How steady overnight HRV has been over the last week: the coefficient of
 * variation of RMSSD. A week under 10 % is stable; a rising value, with HRV
 * swinging night to night, is an early sign of not coping with load before
 * the average itself drops (Flatt & Esco 2016). Needs 4 nights.
 */
export function hrvStability(nights: { at: number; rmssd: number }[], now: number) {
  const week = nights.filter((n) => now - n.at < 7 * DAY && n.at <= now && n.rmssd > 0).map((n) => n.rmssd);
  if (week.length < 4) return calibrating(week.length, 4);
  const cv = round1((100 * sd(week)!) / mean(week)!);
  return { status: "ready" as const, cv, level: cv < 10 ? "stable" : cv < 18 ? "variable" : "unstable", nights: week.length };
}

export type HealthSign = { key: "restingHr" | "hrv" | "respiration" | "spo2"; label: string; value: number; usual: number; z: number; flagged: boolean };

/**
 * A health monitor in the style of Whoop's and Oura's Symptom Radar: last
 * night's resting heart rate, HRV, breathing rate and SpO2 against the last 4
 * weeks, each turned so that positive means strain (heart rate and breathing
 * up, HRV and SpO2 down). A sign 1.5 standard deviations out counts one
 * point, 2.5 counts two; a point or two reads as minor signs, three or more
 * as major signs, the pattern that tends to show a day or two before an
 * illness is felt (Mishra et al. 2020). Needs 7 baseline nights.
 */
export function healthMonitor(
  last: { restingHr: number | null; hrv: number | null; respiration: number | null; spo2: number | null },
  baseline: { restingHr: number | null; hrv: number | null; respiration: number | null; spo2: number | null }[],
) {
  const specs = [
    { key: "restingHr" as const, label: "Resting heart rate", sign: 1, floor: 2, log: false },
    { key: "hrv" as const, label: "HRV", sign: -1, floor: 0.08, log: true },
    { key: "respiration" as const, label: "Breathing rate", sign: 1, floor: 0.4, log: false },
    { key: "spo2" as const, label: "Blood oxygen", sign: -1, floor: 0.8, log: false },
  ];
  const have = Math.max(...specs.map((s) => baseline.filter((b) => b[s.key] !== null).length), 0);
  if (have < 7) return calibrating(have, 7);
  const signs: HealthSign[] = [];
  for (const spec of specs) {
    const value = last[spec.key];
    const values = baseline.map((b) => b[spec.key]).filter((v): v is number => v !== null);
    if (value === null || values.length < 7) continue;
    const scaled = values.map((v) => (spec.log ? Math.log(v) : v));
    const mu = mean(scaled)!;
    const z = (spec.sign * ((spec.log ? Math.log(value) : value) - mu)) / Math.max(spec.floor, sd(scaled) ?? spec.floor);
    signs.push({ key: spec.key, label: spec.label, value: round1(value), usual: round1(spec.log ? Math.exp(mu) : mu), z: round1(z), flagged: z >= 1.5 });
  }
  if (!signs.length) return null;
  const points = signs.reduce((a, s) => a + (s.z >= 2.5 ? 2 : s.z >= 1.5 ? 1 : 0), 0);
  return { status: "ready" as const, level: points === 0 ? "no signs" : points <= 2 ? "minor signs" : "major signs", points, signs };
}
