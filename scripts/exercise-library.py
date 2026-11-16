"""Builds the workout library's dataset half from exercises-dataset.

    python3 scripts/exercise-library.py <exercises.json> <hub repo>

exercises.json is data/exercises.json from github.com/hasaneyldrm/exercises-dataset
(data MIT; media (c) Gym visual, credited in the app). Writes:
  <hub>/lib/workouts/library-dataset.ts   every dataset exercise the hand-written
                                          library doesn't already cover
  Armstrong-Smart-Hub-App/Features/Workouts/ExerciseMedia.json
                                          media file, muscles and steps per library id
Ids already shipped must stay stable: names only change if the dataset's do.
"""
import json, re, sys
from pathlib import Path

data_path, hub = sys.argv[1], Path(sys.argv[2])
app = Path(__file__).resolve().parent.parent
hub_out = hub / "lib/workouts/library-dataset.ts"
app_out = app / "Armstrong-Smart-Hub-App/Features/Workouts/ExerciseMedia.json"
d = json.load(open(data_path))
by_id = {r['id']: r for r in d}

# Hand-written library id -> the dataset exercise it shows. Rowing Machine has none.
MAPPED = {
    "bench-press-barbell": "0025",
    "bench-press-dumbbell": "0289",
    "incline-bench-press-barbell": "0047",
    "incline-bench-press-dumbbell": "0314",
    "decline-bench-press-barbell": "0033",
    "chest-press-machine": "0577",
    "chest-fly-dumbbell": "0308",
    "chest-fly-machine": "0596",
    "cable-crossover": "0155",
    "push-up": "0662",
    "chest-dip": "0251",
    "deadlift-barbell": "0032",
    "pull-up": "0652",
    "chin-up": "1326",
    "lat-pulldown-cable": "0198",
    "bent-over-row-barbell": "0027",
    "dumbbell-row": "0292",
    "seated-cable-row": "0861",
    "t-bar-row": "0606",
    "chest-supported-row-machine": "1350",
    "pullover-cable": "0238",
    "back-extension": "0489",
    "shrug-dumbbell": "0406",
    "overhead-press-barbell": "1457",
    "shoulder-press-dumbbell": "0405",
    "shoulder-press-machine": "0603",
    "arnold-press-dumbbell": "2137",
    "lateral-raise-dumbbell": "0334",
    "lateral-raise-cable": "0178",
    "front-raise-dumbbell": "0310",
    "rear-delt-fly-dumbbell": "0378",
    "rear-delt-fly-machine": "0602",
    "face-pull-cable": "0233",
    "upright-row-barbell": "0120",
    "bicep-curl-barbell": "0031",
    "bicep-curl-dumbbell": "0294",
    "hammer-curl-dumbbell": "0313",
    "preacher-curl-ez": "1627",
    "bicep-curl-cable": "0868",
    "incline-curl-dumbbell": "0318",
    "triceps-pushdown-cable": "0201",
    "overhead-triceps-extension-cable": "0194",
    "skull-crusher-ez": "0060",
    "close-grip-bench-press": "0030",
    "triceps-dip": "0814",
    "wrist-curl-dumbbell": "0401",
    "squat-barbell": "0043",
    "front-squat-barbell": "0042",
    "hack-squat-machine": "0743",
    "leg-press-machine": "0739",
    "goblet-squat": "1760",
    "bulgarian-split-squat": "0410",
    "lunge-dumbbell": "0336",
    "leg-extension-machine": "0585",
    "romanian-deadlift-barbell": "0085",
    "romanian-deadlift-dumbbell": "1459",
    "lying-leg-curl-machine": "0586",
    "seated-leg-curl-machine": "0599",
    "hip-thrust-barbell": "3562",
    "glute-bridge": "3013",
    "hip-abduction-machine": "0597",
    "hip-adduction-machine": "0598",
    "standing-calf-raise-machine": "0605",
    "seated-calf-raise-machine": "0594",
    "plank": "2135",
    "crunch": "0274",
    "hanging-leg-raise": "0472",
    "cable-crunch": "0175",
    "ab-wheel": "0857",
    "russian-twist": "0687",
    "kettlebell-swing": "0549",
    "clean-barbell": "0648",
    "farmers-walk": "2133",
    "burpee": "1160",
    "treadmill": "3666",
    "stair-climber": "2311",
    "assault-bike": "2331",
}
mapped = MAPPED
hand = re.findall(r'^\s*\["([^"]+)", "([^"]+)"', (hub / "lib/workouts/library.ts").read_text(), re.M)
existing_ids = {i for i, _ in hand}
existing_names = {n for _, n in hand}
# Dataset names that mislead: its "air bike" is a bicycle crunch, not the machine.
RENAME = {"air bike": "bicycle crunch"}
MUSCLE = {"abs": "core", "pectorals": "chest", "serratus anterior": "chest", "biceps": "biceps",
          "glutes": "glutes", "abductors": "glutes", "delts": "shoulders", "triceps": "triceps",
          "upper back": "back", "lats": "back", "spine": "back", "traps": "back", "levator scapulae": "back",
          "calves": "calves", "quads": "quads", "adductors": "quads", "forearms": "forearms",
          "hamstrings": "hamstrings", "cardiovascular system": "cardio"}
EQUIP = {"body weight": "bodyweight", "assisted": "bodyweight", "dumbbell": "dumbbell", "cable": "cable",
         "barbell": "barbell", "ez barbell": "barbell", "olympic barbell": "barbell", "trap bar": "barbell",
         "leverage machine": "machine", "smith machine": "machine", "sled machine": "machine",
         "upper body ergometer": "machine", "skierg machine": "machine", "stationary bike": "machine",
         "elliptical machine": "machine", "stepmill machine": "machine",
         "band": "band", "resistance band": "band", "kettlebell": "kettlebell"}
# Leading words naming the equipment move to a bracket, the library's style: "Incline Curl (Dumbbell)".
PREFIX = [("resistance band", "Band"), ("smith machine", "Smith Machine"), ("olympic barbell", "Barbell"),
          ("ez-barbell", "EZ Bar"), ("ez barbell", "EZ Bar"), ("ez-bar", "EZ Bar"), ("ez bar", "EZ Bar"),
          ("trap bar", "Trap Bar"), ("medicine ball", "Medicine Ball"), ("stability ball", "Stability Ball"),
          ("exercise ball", "Stability Ball"), ("barbell", "Barbell"), ("dumbbells", "Dumbbell"),
          ("dumbbell", "Dumbbell"), ("cable", "Cable"), ("lever", "Machine"), ("smith", "Smith Machine"),
          ("sled", "Machine"), ("kettlebell", "Kettlebell"), ("band", "Band"), ("weighted", "Weighted")]
SMALL = {"a", "an", "and", "the", "of", "on", "to", "with", "in", "at", "for", "or"}
UPPER = {"jm": "JM", "ez": "EZ", "sz": "SZ", "v": "V", "bosu": "BOSU", "trx": "TRX", "ii": "II"}

def title(text):
    words = text.split(" ")
    out = []
    for i, w in enumerate(words):
        def cap(part):
            low = part.lower()
            if low in UPPER: return UPPER[low]
            if i > 0 and low in SMALL: return low
            return part[:1].upper() + part[1:]
        # Capitalise each piece of hyphenated or bracketed words.
        out.append(re.sub(r"[A-Za-z][A-Za-z']*", lambda m: cap(m.group(0)), w))
    return " ".join(out)

def display(raw):
    name = RENAME.get(raw.strip().lower(), raw).replace("в°", "°").replace("_", "/").strip()
    name = re.sub(r"\s+", " ", name)
    name = re.sub(r"\bv\. ?(\d)", r"v\1", name)
    tag = None
    for prefix, label in PREFIX:
        if name.lower().startswith(prefix + " "):
            name, tag = name[len(prefix) + 1:], label
            break
    name = title(name)
    return f"{name} ({tag})" if tag else name

def kind(r, muscle, equip):
    n = r['name'].lower()
    if muscle == "cardio" or re.search(r"\b(stretch|hold|plank|pose|walk|run|jog|hang)\b", n) and "push-up" not in n:
        return "duration"
    if equip in ("bodyweight",) or r['equipment'] in ("stability ball", "bosu ball", "rope", "roller", "wheel roller"):
        return "reps"
    return None  # weight_reps

def slug(text):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")

taken_names = set(existing_names)
taken_ids = set(existing_ids)
mapped_ds = set(mapped.values())
rows, media, skipped = [], {}, []
for hub_id, ds in mapped.items():
    media[hub_id] = by_id[ds]
for r in sorted(d, key=lambda r: r['id']):
    if r['id'] in mapped_ds: continue
    name = display(r['name'])
    if name.lower() in {n.lower() for n in taken_names}:
        skipped.append((r['id'], r['name'], name)); continue
    muscle = MUSCLE[r['target']]
    equip = EQUIP.get(r['equipment'], "other")
    ident = slug(name)
    if ident in taken_ids: ident = f"{ident}-{r['id']}"
    taken_ids.add(ident); taken_names.add(name)
    rows.append((ident, name, muscle, equip, kind(r, muscle, equip)))
    media[ident] = r

# Hub: the generated half of the library.
def js(x): return json.dumps(x, ensure_ascii=False)
lines = ["/**",
         " * Generated from exercises-dataset (github.com/hasaneyldrm/exercises-dataset,",
         " * data MIT) by the app repo's scripts/exercise-library.py: every exercise there",
         " * the hand-written library doesn't already cover. Ids are stable once shipped;",
         " * regenerate rather than edit by hand.",
         " */",
         'import type { Entry } from "./library.ts";', "",
         "export const DATASET_ENTRIES: Entry[] = ["]
for ident, name, muscle, equip, k in rows:
    lines.append(f"  [{js(ident)}, {js(name)}, {js(muscle)}, {js(equip)}" + (f", {js(k)}" if k else "") + "],")
lines += ["];", ""]
open(hub_out, "w").write("\n".join(lines))

# App: media file, target, secondary muscles and steps per hub id.
table = {}
for ident, r in media.items():
    table[ident] = {"file": r['image'].split('/')[-1].rsplit('.', 1)[0], "target": r['target'],
                    "secondary": [m for m in r.get('secondary_muscles') or [] if m],
                    "steps": [t.strip() for t in r['instruction_steps']['en'] if t.strip()]}
json.dump(table, open(app_out, "w"), ensure_ascii=False, separators=(",", ":"), sort_keys=True)
print(f"added {len(rows)}, media {len(table)}, skipped {len(skipped)} duplicate names", file=sys.stderr)
for s in skipped[:40]: print("  skip", s, file=sys.stderr)
