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
