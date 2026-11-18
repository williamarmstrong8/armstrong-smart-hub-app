import assert from "node:assert/strict";
import { test } from "node:test";

import {
  allInputs, baselines, type DayFeatures, fitEnergy, fitState, formatMetric, guessDay, type LabelledDay, pastStretches,
  stateProbability,
} from "../lib/fitness/checkin-engine.ts";

const none = { states: {}, energy: null };

/** A steady month with a little day-to-day wobble, ending the day before `last`. */
function month(last = "2026-03-01"): DayFeatures[] {
  const end = Date.parse(`${last}T00:00:00Z`);
  return Array.from({ length: 30 }, (_, i) => {
    const w = Math.sin(i * 1.7);
    return {
      day: new Date(end - (30 - i) * 86_400_000).toISOString().slice(0, 10),
      restingHr: 55 + w, hrv: 50 + 3 * w, sleepHours: 7.5 + 0.3 * w, sleepScore: 80 + 4 * w, bedtime: 23.5 + 0.3 * w,
      sleepHr: 58 + w, respiration: 14 + 0.2 * w, sleepStress: 18 + 2 * w, bodyBatteryWake: 80 + 4 * w, readiness: 75 + 5 * w,
      spo2: 96, dayStress: 30 + 3 * w, load: 100,
    };
  });
}

const day = (base: DayFeatures, patch: Partial<DayFeatures>): DayFeatures => ({ ...base, ...patch });

test("a normal morning guesses nothing in particular and about 3 for energy", () => {
  const days = month();
  days.push(day(days[days.length - 1], { day: "2026-03-01" }));
  const guess = guessDay(days, "2026-03-01", none)!;
  assert.ok(guess.calibrated);
  assert.ok(guess.states.every((s) => s.state === "energized" || s.probability < 0.3), JSON.stringify(guess.states));
  assert.ok(guess.energy >= 2.5 && guess.energy <= 3.6, `energy ${guess.energy}`);
});

test("two nights of raised resting HR and breathing with low HRV look like getting sick", () => {
  const days = month("2026-03-02");
  const last = days[days.length - 1];
  days.push(day(last, { day: "2026-03-01", restingHr: 60, hrv: 40, respiration: 15.2, sleepHr: 62 }));
  days.push(day(last, { day: "2026-03-02", restingHr: 62, hrv: 37, respiration: 15.6, sleepHr: 64 }));
  const guess = guessDay(days, "2026-03-02", none)!;
  assert.equal(guess.states[0].state, "sick", JSON.stringify(guess.states.map((s) => [s.state, s.probability])));
  assert.ok(guess.states[0].probability > 0.6);
  assert.ok(guess.states[0].reasons.some((r) => r.metric === "respiration"));
  assert.ok(guess.energy < 2.5);
});

test("a 2 am bedtime with a racing sleeping HR on a Saturday looks hungover, not sick", () => {
  const days = month("2026-03-07"); // 2026-03-07 is a Saturday
  days.push(day(days[days.length - 1], { day: "2026-03-07", bedtime: 26, sleepHr: 66, hrv: 32, sleepStress: 35, sleepHours: 6, restingHr: 58 }));
  const guess = guessDay(days, "2026-03-07", none)!;
  assert.equal(guess.states[0].state, "hungover", JSON.stringify(guess.states.map((s) => [s.state, s.probability])));
  assert.ok(guess.states.find((s) => s.state === "sick")!.probability < guess.states[0].probability);
  assert.equal(guess.states[0].reasons[0].metric, "bedtime");
});

test("baselines ignore the day itself and need a week of values", () => {
  const days = month();
  assert.equal(baselines(days.slice(0, 5), "2026-03-01").hrv, undefined);
  const b = baselines(days, "2026-03-01");
  assert.ok(Math.abs(b.restingHr!.median - 55) < 1);
  assert.ok(b.restingHr!.spread >= 1.5);
});

test("labels pull a state's model toward the person: a pattern the rules miss is learned", () => {
  const days = month("2026-03-01");
  const extra: DayFeatures[] = [];
  // For this person, being run down shows up only as high yesterday's stress, which the rule barely weighs.
  for (let i = 0; i < 40; i++) {
    const d = new Date(Date.parse("2026-03-01T00:00:00Z") + i * 86_400_000).toISOString().slice(0, 10);
    extra.push(day(days[i % 28], { day: d, dayStress: i % 4 === 0 ? 55 : 30 }));
  }
  const all = [...days, ...extra];
  const x = allInputs(all);
  const labelled: LabelledDay[] = extra.map((d, i) => ({ inputs: x.get(d.day)!, states: i % 4 === 0 ? ["run_down"] : [], rejected: [], energy: i % 4 === 0 ? 2 : 4 }));
  const model = fitState("run_down", labelled);
  assert.ok(model);
  const stressed = x.get(extra[36].day)!;
  assert.ok(stateProbability("run_down", stressed, model) > stateProbability("run_down", stressed, null) + 0.1);
  const energy = fitEnergy(labelled);
  assert.ok(energy && energy.error < 1);
});

test("past stretches group neighbouring days and skip answered ones", () => {
  const days = month("2026-03-10");
  const last = days[days.length - 1];
  for (const [d, r] of [["2026-03-03", 61], ["2026-03-04", 63], ["2026-03-05", 62]] as const) {
    days.push(day(last, { day: d, restingHr: r, hrv: 36, respiration: 15.6, sleepHr: 64 }));
  }
  const x = allInputs(days);
  const stretches = pastStretches(x, new Set(), "sick", 0.5, {});
  assert.equal(stretches.length, 1);
  assert.equal(stretches[0].to, "2026-03-05");
  assert.equal(pastStretches(x, new Set(["2026-03-03", "2026-03-04", "2026-03-05"]), "sick", 0.5, {}).length, 0);
});

test("bedtimes and durations read like a person would say them", () => {
  assert.equal(formatMetric("bedtime", 23.5), "11:30 pm");
  assert.equal(formatMetric("bedtime", 25.25), "1:15 am");
  assert.equal(formatMetric("sleepHours", 7.5), "7h 30m");
});

test("a normal morning offers three cards, normal first", () => {
  const days = month();
  days.push(day(days[days.length - 1], { day: "2026-03-01" }));
  const guess = guessDay(days, "2026-03-01", none)!;
  assert.equal(guess.options.length, 3);
  assert.equal(guess.options[0].key, "fine", JSON.stringify(guess.options));
  assert.equal(new Set(guess.options.map((o) => o.key)).size, 3);
});

test("sick yesterday makes sick a likely card today even on ordinary numbers", () => {
  const days = month();
  days.push(day(days[days.length - 1], { day: "2026-03-01" }));
  const plain = guessDay(days, "2026-03-01", none)!;
  const history = new Map([["2026-02-28", { states: ["sick" as const], rejected: [] }]]);
  const guess = guessDay(days, "2026-03-01", none, history)!;
  const sick = (g: typeof guess) => g.states.find((s) => s.state === "sick")!.probability;
  assert.ok(sick(guess) > sick(plain) * 4, `${sick(plain)} -> ${sick(guess)}`);
  const card = guess.options.find((o) => o.key === "sick");
  assert.ok(card, JSON.stringify(guess.options));
  assert.equal(card.reason, "Sick yesterday");
  // A good answer is always one tap away.
  assert.ok(guess.options.some((o) => o.key === "fine" || o.key === "energized"));
});

test("a long run of sick days pulls less each day", () => {
  const days = month();
  days.push(day(days[days.length - 1], { day: "2026-03-01" }));
  const run = (n: number) => new Map(Array.from({ length: n }, (_, i) => [
    new Date(Date.parse("2026-03-01T00:00:00Z") - (i + 1) * 86_400_000).toISOString().slice(0, 10),
    { states: ["sick" as const], rejected: [] },
  ]));
  const p = (n: number) => guessDay(days, "2026-03-01", none, run(n))!.states.find((s) => s.state === "sick")!.probability;
  assert.ok(p(9) < p(3), `${p(3)} vs ${p(9)}`);
  assert.equal(guessDay(days, "2026-03-01", none, run(3))!.options.find((o) => o.key === "sick")?.reason, "Sick 3 days running");
});

test("a hangover doesn't carry, but the morning after is likely run down", () => {
  const days = month();
  days.push(day(days[days.length - 1], { day: "2026-03-01" }));
  const history = new Map([["2026-02-28", { states: ["hungover" as const], rejected: [] }]]);
  const plain = guessDay(days, "2026-03-01", none)!;
  const guess = guessDay(days, "2026-03-01", none, history)!;
  const p = (g: typeof guess, s: string) => g.states.find((x) => x.state === s)!.probability;
  assert.ok(p(guess, "run_down") > p(plain, "run_down"));
  assert.ok(p(guess, "hungover") < p(plain, "hungover"));
});

test("logged drinks make a hungover morning likely and a logged dry night rules it out", () => {
  const days = month("2026-03-04"); // a Wednesday, a little late to bed
  const last = days[days.length - 1];
  const tells = { day: "2026-03-04", bedtime: 24.3, sleepHr: 60 };
  const p = (drinks: number | null) =>
    guessDay([...days, day(last, { ...tells, drinks })], "2026-03-04", none)!.states.find((s) => s.state === "hungover")!.probability;
  assert.ok(p(6) > p(null) + 0.2, `6 drinks ${p(6)} vs unknown ${p(null)}`);
  assert.ok(p(0) < p(null) / 3, `dry ${p(0)} vs unknown ${p(null)}`);
  const guess = guessDay([...days, day(last, { ...tells, drinks: 6 })], "2026-03-04", none)!;
  assert.equal(guess.options[0].key, "hungover", JSON.stringify(guess.options));
  assert.equal(guess.options[0].reason, "6 drinks last night");
  const unsure = guessDay([...days, day(last, { ...tells, drinks: null, drankUnknown: true })], "2026-03-04", none)!;
  const hung = unsure.states.find((s) => s.state === "hungover")!.probability;
  assert.ok(hung > p(null) && hung < p(6), `unknown amount ${hung}`);
  assert.equal(unsure.options.find((o) => o.key === "hungover")?.reason ?? "Drank last night", "Drank last night");
});
