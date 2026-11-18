import assert from "node:assert/strict";
import { test } from "node:test";
import { buildInsights, type InsightNight } from "../lib/fitness/insight-metrics.ts";
import {
  aerobicEffect, anaerobicEffect, anaerobicFeatures, appleSleepScore, bedtimeSpread, best20MinHr, cardioFitness, dayStrain,
  effortRating, fitnessAge, focusSplit, hubAge, interruptions, lactateThreshold, loadFocus, raceTime, recovery, recoveryIndex,
  sleepNeed, strain, trimp, vitals,
} from "../lib/fitness/insights.ts";

const profile = { maxHr: 200, restingHr: 55, sex: "male" as const, age: 22 };
const HOUR = 3_600_000, DAY = 24 * HOUR;

/** [seconds, bpm] once a second at a steady heart rate. */
const steady = (minutes: number, bpm: number, from = 0): [number, number][] =>
  Array.from({ length: minutes * 60 }, (_, i) => [from + i, bpm]);

test("strain: an easy strength session is light, a hard hour's run strenuous, and it tops out at 21", () => {
  const easy = strain(trimp(steady(45, 104), profile));
  const hard = strain(trimp(steady(60, 171), profile));
  assert.ok(easy >= 5 && easy <= 9, `easy ${easy}`);
  assert.ok(hard >= 14 && hard <= 18, `hard ${hard}`);
  assert.equal(strain(5000), 21);
});

test("day strain ignores all-day time below Whoop's zone 1", () => {
  const sitting = Array.from({ length: 16 * 60 }, (_, i) => ({ at: i * 60_000, bpm: 72 }));
  assert.equal(dayStrain(sitting, [], profile).strain, 0);
  const walking = sitting.map((s, i) => ({ ...s, bpm: i < 60 ? 115 : 72 }));
  assert.ok(dayStrain(walking, [], profile).strain > 0);
});

test("training effect follows the fit to the watch and stays in 0-5", () => {
  assert.equal(aerobicEffect(null), null);
  assert.equal(aerobicEffect(0), 0);
  // The watch said 3.5 for a 192-load basketball game and 0.9 for a 17-load strength session.
  assert.ok(Math.abs(aerobicEffect(192)! - 3.8) < 0.4);
  assert.ok(Math.abs(aerobicEffect(17)! - 1.3) < 0.4);
  assert.equal(aerobicEffect(100_000), 5);
});

test("anaerobic effect rises with repeated sprints, not with steady hard work", () => {
  const steadyHard = anaerobicFeatures(steady(40, 175), profile);
  const intervals: [number, number][] = [];
  for (let rep = 0; rep < 10; rep++) {
    intervals.push(...steady(2, 110, rep * 240));
    // A 30-second climb from 110 to 190, then held.
    for (let s = 0; s < 120; s++) intervals.push([rep * 240 + 120 + s, Math.min(190, 110 + s * 3)]);
  }
  const sprinty = anaerobicFeatures(intervals, profile);
  assert.ok(sprinty.bursts >= 9, `bursts ${sprinty.bursts}`);
  assert.ok(anaerobicEffect(sprinty) > anaerobicEffect(steadyHard) + 1);
});

test("effort is 1-10, led by aerobic effect", () => {
  assert.equal(effortRating(null, null), null);
  assert.equal(effortRating(0.2, 0), 1);
  assert.equal(effortRating(3.5, 2.9), 9);
  assert.equal(effortRating(5, 5), 10);
});

test("load focus splits by intensity and flags the biggest shortage", () => {
  const easy = focusSplit(steady(60, 120), profile, 60);
  assert.deepEqual(easy, { low: 60, high: 0, anaerobic: 0 });
  const now = 30 * DAY;
  const block = loadFocus([{ at: now - DAY, focus: easy }], now);
  assert.equal(block.status, "High aerobic shortage");
});

test("lactate threshold uses a real 20-minute effort when there is one, 87 % of max otherwise", () => {
  const now = 200 * DAY;
  assert.equal(best20MinHr(steady(25, 178)), 178);
  const measured = lactateThreshold([{ at: now - DAY, best20: 178 }], [], profile, now);
  assert.equal(measured.measured, true);
  assert.equal(measured.heartRate, 178);
  const estimated = lactateThreshold([{ at: now - DAY, best20: 140 }], [], profile, now);
  assert.deepEqual([estimated.measured, estimated.heartRate], [false, 174]);
});

test("race times match Daniels' tables", () => {
  // VDOT 50: 5K 19:57, marathon 3:10:49.
  assert.ok(Math.abs(raceTime(50, 5000) - (19 * 60 + 57)) < 15, `${raceTime(50, 5000)}`);
  assert.ok(Math.abs(raceTime(50, 42195) - (3 * 3600 + 10 * 60 + 49)) < 120, `${raceTime(50, 42195)}`);
});

test("fitness age and cardio fitness follow the HUNT averages", () => {
  assert.equal(fitnessAge(54.4, "male"), 25);
  assert.ok(fitnessAge(65, "male") < 22);
  assert.equal(cardioFitness(54.4, 25, "male").percentile, 50);
  assert.equal(cardioFitness(35, 25, "male").lowFitness, true);
});

test("Hub Age starts at your age and moves with each habit", () => {
  // Fewer than three inputs say too little.
  assert.equal(hubAge({ age: 22, sex: "male", vo2max: null, restingHr: 55, hrv: null, bedtimeSpread: null, sleepHours: 8 }), null);
  // Without VO2max it still works from the rest.
  assert.ok(hubAge({ age: 22, sex: "male", vo2max: null, restingHr: 55, hrv: 60, bedtimeSpread: 20, sleepHours: 8, steps: 9000 }));
  const habits = { steps: 10000, easyMinutes: 300, hardMinutes: 75, strengthMinutes: 60 };
  const healthy = hubAge({ age: 22, sex: "male", vo2max: 58, restingHr: 50, hrv: 70, bedtimeSpread: 15, sleepHours: 8, ...habits })!;
  const rough = hubAge({
    age: 22, sex: "male", vo2max: 58, restingHr: 72, hrv: 25, bedtimeSpread: 120, sleepHours: 5.5,
    steps: 2500, easyMinutes: 20, hardMinutes: 0, strengthMinutes: 0,
  })!;
  assert.ok(rough.age - healthy.age > 9, `${rough.age} vs ${healthy.age}`);
  assert.ok(healthy.difference < -5);
  // Same fitness, same habits: an average person lands on their own age.
  const average = hubAge({
    age: 40, sex: "male", vo2max: 47.65, restingHr: 60, hrv: 45 * 0.99 ** 15, bedtimeSpread: 60, sleepHours: 6.9,
    steps: 6000, easyMinutes: 150, hardMinutes: 25, strengthMinutes: 30,
  })!;
  assert.ok(Math.abs(average.difference) <= 1, `${average.difference}`);
  // With no zone time it falls back to plain exercise minutes.
  assert.ok(hubAge({ age: 30, sex: null, vo2max: 45, restingHr: 60, hrv: null, bedtimeSpread: null, sleepHours: null, activeMinutes: 200 })!.parts.some((p) => p.key === "activity"));
});

test("recovery calibrates for 4 nights, then rewards high HRV and low resting heart rate", () => {
  const usual = { hrv: 50, restingHr: 52, respiration: 15, performance: 90, spo2: 96 };
  const base = [usual, { ...usual, hrv: 54 }, { ...usual, hrv: 46, restingHr: 54 }, { ...usual, restingHr: 50 }, { ...usual, hrv: 52 }];
  assert.deepEqual(recovery(usual, base.slice(0, 3)), { status: "calibrating", have: 3, need: 4 });
  const good = recovery({ ...usual, hrv: 62, restingHr: 48 }, base);
  const bad = recovery({ ...usual, hrv: 35, restingHr: 60, performance: 60 }, base);
  assert.ok(good && good.status === "ready" && good.zone === "green");
  assert.ok(bad && bad.status === "ready" && bad.zone === "red");
});

test("recovery index: an early low scores high, a late one low", () => {
  const start = 0, end = 8 * HOUR;
  const night = (lowAt: number) => ({
    start, end,
    heartRate: Array.from({ length: 8 * 30 }, (_, i) => ({ at: i * 120_000, bpm: Math.abs(i * 120_000 - lowAt) < 20 * 60_000 ? 45 : 58 })),
  });
  assert.ok(recoveryIndex(night(1.5 * HOUR))!.score >= 85);
  assert.ok(recoveryIndex(night(7 * HOUR))!.score <= 40);
});

test("sleep need adds debt and strain, takes away naps", () => {
  const eight = { asleepSeconds: 8 * 3600 };
  const rested = sleepNeed({ history: Array(10).fill(eight), lastWeek: Array(7).fill(eight), yesterdayStrain: 0, napSeconds: 0 });
  assert.equal(rested.hours, 8);
  const short = sleepNeed({ history: Array(10).fill(eight), lastWeek: [{ asleepSeconds: 5 * 3600 }], yesterdayStrain: 21, napSeconds: 0 });
  assert.equal(short.debt, 1.5);
  assert.equal(short.strain, 1);
  assert.equal(short.hours, 10.5);
  const napped = sleepNeed({ history: [], lastWeek: [], yesterdayStrain: null, napSeconds: 3600 });
  assert.equal(napped.hours, 8);
});

test("interruptions count wakeups of 3 minutes or more inside the night", () => {
  const levels: [number, number][] = [[0, 1], [600, 2], [3600, 1], [3660, 2], [7200, 1], [7500, 3], [20000, 1]];
  // The opening wake and the final one don't count, nor the 1-minute one.
  assert.equal(interruptions(levels, 20600), 1);
});

test("bedtime spread measures around midnight", () => {
  const offset = 0;
  const at = (h: number, m: number) => Date.UTC(2026, 0, 1) + h * HOUR + m * 60_000;
  assert.ok(bedtimeSpread([at(23, 50), at(0, 10), at(0, 0)], offset)! <= 10);
  assert.equal(bedtimeSpread([at(23, 0)], offset), null);
  assert.equal(appleSleepScore(8 * 3600, 10, 0).score, 100);
});

test("vitals flag a reading outside the usual range after 7 nights", () => {
  const night = { heartRate: 52, hrv: 50, respiration: 15, spo2: 96, sleepHours: 7.5 };
  const history = Array.from({ length: 10 }, (_, i) => ({ ...night, heartRate: 51 + (i % 3) }));
  const result = vitals({ ...night, heartRate: 64, respiration: 19 }, history);
  assert.equal(result.calibrating, false);
  assert.equal(result.outliers, 2);
  assert.equal(vitals(night, history.slice(0, 5)).calibrating, true);
});

test("buildInsights holds together on a sparse first week", () => {
  const now = Date.UTC(2026, 9, 16, 14);
  const lastNight: InsightNight = {
    start: now - 9 * HOUR, end: now - 2 * HOUR, asleepSeconds: 6.5 * 3600, levels: [[0, 2], [7200, 1], [7500, 3]], score: 72,
    hrv: 45, respiration: 15, spo2: 95, heartRate: [], dailyRestingHr: 54,
  };
  const insights = buildInsights({
    now, utcOffset: -4 * 3600, profile, vo2max: 53,
    activities: [{
      start: now - 30 * HOUR, end: now - 29 * HOUR, sport: "running", minutes: 60, load: 120, trimp: 140, strain: 15,
      aerobicEffect: 3.3, anaerobicEffect: 0.5, watchAerobic: 3.2, watchAnaerobic: 0.4, effort: 7,
      focus: { low: 40, high: 70, anaerobic: 10 }, best20Hr: 176, bestClimbRate: null, ascent: 40, earlyVo2max: 51, steady: [],
    }],
    heartRate: [], nights: [lastNight], stress: [], bodyBattery: [], restingHr: [54],
  });
  assert.equal(insights.recovery?.status, "calibrating");
  assert.equal(insights.sleep.lastNight?.interruptions, 1);
  assert.equal(insights.training.lastWorkout?.effort, 7);
  assert.equal(insights.training.performanceCondition?.value, -4);
  assert.equal(insights.training.lactateThreshold?.measured, true);
  assert.equal(insights.age?.cardioFitness?.lowFitness, false);
  assert.equal(insights.stress.resilience && "status" in insights.stress.resilience ? insights.stress.resilience.status : null, "calibrating");
});
