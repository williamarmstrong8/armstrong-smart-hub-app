// ---------------------------------------------------------------------------
// Glue for the phone (LocalFitness.swift): the parts of the hub's
// lib/fitness/store.ts and checkins.ts that aren't SQL, copied as closely as
// possible so the numbers match what the hub showed. Swift runs the queries
// (same columns and aliases as the hub's) and passes the rows in as JSON;
// every function here takes one JSON string and returns one.
//
// Times arrive either as ISO strings or as epoch milliseconds (the high-volume
// tables store milliseconds); `ms` and `iso` accept both.
// ---------------------------------------------------------------------------
(function () {
  const { decodeFit, isFit, isPartialFit, FitError } = __require("fit");
  const { summarize, inspect } = __require("summarize");
  const { buildMetrics, preferWatch } = __require("metrics");
  const { buildInsights } = __require("insight-metrics");
  const { sleepScore } = __require("physiology");
  const { buildWatchSnapshot } = __require("watch-snapshot");
  const { buildWatchSettings } = __require("watch-settings");
  const {
    allInputs, energyDrivers, fitEnergy, fitState, guessDay, pastStretches, personalWeight, STATE_LABELS, STATES,
  } = __require("checkin-engine");

  const DAY = 86_400_000;
  const ms = (v) => (typeof v === "number" ? v : Date.parse(v));
  const iso = (v) => (v === null || v === undefined ? null : typeof v === "number" ? new Date(v).toISOString() : v);
  const num = (v) => (v === null || v === undefined || v === "" ? null : Number.isFinite(Number(v)) ? Number(v) : null);
  const text = (v) => (v === null || v === undefined ? null : String(v));

  // MARK: Files

  /** Is this a FIT file (whole, or one the watch is still writing)? Takes a Uint8Array. */
  function isValid(bytes) {
    return isFit(bytes) || isPartialFit(bytes);
  }

  /** One file from the watch, summarized; readings come back as compact rows with epoch milliseconds. */
  function parseFile(bytes, utcOffset) {
    if (!isValid(bytes)) return JSON.stringify({ error: "not a valid FIT file (header, length or CRC)", invalid: true });
    try {
      const s = summarize(decodeFit(bytes, { partial: true }), utcOffset);
      // One row per kind and moment: a file can repeat a record.
      const watch = [...new Map(s.watch.map((w) => [`${w.kind}|${w.at}`, w])).values()];
      return JSON.stringify({
        activity: s.activity, daily: s.daily, sleep: s.sleep, hrv: s.hrv,
        heartRate: s.heartRate.map((h) => [Date.parse(h.at), h.bpm]),
        vitals: s.vitals.map((v) => [v.kind, Date.parse(v.at), v.value]),
        watch: watch.map((w) => [w.kind, Date.parse(w.at), w.data]),
      });
    } catch (error) {
      return JSON.stringify({ error: error instanceof FitError ? error.message : "couldn't read the file" });
    }
  }

  /** The file's messages laid out by number, for the Inspect screen. */
  function inspectFile(bytes) {
    try {
      return JSON.stringify({ messages: inspect(decodeFit(bytes, { partial: true })) });
    } catch (error) {
      return JSON.stringify({ error: error instanceof Error ? error.message : "unreadable" });
    }
  }

  // MARK: Snapshot (store.ts fitnessSnapshot, fitnessMetrics, fitnessInsights, fitnessActivity)

  /** ACTIVITY_FIELDS: the stored columns plus what store.ts read out of `metrics`. */
  function activityFields(row) {
    const { metrics: m, heartRate, ...rest } = row;
    return {
      ...rest,
      load: num(m?.load), vo2max: num(m?.vo2max),
      watchLoad: num(m?.watch?.load), anaerobicEffect: num(m?.watch?.anaerobicEffect),
      primaryBenefit: text(m?.extras?.primaryBenefit),
    };
  }

  function activity(json) {
    const row = JSON.parse(json);
    const m = row.metrics;
    return JSON.stringify({
      ...activityFields(row),
      heartRate: row.heartRate ?? [],
      extras: m?.extras ?? null,
      recoveryHours: num(m?.watch?.recoveryHours),
    });
  }

  function fitnessMetrics(M, now, allDayEnd) {
    return buildMetrics({
      now,
      allDayEnd,
      activities: M.activities.map((a) => ({
        // The watch's own session load when it wrote one; the hub's EPOC model otherwise.
        start: ms(a.start), elapsedSeconds: a.elapsed, load: a.metrics?.watch?.load ?? a.metrics?.load ?? null,
        vo2max: a.metrics?.vo2max ?? null, vo2maxMinutes: a.metrics?.vo2maxMinutes ?? null,
        watchVo2max: a.metrics?.watch?.vo2max ?? null, profile: a.metrics?.profile ?? null,
      })),
      restingHr: M.rest.map((r) => r.resting_hr),
      heartRate: M.heartRate.map((h) => ({ at: ms(h.at), bpm: h.bpm })),
      nights: M.nights.map((n) => ({
        start: ms(n.start), end: ms(n.end), deep: n.deep ?? 0, light: n.light ?? 0, rem: n.rem ?? 0, awake: n.awake ?? 0,
        score: n.score,
      })),
      hrv: M.vitals.filter((v) => v.kind === "hrv").map((v) => ({ at: ms(v.at), value: v.value })),
      vitals: M.vitals.map((v) => ({ kind: v.kind, at: ms(v.at), value: v.value })),
    });
  }

  /** Age, height and weight from the newest activity whose profile has them. */
  function pickAge(activities) {
    const profile = activities.find((a) => a.metrics?.profile?.age != null)?.metrics?.profile;
    return profile ? { age: profile.age ?? null, heightCm: profile.heightCm ?? null, weightKg: profile.weightKg ?? null } : {};
  }

  function fitnessInsights(N, metrics, now, allDayEnd, extra) {
    const hrByNight = new Map();
    for (const row of N.nightHr) {
      const list = hrByNight.get(row.id) ?? [];
      list.push({ at: ms(row.at), bpm: row.bpm });
      hrByNight.set(row.id, list);
    }
    const nights = N.nights.map((n) => {
      const stages = { deep: n.deep ?? 0, light: n.light ?? 0, rem: n.rem ?? 0, awake: n.awake ?? 0 };
      return {
        start: ms(n.start), end: ms(n.end),
        asleepSeconds: stages.deep + stages.light + stages.rem,
        levels: n.levels ?? [],
        score: n.score ?? sleepScore({ start: 0, end: 0, ...stages, stress: n.stress }),
        hrv: n.hrv, respiration: n.respiration, spo2: n.spo2,
        heartRate: hrByNight.get(n.id) ?? [],
        dailyRestingHr: n.resting,
        stages,
      };
    });
    return buildInsights({
      now,
      allDayEnd,
      utcOffset: N.activities.find((a) => a.offset !== null)?.offset ?? 0,
      profile: metrics.profile && { ...metrics.profile, ...pickAge(N.activities) },
      vo2max: metrics.vo2max?.value ?? null,
      activities: N.activities.map((a) => {
        const m = a.metrics;
        const start = ms(a.start);
        return {
          start, end: start + (a.elapsed ?? 0) * 1000, sport: a.sport, minutes: (a.elapsed ?? 0) / 60,
          load: m?.load ?? null, trimp: m?.trimp ?? null, strain: m?.strain ?? null,
          aerobicEffect: m?.aerobicEffect ?? null, anaerobicEffect: m?.anaerobicEffect ?? null,
          watchAerobic: m?.watch?.trainingEffect ?? null, watchAnaerobic: m?.watch?.anaerobicEffect ?? null,
          effort: m?.effort ?? null, focus: m?.focus ?? null, best20Hr: m?.best20Hr ?? null,
          bestClimbRate: m?.bestClimbRate ?? null, ascent: a.ascent, earlyVo2max: m?.earlyVo2max ?? null, steady: m?.steady ?? [],
          subSport: a.subSport, zones: m?.zones ?? null, recoveryHr: m?.extras?.session?.recoveryHr ?? null, endHr: a.endHr,
        };
      }),
      heartRate: N.heartRate.map((h) => ({ at: ms(h.at), bpm: h.bpm })),
      nights,
      stress: N.buckets.filter((b) => b.kind === "stress").map((b) => ({ at: ms(b.at), value: b.value })),
      bodyBattery: N.buckets.filter((b) => b.kind === "body_battery").map((b) => ({ at: ms(b.at), value: b.value })),
      restingHr: N.rest.map((r) => r.resting_hr),
      days: N.days,
      spo2: N.spo2.map((p) => ({ at: ms(p.at), value: p.value })),
      // The watch keeps a nap it has since deleted, flagged; times are Unix seconds.
      naps: N.naps.filter((n) => n.data.deleted !== 1 && n.data.start && n.data.end)
        .map((n) => ({ start: n.data.start * 1000, end: n.data.end * 1000 })),
      load: { acute: metrics.load.acute, chronic: metrics.load.chronic, ratio: metrics.load.ratio },
      hrvStatus: extra.hrvStatus,
      vo2maxHistory: extra.vo2max.map((p) => ({ at: ms(p.at), value: p.value })),
    });
  }

  function snapshot(json) {
    const I = JSON.parse(json);
    const now = I.now;
    const through = I.through ?? null;
    // The last 24 hours of all-day data end at the newest reading, not now.
    const allDayEnd = through !== null ? Math.min(through, now) : now;
    const watch = buildWatchSnapshot(I.watchRows.map((r) => ({ kind: r.kind, at: iso(r.at), data: r.data })), now);
    const series = (kind) => I.recent.filter((r) => r.kind === kind).map((r) => ({ at: ms(r.at), value: r.value }));
    const metrics = preferWatch(fitnessMetrics(I.metricsInput, now, allDayEnd), watch,
      { stress: series("stress"), bodyBattery: series("body_battery") }, allDayEnd);
    const hrv = I.hrv;
    const hrvStatus = hrv[0] && now - Date.parse(hrv[0].day) < 3 * DAY && hrv[0].status && hrv[0].status !== "none"
      ? hrv[0].status : metrics.hrv.status === "building" ? null : metrics.hrv.status;
    const insights = fitnessInsights(I.insightsInput, metrics, now, allDayEnd, { hrvStatus, vo2max: watch.vo2max?.history ?? [] });
    const sleep = I.sleep.map(({ stress, ...night }) => ({
      ...night,
      score: night.watchScore ?? sleepScore({
        start: 0, end: 0, deep: night.deepSeconds ?? 0, light: night.lightSeconds ?? 0, rem: night.remSeconds ?? 0,
        awake: night.awakeSeconds ?? 0, stress,
      }),
    }));
    return JSON.stringify({
      days: I.days, hrv, heartRateTrend: I.heartRateTrend, activities: I.activities.map(activityFields), sleep,
      heartRate: I.heartRate.map((h) => ({ at: iso(h.at), bpm: h.bpm })), files: I.files, metrics, insights, watch,
      allDayThrough: iso(through),
      // The written daily summary needed the AI on the hub; the page no longer shows it.
      summary: null, summaryWriting: false,
    });
  }

  function watchSettings(json) {
    const I = JSON.parse(json);
    return JSON.stringify(buildWatchSettings({ now: I.now, sleep: I.sleep, hrv: I.hrv, metrics: fitnessMetrics(I.metricsInput, I.now, I.now) }));
  }

  // MARK: Check-ins (checkins.ts)

  const VOCABULARY = {
    states: STATES.map((key) => ({ key, label: STATE_LABELS[key] })),
    causes: [
      { key: "alcohol", label: "Drinks" }, { key: "late_night", label: "Late night" }, { key: "poor_sleep", label: "Bad sleep" },
      { key: "caffeine_late", label: "Late caffeine" }, { key: "late_meal", label: "Late meal" }, { key: "travel", label: "Travel" },
      { key: "worked_late", label: "Worked late" }, { key: "sore", label: "Sore" },
    ],
    symptoms: [
      { key: "sore_throat", label: "Sore throat" }, { key: "congestion", label: "Congestion" }, { key: "fever", label: "Fever" },
      { key: "headache", label: "Headache" }, { key: "body_aches", label: "Body aches" }, { key: "stomach", label: "Stomach" },
      { key: "fatigue", label: "Fatigue" },
    ],
  };

  /** 23.5 for 11:30 pm, 25 for 1 am: the local hour counted past midnight so bedtimes average sensibly. */
  function bedtimeHour(localMs) {
    const d = new Date(localMs);
    const h = d.getUTCHours() + d.getUTCMinutes() / 60;
    return h < 15 ? h + 24 : h;
  }

  const shiftDay = (day, by) => new Date(Date.parse(`${day}T00:00:00Z`) + by * DAY).toISOString().slice(0, 10);
  const finite = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

  /** Every day there's data for, oldest first (checkins.ts dayFeatures, after its queries). */
  function dayFeatures(D) {
    const drinks = new Map(Object.entries(D.drinks ?? {}));
    const byDay = new Map();
    const get = (day) => {
      let d = byDay.get(day);
      if (!d) {
        d = {
          day, restingHr: null, hrv: null, sleepHours: null, sleepScore: null, bedtime: null, sleepHr: null, respiration: null,
          sleepStress: null, bodyBatteryWake: null, readiness: null, spo2: null, dayStress: null, load: null,
        };
        byDay.set(day, d);
      }
      return d;
    };
    /** Sets a field only when nothing earlier (Connect) already did. */
    const fill = (d, key, value) => {
      if (d[key] === null && value !== null && value !== undefined && Number.isFinite(value)) d[key] = value;
    };

    const connectStress = new Map();
    for (const row of D.connect) {
      const d = get(row.day);
      const s = row.data.summary ?? {};
      const sl = row.data.sleep ?? {};
      fill(d, "restingHr", finite(sl.restingHeartRate) ?? finite(s.restingHeartRate));
      fill(d, "hrv", finite(row.data.hrv?.lastNightAvg) ?? finite(sl.avgOvernightHrv));
      const asleep = finite(sl.sleepTimeSeconds);
      fill(d, "sleepHours", asleep ? asleep / 3600 : null);
      fill(d, "sleepScore", finite(sl.score));
      const start = finite(sl.sleepStartTimestampLocal);
      fill(d, "bedtime", start ? bedtimeHour(start) : null);
      fill(d, "sleepHr", finite(sl.avgHeartRate));
      fill(d, "respiration", finite(sl.averageRespirationValue));
      fill(d, "sleepStress", finite(sl.avgSleepStress));
      fill(d, "bodyBatteryWake", finite(s.bodyBatteryAtWakeTime));
      fill(d, "readiness", finite(row.data.readiness?.score));
      fill(d, "spo2", finite(sl.averageSpO2Value) ?? finite(s.averageSpo2));
      const avgStress = finite(s.averageStressLevel);
      if (avgStress !== null && avgStress >= 0) connectStress.set(row.day, avgStress);
    }
    for (const n of D.nights) {
      if (!n.asleep) continue;
      const d = get(n.day);
      fill(d, "sleepHours", n.asleep / 3600);
      fill(d, "sleepScore", n.score);
      fill(d, "bedtime", bedtimeHour(Date.parse(`${n.startLocal.slice(0, 19)}Z`)));
      fill(d, "sleepHr", n.hr);
      fill(d, "respiration", n.resp);
      fill(d, "sleepStress", n.stress);
      fill(d, "spo2", n.spo2);
      fill(d, "bodyBatteryWake", n.battery);
    }
    for (const h of D.hrv) fill(get(h.day), "hrv", h.value);
    for (const r of D.daily) if (byDay.has(r.day)) fill(get(r.day), "restingHr", r.restingHr);
    for (const r of D.readiness) if (byDay.has(r.day)) fill(get(r.day), "readiness", r.score);
    // Yesterday's stress and load belong to today's morning.
    const watchStress = new Map(D.stress.map((s) => [s.day, s.value]));
    const loadByDay = new Map(D.loads.map((l) => [l.day, l.load]));
    for (const d of byDay.values()) {
      const prev = shiftDay(d.day, -1);
      fill(d, "dayStress", connectStress.get(prev) ?? watchStress.get(prev) ?? null);
      d.load = loadByDay.get(prev) ?? 0;
      d.drinks = drinks.has(d.day) ? drinks.get(d.day) : null;
      d.drankUnknown = drinks.has(d.day) && drinks.get(d.day) === null;
    }
    return [...byDay.values()].sort((a, b) => a.day.localeCompare(b.day));
  }

  const isState = (t) => STATES.includes(t);

  function fitModels(days, entries) {
    const inputsByDay = allInputs(days);
    const labelled = entries.flatMap((c) => {
      const x = inputsByDay.get(c.day);
      if (!x) return [];
      return [{ inputs: x, states: c.tags.filter(isState), rejected: c.rejected.filter(isState), energy: c.energy }];
    });
    const models = {
      states: Object.fromEntries(STATES.map((s) => [s, fitState(s, labelled)])),
      energy: fitEnergy(labelled),
    };
    return { inputsByDay, labelled, models };
  }

  /** What each check-in said, by day, so yesterday's answer carries into today's guess. */
  function history(entries) {
    return new Map(entries.map((c) => [c.day, { states: c.tags.filter(isState), rejected: c.rejected.filter(isState) }]));
  }

  function checkinPage(json) {
    const { dayInput, entries, skips, day } = JSON.parse(json);
    const days = dayFeatures(dayInput);
    const skipped = new Map();
    for (const r of skips) skipped.set(r.state, (skipped.get(r.state) ?? new Set()).add(r.day));
    const { inputsByDay, labelled, models } = fitModels(days, entries);
    const answered = new Set(entries.map((c) => c.day));
    answered.add(day);
    // Answered days, and days already skipped for this state, aren't asked about again.
    const asked = (state) => new Set([...answered, ...(skipped.get(state) ?? [])]);
    // Only being sick, only the last month, never the last few days, at most three at a time.
    const past = new Map([...inputsByDay].filter(([d]) => d < shiftDay(day, -3) && d >= shiftDay(day, -30)));
    const suggestions = pastStretches(past, asked("sick"), "sick", 0.5, models.states, 3);
    return JSON.stringify({
      day,
      guess: guessDay(days, day, models, history(entries)),
      entry: entries.find((c) => c.day === day) ?? null,
      recent: entries.filter((c) => c.day <= day && c.day > shiftDay(day, -14)),
      suggestions,
      learning: {
        labelledDays: labelled.length,
        daysOfData: days.filter((d) => d.hrv !== null || d.restingHr !== null).length,
        states: STATES.map((state) => ({
          state, label: STATE_LABELS[state],
          yes: labelled.filter((l) => l.states.includes(state)).length,
          no: labelled.filter((l) => !l.states.includes(state)).length,
          personal: Math.round(personalWeight(models.states[state] ?? null) * 100) / 100,
        })),
        energy: {
          ratings: labelled.filter((l) => l.energy !== null).length,
          error: models.energy ? Math.round(models.energy.error * 100) / 100 : null,
          drivers: energyDrivers(models.energy),
        },
      },
      vocabulary: VOCABULARY,
    });
  }

  /** Training Effect 1–5 as a 1–10 effort: 1 is barely anything, 3 a solid session, 5 everything. */
  function effortFromTrainingEffect(aerobic, anaerobic) {
    if (aerobic === null) return null;
    const te = Math.max(aerobic, (anaerobic ?? 0) * 0.9);
    return Math.max(1, Math.min(10, Math.round(te * 2)));
  }

  /** What a session probably felt like, before the person says, with the reasons shown. */
  function sessionGuess(json) {
    const { kind, row, utcOffset, dayInput, entries } = JSON.parse(json);
    const reasons = [];
    let effort = null;
    let start = null;
    if (row && kind === "activity") {
      start = row.start;
      effort = effortFromTrainingEffect(row.te, row.anaerobic);
      if (row.te !== null) reasons.push(`Training Effect ${row.te.toFixed(1)}${row.anaerobic ? ` aerobic, ${row.anaerobic.toFixed(1)} anaerobic` : ""}`);
    } else if (row) {
      start = row.start;
      if (row.rpe !== null) {
        effort = Math.round(row.rpe);
        reasons.push(`Average set RPE ${row.rpe.toFixed(1)} over ${row.sets} sets`);
      }
    }
    let feel = null;
    if (start) {
      // How the session felt starts from how the morning looked.
      const day = new Date(Date.parse(start) + utcOffset * 1000).toISOString().slice(0, 10);
      const entry = entries.find((c) => c.day === day);
      if (entry?.energy) {
        feel = entry.energy;
        reasons.push(`You rated your energy ${entry.energy}/5 that morning`);
      } else {
        const days = dayFeatures(dayInput);
        const guess = guessDay(days, day, fitModels(days, entries).models, history(entries));
        if (guess) {
          feel = Math.round(guess.energy);
          const top = guess.metrics[0];
          reasons.push(top ? `Morning ${top.label.toLowerCase()} ${top.value} (usual ${top.usual})` : "From this morning's numbers");
        }
      }
    }
    return JSON.stringify({ feel, effort, reasons });
  }

  globalThis.Fitness = { isValid, parseFile, inspectFile, snapshot, activity, watchSettings, checkinPage, sessionGuess };
})();
