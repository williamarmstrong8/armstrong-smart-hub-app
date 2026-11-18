import assert from "node:assert/strict";
import { test } from "node:test";
import { agreement, calibrate, type CalibrationFile } from "../lib/fitness/calibrate.ts";
import type { ActivitySummary, FitSummary } from "../lib/fitness/summarize.ts";

const profile = { maxHr: 198, restingHr: 55, sex: "male" as const };
const empty: FitSummary = { activity: null, daily: [], heartRate: [], sleep: null, hrv: null, vitals: [], watch: [] };

test("agreement: perfect, offset and empty", () => {
  const same = [1, 2, 3, 4].map((v, i) => ({ at: i, hub: v, watch: v }));
  assert.deepEqual(agreement(same), { n: 4, r: 1, mae: 0, bias: 0 });
  const high = [1, 2, 3, 4].map((v, i) => ({ at: i, hub: v + 2, watch: v }));
  assert.deepEqual(agreement(high), { n: 4, r: 1, mae: 2, bias: 2 });
  assert.deepEqual(agreement([]), { n: 0, r: null, mae: null, bias: null });
  assert.equal(agreement(same.slice(0, 2)).r, null);
});

function activity(start: string, hub: number, watch: number): CalibrationFile {
  const summary: ActivitySummary = {
    sport: "running", subSport: null, startTime: start, utcOffset: 0, elapsedSeconds: 1800, movingSeconds: 1800,
    distanceMeters: 5000, calories: 300, avgHeartRate: 150, maxHeartRate: 170, ascentMeters: 0, avgSpeed: 2.8,
    trainingEffect: 3, heartRate: [],
    metrics: {
      profile, load: hub, vo2max: null, vo2maxMinutes: null, aerobicEffect: null,
      watch: { load: watch, vo2max: null, recoveryHours: null, trainingEffect: null },
    },
  };
  return { kind: "activity", summary: { ...empty, activity: summary } };
}

test("calibrate pairs each activity's load with the watch's and skips missing values", () => {
  const result = calibrate([
    activity("2026-10-01T10:00:00Z", 100, 110),
    activity("2026-10-02T10:00:00Z", 50, 60),
    activity("2026-10-03T10:00:00Z", 80, 90),
  ]);
  assert.deepEqual(result.load, { n: 3, r: 1, mae: 10, bias: -10 });
  assert.equal(result.vo2max.n, 0);
  assert.equal(result.aerobicEffect.n, 0);
});

test("calibrate scores the hub's sleep score against the watch's", () => {
  const night = (end: string, watch: number): CalibrationFile => ({
    kind: "sleep",
    summary: { ...empty, sleep: { start: "2026-10-01T23:00:00Z", end, deepSeconds: 5400, lightSeconds: 14400, remSeconds: 7200, awakeSeconds: 600, score: watch, levels: [] } },
  });
  const result = calibrate([night("2026-10-02T07:00:00Z", 90)]);
  assert.equal(result.sleepScore.n, 1);
  assert.equal(result.sleepScore.r, null);
});

test("calibrate lines up all-day stress and battery with the watch's 3-minute averages", () => {
  const t0 = Date.parse("2026-10-05T12:00:00Z");
  const minutes = Array.from({ length: 60 }, (_, i) => t0 + i * 60_000);
  const monitor: CalibrationFile = {
    kind: "monitor",
    summary: {
      ...empty,
      heartRate: minutes.map((at, i) => ({ at: new Date(at).toISOString(), bpm: i < 30 ? 62 : 80 })),
      vitals: minutes.flatMap((at, i) => [
        { kind: "stress" as const, at: new Date(at).toISOString(), value: i < 30 ? 20 : 60 },
        { kind: "body_battery" as const, at: new Date(at).toISOString(), value: 50 },
      ]),
    },
  };
  // A past activity supplies the heart profile.
  const result = calibrate([activity("2026-10-01T10:00:00Z", 100, 100), monitor]);
  assert.equal(result.stress.n, 20);
  assert.ok(result.stress.r !== null && result.stress.r > 0.9);
  assert.equal(result.bodyBattery.n, 20);
});
