/**
 * Transaction categories. Split out from lib/finance.ts (which pulls in
 * "server-only" via lib/simplefin.ts) so Client Components — like the
 * category picker on each transaction row — can import this list directly.
 */

export const CATEGORIES = [
  "Income",
  "Transfers",
  "Rent",
  "Groceries",
  "Food & Drinks",
  "Transport",
  "Lifestyle",
  "Bills & Utilities",
  "Subscriptions & Fees",
  "Travel",
] as const;

/**
 * Placeholder for money out that no rule or past tag recognizes. It is not a
 * category you can pick: it only exists until the transaction is tagged.
 */
export const UNCATEGORIZED = "Uncategorized";

/**
 * Retired category names and where they went. Dining and bars became Food &
 * Drinks; shopping, entertainment and health became Lifestyle; fees joined
 * subscriptions. Typing an old name in
 * the picker lands on its replacement instead of recreating it as a custom tag.
 */
const ALIASES: Record<string, BuiltInCategory> = {
  dining: "Food & Drinks",
  entertainment: "Lifestyle",
  shopping: "Lifestyle",
  health: "Lifestyle",
  "fees & interest": "Subscriptions & Fees",
  bills: "Subscriptions & Fees",
};

/** Names that can never be saved as a tag. "Other" was retired in favor of tagging properly. */
const RESERVED = new Set([UNCATEGORIZED.toLowerCase(), "other"]);

export const MAX_CATEGORY_LENGTH = 40;

/** Built-in names plus any user-created tags. */
export type Category = string;

export type BuiltInCategory = (typeof CATEGORIES)[number];

export function isBuiltInCategory(name: string): name is BuiltInCategory {
  return (CATEGORIES as readonly string[]).includes(name);
}

/** Trims, collapses whitespace, and maps case-insensitive hits onto built-in names. */
export function normalizeCategory(raw: string): string | null {
  const trimmed = raw.trim().replace(/\s+/g, " ");
  if (!trimmed || trimmed.length > MAX_CATEGORY_LENGTH) return null;
  if (RESERVED.has(trimmed.toLowerCase())) return null;

  const builtin = CATEGORIES.find(
    (category) => category.toLowerCase() === trimmed.toLowerCase(),
  );
  return builtin ?? ALIASES[trimmed.toLowerCase()] ?? trimmed;
}

/** Maps a stored name onto its current spelling, retired names included. */
export function canonicalCategory(name: string): string {
  return normalizeCategory(name) ?? name;
}

/** Like normalizeCategory, but reuses the spelling of an already-known custom tag. */
export function resolveCategory(
  raw: string,
  existing: readonly string[],
): string | null {
  const normalized = normalizeCategory(raw);
  if (!normalized) return null;

  const match = existing.find(
    (category) => category.toLowerCase() === normalized.toLowerCase(),
  );
  return match ?? normalized;
}

/** Built-in categories first, then custom tags in alphabetical order. */
export function mergeCategoryOptions(
  ...lists: readonly (readonly string[])[]
): string[] {
  const seen = new Set<string>([...CATEGORIES.map((category) => category.toLowerCase()), ...RESERVED]);
  const custom: string[] = [];

  for (const list of lists) {
    for (const name of list) {
      const trimmed = name.trim();
      if (!trimmed) continue;
      const key = trimmed.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      custom.push(trimmed);
    }
  }

  custom.sort((a, b) => a.localeCompare(b));
  return [...CATEGORIES, ...custom];
}
