/**
 * Guesses how the morning feels from last night and yesterday, so a check-in
 * is a confirm or a nudge rather than a form: "we think you're run down,
 * here's why — right?". Every answer becomes a label, and once a state has a
 * few of them the hub fits a small model to them and leans on it more than
 * the starting rules.
 *
 * How it works:
 * - Each day is a handful of numbers (DayFeatures) from Garmin Connect's
 *   history or the watch's own files.
 * - Each number is turned into a z-score against the person's previous
 *   four weeks (median and MAD, so one bad night doesn't move the baseline).
 * - Each state starts from a hand-set logistic rule over those z-scores. The
 *   weights follow the illness-detection literature (resting HR and
 *   respiration rise, HRV falls, for more than one night) and the obvious
 *   tells of a big night out (late to bed, high sleeping HR, crushed HRV,
 *   gone by the next night). They are a prior, not a fit.
 * - Once the person has labelled a state (confirmed or denied, or checked in
 *   without it), an L2 logistic regression on their own labelled days is
 *   blended in with weight n / (n + 10). Energy works the same way with a
 *   ridge regression.
 *
 * Pure functions, no dependencies, so they run under `node --test`.
 */

const DAY = 86_400_000;

export type DayFeatures = {
  /** The local day the person woke up on (YYYY-MM-DD); last night's sleep belongs to it. */
  day: string;
  restingHr: number | null;
  hrv: number | null;
  sleepHours: number | null;
  sleepScore: number | null;
  /** Local hour the person fell asleep, counted past midnight: 23.5 is 11:30 pm, 25 is 1 am. */
  bedtime: number | null;
  sleepHr: number | null;
  respiration: number | null;
  sleepStress: number | null;
  bodyBatteryWake: number | null;
  readiness: number | null;
  spo2: number | null;
  /** Yesterday's (the day before `day`) average all-day stress and the load of its workouts. */
  dayStress: number | null;
  load: number | null;
  /** Standard drinks logged for the night before `day`: 0 for a night answered "No drinks", null or missing when nothing was logged. */
  drinks?: number | null;
  /** The night before `day` was answered "Drank, not sure how much". */
  drankUnknown?: boolean;
};

export type Metric = Exclude<keyof DayFeatures, "day" | "drinks" | "drankUnknown">;

export const METRICS: Metric[] = [
  "restingHr", "hrv", "sleepHours", "sleepScore", "bedtime", "sleepHr", "respiration", "sleepStress",
  "bodyBatteryWake", "readiness", "spo2", "dayStress", "load",
];

/** +1 when higher is better for how the day feels. Load is neither; it only matters for "run down". */
const GOOD: Record<Metric, number> = {
  restingHr: -1, hrv: 1, sleepHours: 1, sleepScore: 1, bedtime: -1, sleepHr: -1, respiration: -1, sleepStress: -1,
  bodyBatteryWake: 1, readiness: 1, spo2: 1, dayStress: -1, load: 0,
};

/** The smallest spread a baseline may have, so a very steady stretch doesn't make every small wobble look huge. */
const MIN_SPREAD: Record<Metric, number> = {
  restingHr: 1.5, hrv: 3, sleepHours: 0.4, sleepScore: 5, bedtime: 0.4, sleepHr: 1.5, respiration: 0.3, sleepStress: 3,
  bodyBatteryWake: 5, readiness: 5, spo2: 0.7, dayStress: 3, load: 20,
};

/** Up to four weeks of nights, reaching back as far as four months to get past a stretch without the watch. */
const BASELINE_DAYS = 28;
const LOOKBACK_DAYS = 120;
const MIN_BASELINE = 7;

export type Baseline = { median: number; spread: number; n: number };
export type Z = Partial<Record<Metric, number>>;

function median(values: number[]) {
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

const dayMs = (day: string) => Date.parse(`${day}T00:00:00Z`);

/** The person's usual value of each metric over their last four weeks of nights before `day` (not counting it). */
export function baselines(days: DayFeatures[], day: string): Partial<Record<Metric, Baseline>> {
  const end = dayMs(day);
  const window = days
    .filter((d) => {
      const t = dayMs(d.day);
      return t < end && t >= end - LOOKBACK_DAYS * DAY;
    })
    .sort((a, b) => b.day.localeCompare(a.day));
  const out: Partial<Record<Metric, Baseline>> = {};
  for (const metric of METRICS) {
    const values = window.map((d) => d[metric]).filter((v): v is number => v !== null && Number.isFinite(v)).slice(0, BASELINE_DAYS);
    if (values.length < MIN_BASELINE) continue;
    const m = median(values);
    const mad = median(values.map((v) => Math.abs(v - m))) * 1.4826;
    out[metric] = { median: m, spread: Math.max(mad, MIN_SPREAD[metric]), n: values.length };
  }
  return out;
}

/** How unusual each of a day's numbers is for this person, capped at ±4. */
export function zScores(features: DayFeatures, base: Partial<Record<Metric, Baseline>>): Z {
  const z: Z = {};
  for (const metric of METRICS) {
    const value = features[metric];
    const b = base[metric];
    if (value === null || !b) continue;
    z[metric] = Math.max(-4, Math.min(4, (value - b.median) / b.spread));
  }
  return z;
}

// MARK: States

export const STATES = ["sick", "hungover", "run_down", "stressed", "energized"] as const;
export type State = (typeof STATES)[number];

export const STATE_LABELS: Record<State, string> = {
  sick: "Getting sick", hungover: "Hungover", run_down: "Run down", stressed: "Stressed", energized: "Full of energy",
};

/** The model's inputs: z-scores turned so that positive means "worse than usual", plus a few combined signals. */
export const INPUTS = [
  "rhrUp", "hrvDown", "respUp", "sleepHrUp", "sleepStressUp", "lateBed", "shortSleep", "lowBattery", "lowReadiness",
  "stressUp", "loadUp", "persist", "weekendNight", "wellness", "drank", "dryNight",
] as const;
type Input = (typeof INPUTS)[number];
export type Inputs = Record<Input, number>;

const pos = (v: number | undefined) => Math.max(0, v ?? 0);

/**
 * `z` is today's, `yesterday` the day before's. `weekendNight` is whether
 * last night was a Friday or Saturday night. `drinks` is what was logged for
 * last night: `drank` is about 1 per four standard drinks, `dryNight` 1 when
 * the night was answered "No drinks". A night of drinking with no amount
 * (`drankUnknown`) counts as a typical night out, about four drinks. Both stay
 * 0 when nothing was logged.
 */
export function inputs(z: Z, yesterday: Z | null, day: string, drinks?: number | null, drankUnknown?: boolean): Inputs {
  const wellness = wellnessScore(z);
  const sickish = (d: Z | null) => !!d && ((d.restingHr ?? 0) > 0.8 && -(d.hrv ?? 0) > 0.8 || (d.respiration ?? 0) > 1);
  const dow = new Date(dayMs(day)).getUTCDay();
  return {
    rhrUp: pos(z.restingHr),
    hrvDown: pos(-(z.hrv ?? 0)),
    respUp: pos(z.respiration),
    sleepHrUp: pos(z.sleepHr),
    sleepStressUp: pos(z.sleepStress),
    lateBed: pos(z.bedtime),
    shortSleep: pos(-(z.sleepHours ?? 0)),
    lowBattery: pos(-(z.bodyBatteryWake ?? 0)),
    lowReadiness: pos(-(z.readiness ?? 0)),
    stressUp: pos(z.dayStress),
    loadUp: pos(z.load),
    persist: sickish(z) && sickish(yesterday) ? 1 : 0,
    weekendNight: dow === 6 || dow === 0 ? 1 : 0,
    wellness,
    drank: drinks ? Math.min(drinks, 12) / 4 : drankUnknown ? 1 : 0,
    dryNight: drinks === 0 ? 1 : 0,
  };
}

/** The average of every metric pointed so that up is good: about 0 on a normal day, ±1 on a clearly good or bad one. */
export function wellnessScore(z: Z): number {
  const parts = METRICS.filter((m) => GOOD[m] !== 0 && z[m] !== undefined).map((m) => GOOD[m] * z[m]!);
  if (!parts.length) return 0;
  return Math.max(-3, Math.min(3, parts.reduce((a, b) => a + b, 0) / parts.length));
}

/** Hand-set starting rules: an intercept and weights over the inputs. */
const PRIOR: Record<State, Partial<Record<Input | "bias", number>>> = {
  sick: { bias: -3.4, rhrUp: 0.9, hrvDown: 0.7, respUp: 1.1, sleepHrUp: 0.5, sleepStressUp: 0.3, persist: 1.2, lateBed: -0.6 },
  hungover: {
    bias: -3.6, sleepHrUp: 0.9, hrvDown: 0.7, sleepStressUp: 0.5, lateBed: 0.9, rhrUp: 0.3, weekendNight: 0.7, persist: -1, respUp: -0.5,
    // A logged night out says more than any of the body's tells, and a logged dry night rules it out.
    drank: 2, dryNight: -3,
  },
  run_down: { bias: -2.6, shortSleep: 0.8, lowBattery: 0.6, lowReadiness: 0.5, hrvDown: 0.3, loadUp: 0.4, lateBed: 0.2, drank: 0.3 },
  stressed: { bias: -2.8, stressUp: 0.9, sleepStressUp: 0.6, hrvDown: 0.3, rhrUp: 0.2 },
  energized: { bias: -1.6, wellness: 1.8, rhrUp: -0.4, hrvDown: -0.4, shortSleep: -0.5 },
};

const sigmoid = (x: number) => 1 / (1 + Math.exp(-x));

function linear(weights: Partial<Record<Input | "bias", number>>, x: Inputs) {
  let sum = weights.bias ?? 0;
  for (const key of INPUTS) sum += (weights[key] ?? 0) * x[key];
  return sum;
}

export function priorProbability(state: State, x: Inputs) {
  return sigmoid(linear(PRIOR[state], x));
}

// MARK: Learning from labels

export type LabelledDay = { inputs: Inputs; states: State[]; rejected: State[]; energy: number | null };

export type StateModel = { weights: Record<Input | "bias", number>; positives: number; negatives: number };
export type EnergyModel = { weights: Record<Input | "bias", number>; n: number; error: number };

/**
 * An L2 logistic regression on the person's own days, started from the prior
 * so a handful of labels only nudges it. A check-in without the state counts
 * as a no, as does a denied guess.
 */
export function fitState(state: State, days: LabelledDay[]): StateModel | null {
  const rows = days.map((d) => ({ x: d.inputs, y: d.states.includes(state) ? 1 : 0 }));
  const positives = rows.filter((r) => r.y === 1).length;
  const negatives = rows.length - positives;
  if (positives < 2 || negatives < 2) return null;
  const w = { bias: 0, ...Object.fromEntries(INPUTS.map((k) => [k, 0])), ...PRIOR[state] } as Record<Input | "bias", number>;
  const prior = { ...w };
  const rate = 0.05, l2 = 0.3;
  for (let step = 0; step < 400; step++) {
    const grad = Object.fromEntries(Object.keys(w).map((k) => [k, 0])) as Record<Input | "bias", number>;
    for (const { x, y } of rows) {
      const err = sigmoid(linear(w, x)) - y;
      grad.bias += err;
      for (const k of INPUTS) grad[k] += err * x[k];
    }
    for (const k of Object.keys(w) as (Input | "bias")[]) {
      // Pulled toward the prior rather than toward zero.
      w[k] -= rate * (grad[k] / rows.length + l2 * (w[k] - prior[k]) / rows.length);
    }
  }
  return { weights: w, positives, negatives };
}

/** How much of a state's guess comes from the person's own model: none at first, most of it after a few dozen labels. */
export function personalWeight(model: StateModel | null) {
  if (!model) return 0;
  const n = Math.min(model.positives * 3, model.positives + model.negatives);
  return n / (n + 10);
}

export function stateProbability(state: State, x: Inputs, model: StateModel | null) {
  const prior = priorProbability(state, x);
  if (!model) return prior;
  const w = personalWeight(model);
  return (1 - w) * prior + w * sigmoid(linear(model.weights, x));
}

/** Energy 1–5 from the rules: 3 on a normal day, a point either way per clear standard deviation of wellness. */
export function priorEnergy(x: Inputs) {
  return Math.max(1, Math.min(5, 3 + 1.1 * x.wellness - 0.4 * x.shortSleep - 0.3 * x.respUp * x.persist));
}

/** Ridge regression of the person's own energy ratings on the inputs, once there are ten of them. */
export function fitEnergy(days: LabelledDay[]): EnergyModel | null {
  const rows = days.filter((d) => d.energy !== null);
  if (rows.length < 10) return null;
  const keys = ["bias", ...INPUTS] as (Input | "bias")[];
  const X = rows.map((d) => keys.map((k) => (k === "bias" ? 1 : d.inputs[k])));
  const y = rows.map((d) => d.energy! - priorEnergy(d.inputs));
  const p = keys.length;
  // (XᵀX + λI) w = Xᵀy, fitting what the rules miss.
  const A = Array.from({ length: p }, (_, i) => Array.from({ length: p }, (_, j) =>
    X.reduce((s, row) => s + row[i] * row[j], 0) + (i === j ? 4 : 0)));
  const b = keys.map((_, i) => X.reduce((s, row, r) => s + row[i] * y[r], 0));
  const w = solve(A, b);
  if (!w) return null;
  const weights = Object.fromEntries(keys.map((k, i) => [k, w[i]])) as Record<Input | "bias", number>;
  const error = rows.reduce((s, d) => s + Math.abs(energyFrom(weights, d.inputs) - d.energy!), 0) / rows.length;
  return { weights, n: rows.length, error };
}

function energyFrom(weights: Record<Input | "bias", number>, x: Inputs) {
  return Math.max(1, Math.min(5, priorEnergy(x) + linear(weights, x)));
}

export function predictEnergy(x: Inputs, model: EnergyModel | null) {
  const prior = priorEnergy(x);
  if (!model) return prior;
  const w = model.n / (model.n + 10);
  return (1 - w) * prior + w * energyFrom(model.weights, x);
}

/** Gaussian elimination with partial pivoting; null when the system is singular. */
function solve(A: number[][], b: number[]): number[] | null {
  const n = b.length;
  const M = A.map((row, i) => [...row, b[i]]);
  for (let c = 0; c < n; c++) {
    let pivot = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[pivot][c])) pivot = r;
    if (Math.abs(M[pivot][c]) < 1e-9) return null;
    [M[c], M[pivot]] = [M[pivot], M[c]];
    for (let r = 0; r < n; r++) {
      if (r === c) continue;
      const f = M[r][c] / M[c][c];
      for (let k = c; k <= n; k++) M[r][k] -= f * M[c][k];
    }
  }
  return M.map((row, i) => row[n] / row[i]);
}

// MARK: The guess

export type Reason = { metric: Metric; label: string; value: string; usual: string; z: number };
export type StateGuess = { state: State; label: string; probability: number; personal: number; reasons: Reason[] };
/** One of the three cards the morning check-in offers: a state, or "fine" for a normal day. */
export type Option = { key: State | "fine"; label: string; probability: number; reason: string | null };
export type DayGuess = {
  day: string;
  energy: number;
  states: StateGuess[];
  /** The three likeliest ways the morning feels, likeliest first, always with a good one to pick. */
  options: Option[];
  /** Every metric that was available with the person's usual value, most unusual first. */
  metrics: Reason[];
  /** False until there are enough days for baselines; the guess is then only the rules on raw values. */
  calibrated: boolean;
};

/** Which metrics speak for each state, so its reasons are the ones that matter. */
const EVIDENCE: Record<State, Metric[]> = {
  sick: ["restingHr", "hrv", "respiration", "sleepHr", "sleepStress"],
  hungover: ["bedtime", "sleepHr", "hrv", "sleepStress", "restingHr"],
  run_down: ["sleepHours", "bodyBatteryWake", "readiness", "hrv", "load"],
  stressed: ["dayStress", "sleepStress", "hrv"],
  energized: ["hrv", "bodyBatteryWake", "sleepScore", "restingHr", "readiness"],
};

const LABELS: Record<Metric, string> = {
  restingHr: "Resting HR", hrv: "HRV", sleepHours: "Sleep", sleepScore: "Sleep score", bedtime: "Bedtime",
  sleepHr: "Sleeping HR", respiration: "Breathing", sleepStress: "Sleep stress", bodyBatteryWake: "Body Battery at wake",
  readiness: "Readiness", spo2: "Blood oxygen", dayStress: "Yesterday's stress", load: "Yesterday's training load",
};

export function formatMetric(metric: Metric, value: number): string {
  switch (metric) {
    case "restingHr": case "sleepHr": return `${Math.round(value)} bpm`;
    case "hrv": return `${Math.round(value)} ms`;
    case "sleepHours": return `${Math.floor(value)}h ${String(Math.round((value % 1) * 60)).padStart(2, "0")}m`;
    case "bedtime": {
      const h = ((Math.floor(value) % 24) + 24) % 24;
      const m = Math.round((value - Math.floor(value)) * 60) % 60;
      return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, "0")} ${h < 12 ? "am" : "pm"}`;
    }
    case "respiration": return `${value.toFixed(1)}/min`;
    case "spo2": return `${Math.round(value)}%`;
    default: return `${Math.round(value)}`;
  }
}

function reason(metric: Metric, features: DayFeatures, base: Partial<Record<Metric, Baseline>>, z: Z): Reason | null {
  const value = features[metric];
  const b = base[metric];
  if (value === null || !b || z[metric] === undefined) return null;
  return { metric, label: LABELS[metric], value: formatMetric(metric, value), usual: formatMetric(metric, b.median), z: Math.round(z[metric]! * 10) / 10 };
}

// MARK: The days before

/** What the person said about each day they checked in: the states they had and the ones they said no to. */
export type History = Map<string, { states: State[]; rejected: State[] }>;

/**
 * How much yesterday's answer moves today's odds, in log-odds. Being sick
 * lasts days, so a sick yesterday makes a sick today likely and a lively one
 * unlikely; a hangover rarely runs to a second morning but leaves you run
 * down; stress and tiredness linger.
 */
const CARRY: Record<State, Partial<Record<State, number>>> = {
  sick: { sick: 2.6, run_down: 0.9, energized: -1.2 },
  hungover: { hungover: -1, run_down: 1 },
  run_down: { run_down: 1, energized: -0.4 },
  stressed: { stressed: 1.1 },
  energized: { energized: 0.5 },
};

const YESTERDAY: Record<State, string> = {
  sick: "Sick yesterday", hungover: "Hungover yesterday", run_down: "Run down yesterday", stressed: "Stressed yesterday",
  energized: "Great day yesterday",
};

/**
 * Today's shift per state from what the person said about the days before,
 * with the line to show for it. A cold fades: after five sick days in a row
 * the pull weakens. Sick two days ago and unanswered yesterday still counts
 * for some, and "fine" yesterday after being sick leaves a little relapse risk.
 */
export function carryOver(history: History | undefined, day: string) {
  const shift: Partial<Record<State, number>> = {};
  const because: Partial<Record<State, string>> = {};
  if (!history) return { shift, because };
  const add = (state: State, by: number) => { shift[state] = (shift[state] ?? 0) + by; };
  const back = (n: number) => history.get(new Date(dayMs(day) - n * DAY).toISOString().slice(0, 10));
  const yesterday = back(1), before = back(2);
  if (yesterday) {
    let streak = 0;
    while (back(streak + 1)?.states.includes("sick")) streak++;
    const fade = streak <= 5 ? 1 : Math.max(0.35, 1 - 0.15 * (streak - 5));
    for (const state of yesterday.states) {
      for (const [target, by] of Object.entries(CARRY[state]) as [State, number][]) add(target, state === "sick" ? by * fade : by);
      because[state] = state === "sick" && streak > 1 ? `Sick ${streak} days running` : YESTERDAY[state];
    }
    for (const state of yesterday.rejected) if (!yesterday.states.includes(state)) add(state, -0.3);
    if (!yesterday.states.includes("sick") && before?.states.includes("sick")) {
      add("sick", 0.4);
      add("run_down", 0.6);
      because.run_down ??= "Getting over being sick";
    }
  } else if (before?.states.includes("sick")) {
    add("sick", 1.4);
    add("run_down", 0.5);
    because.sick = "Sick two days ago";
  }
  return { shift, because };
}

const logit = (p: number) => Math.log(Math.max(1e-6, p) / Math.max(1e-6, 1 - p));

const OPTION_LABELS: Record<State | "fine", string> = {
  sick: "Sick", hungover: "Hungover", run_down: "Run down", stressed: "Stressed", energized: "Energized", fine: "Normal",
};

/** A reason as a few words for a small card: "HRV down", "Late bedtime". */
function shortReason(r: Reason): string {
  const up = r.z > 0;
  switch (r.metric) {
    case "bedtime": return up ? "Late bedtime" : "Early bedtime";
    case "sleepHours": return up ? "Long sleep" : "Short sleep";
    case "dayStress": return up ? "Stressful yesterday" : "Calm yesterday";
    case "load": return up ? "Hard training yesterday" : "Easy day yesterday";
    case "sleepScore": return up ? "Great sleep score" : "Poor sleep score";
    default: return `${r.label} ${up ? "up" : "down"}`;
  }
}

/**
 * The three cards: the likeliest states, plus "fine" (the chance that none of
 * the bad ones is true). One of "fine" and "energized" is always there, so a
 * good morning is one tap even when the numbers look bad.
 */
export function options(states: StateGuess[], metrics: Reason[], because: Partial<Record<State, string>>): Option[] {
  const bad: State[] = ["sick", "hungover", "run_down", "stressed"];
  const fine = states.filter((s) => bad.includes(s.state)).reduce((p, s) => p * (1 - s.probability), 1);
  const good = (r: Reason) => GOOD[r.metric] * r.z > 0.8;
  const all: Option[] = [
    ...states.map((s) => ({
      key: s.state, label: OPTION_LABELS[s.state], probability: s.probability,
      reason: because[s.state] ?? (s.reasons[0] ? shortReason(s.reasons[0]) : null),
    })),
    {
      key: "fine", label: OPTION_LABELS.fine, probability: Math.round(fine * 100) / 100,
      reason: metrics.some((m) => Math.abs(m.z) >= 1.5 && !good(m)) ? null : "Numbers look usual",
    },
  ];
  // The likeliest first; a tie keeps the gentler answer ahead.
  const order: (State | "fine")[] = ["fine", "energized", "run_down", "stressed", "hungover", "sick"];
  all.sort((a, b) => b.probability - a.probability || order.indexOf(a.key) - order.indexOf(b.key));
  const top = all.slice(0, 3);
  if (!top.some((o) => o.key === "fine" || o.key === "energized")) {
    top[2] = all.find((o) => o.key === "fine" || o.key === "energized")!;
  }
  return top;
}

/**
 * The guess for `day`. `days` is every day of features (any order); `models`
 * the person's own fits; `history` what they said on the days before, which
 * carries over (sick yesterday, likely sick today).
 */
export function guessDay(
  days: DayFeatures[],
  day: string,
  models: { states: Partial<Record<State, StateModel | null>>; energy: EnergyModel | null },
  history?: History,
): DayGuess | null {
  const today = days.find((d) => d.day === day);
  if (!today) return null;
  const base = baselines(days, day);
  const z = zScores(today, base);
  const prevDay = new Date(dayMs(day) - DAY).toISOString().slice(0, 10);
  const prev = days.find((d) => d.day === prevDay);
  const zPrev = prev ? zScores(prev, baselines(days, prevDay)) : null;
  const x = inputs(z, zPrev, day, today.drinks, today.drankUnknown);
  const carry = carryOver(history, day);
  if (today.drinks) carry.because.hungover ??= today.drinks === 1 ? "1 drink last night" : `${today.drinks} drinks last night`;
  else if (today.drankUnknown) carry.because.hungover ??= "Drank last night";
  const states = STATES.map((state) => {
    const model = models.states[state] ?? null;
    const p = sigmoid(logit(stateProbability(state, x, model)) + (carry.shift[state] ?? 0));
    const reasons = EVIDENCE[state]
      .map((m) => reason(m, today, base, z))
      .filter((r): r is Reason => !!r && Math.abs(r.z) >= 0.8)
      .sort((a, b) => Math.abs(b.z) - Math.abs(a.z))
      .slice(0, 3);
    return {
      state, label: STATE_LABELS[state],
      probability: Math.round(p * 100) / 100,
      personal: Math.round(personalWeight(model) * 100) / 100,
      reasons,
    };
  }).sort((a, b) => b.probability - a.probability);
  const metrics = METRICS.map((m) => reason(m, today, base, z)).filter((r): r is Reason => !!r)
    .sort((a, b) => Math.abs(b.z) - Math.abs(a.z));
  // A sick yesterday drags the energy guess down too.
  const energy = predictEnergy(x, models.energy) - 0.5 * Math.max(0, carry.shift.sick ?? 0) / 2.6;
  return {
    day,
    energy: Math.round(Math.max(1, energy) * 10) / 10,
    states,
    options: options(states, metrics, carry.because),
    metrics,
    calibrated: Object.keys(base).length >= 4,
  };
}

/** Every day's inputs, for fitting and for finding past stretches worth asking about. */
export function allInputs(days: DayFeatures[]): Map<string, Inputs> {
  const byDay = new Map(days.map((d) => [d.day, d]));
  const zByDay = new Map<string, Z>();
  const sorted = [...days].sort((a, b) => a.day.localeCompare(b.day));
  // Baselines from a sorted, growing window: fine for a year of days.
  for (const d of sorted) zByDay.set(d.day, zScores(d, baselines(sorted, d.day)));
  const out = new Map<string, Inputs>();
  for (const d of sorted) {
    const prevDay = new Date(dayMs(d.day) - DAY).toISOString().slice(0, 10);
    out.set(d.day, inputs(zByDay.get(d.day)!, byDay.has(prevDay) ? zByDay.get(prevDay)! : null, d.day, d.drinks, d.drankUnknown));
  }
  return out;
}

export type PastStretch = { state: State; label: string; from: string; to: string; peak: number };

/**
 * Past runs of days that look like `state` and haven't been answered, newest
 * first: "were you sick around March 3–5?". Answering one labels every day in it.
 */
export function pastStretches(
  inputsByDay: Map<string, Inputs>,
  answered: Set<string>,
  state: State,
  threshold: number,
  models: Partial<Record<State, StateModel | null>>,
  limit = 5,
): PastStretch[] {
  const hits = [...inputsByDay.entries()]
    .filter(([day]) => !answered.has(day))
    .map(([day, x]) => ({ day, p: stateProbability(state, x, models[state] ?? null) }))
    .filter((h) => h.p >= threshold)
    .sort((a, b) => a.day.localeCompare(b.day));
  const stretches: PastStretch[] = [];
  for (const h of hits) {
    const last = stretches[stretches.length - 1];
    if (last && dayMs(h.day) - dayMs(last.to) <= 2 * DAY) {
      last.to = h.day;
      last.peak = Math.max(last.peak, h.p);
    } else {
      stretches.push({ state, label: STATE_LABELS[state], from: h.day, to: h.day, peak: h.p });
    }
  }
  return stretches
    .map((s) => ({ ...s, peak: Math.round(s.peak * 100) / 100 }))
    .sort((a, b) => b.to.localeCompare(a.to))
    .slice(0, limit);
}

/** The inputs that most move the person's energy, from their own model: "late bedtimes cost you about 0.6". */
export function energyDrivers(model: EnergyModel | null): { input: string; effect: number }[] {
  if (!model) return [];
  return INPUTS.map((k) => ({ input: k, effect: Math.round(model.weights[k] * 100) / 100 }))
    .filter((d) => Math.abs(d.effect) >= 0.1)
    .sort((a, b) => Math.abs(b.effect) - Math.abs(a.effect))
    .slice(0, 5);
}
