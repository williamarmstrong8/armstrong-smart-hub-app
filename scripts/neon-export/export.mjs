// One-time export of the old hub database (Neon) into the shapes the phone and the
// Pi use now. Run on the Mac once Neon answers queries again:
//
//   cd scripts/neon-export && npm install && DATABASE_URL='postgres://…neon.tech/…' node export.mjs
//
// Writes out/import.json (every table, shaped like the phone's SQLite tables; the
// phone imports it once from the Pi's /api/mobile/import) and out/pi/ (the app list
// and watch faces the Pi keeps in its data folder). Copy both with ./upload.sh.
import { mkdirSync, writeFileSync } from "node:fs";
import pg from "pg";

const url = process.env.DATABASE_URL;
if (!url) throw new Error("Set DATABASE_URL to the Neon connection string (it's in the hub's .env.local).");

// Dates and numerics come back as text, exactly as stored.
pg.types.setTypeParser(1082, (v) => v); // date
pg.types.setTypeParser(1700, (v) => v); // numeric
const client = new pg.Client({ connectionString: url, ssl: /sslmode=disable/.test(url) ? false : { rejectUnauthorized: false } });
await client.connect();

const iso = (col) => `to_char(${col} at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')`;
const ms = (col) => `(extract(epoch from ${col}) * 1000)::bigint`;
const day = (col) => `to_char(${col}, 'YYYY-MM-DD')`;

/** Phone table → the SELECT that produces its columns, in order. */
const TABLES = {
  todos: `select id::text as id, text, done, ${iso("done_at")} as done_at, ${iso("created_at")} as created_at from todos`,
  habits: `select id::text as id, name, color, icon, position, archived, ${iso("created_at")} as created_at from habits`,
  habit_completions: `select habit_id::text as habit_id, ${day("date")} as date from habit_completions`,
  fitness_drinks: `select id::text as id, ${day("night")} as night, ${iso("at")} as at, kind, count, time_of_day, ${iso("logged_at")} as logged_at, ${iso("updated_at")} as updated_at from fitness_drinks`,
  fitness_dry_nights: `select ${day("night")} as night from fitness_dry_nights`,
  fitness_drank_nights: `select ${day("night")} as night from fitness_drank_nights`,
  workout_exercises: `select id::text as id, name, muscle, equipment, kind, archived, ${iso("created_at")} as created_at from workout_exercises`,
  workout_routines: `select id::text as id, name, exercises, position, ${iso("updated_at")} as updated_at from workout_routines`,
  workouts: `select id::text as id, name, routine_id::text as routine_id, ${iso("started_at")} as started_at, ${iso("ended_at")} as ended_at, notes, hr_series, place, ${iso("updated_at")} as updated_at from workouts`,
  workout_sets: `select workout_id::text as workout_id, exercise_order, set_order, exercise_id, exercise_name, superset, kind, weight_kg, reps, duration_s, rpe, ${iso("completed_at")} as completed_at, ${iso("started_at")} as started_at, live_hr from workout_sets`,
  fitness_files: `select file_id, kind, size, ${iso("recorded_at")} as recorded_at, sha256, ${iso("received_at")} as received_at, ${iso("parsed_at")} as parsed_at, parse_error from fitness_files`,
  fitness_activities: `select file_id, sport, sub_sport, ${iso("start_time")} as start_time, ${ms("start_time")} as start_ms, utc_offset, elapsed_s, moving_s, distance_m, calories, avg_hr, max_hr, ascent_m, avg_speed, training_effect, hr_series, metrics from fitness_activities`,
  fitness_daily: `select ${day("day")} as day, steps, step_goal, resting_hr, distance_m, active_kcal, resting_kcal, active_s, ascent_m, descent_m, moderate_min, vigorous_min, ${iso("updated_at")} as updated_at from fitness_daily`,
  fitness_heart_rate: `select ${ms("at")} as at, bpm from fitness_heart_rate`,
  fitness_sleep: `select file_id, ${iso("start_time")} as start_time, ${iso("end_time")} as end_time, ${ms("start_time")} as start_ms, ${ms("end_time")} as end_ms, deep_s, light_s, rem_s, awake_s, score, levels from fitness_sleep`,
  fitness_hrv: `select file_id, ${day("day")} as day, weekly_avg, last_night_avg, last_night_high, baseline_low_upper, baseline_balanced_lower, baseline_balanced_upper, status, readings from fitness_hrv`,
  fitness_vitals: `select kind, ${ms("at")} as at, value from fitness_vitals`,
  fitness_watch_metrics: `select kind, ${ms("at")} as at, data from fitness_watch_metrics`,
  fitness_connect_daily: `select ${day("day")} as day, data from fitness_connect_daily`,
  fitness_checkins: `select ${day("day")} as day, energy, mood, soreness, to_jsonb(tags) as tags, to_jsonb(rejected) as rejected, note, guess, ${iso("created_at")} as created_at, ${iso("updated_at")} as updated_at from fitness_checkins`,
  fitness_checkin_skips: `select state, ${day("day")} as day from fitness_checkin_skips`,
  fitness_session_feedback: `select kind, ref_id, feel, effort, vs_expected, to_jsonb(tags) as tags, note, guess, ${iso("updated_at")} as updated_at from fitness_session_feedback`,
  fitness_merchant_drinks: `select merchant, yes, no, ${iso("updated_at")} as updated_at from fitness_merchant_drinks`,
  accounts: `select id, name, institution, currency, balance::text as balance, available_balance::text as available_balance, ${iso("balance_date")} as balance_date, raw, ${iso("updated_at")} as updated_at from accounts`,
  transactions: `select id, account_id, ${iso("posted")} as posted, amount::text as amount, description, payee, memo, pending, raw, ${iso("created_at")} as created_at, ${iso("updated_at")} as updated_at from transactions`,
  category_overrides: `select transaction_id, category, ${iso("updated_at")} as updated_at from category_overrides`,
  custom_categories: `select name from custom_categories`,
  recurring_ignored: `select id from recurring_ignored`,
  app_settings: `select key, value from app_settings where key = 'net_worth_goal'`,
  net_worth_snapshots: `select ${day("day")} as day, value::text as value, ${iso("updated_at")} as updated_at from net_worth_snapshots`,
  holding_snapshots: `select ${day("day")} as day, account_id, symbol, shares::text as shares, market_value::text as market_value, cost_basis::text as cost_basis, ${iso("updated_at")} as updated_at from holding_snapshots`,
  // The last good sync, so the phone's next one only fills the gap.
  sync_runs: `select ${iso("started_at")} as started_at, ${iso("finished_at")} as finished_at, trigger, mode, ${iso("window_start")} as window_start, status, accounts_synced, transactions_upserted, notices from sync_runs where status = 'success' order by finished_at desc limit 1`,
  voice_log: `select heard, reply, ${iso("created_at")} as created_at from voice_log`,
  voice_memories: `select id::text as id, text, ${iso("updated_at")} as updated_at from voice_memories`,
  home_visible: `select entity_id from home_visible_entities`,
};

const tables = {};
for (const [name, sql] of Object.entries(TABLES)) {
  try {
    const result = await client.query({ text: sql, rowMode: "array" });
    tables[name] = { columns: result.fields.map((f) => f.name), rows: result.rows.map((r) => r.map((v) => (typeof v === "bigint" ? Number(v) : v))) };
    console.log(`${name}: ${result.rowCount}`);
  } catch (error) {
    console.log(`${name}: skipped (${error.message.split("\n")[0]})`);
  }
}
// bigint comes back as text from pg; the millisecond columns are numbers on the phone.
for (const t of Object.values(tables)) {
  t.columns.forEach((c, i) => {
    if (["at", "start_ms", "end_ms"].includes(c)) for (const r of t.rows) r[i] = r[i] === null ? null : Number(r[i]);
  });
}
// Home's picked devices only count once some were picked.
if (tables.home_visible?.rows.length) tables.settings = { columns: ["key", "value"], rows: [["home_visible_set", "1"]] };

mkdirSync("out/pi/watch-faces", { recursive: true });
writeFileSync("out/import.json", JSON.stringify({ version: 1, exportedAt: new Date().toISOString(), tables }));

// What the Pi keeps itself: the app list for Jarvis's app changes, and the watch faces.
const apps = await client.query(`select key, name, description, template, ${iso("created_at")} as "createdAt" from dev_apps`).catch(() => ({ rows: [] }));
const templates = await client.query(`select templates from dev_runner where id = 1`).catch(() => ({ rows: [] }));
writeFileSync("out/pi/dev.json", JSON.stringify({ apps: apps.rows, jobs: [], runner: { seenAt: null, templates: templates.rows[0]?.templates ?? null } }));
const faces = await client.query(`select id, name, version, size, sha256, ${iso("updated_at")} as "updatedAt", data from watch_faces`).catch(() => ({ rows: [] }));
for (const f of faces.rows) writeFileSync(`out/pi/watch-faces/${f.id}.prg`, f.data);
writeFileSync("out/pi/watch-faces.json", JSON.stringify({ faces: faces.rows.map(({ data: _d, ...info }) => info) }));
console.log(`apps: ${apps.rows.length}, watch faces: ${faces.rows.length}`);
await client.end();
