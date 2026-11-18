import { type FitMessage, fitDate, num } from "./fit.ts";

/**
 * The numbers Garmin's firmware works out on the watch itself (Firstbeat's
 * models) and writes into its metrics, sleep and activity files: Training
 * Readiness, acute and chronic load, load focus, Endurance and Hill Score,
 * race predictions, recovery time, sleep need, sleep sub-scores and more.
 *
 * None of these are in the public FIT profile. Message and field numbers are
 * from Gadgetbridge's FIT profile (fit_profile.json, AGPL-3.0), checked
 * against this watch's files: e.g. readiness 78 sits at level 4 ("high",
 * 75-94) and 34 at level 2 ("low", 25-49), and the readiness message's sleep
 * score matches the sleep file's. Fields Gadgetbridge leaves unnamed are kept
 * under `raw` so they can be named later without re-reading the files.
 *
 * Lactate threshold speed is stored in 0.1 km/h (133 is 13.3 km/h, 3.7 m/s),
 * so it is divided by 36 to give m/s.
 *
 * Pure, so it runs under `node --test`.
 */

/** A field: number and divisor. */
type Spec = Record<string, [field: number, scale?: number]>;

/** `split`: a field whose value joins the kind, for messages that come several to a timestamp. */
type Def = { kind: string; time?: number; fields: Spec; raw?: number[]; split?: number };

const DEFS: Record<number, Def> = {
  369: {
    kind: "readiness",
    fields: {
      score: [0], level: [1], sleepScore: [4], recoveryMinutes: [7], trackedSleep: [18], weeklyHrv: [21, 128], acuteLoad: [22],
    },
    raw: [2, 3, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 19, 25, 26, 27, 28, 29, 30],
  },
  378: { kind: "training_load", fields: { acute: [3], chronic: [4], ratio: [5, 10] }, raw: [0, 1, 2] },
  294: {
    kind: "load_focus",
    // Actuals are 0-2. Targets follow as min/max pairs: Gadgetbridge names
    // 7-8 the anaerobic target, so 3-4 and 5-6 are low and high aerobic.
    fields: {
      low: [0, 65536], high: [1, 65536], anaerobic: [2, 65536],
      lowMin: [3], lowMax: [4], highMin: [5], highMax: [6], anaerobicMin: [7], anaerobicMax: [8],
    },
  },
  232: { kind: "load_history", fields: { weeklyLoad: [5], targetMin: [6], targetMax: [7] }, raw: [2, 3, 9, 11] },
  403: {
    kind: "endurance_score",
    fields: {
      score: [0], level: [1], intermediate: [3], trained: [4], wellTrained: [5], expert: [6], superior: [7], elite: [8],
      gaugeLow: [9], gaugeHigh: [10],
    },
  },
  402: { kind: "hill_score", fields: { score: [0], strength: [1], endurance: [2], trend: [3], level: [4] } },
  339: { kind: "race_predictions", fields: { fiveK: [1], tenK: [2], half: [3], marathon: [4] } },
  284: { kind: "recovery", time: 1, fields: { minutes: [0] } },
  357: { kind: "recovery_true_up", fields: { staminaLoad: [0], staminaDistance: [1], minutes: [2] } },
  410: { kind: "sleep_need", fields: { normalMinutes: [0], needMinutes: [1] }, raw: [2, 3, 4, 5, 6] },
  356: {
    kind: "functional",
    fields: { ftp: [4], runLtPower: [7], runLtHr: [8], bikeLtHr: [9] },
    raw: [0, 1, 2, 3, 5, 6, 10, 11, 12],
  },
  346: {
    kind: "sleep_scores",
    fields: {
      overall: [6], quality: [7], duration: [4], deep: [3], light: [5], rem: [9], recovery: [8], restlessness: [10],
      awakeTime: [1], awakenings: [2], interruptions: [14], combinedAwake: [0], awakeningsCount: [11],
      avgStress: [15, 100],
    },
    raw: [12, 13, 16],
  },
  384: {
    kind: "daily_sleep",
    fields: {
      score: [2], minHr: [0], awakeSeconds: [3], start: [9], end: [11], startBattery: [14], endBattery: [16],
      endBatteryYesterday: [15], durationScore: [20], sleepPressure: [22], recoveryScore: [23], awakeDuration: [24],
      qualityScore: [25],
    },
    raw: [1, 17, 18, 19, 21],
  },
  471: { kind: "sleep_disruption", fields: { severity: [0] } },
  // Sleep file: restless moments in the night, and Garmin's sleep insight (score and window; the rest unnamed).
  382: { kind: "sleep_restless", fields: { count: [1], startOffset: [0] } },
  // The watch's own averages over the night (Gadgetbridge's SLEEP_INSIGHT): HRV in ms, SpO2, breaths and beats a minute.
  521: {
    kind: "sleep_insight",
    fields: {
      score: [1], hrv: [2, 65536], start: [3], end: [5], skinTempDeviation: [7, 10], spo2: [8, 100], respiration: [9, 100],
      heartRate: [10, 100],
    },
    raw: [11],
  },
  // A nap the watch detected (it writes these in a sleep file with no stages).
  412: { kind: "nap", time: 0, fields: { start: [0], end: [2], feedback: [4], deleted: [5], source: [6] } },
  // Metrics file: what each sport adds to the Endurance Score, and heat/altitude acclimation.
  404: { kind: "endurance_contributor", split: 0, fields: { sport: [0], subSport: [1], contribution: [3, 100] } },
  281: { kind: "acclimatization", fields: { acclimatizedAltitude: [4], altitude: [11] }, raw: [0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 12, 13] },
  // Unnamed in Gadgetbridge's profile; kept whole so they can be named later.
  330: { kind: "metrics_330", time: 1, fields: {}, raw: [0, 2, 3] },
  407: { kind: "monitor_407", fields: {}, raw: [0, 1, 2, 3, 4, 5, 6, 7] },
  408: { kind: "monitor_408", fields: {}, raw: [0, 1, 2] },
  79: {
    kind: "user_metrics",
    fields: {
      vo2max: [0, 292.5714], maxHr: [6], recoveryMinutes: [8], monthlyLoad: [9], minHr: [10], lthr: [11],
      ltSpeed: [13, 36], startBattery: [15], sleepNeedMinutes: [38], wakeSecondOfDay: [25], sleepSecondOfDay: [26],
    },
  },
};

/** Kinds whose `start` and `end` are times. */
const UNIX_WINDOWS = new Set(["daily_sleep", "sleep_insight", "nap"]);

export type WatchMetric = { kind: string; at: string; data: Record<string, number | null> };

/** Every watch-computed reading in a file, newest last. */
export function watchMetrics(messages: FitMessage[]): WatchMetric[] {
  const out: WatchMetric[] = [];
  let lastTime: number | null = null;
  for (const message of messages) {
    const stamp = num(message, 253);
    if (stamp !== null) lastTime = stamp;
    const def = DEFS[message.num];
    if (!def) continue;
    const time = (def.time !== undefined ? num(message, def.time) : null) ?? stamp ?? lastTime;
    if (time === null) continue;
    const data: Record<string, number | null> = {};
    for (const [name, [field, scale]] of Object.entries(def.fields)) {
      const value = num(message, field, scale ?? 1);
      data[name] = value === null ? null : Math.round(value * 100) / 100;
    }
    for (const field of def.raw ?? []) {
      const value = num(message, field);
      if (value !== null) data[`f${field}`] = value;
    }
    // A record of only nulls (unset fields) says nothing.
    if (Object.values(data).every((v) => v === null)) continue;
    // Sleep window times are FIT seconds; turn them into Unix seconds.
    for (const key of ["start", "end"]) {
      if (UNIX_WINDOWS.has(def.kind) && data[key] !== null && data[key] !== undefined) data[key] = Math.round(fitDate(data[key]!).getTime() / 1000);
    }
    const split = def.split === undefined ? null : num(message, def.split);
    out.push({ kind: split === null ? def.kind : `${def.kind}_${split}`, at: fitDate(time).toISOString(), data });
  }
  return out;
}

export const READINESS_LEVELS = ["none", "poor", "low", "moderate", "high", "prime"] as const;

// MARK: Activity extras

const CATEGORIES: Record<number, string> = {
  0: "bench_press", 1: "calf_raise", 2: "cardio", 3: "carry", 4: "chop", 5: "core", 6: "crunch", 7: "curl", 8: "deadlift",
  9: "flye", 10: "hip_raise", 11: "hip_stability", 12: "hip_swing", 13: "hyperextension", 14: "lateral_raise",
  15: "leg_curl", 16: "leg_raise", 17: "lunge", 18: "olympic_lift", 19: "plank", 20: "plyo", 21: "pull_up", 22: "push_up",
  23: "row", 24: "shoulder_press", 25: "shoulder_stability", 26: "shrug", 27: "sit_up", 28: "squat", 29: "total_body",
  30: "triceps_extension", 31: "warm_up", 32: "run", 33: "bike", 34: "cardio_sensors", 35: "move", 36: "pose",
  37: "banded_exercises", 38: "battle_rope", 39: "elliptical", 40: "floor_climb", 41: "indoor_bike", 42: "indoor_row",
  43: "ladder", 44: "sandbag", 45: "sled", 46: "sledge_hammer", 47: "stair_stepper", 49: "suspension", 50: "tire",
  52: "run_indoor", 53: "bike_outdoor",
};

/** Firstbeat's primary benefit labels, as Garmin Connect shows them. */
const BENEFITS: Record<number, string> = {
  0: "none", 1: "recovery", 2: "base", 3: "tempo", 4: "threshold", 5: "vo2max", 6: "anaerobic", 7: "sprint",
};

export type StrengthSet = { at: string; seconds: number | null; reps: number | null; weightKg: number | null; exercise: string | null };
export type Lap = { start: string; seconds: number | null; meters: number | null; avgSpeed: number | null; avgHr: number | null; maxHr: number | null; ascent: number | null };
export type BestEffort = { meters: number; seconds: number; personalRecord: boolean };

export type ActivityExtras = {
  /** Firstbeat's verdict on what the session trained. */
  primaryBenefit: string | null;
  /** Performance Condition at the end, −20 to +20 against your fitness. */
  performanceCondition: number | null;
  endingBodyBattery: number | null;
  lactateThresholdHr: number | null;
  /** Lactate threshold pace, m/s. */
  lactateThresholdSpeed: number | null;
  /** The watch's race predictions after this run, seconds. */
  racePredictions: { fiveK: number | null; tenK: number | null; half: number | null; marathon: number | null } | null;
  /** Active sets only, rest periods dropped. */
  sets: StrengthSet[];
  laps: Lap[];
  bestEfforts: BestEffort[];
  /** The rest of the session message, and Body Battery from the records (absent on files parsed before). */
  session?: SessionExtras;
};

export type SessionExtras = {
  activeSeconds: number | null;
  avgTempC: number | null; minTempC: number | null; maxTempC: number | null;
  sweatLossMl: number | null;
  /** Heart rate drop in the two minutes after stopping. */
  recoveryHr: number | null;
  startStress: number | null; endStress: number | null; avgStress: number | null; maxStress: number | null;
  avgRespiration: number | null; minRespiration: number | null; maxRespiration: number | null;
  avgSpo2: number | null;
  totalSets: number | null; volumeKg: number | null;
  metabolicKcal: number | null;
  floorsUp: number | null; floorsDown: number | null;
  /** The watch's after-workout questions: perceived effort (0-100, 10 per RPE step) and feel (0 weak - 100 strong). */
  rpe: number | null; feel: number | null;
  /** Stamina potential at the start and end, and its lowest, percent. */
  startStamina: number | null; endStamina: number | null; minStamina: number | null;
  startBodyBattery: number | null; endBodyBattery: number | null;
  /** Running dynamics and power, when the sport records them (absent on files parsed before). */
  minHr?: number | null;
  /** Steps a minute for runs and walks (both feet), revolutions for rides. */
  avgCadence?: number | null; maxCadence?: number | null;
  avgPowerW?: number | null; maxPowerW?: number | null; normalizedPowerW?: number | null;
  verticalOscillationMm?: number | null; groundContactMs?: number | null; verticalRatio?: number | null; stepLengthM?: number | null;
  /** Pace with the hills taken out, m/s. */
  gradeAdjustedSpeed?: number | null;
  /** The watch's own time in heart rate zones 1-5, seconds. */
  zoneSeconds?: number[] | null;
};

const round2 = (value: number | null) => (value === null ? null : Math.round(value * 100) / 100);

/** The watch's time in each heart rate zone for the whole session (time_in_zone, field 2, ms). */
function zoneSeconds(messages: FitMessage[]): number[] | null {
  const zones = messages.filter((m) => m.num === 216).map((m) => m.fields.get(2)).filter((v): v is (number | null)[] => Array.isArray(v));
  // The watch writes seven numbers: time under zone 1 (often garbage), zones 1-5, and a spare.
  const totals = zones.map((z) => (z.length >= 6 ? z.slice(1, 6) : z.slice(0, 5)).map((ms) => Math.round((ms ?? 0) / 1000)));
  // One per lap and one for the session: the session's is the one with the most time.
  const best = totals.sort((a, b) => b.reduce((x, y) => x + y, 0) - a.reduce((x, y) => x + y, 0))[0];
  return best && best.some((s) => s > 0) ? best : null;
}

function sessionExtras(messages: FitMessage[]): SessionExtras | undefined {
  const session = messages.find((m) => m.num === 18);
  if (!session) return undefined;
  const f = (field: number, scale = 1) => num(session, field, scale);
  const sport = f(5);
  // Running and walking cadence is stored per leg (strides); double it for steps a minute.
  const cadence = (whole: number | null, fraction: number | null) =>
    (whole === null ? null : Math.round((whole + (fraction ?? 0)) * (sport === 1 || sport === 11 || sport === 17 ? 2 : 1)));
  const battery = messages.filter((m) => m.num === 20).map((m) => num(m, 143)).filter((v): v is number => v !== null && v <= 100);
  return {
    activeSeconds: f(78, 1000),
    avgTempC: f(57), minTempC: f(150), maxTempC: f(58),
    sweatLossMl: f(178),
    recoveryHr: f(202),
    startStress: f(189, 100), endStress: f(190, 100), avgStress: f(195), maxStress: f(201),
    avgRespiration: f(169, 100) ?? f(147), minRespiration: f(180, 100) ?? f(149), maxRespiration: f(170, 100) ?? f(148),
    avgSpo2: f(194),
    totalSets: f(151), volumeKg: f(152, 100),
    metabolicKcal: f(196),
    floorsUp: f(157), floorsDown: f(158),
    rpe: f(193), feel: f(192),
    startStamina: f(205), endStamina: f(206), minStamina: f(207),
    startBodyBattery: f(215) ?? battery[0] ?? null, endBodyBattery: f(216) ?? battery.at(-1) ?? null,
    minHr: f(64),
    avgCadence: cadence(f(18), f(92, 128)), maxCadence: cadence(f(19), f(93, 128)),
    avgPowerW: f(20), maxPowerW: f(21), normalizedPowerW: f(34),
    verticalOscillationMm: f(89, 10), groundContactMs: f(91, 10), verticalRatio: f(132, 100),
    stepLengthM: round2(f(134, 10000)),
    gradeAdjustedSpeed: f(211, 1000),
    zoneSeconds: zoneSeconds(messages),
  };
}

export function activityExtras(messages: FitMessage[]): ActivityExtras {
  const physio = messages.find((m) => m.num === 140);
  const p = (field: number, scale = 1) => (physio ? num(physio, field, scale) : null);
  const races = [p(69), p(70), p(71), p(72)];
  const benefit = p(41);
  const sets = messages.filter((m) => m.num === 225 && num(m, 5) === 1).map((m) => {
    const start = num(m, 6) ?? num(m, 254);
    const category = m.fields.get(7);
    const first = Array.isArray(category) ? category[0] : category;
    const weight = num(m, 4, 16);
    return {
      at: start === null ? new Date(0).toISOString() : fitDate(start).toISOString(),
      seconds: num(m, 0, 1000),
      reps: num(m, 3),
      weightKg: weight === null ? null : Math.round(weight * 10) / 10,
      exercise: typeof first === "number" ? (CATEGORIES[first] ?? null) : null,
    };
  });
  const laps = messages.filter((m) => m.num === 19).map((m) => ({
    start: fitDate(num(m, 2) ?? num(m, 253) ?? 0).toISOString(),
    seconds: num(m, 8, 1000) ?? num(m, 7, 1000),
    meters: num(m, 9, 100),
    avgSpeed: num(m, 110, 1000) ?? num(m, 13, 1000),
    avgHr: num(m, 15),
    maxHr: num(m, 16),
    ascent: num(m, 21),
  }));
  const bestEfforts = messages.filter((m) => m.num === 113 && num(m, 2, 100) !== null && num(m, 3, 1000) !== null)
    .map((m) => ({ meters: num(m, 2, 100)!, seconds: num(m, 3, 1000)!, personalRecord: num(m, 5) === 1 }));
  return {
    primaryBenefit: benefit === null ? null : (BENEFITS[benefit] ?? null),
    performanceCondition: p(17),
    endingBodyBattery: p(25),
    lactateThresholdHr: p(14),
    lactateThresholdSpeed: p(16, 36),
    racePredictions: races.every((r) => r === null || r === 0) ? null
      : { fiveK: races[0] || null, tenK: races[1] || null, half: races[2] || null, marathon: races[3] || null },
    sets, laps, bestEfforts,
    session: sessionExtras(messages),
  };
}
