import assert from "node:assert/strict";
import { test } from "node:test";
import { FIT_EPOCH, type FitMessage } from "../lib/fitness/fit.ts";
import { buildMetrics, preferWatch } from "../lib/fitness/metrics.ts";
import { activityExtras, watchMetrics } from "../lib/fitness/watch-metrics.ts";
import { buildWatchSnapshot } from "../lib/fitness/watch-snapshot.ts";

const msg = (num: number, fields: Record<number, number | (number | null)[] | null>): FitMessage =>
  ({ num, fields: new Map(Object.entries(fields).map(([k, v]) => [Number(k), v])) });
const fitTime = (iso: string) => Date.parse(iso) / 1000 - FIT_EPOCH;
const NOW = Date.parse("2026-10-19T12:00:00Z");

test("watchMetrics reads readiness, race predictions and endurance with their scales", () => {
  const t = fitTime("2026-10-19T09:53:29Z");
  const out = watchMetrics([
    msg(369, { 253: t, 0: 64, 1: 3, 4: 61, 21: 4224, 3: 62 }),
    msg(339, { 253: t, 1: 1388, 2: 3035, 3: 6854, 4: 15566 }),
    msg(403, { 253: t, 0: 5780, 1: 2, 3: 5100, 4: 5800 }),
    msg(20, { 253: t, 3: 120 }),
  ]);
  assert.equal(out.length, 3);
  assert.deepEqual(out[0].data.score, 64);
  assert.equal(out[0].data.weeklyHrv, 33);
  assert.equal(out[0].data.f3, 62);
  assert.equal(out[0].at, "2026-10-19T09:53:29.000Z");
  assert.equal(out[1].data.half, 6854);
});

test("watchMetrics skips records with nothing set and takes recovery's own start time", () => {
  const t = fitTime("2026-10-19T09:00:00Z");
  const out = watchMetrics([msg(402, { 253: t, 0: null, 1: null, 2: null, 3: null, 4: null }), msg(284, { 0: 390, 1: t })]);
  assert.equal(out.length, 1);
  assert.equal(out[0].kind, "recovery");
  assert.equal(out[0].at, "2026-10-19T09:00:00.000Z");
});

test("activityExtras: active sets with exercise and weight, laps, primary benefit", () => {
  const t = fitTime("2026-10-10T18:00:00Z");
  const extras = activityExtras([
    msg(140, { 41: 2, 17: -3, 25: 70, 69: 1469 }),
    msg(225, { 5: 1, 6: t, 0: 52004, 3: 9, 4: 326, 7: [0, null, null] }),
    msg(225, { 5: 0, 6: t + 60, 0: 90000 }),
    msg(19, { 2: t, 8: 300000, 9: 100000, 15: 150 }),
  ]);
  assert.equal(extras.primaryBenefit, "base");
  assert.equal(extras.performanceCondition, -3);
  assert.deepEqual(extras.sets, [{ at: "2026-10-10T18:00:00.000Z", seconds: 52.004, reps: 9, weightKg: 20.4, exercise: "bench_press" }]);
  assert.equal(extras.laps[0].meters, 1000);
  assert.equal(extras.racePredictions?.fiveK, 1469);
});

test("buildWatchSnapshot: readiness level names, endurance level from its bounds, recovery counted down", () => {
  const at = "2026-10-19T09:00:00.000Z";
  const watch = buildWatchSnapshot([
    { kind: "readiness", at, data: { score: 64, level: 3, sleepScore: 61, weeklyHrv: 33 } },
    { kind: "endurance_score", at, data: { score: 5780, level: 2, intermediate: 5100, trained: 5800, wellTrained: 6600, expert: 7300, superior: 8100, elite: 8800, gaugeLow: 3570, gaugeHigh: 10560 } },
    { kind: "recovery", at, data: { minutes: 600 } },
    { kind: "readiness", at: "2026-10-10T09:00:00.000Z", data: { score: 80, level: 4 } },
  ], NOW);
  assert.equal(watch.readiness?.score, 64);
  assert.equal(watch.readiness?.level, "moderate");
  assert.equal(watch.readiness?.history.length, 2);
  assert.equal(watch.endurance?.level, "intermediate");
  assert.equal(watch.endurance?.nextLevel?.name, "trained");
  assert.equal(watch.recovery?.remainingHours, 7);
  assert.equal(watch.races, null);
});

test("buildWatchSnapshot ignores stale readiness", () => {
  const watch = buildWatchSnapshot([{ kind: "readiness", at: "2026-10-15T09:00:00.000Z", data: { score: 64, level: 3 } }], NOW);
  assert.equal(watch.readiness, null);
});

test("preferWatch swaps in the watch's numbers and keeps the hub's as the fallback", () => {
  const metrics = buildMetrics({ now: NOW, activities: [], restingHr: [], heartRate: [], nights: [], hrv: [], vitals: [] });
  const watch = buildWatchSnapshot([
    { kind: "readiness", at: "2026-10-19T09:00:00.000Z", data: { score: 64, level: 3 } },
    { kind: "user_metrics", at: "2026-07-11T16:00:00.000Z", data: { vo2max: 54.67 } },
  ], NOW);
  const battery = [0, 1, 2].map((i) => ({ at: NOW - (3 - i) * 300_000, value: 50 + i }));
  const result = preferWatch(metrics, watch, { stress: [], bodyBattery: battery }, NOW);
  assert.equal(result.readiness.score, 64);
  assert.equal(result.readiness.level, "moderate");
  assert.equal(result.vo2max?.value, 54.67);
  assert.equal(result.bodyBattery?.current, 52);
  assert.equal(result.bodyBattery?.charged, 2);
  assert.deepEqual(result.sources, { readiness: "watch", recovery: "hub", vo2max: "watch", bodyBattery: "watch", stress: "hub" });
});
