import Foundation

/// The local database's tables: the hub's Postgres schema (lib/db.ts) without
/// `user_id`, since everything on the phone belongs to its owner. Times are ISO
/// text, json columns are text, booleans are 0/1.
///
/// Each entry in `steps` runs once, in order, tracked by `pragma user_version`.
/// Add new steps at the end; never edit one that has shipped.
nonisolated enum LocalSchema {
    static let steps: [String] = [
        // 1: to-dos, habits, drinks, workouts.
        """
        create table if not exists todos (
          id text primary key, text text not null, done integer not null default 0,
          done_at text, created_at text not null
        );
        create table if not exists habits (
          id text primary key, name text not null, color text not null, icon text,
          position integer not null default 0, archived integer not null default 0, created_at text not null
        );
        create table if not exists habit_completions (
          habit_id text not null references habits (id) on delete cascade, date text not null,
          primary key (habit_id, date)
        );
        create table if not exists fitness_drinks (
          id text primary key, night text not null, at text not null, kind text not null,
          count integer not null, time_of_day text, logged_at text, updated_at text not null
        );
        create index if not exists fitness_drinks_night on fitness_drinks (night);
        create table if not exists fitness_dry_nights (night text primary key);
        create table if not exists fitness_drank_nights (night text primary key);
        create table if not exists workout_exercises (
          id text primary key, name text not null, muscle text not null, equipment text not null,
          kind text not null default 'weight_reps', archived integer not null default 0, created_at text not null
        );
        create table if not exists workout_routines (
          id text primary key, name text not null, exercises text not null default '[]',
          position integer not null default 0, updated_at text not null
        );
        create table if not exists workouts (
          id text primary key, name text not null, routine_id text, started_at text not null, ended_at text not null,
          notes text, hr_series text not null default '[]', place text, updated_at text not null
        );
        create index if not exists workouts_started on workouts (started_at desc);
        create table if not exists workout_sets (
          workout_id text not null references workouts (id) on delete cascade,
          exercise_order integer not null, set_order integer not null,
          exercise_id text not null, exercise_name text not null, superset integer,
          kind text not null default 'normal', weight_kg real, reps integer, duration_s real, rpe real,
          completed_at text, started_at text, live_hr integer,
          primary key (workout_id, exercise_order, set_order)
        );
        create index if not exists workout_sets_exercise on workout_sets (exercise_id);
        """,
        // 2: fitness from the watch. Raw files aren't kept: `fitness_files` only remembers what was
        // read. Readings that come by the minute store `at` as epoch milliseconds, to stay small.
        """
        create table if not exists fitness_files (
          file_id text primary key, kind text not null, size integer not null, recorded_at text,
          sha256 text not null, received_at text not null, parsed_at text, parse_error text
        );
        create table if not exists fitness_activities (
          file_id text primary key, sport text not null, sub_sport text, start_time text not null, start_ms integer not null,
          utc_offset integer, elapsed_s real, moving_s real, distance_m real, calories integer, avg_hr integer, max_hr integer,
          ascent_m real, avg_speed real, training_effect real, hr_series text not null default '[]', metrics text
        );
        create index if not exists fitness_activities_start on fitness_activities (start_ms desc);
        create table if not exists fitness_daily (
          day text primary key, steps integer, step_goal integer, resting_hr integer, distance_m integer,
          active_kcal integer, resting_kcal integer, active_s integer, ascent_m real, descent_m real,
          moderate_min integer, vigorous_min integer, updated_at text not null
        );
        create table if not exists fitness_heart_rate (at integer primary key, bpm integer not null);
        create table if not exists fitness_sleep (
          file_id text primary key, start_time text not null, end_time text not null, start_ms integer not null, end_ms integer not null,
          deep_s integer, light_s integer, rem_s integer, awake_s integer, score integer, levels text not null default '[]'
        );
        create index if not exists fitness_sleep_end on fitness_sleep (end_ms desc);
        create table if not exists fitness_hrv (
          file_id text primary key, day text not null, weekly_avg real, last_night_avg real, last_night_high real,
          baseline_low_upper real, baseline_balanced_lower real, baseline_balanced_upper real, status text,
          readings text not null default '[]'
        );
        create index if not exists fitness_hrv_day on fitness_hrv (day desc);
        create table if not exists fitness_vitals (
          kind text not null, at integer not null, value real not null, primary key (kind, at)
        ) without rowid;
        create table if not exists fitness_watch_metrics (
          kind text not null, at integer not null, data text not null, primary key (kind, at)
        ) without rowid;
        create table if not exists fitness_connect_daily (day text primary key, data text not null);
        create table if not exists fitness_checkins (
          day text primary key, energy integer, mood integer, soreness integer,
          tags text not null default '[]', rejected text not null default '[]', note text, guess text,
          created_at text not null, updated_at text not null
        );
        create table if not exists fitness_checkin_skips (state text not null, day text not null, primary key (state, day));
        create table if not exists fitness_session_feedback (
          kind text not null, ref_id text not null, feel integer, effort integer, vs_expected integer,
          tags text not null default '[]', note text, guess text, updated_at text not null,
          primary key (kind, ref_id)
        );
        """,
    ]

    static func migrate(_ db: LocalDB) {
        let current = (db.one("pragma user_version")?["user_version"] as? Int) ?? 0
        guard current < steps.count else { return }
        for (index, sql) in steps.enumerated() where index >= current {
            db.exec("begin immediate")
            db.exec(sql)
            db.exec("pragma user_version = \(index + 1)")
            db.exec("commit")
        }
    }
}
