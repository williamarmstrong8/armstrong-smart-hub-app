import {
  appleSleepScore, bedtimeSpread, type Calibrating, cardioFitness, daytimeStress, dayStrain, effectLabel, enduranceScore,
  type FocusSplit, hillScore, hubAge, interruptions, lactateThreshold, loadFocus, performanceCondition, racePredictions,
  recovery, recoveryIndex, resilience, sleepingRestingHr, sleepNeed, sleepPerformance, strainLevel, vitals,
} from "./insights.ts";
import type { Profile } from "./physiology.ts";
import {
  activeZoneMinutes, breathingDisturbances, cardioRecovery, chronotype, contributorReadiness, fitnessFatigueForm, healthMonitor,
  hrvStability, monotony, sleepDebt, sleepEfficiency, sleepRegularity, stageBalance, strainTarget, trainingStatus, zoneDistribution,
} from "./scores.ts";

/**
 * Puts insights.ts together over what the hub has stored: the Whoop, Oura,
 * Garmin and Apple style scores on the Fitness page. Pure, so it can be
 * tested with made-up weeks; the store does the querying and hands over
 * nights with their vitals already averaged and stress in 5-minute steps.
 */

const DAY = 86_400_000;
const avg = (values: number[]) => (values.length ? values.reduce((a, b) => a + b, 0) / values.length : null);
const round1 = (value: number) => Math.round(value * 10) / 10;

export type InsightActivity = {
  start: number;
  end: number;
  sport: string;
  minutes: number;
  load: number | null;
  trimp: number | null;
  strain: number | null;
  aerobicEffect: number | null;
  anaerobicEffect: number | null;
  watchAerobic: number | null;
  watchAnaerobic: number | null;
  effort: number | null;
  focus: FocusSplit | null;
  best20Hr: number | null;
  bestClimbRate: number | null;
  ascent: number | null;
  earlyVo2max: number | null;
  steady: [number, number][];
  subSport?: string | null;
  /** Seconds in heart rate zones 1-5. */
  zones?: number[] | null;
  /** The watch's 2-minute heart rate drop after the session, and the heart rate it stopped at. */
  recoveryHr?: number | null;
  endHr?: number | null;
};

export type InsightNight = {
  start: number;
  end: number;
  asleepSeconds: number;
  levels: [number, number][];
  /** The watch's sleep score when it gave one, else the hub's. */
  score: number | null;
  /** Averages over the night. */
  hrv: number | null;
  respiration: number | null;
  spo2: number | null;
  /** Overnight heart rate samples (empty for nights before all-day heart rate was kept). */
  heartRate: { at: number; bpm: number }[];
  /** Garmin's resting heart rate for the day the night ended. */
  dailyRestingHr: number | null;
  /** Seconds in each stage, for the stage balance. */
  stages?: { deep: number; light: number; rem: number; awake: number };
};

export type InsightInput = {
  now: number;
  /** End of the newest all-day data (defaults to now): the day's stress and battery are the 24 hours before it. */
  allDayEnd?: number;
  /** Local time minus UTC, seconds. */
  utcOffset: number;
  profile: Profile | null;
  /** The hub's current VO2max (metrics.ts). */
  vo2max: number | null;
  activities: InsightActivity[];
  /** All-day heart rate, the last 8 days. */
  heartRate: { at: number; bpm: number }[];
  /** The last 35 nights. */
  nights: InsightNight[];
  /** The watch's stress, 5-minute averages, the last 15 days. */
  stress: { at: number; value: number }[];
  /** The watch's Body Battery, 5-minute averages, the last 2 days. */
  bodyBattery: { at: number; value: number }[];
  /** Daily resting heart rate, newest first. */
  restingHr: number[];
  /** Steps per local day, the last 4 weeks. */
  days?: { day: string; steps: number | null }[];
  /** Overnight SpO2 readings, the last day and a half. */
  spo2?: { at: number; value: number }[];
  /** Naps the watch detected, the last 5 weeks. */
  naps?: { start: number; end: number }[];
  /** Acute and chronic load (metrics.ts), the HRV status, and VO2max readings oldest first. */
  load?: { acute: number; chronic: number; ratio: number | null };
  hrvStatus?: string | null;
  vo2maxHistory?: { at: number; value: number }[];
};

export function buildInsights(input: InsightInput) {
  const { now, profile } = input;
  const offsetMs = input.utcOffset * 1000;
  const dayStart = (ms: number) => Math.floor((ms + offsetMs) / DAY) * DAY - offsetMs;
  const dayKey = (ms: number) => new Date(ms + offsetMs).toISOString().slice(0, 10);
  const today = dayStart(now);

  const activities = [...input.activities].sort((a, b) => b.start - a.start);
  const nights = [...input.nights].sort((a, b) => b.end - a.end);
  const asleep = (at: number) => nights.some((n) => at >= n.start && at <= n.end);
  const exercising = (at: number) => activities.some((a) => at >= a.start && at <= a.end + 10 * 60_000);

  // MARK: Strain: today and the last 7 days.
  const strainFor = (from: number) => {
    if (!profile) return null;
    const to = from + DAY;
    const workouts = activities.filter((a) => a.start >= from && a.start < to && a.trimp !== null)
      .map((a) => ({ start: a.start, end: a.end, trimp: a.trimp! }));
    const hr = input.heartRate.filter((s) => s.at >= from && s.at < to);
    if (!hr.length && !workouts.length) return null;
    return dayStrain(hr, workouts, profile).strain;
  };
  const strainWeek = Array.from({ length: 7 }, (_, i) => {
    const from = today - (6 - i) * DAY;
    return { day: dayKey(from + DAY / 2), strain: strainFor(from) };
  });
  const strainToday = strainWeek[6].strain;
  const strainYesterday = strainWeek[5].strain;

  // MARK: Sleep need, performance, consistency, recovery index.
  const lastNight = nights[0] && now - nights[0].end < 18 * 3600_000 ? nights[0] : null;
  const isNap = (n: InsightNight) => n.asleepSeconds < 3 * 3600;
  const mainNights = nights.filter((n) => !isNap(n));
  // Naps: short sleeps with stages, and the ones the watch logs as a nap with none.
  const naps = (input.naps ?? []).filter((n) => n.end > n.start && n.end - n.start <= 4 * 3600_000 && !nights.some((m) => n.start < m.end && n.end > m.start));
  const napsToday = nights.filter((n) => isNap(n) && n.start >= today).reduce((a, n) => a + n.asleepSeconds, 0)
    + naps.filter((n) => n.start >= today).reduce((a, n) => a + (n.end - n.start) / 1000, 0);
  const need = sleepNeed({
    history: mainNights.filter((n) => now - n.end < 30 * DAY),
    lastWeek: mainNights.filter((n) => now - n.end < 7 * DAY),
    yesterdayStrain: strainToday,
    napSeconds: napsToday,
  });
  // What last night needed: the same, as of the day before it.
  const before = (n: InsightNight) => mainNights.filter((m) => m.end < n.end);
  const needFor = (n: InsightNight, dayStrainValue: number | null) => sleepNeed({
    history: before(n).filter((m) => n.end - m.end < 30 * DAY),
    lastWeek: before(n).filter((m) => n.end - m.end < 7 * DAY),
    yesterdayStrain: dayStrainValue,
    napSeconds: 0,
  }).hours;
  const lastNeed = lastNight ? needFor(lastNight, strainYesterday) : null;
  const spread = bedtimeSpread(mainNights.filter((n) => now - n.end < 14 * DAY).map((n) => n.start), input.utcOffset);
  const sleep = {
    need,
    lastNight: lastNight && {
      asleepHours: round1(lastNight.asleepSeconds / 3600),
      needed: lastNeed,
      performance: lastNeed === null ? null : sleepPerformance(lastNight.asleepSeconds, lastNeed),
      score: lastNight.score,
      interruptions: interruptions(lastNight.levels, (lastNight.end - lastNight.start) / 1000),
      recoveryIndex: recoveryIndex(lastNight),
      apple: appleSleepScore(lastNight.asleepSeconds, spread, interruptions(lastNight.levels, (lastNight.end - lastNight.start) / 1000)),
      efficiency: sleepEfficiency(lastNight.asleepSeconds, lastNight.start, lastNight.end),
      stages: lastNight.stages ? stageBalance(lastNight.stages) : null,
      breathing: breathingDisturbances((input.spo2 ?? []).filter((p) => p.at >= lastNight.start && p.at <= lastNight.end)),
    },
    bedtimeSpread: spread,
    debt: sleepDebt(mainNights, need.baseline, now),
    chronotype: chronotype(mainNights.filter((n) => now - n.end < 28 * DAY), input.utcOffset),
    regularity: sleepRegularity([...nights, ...naps], now),
    naps: naps.filter((n) => now - n.start < 7 * DAY).sort((a, b) => b.start - a.start)
      .map((n) => ({ start: new Date(n.start).toISOString(), end: new Date(n.end).toISOString(), minutes: Math.round((n.end - n.start) / 60_000) })),
  };

  // MARK: Recovery (Whoop).
  const nightInputs = (n: InsightNight) => {
    const neededHours = needFor(n, null);
    return {
      hrv: n.hrv,
      restingHr: sleepingRestingHr(n.heartRate.filter((s) => s.at >= n.start && s.at <= n.end))?.bpm ?? n.dailyRestingHr,
      respiration: n.respiration,
      performance: sleepPerformance(n.asleepSeconds, neededHours),
      spo2: n.spo2,
    };
  };
  let recoveryResult: ReturnType<typeof recovery> = null;
  if (lastNight) {
    const baseline = mainNights.filter((n) => n.end < lastNight.end && lastNight.end - n.end < 30 * DAY).map(nightInputs);
    recoveryResult = recovery({ ...nightInputs(lastNight), performance: sleep.lastNight?.performance ?? null }, baseline);
  }

  // MARK: Readiness with contributors (Oura), and the health monitor.
  const lowestOf = (n: InsightNight) => sleepingRestingHr(n.heartRate.filter((s) => s.at >= n.start && s.at <= n.end))?.bpm ?? n.dailyRestingHr;
  const hrvNights = mainNights.filter((n) => n.hrv !== null).map((n) => ({ at: n.end, rmssd: n.hrv! }));
  const fortnight = mainNights.filter((n) => now - n.end < 14 * DAY);
  let readiness: ReturnType<typeof contributorReadiness> | null = null;
  let monitor: ReturnType<typeof healthMonitor> = null;
  if (lastNight) {
    const earlier = mainNights.filter((n) => n.end < lastNight.end);
    const usualLows = earlier.filter((n) => lastNight.end - n.end < 14 * DAY).map(lowestOf).filter((v): v is number => v !== null);
    readiness = contributorReadiness({
      lowestHr: lowestOf(lastNight),
      baselineLowestHr: usualLows.length >= 3 ? avg(usualLows) : null,
      hrvRecent: hrvNights.filter((n) => lastNight.end - n.at < 3 * DAY && n.at <= lastNight.end).map((n) => n.rmssd),
      hrvBaseline: hrvNights.filter((n) => lastNight.end - n.at >= 3 * DAY && lastNight.end - n.at < 33 * DAY).map((n) => n.rmssd),
      recoveryIndex: sleep.lastNight?.recoveryIndex?.score ?? null,
      sleepScore: lastNight.score,
      sleepAverageHours: fortnight.length >= 3 ? avg(fortnight.map((n) => n.asleepSeconds / 3600)) : null,
      needHours: need.baseline,
      yesterdayStrain: strainYesterday,
      loadRatio: input.load?.ratio ?? null,
    });
    const signs = (n: InsightNight) => ({ restingHr: lowestOf(n), hrv: n.hrv, respiration: n.respiration, spo2: n.spo2 });
    monitor = healthMonitor(signs(lastNight), earlier.filter((n) => lastNight.end - n.end < 28 * DAY).map(signs));
  }
  const health = { monitor, hrvStability: hrvStability(hrvNights, now) };

  // MARK: Stress and resilience (Oura), Body Battery from the watch.
  const stressDays = Array.from({ length: 14 }, (_, i) => today - (14 - i) * DAY).map((from) => {
    const points = input.stress.filter((p) => p.at >= from && p.at < from + DAY)
      .map((p) => ({ at: p.at, value: p.value, kind: exercising(p.at) ? "activity" : "stress" }));
    const day = daytimeStress(points, asleep, 5);
    return { restored: day.restoredMinutes, stressed: day.stressedMinutes };
  });
  const allDayEnd = Math.min(input.allDayEnd ?? now, now);
  // The 24 hours up to the newest reading, not since midnight: just after 12 am
  // that would be a few minutes.
  const todayPoints = input.stress.filter((p) => p.at > allDayEnd - DAY && p.at <= allDayEnd)
    .map((p) => ({ at: p.at, value: p.value, kind: exercising(p.at) ? "activity" : "stress" }));
  const latestStress = input.stress.length ? input.stress.reduce((a, b) => (b.at > a.at ? b : a)) : null;
  const latestBattery = input.bodyBattery.length ? input.bodyBattery.reduce((a, b) => (b.at > a.at ? b : a)) : null;
  const batteryDay = input.bodyBattery.filter((p) => allDayEnd - p.at < DAY && p.at <= allDayEnd).sort((a, b) => a.at - b.at);
  const stress = {
    now: latestStress && now - latestStress.at < 2 * 3600_000 ? Math.round(latestStress.value) : null,
    today: daytimeStress(todayPoints, asleep, 5),
    resilience: resilience(stressDays, nights.filter((n) => now - n.end < 14 * DAY && n.score !== null).map((n) => n.score!)),
    bodyBattery: latestBattery && now - latestBattery.at < 6 * 3600_000 ? {
      current: Math.round(latestBattery.value),
      high: Math.round(Math.max(...batteryDay.map((p) => p.value))),
      low: Math.round(Math.min(...batteryDay.map((p) => p.value))),
      series: batteryDay.map((p) => ({ at: new Date(p.at).toISOString(), value: Math.round(p.value) })),
    } : null,
  };

  // MARK: Training (Garmin, Apple).
  const last = activities[0] ?? null;
  const runs = activities.filter((a) => a.sport === "running");
  const latestEarly = runs.find((r) => r.earlyVo2max !== null) ?? null;
  const effortLoad = (from: number, days: number) => {
    const total = activities.filter((a) => a.start >= from && a.start < from + days * DAY && a.effort !== null)
      .reduce((s, a) => s + a.effort! * a.minutes, 0);
    return total / days;
  };
  const acuteEffort = effortLoad(today - 6 * DAY, 7);
  const chronicEffort = effortLoad(today - 27 * DAY, 28);
  const effortRatio = chronicEffort > 0 ? acuteEffort / chronicEffort : null;
  const impulses = activities.filter((a) => a.trimp !== null).map((a) => ({ at: a.start, load: a.trimp! }));
  const training = {
    lastWorkout: last && {
      sport: last.sport,
      at: new Date(last.start).toISOString(),
      minutes: Math.round(last.minutes),
      aerobic: last.aerobicEffect, aerobicLabel: effectLabel(last.aerobicEffect), watchAerobic: last.watchAerobic,
      anaerobic: last.anaerobicEffect, anaerobicLabel: effectLabel(last.anaerobicEffect), watchAnaerobic: last.watchAnaerobic,
      effort: last.effort,
      strain: last.strain, strainLevel: last.strain === null ? null : strainLevel(last.strain),
    },
    focus: loadFocus(activities.filter((a) => a.focus).map((a) => ({ at: a.start, focus: a.focus! })), now),
    lactateThreshold: profile ? lactateThreshold(
      activities.map((a) => ({ at: a.start, best20: a.best20Hr })),
      runs.filter((r) => now - r.start < 120 * DAY).flatMap((r) => r.steady),
      profile, now,
    ) : null,
    races: input.vo2max === null ? null : racePredictions(input.vo2max),
    endurance: enduranceScore(input.vo2max, activities.filter((a) => a.load !== null).map((a) => ({ at: a.start, minutes: a.minutes, load: a.load! })), now),
    hill: hillScore(activities.map((a) => ({ at: a.start, bestClimbRate: a.bestClimbRate, ascent: a.ascent })), now),
    performanceCondition: latestEarly && {
      value: performanceCondition(latestEarly.earlyVo2max, input.vo2max),
      at: new Date(latestEarly.start).toISOString(),
    },
    effortLoad: {
      week: Math.round(acuteEffort), month: Math.round(chronicEffort),
      trend: effortRatio === null ? null
        : effortRatio > 1.3 ? "well above" : effortRatio > 1.1 ? "above" : effortRatio >= 0.9 ? "steady" : effortRatio >= 0.7 ? "below" : "well below",
    },
    // Fitness, fatigue and form from every workout's training impulse.
    form: fitnessFatigueForm(impulses, now, input.utcOffset),
    monotony: monotony(impulses, now, input.utcOffset),
    status: input.load ? trainingStatus({
      vo2max: input.vo2maxHistory ?? [], ...input.load, hrvStatus: input.hrvStatus ?? null, lastWorkout: last?.start ?? null, now,
    }) : null,
    zones: {
      week: zoneDistribution(activities.filter((a) => now - a.start < 7 * DAY)),
      month: zoneDistribution(activities.filter((a) => now - a.start < 28 * DAY)),
    },
    zoneMinutes: profile ? (() => {
      const days = Array.from({ length: 7 }, (_, i) => {
        const from = today - (6 - i) * DAY;
        return { day: dayKey(from + DAY / 2), ...activeZoneMinutes(input.heartRate.filter((s) => s.at >= from && s.at < from + DAY), profile) };
      });
      return { today: days[6].minutes, week: days.reduce((a, d) => a + d.minutes, 0), goal: 150, days };
    })() : null,
    cardioRecovery: profile
      ? cardioRecovery(activities.map((a) => ({ at: a.start, recoveryHr: a.recoveryHr ?? null, endHr: a.endHr ?? null })), profile.maxHr, now)
      : null,
  };

  // MARK: Age and cardio fitness.
  const recentNights = mainNights.filter((n) => now - n.end < 14 * DAY);
  const weekHrv = avg(mainNights.filter((n) => now - n.end < 7 * DAY && n.hrv !== null).map((n) => n.hrv!));
  const month = activities.filter((a) => now - a.start < 28 * DAY);
  const activeMinutes = month.filter((a) => (a.aerobicEffect ?? 0) >= 1).reduce((s, a) => s + a.minutes, 0) / 4;
  const zoned = month.filter((a) => a.zones);
  const zoneMinutesAWeek = (from: number, to: number) => zoned.reduce((s, a) => s + a.zones!.slice(from, to).reduce((x, y) => x + y, 0), 0) / 60 / 4;
  const isStrength = (a: InsightActivity) => a.subSport === "strength_training" || (a.sport === "training" && !a.subSport);
  const stepDays = (input.days ?? []).filter((d) => d.steps !== null && d.steps > 0 && d.day !== dayKey(now)).map((d) => d.steps!);
  const age = profile?.age ?? null;
  const ageResult = age === null ? null : {
    age,
    cardioFitness: input.vo2max === null ? null : cardioFitness(input.vo2max, age, profile!.sex),
    hubAge: hubAge({
      age, sex: profile!.sex, vo2max: input.vo2max,
      restingHr: input.restingHr.length ? Math.round(avg(input.restingHr.slice(0, 7))!) : null,
      hrv: weekHrv,
      bedtimeSpread: spread,
      sleepHours: recentNights.length >= 3 ? avg(recentNights.map((n) => n.asleepSeconds / 3600)) : null,
      activeMinutes: month.length ? Math.round(activeMinutes) : null,
      steps: stepDays.length >= 5 ? Math.round(avg(stepDays)!) : null,
      easyMinutes: zoned.length ? Math.round(zoneMinutesAWeek(0, 3)) : null,
      hardMinutes: zoned.length ? Math.round(zoneMinutesAWeek(3, 5)) : null,
      // No workouts at all in 4 weeks is a real zero; no history at all isn't.
      strengthMinutes: activities.length ? Math.round(month.filter(isStrength).reduce((s, a) => s + a.minutes, 0) / 4) : null,
    }),
    // Needs a Hub Age from 90 days back, which needs 90 days of nights and runs.
    paceOfAging: null as number | null,
  };

  // MARK: Vitals (Apple).
  const nightVitals = (n: InsightNight) => ({
    heartRate: n.heartRate.length ? Math.round(avg(n.heartRate.filter((s) => s.at >= n.start && s.at <= n.end).map((s) => s.bpm)) ?? 0) || null : null,
    hrv: n.hrv === null ? null : Math.round(n.hrv),
    respiration: n.respiration === null ? null : round1(n.respiration),
    spo2: n.spo2 === null ? null : Math.round(n.spo2),
    sleepHours: round1(n.asleepSeconds / 3600),
  });
  const vitalsResult = lastNight
    ? vitals(nightVitals(lastNight), mainNights.filter((n) => n.end < lastNight.end && lastNight.end - n.end < 30 * DAY).map(nightVitals))
    : null;

  return {
    strain: profile ? {
      today: strainToday, level: strainToday === null ? null : strainLevel(strainToday), week: strainWeek,
      target: strainTarget(recoveryResult && recoveryResult.status === "ready" ? recoveryResult.score : null, strainToday),
    } : null,
    readiness,
    health,
    recovery: recoveryResult as (Exclude<ReturnType<typeof recovery>, Calibrating | null> | Calibrating | null),
    sleep,
    stress,
    training,
    age: ageResult,
    vitals: vitalsResult,
  };
}

export type Insights = ReturnType<typeof buildInsights>;
