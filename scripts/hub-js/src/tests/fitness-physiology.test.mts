import assert from "node:assert/strict";
import { test } from "node:test";
import { buildMetrics } from "../lib/fitness/metrics.ts";
import {
  bodyBattery, currentVo2max, RECOVERY, epocPeak, hrvStatus, loadBalance, readiness, recoveryRemaining, runVo2max, type Sample,
  sleepScore, stressSeries,
} from "../lib/fitness/physiology.ts";

const profile = { maxHr: 198, restingHr: 55, sex: "male" as const };
const HOUR = 3_600_000, DAY = 24 * HOUR;

/** A flat run at a steady speed and heart rate, one sample a second. */
function run(minutes: number, speed: number, hr: number): Sample[] {
  return Array.from({ length: minutes * 60 }, (_, t) => ({ t, hr, speed, altitude: 10, distance: t * speed }));
}

test("VO2max from a steady run extrapolates heart rate reserve to max", () => {
  // 3.2 m/s costs 3.5 + 0.2·192 = 41.9 ml/kg/min; at 70 % of reserve (155 bpm) that's VO2max ≈ 58.4.
  const result = runVo2max(run(30, 3.2, 155), profile);
  assert.ok(result);
  assert.ok(Math.abs(result.vo2max - 58.4) < 0.5, `got ${result.vo2max}`);
  assert.ok(result.minutes >= 20);
});

test("VO2max needs steady, aerobic running", () => {
  assert.equal(runVo2max(run(30, 3.2, 100), profile), null); // too easy to extrapolate from
  assert.equal(runVo2max(run(9, 3.2, 155), profile), null); // too short after the warm-up skip
  const hilly = run(30, 3.2, 155).map((s) => ({ ...s, altitude: s.distance! * 0.08 }));
  assert.equal(runVo2max(hilly, profile), null);
});

test("current VO2max weights recent runs more", () => {
  const now = Date.UTC(2026, 5, 1);
  const value = currentVo2max([{ at: now - 60 * DAY, vo2max: 50, minutes: 20 }, { at: now, vo2max: 56, minutes: 20 }], now)!;
  assert.ok(value > 54.5 && value < 56, `got ${value}`);
  assert.equal(currentVo2max([{ at: now - 200 * DAY, vo2max: 50, minutes: 20 }], now), null);
});

test("load rises with intensity and duration, and easy minutes don't add to the peak", () => {
  const steady = (minutes: number, hr: number) => Array.from({ length: minutes * 60 / 5 }, (_, i) => [i * 5, hr] as [number, number]);
  const easy = epocPeak(steady(45, 120), profile);
  const hard = epocPeak(steady(45, 170), profile);
  const longer = epocPeak(steady(90, 170), profile);
  assert.ok(easy < 30 && hard > 150, `easy ${easy}, hard ${hard}`);
  assert.ok(longer >= hard);
  const cooled = epocPeak([...steady(45, 170), ...steady(30, 100).map(([t, hr]) => [t + 2700, hr] as [number, number])], profile);
  assert.equal(Math.round(cooled), Math.round(hard));
});

test("recovery stacks and counts down", () => {
  const now = Date.UTC(2026, 5, 1);
  assert.equal(recoveryRemaining([], now), 0);
  const one = recoveryRemaining([{ at: now - 10 * HOUR, load: 150 }], now);
  assert.ok(Math.abs(one - (RECOVERY.PER_LOAD * 150 - 10)) < 0.01);
  const two = recoveryRemaining([{ at: now - 10 * HOUR, load: 150 }, { at: now - HOUR, load: 150 }], now);
  assert.ok(two > one + 30);
  assert.equal(recoveryRemaining([{ at: now - 5 * DAY, load: 150 }], now), 0);
});

test("acute:chronic ratio flags a jump in training", () => {
  const now = Date.UTC(2026, 5, 1);
  const usual = Array.from({ length: 28 }, (_, d) => ({ at: now - d * DAY - HOUR, load: d < 7 ? 200 : 60 }));
  const balance = loadBalance(usual, now);
  assert.ok(balance.ratio! > 1.5, `ratio ${balance.ratio}`);
  assert.equal(loadBalance([], now).ratio, null);
});

test("sleep score rewards long nights with enough deep and REM", () => {
  const good = sleepScore({ start: 0, end: 0, deep: 1.4 * 3600, light: 4.2 * 3600, rem: 1.9 * 3600, awake: 300 });
  const short = sleepScore({ start: 0, end: 0, deep: 0.5 * 3600, light: 3.5 * 3600, rem: 0.5 * 3600, awake: 3600 });
  // Stages alone top out near 90, like the watch's best nights.
  assert.ok(good! >= 82 && good! <= 90, `good ${good}`);
  assert.ok(short! < 50, `short ${short}`);
  // A calm night scores higher than the same night under stress.
  const night = { start: 0, end: 0, deep: 1.2 * 3600, light: 4.5 * 3600, rem: 1.6 * 3600, awake: 300 };
  const calm = sleepScore({ ...night, stress: 14 })!, tense = sleepScore({ ...night, stress: 45 })!;
  assert.ok(calm - tense >= 20, `${calm} vs ${tense}`);
  // One of the watch's own nights (2026-11-12: 6.9 h, score 83).
  assert.ok(Math.abs(sleepScore({ start: 0, end: 0, deep: 69 * 60, light: 273 * 60, rem: 71 * 60, awake: 120, stress: 15.74 })! - 83) <= 3);
  assert.equal(sleepScore({ start: 0, end: 0, deep: 0, light: 1000, rem: 0, awake: 0 }), null);
});

test("HRV status compares the week with the 3 weeks before", () => {
  const now = Date.UTC(2026, 5, 1);
  const nights = (week: number) => Array.from({ length: 28 }, (_, d) => ({ at: now - d * DAY, rmssd: d < 7 ? week : 60 + (d % 3) * 4 }));
  assert.equal(hrvStatus(nights(64), now).status, "balanced");
  assert.equal(hrvStatus(nights(40), now).status, "low");
  assert.equal(hrvStatus(nights(64).slice(0, 10), now).status, "building");
});

test("stress reads heart rate above resting, and exercise as activity", () => {
  const t0 = Date.UTC(2026, 5, 1, 12);
  const hr = [58, 70, 80, 90, 150].map((bpm, i) => ({ at: t0 + i * 180_000, bpm }));
  const points = stressSeries(hr, [], profile);
  // Calibrated to the watch: a dozen beats over resting is still rest.
  assert.deepEqual(points.map((p) => p.kind), ["rest", "rest", "stress", "stress", "activity"]);
  assert.ok(points[1].value! <= 25 && points[2].value! > 25 && points[2].value! <= 50 && points[3].value! > 50);
  const during = stressSeries([{ at: t0, bpm: 70 }], [{ start: t0 - 600_000, end: t0 + 600_000 }], profile);
  assert.equal(during[0].kind, "activity");
});

test("body battery charges overnight and drains through a stressful day", () => {
  const t0 = Date.UTC(2026, 5, 1, 22);
  const night = Array.from({ length: 160 }, (_, i) => ({ at: t0 + i * 180_000, bpm: 52 }));
  const day = Array.from({ length: 280 }, (_, i) => ({ at: t0 + 8 * HOUR + i * 180_000, bpm: 85 }));
  const hr = [...night, ...day];
  const levels = bodyBattery(stressSeries(hr, [], profile), hr, [{ start: t0, end: t0 + 8 * HOUR }], profile, 20);
  const morning = levels[159].value, evening = levels[levels.length - 1].value;
  assert.ok(morning >= 65, `morning ${morning}`);
  assert.ok(evening < morning - 30 && evening >= 5, `evening ${evening}`);
});

test("readiness re-weights missing factors and is held down by a poor one", () => {
  const building = { lastNight: null, weekly: null, baseline: null, status: "building" as const, z: null };
  const base = { recoveryHours: 0, hasTraining: true, hrv: building, load: { acute: 300, chronic: 300, ratio: 1 }, recentSleepScores: [], recentStress: [] };
  const fresh = readiness({ ...base, lastSleepScore: 90 });
  assert.equal(fresh.score, 96);
  assert.equal(fresh.level, "prime");
  const tired = readiness({ ...base, lastSleepScore: 20 });
  assert.equal(tired.score, 60);
  assert.equal(readiness({ ...base, hasTraining: false, load: { acute: 0, chronic: 0, ratio: null }, lastSleepScore: null }).score, null);
});

test("metrics come out empty-handed but well formed with no data", () => {
  const metrics = buildMetrics({ now: Date.UTC(2026, 5, 1), activities: [], restingHr: [], heartRate: [], nights: [], hrv: [], vitals: [] });
  assert.equal(metrics.readiness.score, null);
  assert.equal(metrics.bodyBattery, null);
  assert.equal(metrics.vo2max, null);
  assert.equal(metrics.hrv.status, "building");
});

test("stress and Body Battery cover the day before the newest reading, not the day before now", () => {
  const end = Date.UTC(2026, 9, 19, 4);
  const now = end + 22 * HOUR;
  const heartRate = Array.from({ length: 480 }, (_, i) => ({ at: end - 24 * HOUR + i * 180_000, bpm: 62 + (i % 5) }));
  const activity = { start: end - 30 * DAY, elapsedSeconds: 1800, load: 50, vo2max: null, vo2maxMinutes: null, watchVo2max: null, profile };
  const base = { activities: [activity], restingHr: [55], nights: [], hrv: [], vitals: [] };
  const anchored = buildMetrics({ ...base, now, allDayEnd: end, heartRate });
  const fromNow = buildMetrics({ ...base, now, heartRate });
  assert.ok((anchored.stress?.series.length ?? 0) > 400, `anchored ${anchored.stress?.series.length}`);
  // Anchored to now, only the 2 hours of overlap would be left.
  assert.ok((fromNow.stress?.series.length ?? 0) <= 40, `from now ${fromNow.stress?.series.length}`);
});
