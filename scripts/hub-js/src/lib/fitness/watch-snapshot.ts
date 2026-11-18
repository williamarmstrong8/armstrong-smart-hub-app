import { READINESS_LEVELS } from "./watch-metrics.ts";

/**
 * The watch's own numbers (watch-metrics.ts) as the Fitness page shows them:
 * the newest reading of each, short histories for trends, and recovery
 * counted down to now. Everything is null until the watch has written it.
 * Pure, so it can be tested with made-up rows.
 */

export type WatchRow = { kind: string; at: string; data: Record<string, number | null> };

const DAY = 86_400_000;

const ENDURANCE_LEVELS = ["recreational", "intermediate", "trained", "well trained", "expert", "superior", "elite"] as const;

export function buildWatchSnapshot(rows: WatchRow[], now: number) {
  const sorted = [...rows].sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
  const of = (kind: string) => sorted.filter((r) => r.kind === kind);
  const latest = (kind: string, maxAgeDays = Infinity) => {
    const list = of(kind);
    const row = list[list.length - 1];
    return row && now - Date.parse(row.at) <= maxAgeDays * DAY ? row : null;
  };
  /** One value per local-ish day (the newest), oldest first, for the last `days`. */
  const history = (kind: string, field: string, days: number) => {
    const byDay = new Map<string, { at: string; value: number }>();
    for (const row of of(kind)) {
      const value = row.data[field];
      if (value === null || value === undefined || now - Date.parse(row.at) > days * DAY) continue;
      byDay.set(row.at.slice(0, 10), { at: row.at, value });
    }
    return [...byDay.values()];
  };

  const readinessRow = latest("readiness", 1.5);
  const readiness = readinessRow && readinessRow.data.score !== null ? {
    at: readinessRow.at,
    score: readinessRow.data.score!,
    level: READINESS_LEVELS[readinessRow.data.level ?? 0] ?? null,
    sleepScore: readinessRow.data.sleepScore,
    weeklyHrv: readinessRow.data.weeklyHrv,
    history: history("readiness", "score", 30),
  } : null;

  const enduranceRow = latest("endurance_score", 14);
  const endurance = enduranceRow && enduranceRow.data.score ? (() => {
    const d = enduranceRow.data;
    const bounds = [d.intermediate, d.trained, d.wellTrained, d.expert, d.superior, d.elite];
    // The level from where the score sits between the watch's own bounds.
    const index = bounds.filter((b) => b !== null && d.score! >= b).length;
    const next = bounds[index] ?? null;
    return {
      at: enduranceRow.at, score: d.score!, level: ENDURANCE_LEVELS[index],
      nextLevel: next === null ? null : { name: ENDURANCE_LEVELS[index + 1], at: next },
      gauge: d.gaugeLow !== null && d.gaugeHigh !== null ? { low: d.gaugeLow, high: d.gaugeHigh } : null,
      bounds: Object.fromEntries(ENDURANCE_LEVELS.slice(1).map((name, i) => [name, bounds[i]])),
      history: history("endurance_score", "score", 90),
    };
  })() : null;

  const hillRow = latest("hill_score", 14);
  const hill = hillRow && hillRow.data.score ? {
    at: hillRow.at, score: hillRow.data.score, strength: hillRow.data.strength, endurance: hillRow.data.endurance,
  } : null;

  const raceRow = latest("race_predictions", 30);
  const races = raceRow ? {
    at: raceRow.at,
    fiveK: raceRow.data.fiveK || null, tenK: raceRow.data.tenK || null, half: raceRow.data.half || null, marathon: raceRow.data.marathon || null,
    history: history("race_predictions", "fiveK", 90),
  } : null;

  // Recovery runs from when the watch set it; count it down to now.
  const recoveryRow = latest("recovery", 5);
  const recovery = recoveryRow && recoveryRow.data.minutes !== null ? {
    at: recoveryRow.at,
    totalHours: Math.round(recoveryRow.data.minutes! / 6) / 10,
    remainingHours: Math.max(0, Math.round((recoveryRow.data.minutes! / 60 - (now - Date.parse(recoveryRow.at)) / 3_600_000) * 10) / 10),
  } : null;

  const focusRow = latest("load_focus", 7);
  const focus = focusRow ? (() => {
    const d = focusRow.data;
    const band = (min: number | null, max: number | null) => (min === null || max === null ? null : { min, max });
    return {
      at: focusRow.at,
      low: d.low ?? 0, high: d.high ?? 0, anaerobic: d.anaerobic ?? 0,
      targets: { low: band(d.lowMin, d.lowMax), high: band(d.highMin, d.highMax), anaerobic: band(d.anaerobicMin, d.anaerobicMax) },
    };
  })() : null;

  const needRow = latest("sleep_need", 2);
  const sleepNeed = needRow && needRow.data.needMinutes ? {
    at: needRow.at, hours: Math.round(needRow.data.needMinutes / 6) / 10,
    usualHours: needRow.data.normalMinutes ? Math.round(needRow.data.normalMinutes / 6) / 10 : null,
  } : null;

  const scoresRow = latest("sleep_scores", 2);
  const daily = latest("daily_sleep", 2);
  const insight = latest("sleep_insight", 2);
  const sleep = scoresRow ? {
    at: scoresRow.at,
    overall: scoresRow.data.overall,
    // Garmin's sub-scores, each 0-100.
    parts: {
      duration: scoresRow.data.duration, quality: scoresRow.data.quality, deep: scoresRow.data.deep, light: scoresRow.data.light,
      rem: scoresRow.data.rem, recovery: scoresRow.data.recovery, restlessness: scoresRow.data.restlessness,
      interruptions: scoresRow.data.interruptions,
    },
    awakenings: scoresRow.data.awakeningsCount,
    avgStress: scoresRow.data.avgStress,
    lowestHr: daily?.data.minHr ?? null,
    batteryGained: daily && daily.data.endBattery !== null && daily.data.startBattery !== null ? daily.data.endBattery - daily.data.startBattery : null,
    // The watch's own averages over the night (its sleep insight).
    overnight: insight ? {
      hrv: insight.data.hrv ?? null, heartRate: insight.data.heartRate ?? null, respiration: insight.data.respiration ?? null,
      spo2: insight.data.spo2 ?? null,
    } : null,
    history: history("sleep_scores", "overall", 30),
  } : null;

  // VO2max and thresholds come with each activity; keep the newest real values.
  const users = of("user_metrics");
  const newest = (field: string) => {
    for (let i = users.length - 1; i >= 0; i--) {
      const value = users[i].data[field];
      if (value) return { at: users[i].at, value };
    }
    return null;
  };
  const vo2 = newest("vo2max");
  const lthr = newest("lthr");
  const ltSpeed = newest("ltSpeed");

  return {
    readiness,
    recovery,
    endurance,
    hill,
    races,
    focus,
    sleepNeed,
    sleep,
    // Only the points where it moved: the watch repeats it on every activity.
    vo2max: vo2 ? {
      at: vo2.at, value: vo2.value,
      history: history("user_metrics", "vo2max", 365).filter((p, i, all) => i === 0 || p.value !== all[i - 1].value),
    } : null,
    lactateThreshold: lthr ? { at: lthr.at, hr: lthr.value, speed: ltSpeed?.value ?? null } : null,
  };
}

export type WatchSnapshot = ReturnType<typeof buildWatchSnapshot>;
