import { type FitMessage, fitDate, num } from "./fit.ts";
import {
  aerobicEffect, type AnaerobicFeatures, anaerobicEffect, anaerobicFeatures, best20MinHr, bestClimbRate, earlyVo2max, effortRating, type FocusSplit,
  focusSplit, steadyPairs, strain, trimp,
} from "./insights.ts";
import { epocPeak, type Profile, runVo2max, type Sample } from "./physiology.ts";
import { zoneSeconds } from "./scores.ts";
import { type ActivityExtras, activityExtras, type WatchMetric, watchMetrics } from "./watch-metrics.ts";

/**
 * Turns decoded FIT messages into what the hub stores: an activity summary,
 * daily steps and resting heart rate, heart rate samples, and sleep. Message
 * and field numbers are from the FIT SDK profile (Profile.xlsx).
 *
 * The raw files are kept, so they can be parsed again when this file learns
 * more (npm run fitness:reparse).
 */

const MSG = {
  session: 18,
  record: 20,
  activity: 34,
  monitoring: 55,
  monitoringInfo: 103,
  monitoringHrData: 211,
  sleepLevel: 275,
  sleepInsight: 521,
  event: 21,
  sleepAssessment: 346,
  userProfile: 3,
  timeInZone: 216,
  // Undocumented in the public profile; read by field position, as Garmin's own tools do.
  physiologicalMetrics: 140,
  stressLevel: 227,
  spo2: 269,
  respiration: 297,
  hrvStatusSummary: 370,
  hrvValue: 371,
  skinTemp: 398,
} as const;

const SPORTS: Record<number, string> = {
  0: "generic", 1: "running", 2: "cycling", 3: "transition", 4: "fitness_equipment", 5: "swimming",
  6: "basketball", 7: "soccer", 8: "tennis", 9: "american_football", 10: "training", 11: "walking",
  12: "cross_country_skiing", 13: "alpine_skiing", 14: "snowboarding", 15: "rowing", 16: "mountaineering",
  17: "hiking", 18: "multisport", 19: "paddling", 20: "flying", 21: "e_biking", 22: "motorcycling",
  23: "boating", 24: "driving", 25: "golf", 26: "hang_gliding", 27: "horseback_riding", 28: "hunting",
  29: "fishing", 30: "inline_skating", 31: "rock_climbing", 32: "sailing", 33: "ice_skating",
  34: "sky_diving", 35: "snowshoeing", 36: "snowmobiling", 37: "stand_up_paddleboarding", 38: "surfing",
  39: "wakeboarding", 40: "water_skiing", 41: "kayaking", 42: "rafting", 43: "windsurfing", 44: "kitesurfing",
  45: "tactical", 46: "jumpmaster", 47: "boxing", 48: "floor_climbing", 53: "diving", 62: "hiit",
  64: "racket", 76: "water_tubing", 77: "wakesurfing", 80: "mixed_martial_arts", 82: "snorkeling", 83: "dance",
  84: "jump_rope",
};

const SUB_SPORTS: Record<number, string> = {
  0: "generic", 1: "treadmill", 2: "street", 3: "trail", 4: "track", 5: "spin", 6: "indoor_cycling", 7: "road",
  8: "mountain", 9: "downhill", 10: "recumbent", 11: "cyclocross", 12: "hand_cycling", 13: "track_cycling",
  14: "indoor_rowing", 15: "elliptical", 16: "stair_climbing", 17: "lap_swimming", 18: "open_water",
  19: "flexibility_training", 20: "strength_training", 21: "warm_up", 22: "match", 23: "exercise", 24: "challenge",
  25: "indoor_skiing", 26: "cardio_training", 27: "indoor_walking", 28: "e_bike_fitness", 29: "bmx",
  30: "casual_walking", 31: "speed_walking", 32: "bike_to_run_transition", 33: "run_to_bike_transition",
  34: "swim_to_bike_transition", 35: "atv", 36: "motocross", 37: "backcountry", 38: "resort", 39: "rc_drone",
  40: "wingsuit", 41: "whitewater", 42: "skate_skiing", 43: "yoga", 44: "pilates", 45: "indoor_running",
  46: "gravel_cycling", 47: "e_bike_mountain", 48: "commuting", 49: "mixed_surface", 50: "navigate", 51: "track_me",
  52: "map", 53: "single_gas_diving", 54: "multi_gas_diving", 55: "gauge_diving", 56: "apnea_diving",
  57: "apnea_hunting", 58: "virtual_activity", 59: "obstacle", 62: "breathing", 65: "sail_race", 67: "ultra",
  68: "indoor_climbing", 69: "bouldering", 70: "hiit", 73: "amrap", 74: "emom", 75: "tabata", 84: "pickleball",
  85: "padel",
};

export type ActivitySummary = {
  sport: string;
  subSport: string | null;
  startTime: string;
  /** Local time minus UTC, in seconds, when the file says. */
  utcOffset: number | null;
  elapsedSeconds: number | null;
  movingSeconds: number | null;
  distanceMeters: number | null;
  calories: number | null;
  avgHeartRate: number | null;
  maxHeartRate: number | null;
  ascentMeters: number | null;
  avgSpeed: number | null;
  trainingEffect: number | null;
  /** [seconds from start, bpm], at most 300 points. */
  heartRate: [number, number][];
  metrics: ActivityMetrics;
};

/**
 * The hub's own numbers for the activity (see physiology.ts), the heart rate
 * profile they were worked out with, and what the watch itself said, kept to
 * check the hub's models against.
 */
export type ActivityMetrics = {
  profile: Profile | null;
  load: number | null;
  vo2max: number | null;
  vo2maxMinutes: number | null;
  watch: {
    load: number | null; vo2max: number | null; recoveryHours: number | null; trainingEffect: number | null;
    anaerobicEffect?: number | null;
  };
  /** The insights.ts numbers for this session (absent on files parsed before they existed). */
  trimp?: number | null;
  strain?: number | null;
  aerobicEffect?: number | null;
  anaerobic?: AnaerobicFeatures | null;
  anaerobicEffect?: number | null;
  effort?: number | null;
  focus?: FocusSplit | null;
  best20Hr?: number | null;
  bestClimbRate?: number | null;
  /** Seconds in heart rate zones 1-5, by share of max heart rate (absent on files parsed before). */
  zones?: number[] | null;
  /** Laps, strength sets, best efforts and the watch's verdicts (absent on files parsed before they existed). */
  extras?: ActivityExtras;
  /** Runs only: VO2max over minutes 6-20, and steady [heart rate, m/s] minutes. */
  earlyVo2max?: number | null;
  steady?: [number, number][];
};

export type DailySummary = {
  day: string; steps: number | null; restingHeartRate: number | null;
  /** The rest of the watch's day totals; null on files that don't carry them. */
  distanceMeters?: number | null; activeKcal?: number | null; activeSeconds?: number | null;
  /** Resting (basal) calories for the whole day, from monitoring_info. */
  restingKcal?: number | null; stepGoal?: number | null;
  /** Climbed and descended so far today, metres (a floor is 3.048 m). */
  ascentMeters?: number | null; descentMeters?: number | null;
  moderateMinutes?: number | null; vigorousMinutes?: number | null;
  /** True once the watch's closing summary for the day is in: the totals are final. */
  final?: boolean;
};
export type HeartRateSample = { at: string; bpm: number };
/** Overnight and spot readings: RMSSD (ms), SpO2 (%), breaths a minute, skin temperature change (°C). */
/** Also the watch's own all-day stress (0-100) and Body Battery (0-100), each minute. */
/** And from monitoring: steps taken since the previous record, and the minute's intensity (0-7). */
export type VitalSample = {
  kind: "hrv" | "spo2" | "respiration" | "skin_temp" | "stress" | "body_battery" | "steps" | "intensity"; at: string; value: number;
};
export type SleepSummary = {
  start: string;
  end: string;
  deepSeconds: number;
  lightSeconds: number;
  remSeconds: number;
  awakeSeconds: number;
  score: number | null;
  /** [seconds from start, level], each the start of a stage: 0 unmeasurable, 1 awake, 2 light, 3 deep, 4 REM. */
  levels: [number, number][];
};

export type HrvSummary = {
  /** Local day the summary was written (the morning after the night it covers). */
  day: string;
  weeklyAverage: number | null;
  lastNightAverage: number | null;
  lastNight5MinHigh: number | null;
  baselineLowUpper: number | null;
  baselineBalancedLower: number | null;
  baselineBalancedUpper: number | null;
  /** none, poor, low, unbalanced or balanced, as the watch reports it. */
  status: string | null;
  /** [seconds from the first reading, ms], thinned to at most 150 points. */
  readings: [number, number][];
};

export type FitSummary = {
  activity: ActivitySummary | null;
  daily: DailySummary[];
  heartRate: HeartRateSample[];
  sleep: SleepSummary | null;
  hrv: HrvSummary | null;
  vitals: VitalSample[];
  /** What the watch's firmware worked out itself: readiness, load, scores (watch-metrics.ts). */
  watch: WatchMetric[];
};

/** Summarizes one file. `fallbackOffset` is the phone's UTC offset, for files that don't carry local time. */
export function summarize(messages: FitMessage[], fallbackOffset = 0): FitSummary {
  const offset = localOffset(messages) ?? fallbackOffset;
  const daily = monitoring(messages, offset);
  return {
    activity: activity(messages, offset),
    daily: daily.daily,
    heartRate: daily.heartRate,
    sleep: sleep(messages),
    hrv: hrv(messages, offset),
    vitals: [...vitals(messages), ...daily.series],
    watch: watchMetrics(messages),
  };
}

function byNum(messages: FitMessage[], number: number) {
  return messages.filter((message) => message.num === number);
}

/** Local time minus UTC from the activity or monitoring_info message. */
function localOffset(messages: FitMessage[]): number | null {
  for (const message of messages) {
    if (message.num !== MSG.activity && message.num !== MSG.monitoringInfo) continue;
    const utc = num(message, 253);
    const local = num(message, message.num === MSG.activity ? 5 : 0);
    if (utc !== null && local !== null && Math.abs(local - utc) <= 14 * 3600) return Math.round((local - utc) / 900) * 900;
  }
  return null;
}

function localDay(fitSeconds: number, offset: number): string {
  return fitDate(fitSeconds + offset).toISOString().slice(0, 10);
}

function activity(messages: FitMessage[], offset: number): ActivitySummary | null {
  const sessions = byNum(messages, MSG.session);
  const first = sessions[0];
  if (!first) return null;
  const start = num(first, 2) ?? num(first, 253);
  if (start === null) return null;
  const sum = (field: number, scale = 1) => {
    const values = sessions.map((s) => num(s, field, scale)).filter((v): v is number => v !== null);
    return values.length ? values.reduce((a, b) => a + b, 0) : null;
  };
  const max = (field: number) => {
    const values = sessions.map((s) => num(s, field)).filter((v): v is number => v !== null);
    return values.length ? Math.max(...values) : null;
  };
  const sport = num(first, 5);
  const subSport = num(first, 6);

  const records = byNum(messages, MSG.record)
    .map((r) => [num(r, 253), num(r, 3)] as const)
    .filter((pair): pair is readonly [number, number] => pair[0] !== null && pair[1] !== null && pair[1] > 0);
  const step = Math.max(1, Math.ceil(records.length / 300));
  const heartRate = records.filter((_, i) => i % step === 0).map(([t, bpm]) => [t - start, bpm] as [number, number]);
  const sportName = sessions.length > 1 ? "multisport" : sport === null ? "generic" : (SPORTS[sport] ?? `sport_${sport}`);

  return {
    sport: sportName,
    subSport: subSport === null || subSport === 0 ? null : (SUB_SPORTS[subSport] ?? `sub_sport_${subSport}`),
    startTime: fitDate(start).toISOString(),
    utcOffset: offset,
    elapsedSeconds: sum(7, 1000),
    movingSeconds: sum(8, 1000),
    distanceMeters: sum(9, 100),
    calories: sum(11),
    avgHeartRate: num(first, 16),
    maxHeartRate: max(17),
    ascentMeters: sum(22),
    avgSpeed: num(first, 124, 1000) ?? num(first, 14, 1000),
    trainingEffect: num(first, 24, 10),
    heartRate,
    metrics: activityMetrics(messages, start, sportName, subSport, records),
  };
}

/** Max and resting heart rate from the zones the watch used, or its user profile. */
function heartProfile(messages: FitMessage[]): Profile | null {
  const zones = byNum(messages, MSG.timeInZone).find((m) => num(m, 11) !== null);
  const user = byNum(messages, MSG.userProfile)[0];
  const maxHr = zones ? num(zones, 11) : null;
  const restingHr = (zones && num(zones, 12)) ?? (user && num(user, 8));
  if (!maxHr || !restingHr || maxHr - restingHr < 40) return null;
  const gender = user ? num(user, 1) : null;
  // birth year is stored as years since 1900 (field 24); height in cm (field 3, m × 100); weight in kg × 10.
  const birth = user ? num(user, 24) : null;
  const session = byNum(messages, MSG.session)[0] as FitMessage | undefined;
  const when = session ? num(session, 2) : null;
  const year = when === null ? new Date().getUTCFullYear() : fitDate(when).getUTCFullYear();
  const age = birth !== null && birth > 0 && birth < 200 ? year - 1900 - birth : null;
  const height = user ? num(user, 3) : null;
  const weight = user ? num(user, 4, 10) : null;
  return {
    maxHr, restingHr, sex: gender === 1 ? "male" : gender === 0 ? "female" : null,
    age: age !== null && age >= 10 && age <= 100 ? age : null,
    heightCm: height !== null && height > 100 && height < 250 ? height : null,
    weightKg: weight !== null && weight > 30 && weight < 250 ? weight : null,
  };
}

function activityMetrics(
  messages: FitMessage[], start: number, sport: string, subSport: number | null, heart: (readonly [number, number])[],
): ActivityMetrics {
  const session = byNum(messages, MSG.session)[0];
  const physio = byNum(messages, MSG.physiologicalMetrics)[0];
  const watchVo2 = physio ? num(physio, 7) : null;
  const recovery = physio ? num(physio, 9) : null;
  const watch = {
    // training_load_peak; max MET × 3.5 = VO2max (ml/kg/min); recovery time in minutes.
    load: num(session, 168, 65536),
    vo2max: watchVo2 ? Math.round((watchVo2 * 3.5 / 65536) * 10) / 10 : null,
    recoveryHours: recovery === null ? null : Math.round(recovery / 6) / 10,
    trainingEffect: num(session, 24, 10),
    anaerobicEffect: num(session, 137, 10),
  };
  const profile = heartProfile(messages);
  const extras = activityExtras(messages);
  if (!profile) return { profile, load: null, vo2max: null, vo2maxMinutes: null, watch, extras };
  const series = heart.map(([t, bpm]) => [t - start, bpm] as [number, number]);
  const load = heart.length > 1 ? Math.round(epocPeak(series, profile)) : null;
  const samples: Sample[] = byNum(messages, MSG.record).map((r) => {
    const altitude = num(r, 78, 5) ?? num(r, 2, 5);
    return {
      t: (num(r, 253) ?? start) - start,
      hr: num(r, 3),
      speed: num(r, 73, 1000) ?? num(r, 6, 1000),
      altitude: altitude === null ? null : altitude - 500,
      distance: num(r, 5, 100),
    };
  });
  let vo2: ReturnType<typeof runVo2max> = null;
  let early: number | null = null;
  let steady: [number, number][] = [];
  // Outdoor runs only: treadmill pace comes from the wrist and isn't reliable enough.
  if (sport === "running" && subSport !== 1) {
    vo2 = runVo2max(samples, profile);
    early = earlyVo2max(samples, profile);
    steady = steadyPairs(samples);
  }
  const impulse = series.length > 1 ? trimp(series, profile) : null;
  const aerobic = aerobicEffect(load);
  const features = series.length > 1 ? anaerobicFeatures(series, profile) : null;
  const anaerobic = features === null ? null : anaerobicEffect(features);
  return {
    profile, load,
    vo2max: vo2 && Math.round(vo2.vo2max * 10) / 10,
    vo2maxMinutes: vo2?.minutes ?? null,
    watch,
    trimp: impulse === null ? null : Math.round(impulse),
    strain: impulse === null ? null : strain(impulse),
    aerobicEffect: aerobic,
    anaerobic: features,
    anaerobicEffect: anaerobic,
    effort: effortRating(aerobic, anaerobic),
    focus: load === null ? null : focusSplit(series, profile, load),
    best20Hr: best20MinHr(series),
    bestClimbRate: bestClimbRate(samples),
    zones: series.length > 1 ? zoneSeconds(series, profile.maxHr) : null,
    earlyVo2max: early,
    steady,
    extras,
  };
}

/**
 * Overnight HRV (5-minute RMSSD), SpO2, respiration and skin temperature.
 * Field numbers follow the FIT profile; like monitoring, not yet checked
 * against files from this watch.
 */
function vitals(messages: FitMessage[]): VitalSample[] {
  const out: VitalSample[] = [];
  const add = (kind: VitalSample["kind"], time: number | null, value: number | null, low: number, high: number) => {
    if (time !== null && value !== null && value >= low && value <= high) out.push({ kind, at: fitDate(time).toISOString(), value });
  };
  for (const m of messages) {
    const time = num(m, 253);
    if (m.num === MSG.hrvValue) add("hrv", time, num(m, 0, 128), 5, 300);
    else if (m.num === MSG.spo2) add("spo2", time, num(m, 0), 70, 100);
    else if (m.num === MSG.respiration) add("respiration", time, num(m, 0, 100), 4, 60);
    else if (m.num === MSG.skinTemp) add("skin_temp", time, num(m, 1), -5, 5);
    else if (m.num === MSG.stressLevel) {
      // stress_level: 0 value (-1 active, -2 off wrist), 1 time, 3 Body Battery (undocumented, matches the watch's).
      add("stress", num(m, 1), num(m, 0), 0, 100);
      add("body_battery", num(m, 1), num(m, 3), 0, 100);
    }
  }
  return out;
}

/**
 * Monitoring, checked against this watch's files and Garmin Connect's totals
 * for the same day (575 steps, 445 m, 23 kcal, 2.2 floors on 2026-10-15).
 *
 * Steps (`cycles`), distance, active time and active calories are cumulative
 * per activity type since local midnight; a day's total is the sum over types
 * of each type's highest value. The file opens and closes with a summary of
 * the day so far (`duration_min` set); the closing one is stamped at the
 * next local midnight, so a reading at exactly midnight counts for the day
 * before. Records during the day name their type in the low five bits of
 * `current_activity_type_intensity` (the top three bits are the intensity),
 * and most carry only the low 16 bits of the time, relative to the last full
 * timestamp in the file. That timestamp can be a few seconds ahead of the
 * record (other messages interleave), so the difference is signed.
 */
function monitoring(messages: FitMessage[], offset: number): { daily: DailySummary[]; heartRate: HeartRateSample[]; series: VitalSample[] } {
  type Totals = { steps: number; meters: number | null; activeSeconds: number | null; activeKcal: number | null };
  const perType = new Map<string, Map<number, Totals>>(); // day -> activity type -> highest so far
  const days = new Map<string, Partial<DailySummary>>();
  const heartRate: HeartRateSample[] = [];
  const series: VitalSample[] = [];
  const lastSteps = new Map<string, number>(); // "day|type" -> cumulative steps at the last record
  let last: number | null = null;
  let activityType: number | null = null;

  const dayOf = (time: number) => localDay((time + offset) % 86400 === 0 ? time - 1 : time, offset);
  const day = (key: string) => {
    const value = days.get(key) ?? {};
    days.set(key, value);
    return value;
  };
  const higher = (key: keyof DailySummary, d: Partial<DailySummary>, value: number | null) => {
    if (value === null) return;
    const current = d[key] as number | null | undefined;
    (d as Record<string, unknown>)[key] = current == null ? value : Math.max(current, value);
  };

  for (const message of messages) {
    const full = num(message, 253);
    if (full !== null) last = full;
    if (message.num === MSG.monitoringInfo && full !== null) {
      // Resting calories a day, and the step goal (one per counted type; they match).
      // It opens the file, so a midnight stamp starts that day rather than ending the one before.
      const d = day(localDay(full, offset));
      const rmr = num(message, 5);
      if (rmr) d.restingKcal = rmr;
      const goals = message.fields.get(7);
      const goal = Array.isArray(goals) ? goals.find((g) => typeof g === "number" && g > 0) : goals;
      if (typeof goal === "number" && goal > 0) d.stepGoal = goal;
      continue;
    }
    if (message.num === MSG.monitoringHrData && last !== null) {
      const value = num(message, 1) ?? num(message, 0);
      if (value) day(dayOf(last)).restingHeartRate = value;
      continue;
    }
    if (message.num !== MSG.monitoring || last === null) continue;
    let time = last;
    const short = num(message, 26);
    if (full === null && short !== null) time = last + ((((short - (last & 0xffff)) & 0xffff) + 0x8000) % 0x10000) - 0x8000;
    const packed = num(message, 24);
    const type: number | null = num(message, 5) ?? (packed === null ? null : packed & 0x1f) ?? activityType;
    if (type !== null) activityType = type;
    const key = dayOf(time);
    const d = day(key);
    const minutes = num(message, 29);
    const isSummary = minutes !== null;

    const cycles = num(message, 3);
    const meters = num(message, 2, 100);
    const active = num(message, 4, 1000);
    const kcal = num(message, 19);
    if (type !== null && (cycles !== null || meters !== null || active !== null || kcal !== null)) {
      const types = perType.get(key) ?? new Map<number, Totals>();
      const t: Totals = types.get(type) ?? { steps: 0, meters: null, activeSeconds: null, activeKcal: null };
      // Walking (6) and running (1) cycles are steps.
      if (cycles !== null && (type === 1 || type === 6)) {
        const seen = lastSteps.get(`${key}|${type}`);
        if (!isSummary && seen !== undefined && cycles > seen) {
          series.push({ kind: "steps", at: fitDate(time).toISOString(), value: cycles - seen });
        }
        lastSteps.set(`${key}|${type}`, Math.max(seen ?? 0, cycles));
        t.steps = Math.max(t.steps, cycles);
      }
      if (meters !== null) t.meters = Math.max(t.meters ?? 0, meters);
      if (active !== null) t.activeSeconds = Math.max(t.activeSeconds ?? 0, active);
      if (kcal !== null) t.activeKcal = Math.max(t.activeKcal ?? 0, kcal);
      types.set(type, t);
      perType.set(key, types);
    }
    if (packed !== null && !isSummary) series.push({ kind: "intensity", at: fitDate(time).toISOString(), value: packed >> 5 });
    // Climb so far today (mm), and intensity minutes so far.
    higher("ascentMeters", d, num(message, 35, 1000));
    higher("descentMeters", d, num(message, 36, 1000));
    higher("moderateMinutes", d, num(message, 37) ?? num(message, 33));
    higher("vigorousMinutes", d, num(message, 38) ?? num(message, 34));
    // The closing summary means the watch has finished the day.
    if (minutes && (time + offset) % 86400 === 0) d.final = true;

    const bpm = num(message, 27);
    if (bpm) heartRate.push({ at: fitDate(time).toISOString(), bpm });
  }

  const sum = (types: Map<number, Totals> | undefined, field: "meters" | "activeSeconds" | "activeKcal") => {
    const values = [...(types?.values() ?? [])].map((t) => t[field]).filter((v): v is number => v !== null);
    return values.length ? Math.round(values.reduce((a, b) => a + b, 0)) : null;
  };
  // A file that opens at midnight starts with zeroed totals stamped 00:00, which would
  // otherwise make an empty row for the day before.
  const counted = (key: string) => perType.has(key) || days.get(key)!.restingHeartRate != null || days.get(key)!.restingKcal != null;
  const daily = [...days.keys()].filter(counted).sort().map((key): DailySummary => {
    const d = days.get(key)!;
    const types = perType.get(key);
    const steps = types ? [...types].filter(([type]) => type === 1 || type === 6).reduce((a, [, t]) => a + t.steps, 0) : null;
    return {
      day: key,
      steps,
      restingHeartRate: d.restingHeartRate ?? null,
      distanceMeters: sum(types, "meters"),
      activeKcal: sum(types, "activeKcal"),
      activeSeconds: sum(types, "activeSeconds"),
      restingKcal: d.restingKcal ?? null,
      stepGoal: d.stepGoal ?? null,
      ascentMeters: d.ascentMeters ?? null,
      descentMeters: d.descentMeters ?? null,
      moderateMinutes: d.moderateMinutes ?? null,
      vigorousMinutes: d.vigorousMinutes ?? null,
      final: d.final ?? false,
    };
  });
  return { daily, heartRate, series };
}

/**
 * A night from the sleep file. Each sleep_level record is stamped at the END
 * of its stage: the first stage starts at the sleep-start event and the last
 * record is stamped at the sleep-stop event, to the second, in every file from
 * this watch (checked on 27 nights; read the other way round, REM came out at
 * three to five hours a night and nights the watch scored REM 30/100 had more
 * REM than nights it scored 100). The window is the watch's own: the sleep
 * insight's start and end, else the start and stop events, else the records.
 */
function sleep(messages: FitMessage[]): SleepSummary | null {
  const levels = byNum(messages, MSG.sleepLevel)
    .map((m) => [num(m, 253), num(m, 0)] as const)
    .filter((pair): pair is readonly [number, number] => pair[0] !== null && pair[1] !== null)
    .sort((a, b) => a[0] - b[0]);
  if (levels.length === 0) return null;
  const insight = byNum(messages, MSG.sleepInsight)[0];
  const events = byNum(messages, MSG.event).map((m) => ({ at: num(m, 253), type: num(m, 1) }));
  const first = levels[0][0], last = levels[levels.length - 1][0];
  const within = (value: number | null | undefined, low: number, high: number) =>
    (value !== null && value !== undefined && value >= low && value <= high ? value : null);
  // Sleep can't have started after its first stage ended, or more than 4 hours before it.
  const start = within(insight ? num(insight, 3) : null, first - 4 * 3600, first)
    ?? within(events.find((e) => e.type === 0)?.at, first - 4 * 3600, first)
    ?? first;
  const end = last;
  const seconds = [0, 0, 0, 0, 0];
  const stages: [number, number][] = [];
  let from = start;
  for (const [until, level] of levels) {
    if (until > from) {
      if (level >= 0 && level <= 4) seconds[level] += until - from;
      // Two records in a row for one stage draw as one block.
      if (stages.length === 0 || stages[stages.length - 1][1] !== level) stages.push([from - start, level]);
    }
    from = Math.max(from, until);
  }
  if (stages.length === 0) return null;
  const assessment = byNum(messages, MSG.sleepAssessment)[0];
  return {
    start: fitDate(start).toISOString(),
    end: fitDate(end).toISOString(),
    awakeSeconds: seconds[1],
    lightSeconds: seconds[2],
    deepSeconds: seconds[3],
    remSeconds: seconds[4],
    // overall_sleep_score; the sleep insight repeats it.
    score: (assessment ? num(assessment, 6) : null) ?? (insight ? num(insight, 1) : null),
    levels: stages,
  };
}

const HRV_STATUS = ["none", "poor", "low", "unbalanced", "balanced"];

/**
 * HRV status files: one hrv_status_summary (370) per night plus hrv_value (371)
 * readings. Values are milliseconds stored with a scale of 128 in the FIT
 * profile. Not yet checked against a real file from this watch.
 */
function hrv(messages: FitMessage[], offset: number): HrvSummary | null {
  const summary = byNum(messages, MSG.hrvStatusSummary).slice(-1)[0];
  const readings = byNum(messages, MSG.hrvValue)
    .map((m) => [num(m, 253), num(m, 0, 128)] as const)
    .filter((pair): pair is readonly [number, number] => pair[0] !== null && pair[1] !== null && pair[1] > 0)
    .sort((a, b) => a[0] - b[0]);
  if (!summary && readings.length === 0) return null;
  const at = (summary && num(summary, 253)) ?? readings[readings.length - 1]?.[0] ?? null;
  if (at === null) return null;
  const first = readings[0]?.[0] ?? 0;
  const step = Math.max(1, Math.ceil(readings.length / 150));
  const status = summary ? num(summary, 6) : null;
  const value = (field: number) => (summary ? round1(num(summary, field, 128)) : null);
  return {
    day: localDay(at, offset),
    weeklyAverage: value(0),
    lastNightAverage: value(1),
    lastNight5MinHigh: value(2),
    baselineLowUpper: value(3),
    baselineBalancedLower: value(4),
    baselineBalancedUpper: value(5),
    status: status === null ? null : (HRV_STATUS[status] ?? `status_${status}`),
    readings: readings.filter((_, i) => i % step === 0).map(([t, ms]) => [t - first, round1(ms)!] as [number, number]),
  };
}

function round1(value: number | null): number | null {
  return value === null ? null : Math.round(value * 10) / 10;
}

/**
 * What a file actually contains: message numbers with counts and the field
 * numbers seen in each, plus one sample value per field. Lets us see the real
 * layout when the parsers above find nothing.
 */
export function inspect(messages: FitMessage[]): { num: number; count: number; fields: Record<number, unknown> }[] {
  const byMessage = new Map<number, { count: number; fields: Map<number, unknown> }>();
  for (const message of messages) {
    const entry = byMessage.get(message.num) ?? { count: 0, fields: new Map() };
    entry.count++;
    for (const [field, value] of message.fields) if (value !== null && !entry.fields.has(field)) entry.fields.set(field, value);
    byMessage.set(message.num, entry);
  }
  return [...byMessage.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([n, e]) => ({ num: n, count: e.count, fields: Object.fromEntries(e.fields) }));
}
