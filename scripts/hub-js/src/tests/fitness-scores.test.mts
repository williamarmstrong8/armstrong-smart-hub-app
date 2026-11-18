import assert from "node:assert/strict";
import { test } from "node:test";

import {
  activeZoneMinutes, breathingDisturbances, cardioRecovery, chronotype, contributorReadiness, fitnessFatigueForm, healthMonitor,
  hrvStability, monotony, sleepDebt, sleepEfficiency, sleepRegularity, stageBalance, strainTarget, trainingStatus, zoneDistribution,
  zoneSeconds,
} from "../lib/fitness/scores.ts";

const HOUR = 3_600_000, DAY = 24 * HOUR;
const NOW = Date.UTC(2026, 10, 13, 15);
const profile = { maxHr: 190, restingHr: 50, sex: "male" as const };
/** A night ending `daysAgo` mornings back: asleep from `bed` to `wake` (hours UTC, bed may be negative for before midnight). */
const night = (daysAgo: number, bed: number, wake: number) => {
  const midnight = Date.UTC(2026, 10, 13) - daysAgo * DAY;
  return { start: midnight + bed * HOUR, end: midnight + wake * HOUR, asleepSeconds: (wake - bed) * 3600 * 0.93 };
};

test("sleep efficiency and stage balance", () => {
  assert.equal(sleepEfficiency(7 * 3600, 0, 8 * HOUR), 88);
  assert.equal(sleepEfficiency(600, 0, 10 * 60_000), null);
  const stages = stageBalance({ deep: 60 * 60, light: 300 * 60, rem: 100 * 60 })!;
  assert.deepEqual(stages.map((s) => [s.key, s.share, s.status]), [["deep", 13, "low"], ["light", 65, "high"], ["rem", 22, "typical"]]);
});

test("sleep debt builds with short nights and pays back at half speed", () => {
  const nights = (hours: number[]) => hours.map((h, i) => ({ end: NOW - (hours.length - i) * DAY + HOUR, asleepSeconds: h * 3600 }));
  assert.deepEqual(sleepDebt(nights([6, 6]), 8, NOW), { status: "calibrating", have: 2, need: 3 });
  const short = sleepDebt(nights([6, 6, 6]), 8, NOW);
  assert.ok(short.status === "ready" && short.hours === 6 && short.level === "high");
  const repaid = sleepDebt(nights([6, 6, 10, 10]), 8, NOW);
  assert.ok(repaid.status === "ready" && repaid.hours === 2);
  const rested = sleepDebt(nights([8.5, 8, 9]), 8, NOW);
  assert.ok(rested.status === "ready" && rested.hours === 0 && rested.level === "none");
});

test("chronotype reads the midpoint of sleep and weekend drift", () => {
  // 2026-11-13 is a Friday. Weeknights 23:00-07:00, Friday and Saturday nights 01:00-10:00.
  const nights = Array.from({ length: 14 }, (_, i) => {
    const weekday = new Date(Date.UTC(2026, 10, 13) - i * DAY).getUTCDay();
    return weekday === 0 || weekday === 6 ? night(i, 1, 10) : night(i, -1, 7);
  });
  const result = chronotype(nights, 0);
  assert.ok(result.status === "ready");
  assert.equal(result.type, "intermediate");
  assert.equal(result.midpoint, 180);
  assert.equal(result.bedtime, -60);
  assert.equal(result.socialJetlagMinutes, 150);
  assert.equal(chronotype(nights.slice(0, 3), 0).status, "calibrating");
  const owl = chronotype(Array.from({ length: 8 }, (_, i) => night(i, 2, 10)), 0);
  assert.ok(owl.status === "ready" && owl.type === "late");
  // The same nights seen from 5 hours west are 5 hours earlier on the clock.
  const west = chronotype(Array.from({ length: 8 }, (_, i) => night(i, 5, 13)), -5 * 3600);
  assert.ok(west.status === "ready" && west.midpoint === 240);
});

test("sleep regularity is 100 for the same schedule every day and falls when it drifts", () => {
  const steady = Array.from({ length: 15 }, (_, i) => night(i, -1, 7));
  const regular = sleepRegularity(steady, NOW);
  assert.ok(regular.status === "ready" && regular.score === 100 && regular.level === "very regular");
  const drifting = Array.from({ length: 15 }, (_, i) => (i % 2 ? night(i, -2, 6) : night(i, 2, 10)));
  const irregular = sleepRegularity(drifting, NOW);
  assert.ok(irregular.status === "ready" && irregular.score < 70, JSON.stringify(irregular));
  assert.equal(sleepRegularity(steady.slice(0, 3), NOW).status, "calibrating");
});

test("breathing disturbances counts falls of 3 points from the running baseline", () => {
  const minutes = Array.from({ length: 300 }, (_, i) => ({ at: i * 60_000, value: 96 }));
  assert.equal(breathingDisturbances(minutes)!.index, 0);
  // A two-minute dip to 91 every half hour: 10 events in 5 hours.
  const dips = minutes.map((p, i) => ({ ...p, value: i > 20 && i % 30 < 2 ? 91 : 96 }));
  const result = breathingDisturbances(dips)!;
  assert.equal(result.events, 9);
  assert.equal(result.level, "normal");
  assert.equal(result.lowest, 91);
  assert.equal(breathingDisturbances(minutes.slice(0, 60)), null);
});

test("readiness with contributors rewards a calm night and names what pulled it down", () => {
  const base = {
    lowestHr: 50, baselineLowestHr: 50, hrvRecent: [60, 62, 58], hrvBaseline: [55, 60, 65, 58, 62, 60], recoveryIndex: 90,
    sleepScore: 88, sleepAverageHours: 7.8, needHours: 8, yesterdayStrain: 10, loadRatio: 1,
  };
  const good = contributorReadiness(base);
  assert.ok(good.score! >= 85 && good.level === "optimal", `${good.score}`);
  const rough = contributorReadiness({ ...base, lowestHr: 58, hrvRecent: [40], sleepScore: 45, yesterdayStrain: 19 });
  assert.ok(rough.score! < 60 && rough.level === "pay attention", `${rough.score}`);
  assert.equal(rough.contributors.find((c) => c.key === "restingHr")!.score, 36);
  assert.equal(contributorReadiness({ ...base, lowestHr: null, hrvRecent: [], sleepScore: null }).score, null);
});

test("fitness, fatigue and form follow the impulse-response model", () => {
  // 60 TRIMP a day for 60 days, then a week off: fitness holds, fatigue drains, form turns fresh.
  const steady = Array.from({ length: 60 }, (_, i) => ({ at: NOW - (i + 8) * DAY, load: 60 }));
  const rested = fitnessFatigueForm(steady, NOW)!;
  assert.ok(rested.fitness > 30 && rested.fitness < 45, `${rested.fitness}`);
  assert.ok(rested.fatigue < rested.fitness);
  assert.equal(rested.label, "Fresh");
  assert.ok(rested.ramp! < 0);
  // A sudden big week on top of it: fatigue outruns fitness.
  const spike = fitnessFatigueForm([...steady, ...Array.from({ length: 7 }, (_, i) => ({ at: NOW - (i + 1) * DAY, load: 200 }))], NOW)!;
  assert.ok(spike.form < -30 && spike.label === "Overreaching", `${spike.form}`);
  assert.equal(fitnessFatigueForm([], NOW), null);
  assert.equal(spike.series.length, 68);
});

test("monotony is high when every day is the same", () => {
  const same = Array.from({ length: 7 }, (_, i) => ({ at: NOW - i * DAY, load: 100 + (i % 2) }));
  assert.equal(monotony(same, NOW)!.level, "high");
  const varied = [0, 2, 3, 5].map((d, i) => ({ at: NOW - d * DAY, load: [200, 40, 150, 60][i] }));
  const result = monotony(varied, NOW)!;
  assert.equal(result.level, "varied");
  assert.equal(result.weekLoad, 450);
  assert.equal(monotony([{ at: NOW, load: 100 }], NOW), null);
});

test("training status follows load, VO2max trend and HRV", () => {
  const vo2 = (from: number, to: number) => [{ at: NOW - 40 * DAY, value: from }, { at: NOW - 30 * DAY, value: from }, { at: NOW - 5 * DAY, value: to }];
  const base = { acute: 300, chronic: 300, ratio: 1, hrvStatus: "balanced", lastWorkout: NOW - DAY, now: NOW };
  assert.equal(trainingStatus({ ...base, vo2max: vo2(50, 51) }).key, "productive");
  assert.equal(trainingStatus({ ...base, vo2max: vo2(50, 50) }).key, "maintaining");
  assert.equal(trainingStatus({ ...base, vo2max: vo2(50, 49) }).key, "unproductive");
  assert.equal(trainingStatus({ ...base, vo2max: vo2(50, 50), hrvStatus: "low" }).key, "strained");
  assert.equal(trainingStatus({ ...base, vo2max: vo2(50, 50), acute: 500, ratio: 1.67 }).key, "overreaching");
  assert.equal(trainingStatus({ ...base, vo2max: vo2(50, 50), acute: 210, ratio: 0.7 }).key, "peaking");
  assert.equal(trainingStatus({ ...base, vo2max: vo2(50, 50), acute: 120, ratio: 0.4 }).key, "recovery");
  assert.equal(trainingStatus({ ...base, vo2max: [], acute: 60, ratio: 0.2, lastWorkout: NOW - 12 * DAY }).key, "detraining");
  assert.equal(trainingStatus({ ...base, vo2max: [], acute: 0, chronic: 0, ratio: null, lastWorkout: null }).key, "no status");
});

test("heart rate zones, distribution and Active Zone Minutes", () => {
  // Max 190, a minute at each step: the pair averages are 80 and 90 (below the zones), then 100, 120, 140, 157.5 and 175.
  const series: [number, number][] = [[0, 80], [60, 80], [120, 100], [180, 100], [240, 140], [300, 140], [360, 175], [420, 175]];
  assert.deepEqual(zoneSeconds(series, 190), [60, 60, 60, 60, 60]);
  // A gap of more than 5 minutes (watch off) isn't counted.
  assert.deepEqual(zoneSeconds([[0, 150], [60, 150], [1000, 150]], 190), [0, 0, 60, 0, 0]);
  const polarized = zoneDistribution([{ zones: [1800, 3000, 300, 600, 300] }]);
  assert.equal(polarized.pattern, "Polarized");
  assert.equal(polarized.low, 80);
  assert.equal(zoneDistribution([{ zones: [600, 600, 2400, 300, 0] }]).pattern, "Threshold");
  assert.equal(zoneDistribution([{ zones: [60, 60, 0, 0, 0] }]).pattern, null);
  // Reserve 140: 110 bpm is 43 % (fat burn), 140 bpm 64 % (cardio), 175 bpm 89 % (peak).
  const hr = [110, 110, 110, 140, 140, 175, 60].map((bpm, i) => ({ at: i * 60_000, bpm }));
  assert.deepEqual(activeZoneMinutes(hr, profile), { minutes: 8, fatBurn: 2, cardio: 2, peak: 1 });
});

test("strain target slides with recovery", () => {
  assert.equal(strainTarget(null, 5), null);
  const red = strainTarget(20, 12)!, green = strainTarget(90, 12)!;
  assert.ok(red.high < 10 && red.state === "above");
  assert.ok(green.low >= 14 && green.state === "below");
  assert.equal(strainTarget(50, 12)!.state, "in range");
});

test("cardio recovery, HRV stability and the health monitor", () => {
  const sessions = [
    { at: NOW - DAY, recoveryHr: 48, endHr: 170 }, { at: NOW - 3 * DAY, recoveryHr: 44, endHr: 160 },
    // An easy finish, an old session and one the watch didn't measure don't count.
    { at: NOW - 2 * DAY, recoveryHr: 8, endHr: 100 }, { at: NOW - 300 * DAY, recoveryHr: 10, endHr: 180 }, { at: NOW - 2 * DAY, recoveryHr: null, endHr: 175 },
  ];
  assert.deepEqual(cardioRecovery(sessions, 190, NOW), { latest: 48, at: new Date(NOW - DAY).toISOString(), average: 46, sessions: 2, level: "good" });
  assert.equal(cardioRecovery([], 190, NOW), null);

  const hrv = (values: number[]) => values.map((rmssd, i) => ({ at: NOW - i * DAY, rmssd }));
  const stable = hrvStability(hrv([60, 62, 58, 61, 59]), NOW), swinging = hrvStability(hrv([60, 35, 75, 40, 80]), NOW);
  assert.ok(stable.status === "ready" && stable.level === "stable");
  assert.ok(swinging.status === "ready" && swinging.level === "unstable");
  assert.equal(hrvStability(hrv([60, 62]), NOW).status, "calibrating");

  const usual = Array.from({ length: 10 }, (_, i) => ({ restingHr: 50 + (i % 3), hrv: 60 + (i % 4) * 2, respiration: 14 + (i % 2) * 0.4, spo2: 96 + (i % 2) }));
  const fine = healthMonitor({ restingHr: 51, hrv: 62, respiration: 14.2, spo2: 96 }, usual);
  assert.ok(fine && fine.status === "ready" && fine.level === "no signs");
  const sick = healthMonitor({ restingHr: 60, hrv: 38, respiration: 16.5, spo2: 96 }, usual);
  assert.ok(sick && sick.status === "ready" && sick.level === "major signs", JSON.stringify(sick));
  assert.deepEqual(sick.signs.filter((s) => s.flagged).map((s) => s.key), ["restingHr", "hrv", "respiration"]);
  assert.deepEqual(healthMonitor({ restingHr: 60, hrv: 38, respiration: 16, spo2: 96 }, usual.slice(0, 4)), { status: "calibrating", have: 4, need: 7 });
});
