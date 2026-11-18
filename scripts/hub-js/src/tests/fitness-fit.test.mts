import assert from "node:assert/strict";
import { test } from "node:test";
import { decodeFit, fitCrc, FitError, isFit } from "../lib/fitness/fit.ts";
import { summarize } from "../lib/fitness/summarize.ts";

// A tiny FIT writer: fields are [number, base type, value] with uint8 (2), uint16 (0x84), uint32 (0x86).
type Field = [number, number, number];
const SIZE: Record<number, number> = { 0: 1, 2: 1, 0x84: 2, 0x86: 4 };

function fit(records: { local: number; num: number; fields: Field[]; compressed?: number }[]): Uint8Array {
  const body: number[] = [];
  const defined = new Map<number, string>();
  for (const r of records) {
    const shape = `${r.num}:${r.fields.map(([n, t]) => `${n}/${t}`).join(",")}`;
    if (defined.get(r.local) !== shape) {
      body.push(0x40 | r.local, 0, 0, r.num & 0xff, r.num >> 8, r.fields.length);
      for (const [n, t] of r.fields) body.push(n, SIZE[t], t);
      defined.set(r.local, shape);
    }
    body.push(r.compressed === undefined ? r.local : 0x80 | (r.local << 5) | r.compressed);
    for (const [, t, v] of r.fields) for (let i = 0; i < SIZE[t]; i++) body.push((v >>> (8 * i)) & 0xff);
  }
  const header = [14, 0x20, 0x34, 0x08, ...le32(body.length), ...".FIT".split("").map((c) => c.charCodeAt(0))];
  const headerCrc = fitCrc(new Uint8Array(header));
  const bytes = [...header, headerCrc & 0xff, headerCrc >> 8, ...body];
  const crc = fitCrc(new Uint8Array(bytes));
  return new Uint8Array([...bytes, crc & 0xff, crc >> 8]);
}
const le32 = (v: number) => [v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, v >>> 24];

const T0 = 1_100_000_000; // FIT seconds: 2024-11-09 UTC

test("rejects files with a bad CRC", () => {
  const file = fit([{ local: 0, num: 20, fields: [[253, 0x86, T0], [3, 2, 120]] }]);
  assert.ok(isFit(file));
  file[20] ^= 0xff;
  assert.equal(isFit(file), false);
  assert.throws(() => decodeFit(file), FitError);
});

test("summarizes an activity with compressed timestamps", () => {
  const file = fit([
    { local: 0, num: 34, fields: [[253, 0x86, T0 + 4000], [5, 0x86, T0 + 4000 - 4 * 3600]] },
    { local: 1, num: 20, fields: [[253, 0x86, T0], [3, 2, 100]] },
    { local: 1, num: 20, fields: [[253, 0x86, T0], [3, 2, 110]], compressed: (T0 + 5) & 0x1f },
    { local: 2, num: 18, fields: [[2, 0x86, T0], [5, 0, 1], [6, 0, 3], [7, 0x86, 3_600_000], [9, 0x86, 1_000_000], [11, 0x84, 700], [16, 2, 150], [17, 2, 180]] },
  ]);
  const summary = summarize(decodeFit(file));
  assert.deepEqual(summary.activity && { ...summary.activity, heartRate: summary.activity.heartRate }, {
    sport: "running", subSport: "trail", startTime: new Date((T0 + 631065600) * 1000).toISOString(), utcOffset: -4 * 3600,
    elapsedSeconds: 3600, movingSeconds: null, distanceMeters: 10_000, calories: 700, avgHeartRate: 150, maxHeartRate: 180,
    ascentMeters: null, avgSpeed: null, trainingEffect: null, heartRate: [[0, 100], [5, 110]],
    // No heart rate zones or user profile in the file, so no models run.
    metrics: { profile: null, load: null, vo2max: null, vo2maxMinutes: null,
      watch: { load: null, vo2max: null, recoveryHours: null, trainingEffect: null, anaerobicEffect: null },
      extras: {
        primaryBenefit: null, performanceCondition: null, endingBodyBattery: null, lactateThresholdHr: null,
        lactateThresholdSpeed: null, racePredictions: null, sets: [], laps: [], bestEfforts: [],
        session: Object.fromEntries([
          "activeSeconds", "avgTempC", "minTempC", "maxTempC", "sweatLossMl", "recoveryHr", "startStress", "endStress",
          "avgStress", "maxStress", "avgRespiration", "minRespiration", "maxRespiration", "avgSpo2", "totalSets", "volumeKg",
          "metabolicKcal", "floorsUp", "floorsDown", "rpe", "feel", "startStamina", "endStamina", "minStamina",
          "startBodyBattery", "endBodyBattery", "minHr", "avgCadence", "maxCadence", "avgPowerW", "maxPowerW",
          "normalizedPowerW", "verticalOscillationMm", "groundContactMs", "verticalRatio", "stepLengthM",
          "gradeAdjustedSpeed", "zoneSeconds",
        ].map((key) => [key, null])),
      } },
  });
});

test("monitoring adds walking and running steps per local day and reads 16-bit timestamps", () => {
  const day = T0 - (T0 % 86400) + 86400 + 3600; // 01:00 UTC
  const file = fit([
    { local: 0, num: 103, fields: [[253, 0x86, day], [0, 0x86, day]] },
    { local: 1, num: 55, fields: [[253, 0x86, day], [5, 0, 6], [3, 0x86, 1000]] },
    { local: 2, num: 55, fields: [[26, 0x84, (day + 600) & 0xffff], [5, 0, 6], [3, 0x86, 2500]] },
    { local: 2, num: 55, fields: [[26, 0x84, (day + 900) & 0xffff], [5, 0, 1], [3, 0x86, 400]] },
    { local: 3, num: 55, fields: [[26, 0x84, (day + 1200) & 0xffff], [27, 2, 64]] },
    { local: 4, num: 211, fields: [[253, 0x86, day + 1300], [1, 2, 52]] },
  ]);
  const summary = summarize(decodeFit(file));
  const date = new Date((day + 631065600) * 1000).toISOString().slice(0, 10);
  assert.deepEqual(summary.daily, [{
    day: date, steps: 2900, restingHeartRate: 52, distanceMeters: null, activeKcal: null, activeSeconds: null,
    restingKcal: null, stepGoal: null, ascentMeters: null, descentMeters: null, moderateMinutes: null, vigorousMinutes: null,
    final: false,
  }]);
  assert.deepEqual(summary.heartRate, [{ at: new Date((day + 1200 + 631065600) * 1000).toISOString(), bpm: 64 }]);
  assert.equal(summary.activity, null);
});

test("monitoring totals: the closing summary at local midnight belongs to the day before", () => {
  const offset = -4 * 3600;
  const midnight = T0 - ((T0 - offset) % 86400) + 86400 * 2; // a local midnight (FIT seconds, UTC)
  const local = midnight - offset;
  const file = fit([
    { local: 0, num: 103, fields: [[253, 0x86, midnight - 86400], [0, 0x86, local - 86400], [5, 0x84, 2025], [7, 0x84, 9000]] },
    // During the day: type in the low bits of field 24, intensity in the top three.
    { local: 1, num: 55, fields: [[253, 0x86, midnight - 3600], [24, 0, (2 << 5) | 6], [3, 0x86, 1000]] },
    { local: 1, num: 55, fields: [[253, 0x86, midnight - 1800], [24, 0, (1 << 5) | 6], [3, 0x86, 1500]] },
    // The closing summary of the day, stamped at midnight: walking and generic.
    { local: 2, num: 55, fields: [[253, 0x86, midnight], [5, 0, 6], [3, 0x86, 1600], [2, 0x86, 120_000], [4, 0x86, 900_000], [19, 0x84, 80], [29, 0x84, 1440]] },
    { local: 2, num: 55, fields: [[253, 0x86, midnight], [5, 0, 0], [3, 0x86, 0], [2, 0x86, 0], [4, 0x86, 300_000], [19, 0x84, 20], [29, 0x84, 1440]] },
    { local: 3, num: 55, fields: [[253, 0x86, midnight], [35, 0x86, 30_480], [36, 0x86, 3_048], [37, 0x84, 12], [38, 0x84, 4]] },
    { local: 4, num: 211, fields: [[253, 0x86, midnight], [1, 2, 51]] },
  ]);
  const summary = summarize(decodeFit(file), offset);
  const day = new Date((midnight - 1 + offset + 631065600) * 1000).toISOString().slice(0, 10);
  assert.deepEqual(summary.daily, [{
    day, steps: 1600, restingHeartRate: 51, distanceMeters: 1200, activeKcal: 100, activeSeconds: 1200,
    restingKcal: 2025, stepGoal: 9000, ascentMeters: 30.48, descentMeters: 3.048, moderateMinutes: 12, vigorousMinutes: 4,
    final: true,
  }]);
  assert.deepEqual(summary.vitals.filter((v) => v.kind === "steps").map((v) => v.value), [500]);
  assert.deepEqual(summary.vitals.filter((v) => v.kind === "intensity").map((v) => v.value), [2, 1]);
});

test("a 16-bit timestamp a little behind the last full one stays in the past", () => {
  const day = T0 - (T0 % 86400) + 86400 + 3600;
  const file = fit([
    { local: 0, num: 297, fields: [[253, 0x86, day + 60], [0, 0x84, 1500]] },
    { local: 1, num: 55, fields: [[26, 0x84, (day + 30) & 0xffff], [27, 2, 70]] },
  ]);
  assert.deepEqual(summarize(decodeFit(file)).heartRate, [{ at: new Date((day + 30 + 631065600) * 1000).toISOString(), bpm: 70 }]);
});

test("sleep level records mark where each stage ends", () => {
  // Asleep at T0 (the start event); light until +600, deep until +1800, awake until +1900 (the stop event).
  const file = fit([
    { local: 1, num: 21, fields: [[253, 0x86, T0], [1, 0, 0]] },
    { local: 1, num: 21, fields: [[253, 0x86, T0 + 1900], [1, 0, 1]] },
    { local: 0, num: 275, fields: [[253, 0x86, T0 + 600], [0, 0, 2]] },
    { local: 0, num: 275, fields: [[253, 0x86, T0 + 1800], [0, 0, 3]] },
    { local: 0, num: 275, fields: [[253, 0x86, T0 + 1900], [0, 0, 1]] },
    // The file is written a while after waking; that isn't part of the night.
    { local: 2, num: 273, fields: [[253, 0x86, T0 + 2500]] },
  ]);
  const sleep = summarize(decodeFit(file)).sleep!;
  assert.equal(sleep.lightSeconds, 600);
  assert.equal(sleep.deepSeconds, 1200);
  assert.equal(sleep.awakeSeconds, 100);
  assert.equal(sleep.remSeconds, 0);
  assert.deepEqual(sleep.levels, [[0, 2], [600, 3], [1800, 1]]);
  assert.equal(sleep.start, new Date((T0 + 631065600) * 1000).toISOString());
  assert.equal(sleep.end, new Date((T0 + 1900 + 631065600) * 1000).toISOString());
});

test("a sleep file with no start event starts at its first record", () => {
  const file = fit([
    { local: 0, num: 275, fields: [[253, 0x86, T0], [0, 0, 2]] },
    { local: 0, num: 275, fields: [[253, 0x86, T0 + 600], [0, 0, 4]] },
  ]);
  const sleep = summarize(decodeFit(file)).sleep!;
  assert.equal(sleep.remSeconds, 600);
  assert.equal(sleep.lightSeconds, 0);
  assert.deepEqual(sleep.levels, [[0, 4]]);
});

test("HRV status summary and readings are scaled from 1/128 ms", () => {
  const file = fit([
    { local: 0, num: 370, fields: [[253, 0x86, T0 + 40_000], [0, 0x84, 55 * 128], [1, 0x84, 61 * 128 + 64], [2, 0x84, 90 * 128], [6, 0, 4]] },
    { local: 1, num: 371, fields: [[253, 0x86, T0], [0, 0x84, 50 * 128]] },
    { local: 1, num: 371, fields: [[253, 0x86, T0 + 300], [0, 0x84, 70 * 128]] },
  ]);
  const hrv = summarize(decodeFit(file)).hrv!;
  assert.equal(hrv.weeklyAverage, 55);
  assert.equal(hrv.lastNightAverage, 61.5);
  assert.equal(hrv.lastNight5MinHigh, 90);
  assert.equal(hrv.status, "balanced");
  assert.deepEqual(hrv.readings, [[0, 50], [300, 70]]);
  assert.equal(summarize(decodeFit(fit([{ local: 0, num: 20, fields: [[253, 0x86, T0], [3, 2, 100]] }]))).hrv, null);
});

test("an open file (no CRC yet, cut mid-record) reads up to its last whole record with partial", () => {
  const records = [0, 1, 2].map((i) => ({ local: 0, num: 20, fields: [[253, 0x86, T0 + i * 60], [3, 2, 100 + i]] as Field[] }));
  const whole = fit(records);
  // Drop the CRC and half of the last record, as a file still being written can look.
  const open = whole.subarray(0, whole.length - 2 - 3);
  assert.equal(isFit(open), false);
  assert.throws(() => decodeFit(open), FitError);
  const messages = decodeFit(open, { partial: true });
  assert.deepEqual(messages.map((m) => m.fields.get(3)), [100, 101]);
  // A closed file decodes the same either way.
  assert.equal(decodeFit(whole, { partial: true }).length, 3);
});
