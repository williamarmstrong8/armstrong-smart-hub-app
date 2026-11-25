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
        // 3: money from SimpleFIN. Amounts and balances stay as the decimal strings SimpleFIN sends.
        """
        create table if not exists accounts (
          id text primary key, name text not null, institution text not null default 'Connected account',
          currency text not null default 'USD', balance text not null, available_balance text, balance_date text not null,
          raw text not null, updated_at text not null
        );
        create table if not exists transactions (
          id text primary key, account_id text not null, posted text not null, amount text not null,
          description text not null default '', payee text, memo text, pending integer not null default 0, raw text,
          created_at text not null, updated_at text not null
        );
        create index if not exists transactions_posted on transactions (posted desc);
        create index if not exists transactions_account on transactions (account_id);
        create table if not exists sync_runs (
          id integer primary key autoincrement, started_at text not null, finished_at text, trigger text not null,
          mode text not null, window_start text not null, status text not null, accounts_synced integer not null default 0,
          transactions_upserted integer not null default 0, notices text, error text
        );
        create table if not exists category_overrides (transaction_id text primary key, category text not null, updated_at text not null);
        create table if not exists custom_categories (name text primary key);
        create table if not exists app_settings (key text primary key, value text not null);
        create table if not exists recurring_ignored (id text primary key);
        create table if not exists net_worth_snapshots (day text primary key, value text not null, updated_at text not null);
        create table if not exists holding_snapshots (
          day text not null, account_id text not null, symbol text not null, shares text not null, market_value text not null,
          cost_basis text, updated_at text not null, primary key (day, account_id, symbol)
        );
        -- The review queue only holds transactions synced after this, so the first sync's history doesn't all land in it.
        insert or ignore into app_settings (key, value) values ('review_since', strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'));
        """,
        // 4: merchants the phone asked "Drinks at …?" about, and how often the answer was yes.
        """
        create table if not exists fitness_merchant_drinks (
          merchant text primary key, yes integer not null default 0, no integer not null default 0, updated_at text not null
        );
        """,
        // 5: Jarvis's memory: every exchange, and the short durable facts learned from them.
        """
        create table if not exists voice_log (
          id integer primary key autoincrement, heard text not null, reply text not null, created_at text not null
        );
        create index if not exists voice_log_created on voice_log (created_at desc);
        create table if not exists voice_memories (id text primary key, text text not null, updated_at text not null);
        create unique index if not exists voice_memories_text on voice_memories (lower(text));
        """,
        // 6: which devices Home shows (once picked), and small settings.
        """
        create table if not exists home_visible (entity_id text primary key);
        create table if not exists settings (key text primary key, value text not null);
        """,
        // 7: the diet log: meals and their foods (with the FODMAP rating they had when logged),
        // how he felt after (a check with no symptoms is "felt fine"), and foods of his own.
        """
        create table if not exists diet_meals (
          id text primary key, at text not null, day text not null, slot text not null, note text,
          logged_at text not null, updated_at text not null
        );
        create index if not exists diet_meals_at on diet_meals (at desc);
        create table if not exists diet_meal_foods (
          meal_id text not null references diet_meals (id) on delete cascade, position integer not null,
          food_id text, name text not null, fodmap text not null, groups text,
          primary key (meal_id, position)
        );
        create table if not exists diet_checks (
          id text primary key, meal_id text references diet_meals (id) on delete set null,
          at text not null, day text not null, note text, updated_at text not null
        );
        create index if not exists diet_checks_at on diet_checks (at desc);
        create table if not exists diet_symptoms (
          check_id text not null references diet_checks (id) on delete cascade, symptom text not null,
          severity integer not null, primary key (check_id, symptom)
        );
        create table if not exists diet_foods (
          id text primary key, name text not null, fodmap text not null default 'unknown', groups text,
          created_at text not null
        );
        create unique index if not exists diet_foods_name on diet_foods (lower(name));
        """,
        // 8: the kitchen: foods he has, mostly from imported grocery receipts. A food is in
        // stock until gone_at is set; checked_at is when he last said he still has it.
        """
        create table if not exists diet_receipts (
          id text primary key, store text, purchased_at text, imported_at text not null, items integer not null default 0
        );
        create table if not exists diet_pantry (
          id text primary key, name text not null, line text, food_id text, source text not null,
          receipt_id text references diet_receipts (id) on delete set null,
          added_at text not null, checked_at text, gone_at text
        );
        create index if not exists diet_pantry_food on diet_pantry (food_id);
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
