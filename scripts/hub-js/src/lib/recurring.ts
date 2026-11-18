import type { Category, NormalizedTransaction } from "@/lib/finance";

/**
 * Finds subscriptions and bills in transaction history: the same merchant,
 * charging a steady amount, on a steady rhythm. Pure, so it runs anywhere.
 *
 * A merchant can hide several subscriptions (two Squarespace plans billing on
 * different days), so when a merchant's whole history isn't regular, its
 * charges are split by amount and each group is tried on its own.
 */

export type Cadence = "weekly" | "biweekly" | "monthly" | "quarterly" | "yearly";

export type RecurringCharge = {
  /** Stable across syncs; what "Not recurring" stores. */
  id: string;
  name: string;
  category: Category;
  accountName: string;
  cadence: Cadence;
  /** The latest charge, as a positive number. */
  amount: number;
  /** Set when the latest charge is higher than the one before the change. */
  previousAmount: number | null;
  /** Epoch seconds. */
  lastCharged: number;
  nextExpected: number;
  /** Normalized to a month, for totals. */
  monthlyCost: number;
  chargeCount: number;
};

const CADENCES: { cadence: Cadence; min: number; max: number; perMonth: number }[] = [
  { cadence: "weekly", min: 6, max: 8, perMonth: 52 / 12 },
  { cadence: "biweekly", min: 13, max: 16, perMonth: 26 / 12 },
  { cadence: "monthly", min: 26, max: 35, perMonth: 1 },
  { cadence: "quarterly", min: 84, max: 98, perMonth: 1 / 3 },
  { cadence: "yearly", min: 350, max: 380, perMonth: 1 / 12 },
];

/** Money that moves between your own accounts, or comes in, is never a bill. */
const SKIP_CATEGORIES = new Set<string>(["Transfers", "Income"]);

const DAY = 86_400;

function merchantKey(payee: string): string {
  return payee.toLowerCase().replace(/[^a-z]+/g, " ").trim();
}

const median = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

/** Same price, allowing for tax rounding and FX wobble. */
const samePrice = (a: number, b: number) => Math.abs(a - b) <= Math.max(0.05, Math.max(a, b) * 0.03);

type Charge = { posted: number; amount: number; t: NormalizedTransaction };

/**
 * Charges sorted oldest first → a recurring charge, or null if they aren't
 * regular. Allows one price change (that's the increase we want to flag).
 */
function asRecurring(id: string, charges: Charge[], now: number): RecurringCharge | null {
  if (charges.length < 2) return null;

  // Two charges on the same day are a split or a retry, not a rhythm.
  const gaps = charges.slice(1).map((c, i) => Math.round((c.posted - charges[i].posted) / DAY));
  if (gaps.some((g) => g < 3)) return null;

  const typical = median(gaps);
  const match = CADENCES.find((c) => typical >= c.min && typical <= c.max);
  if (!match) return null;
  if (!gaps.every((g) => g >= match.min && g <= match.max)) return null;
  // Weekly and biweekly need a third charge before they count; two is a coincidence.
  if (match.cadence === "weekly" || match.cadence === "biweekly") {
    if (charges.length < 3) return null;
  }

  // Runs of the same price. One run is steady; two is a price change; more is noise.
  const runs: number[][] = [];
  for (const c of charges) {
    const run = runs.at(-1);
    if (run && samePrice(run.at(-1)!, c.amount)) run.push(c.amount);
    else runs.push([c.amount]);
  }
  if (runs.length > 2) return null;
  if (runs.length === 2 && charges.length < 3) return null; // two different prices prove nothing

  const last = charges.at(-1)!;
  const nextExpected = last.posted + typical * DAY;
  // Gone quiet for well over a cycle: probably cancelled.
  if (now > nextExpected + Math.max(7, typical * 0.5) * DAY) return null;

  const previous = runs.length === 2 ? runs[0].at(-1)! : null;
  return {
    id,
    name: last.t.payee,
    category: last.t.category,
    accountName: last.t.accountName.replace(/\s*\(\d+\)$/, ""),
    cadence: match.cadence,
    amount: last.amount,
    previousAmount: previous !== null && last.amount > previous ? previous : null,
    lastCharged: last.posted,
    nextExpected,
    monthlyCost: last.amount * match.perMonth,
    chargeCount: charges.length,
  };
}

/** Splits a merchant's charges into groups of roughly the same price. */
function byPrice(charges: Charge[]): Charge[][] {
  const groups: Charge[][] = [];
  for (const c of charges) {
    const group = groups.find((g) => samePrice(median(g.map((x) => x.amount)), c.amount));
    if (group) group.push(c);
    else groups.push([c]);
  }
  return groups;
}

export function detectRecurring(
  transactions: NormalizedTransaction[],
  ignored: ReadonlySet<string> = new Set(),
  now = Date.now() / 1000,
): RecurringCharge[] {
  const byMerchant = new Map<string, Charge[]>();
  for (const t of transactions) {
    if (t.pending || t.hold || t.netEffect >= 0 || SKIP_CATEGORIES.has(t.category)) continue;
    const key = merchantKey(t.payee);
    if (!key) continue;
    const list = byMerchant.get(key) ?? [];
    list.push({ posted: t.posted, amount: Math.abs(t.amount), t });
    byMerchant.set(key, list);
  }

  const found: RecurringCharge[] = [];
  for (const [key, list] of byMerchant) {
    const charges = list.sort((a, b) => a.posted - b.posted);
    const whole = asRecurring(key, charges, now);
    if (whole) {
      found.push(whole);
      continue;
    }
    const groups = byPrice(charges).sort((a, b) => a[0].posted - b[0].posted);
    const used = new Set<Charge[]>();
    for (const group of groups) {
      if (used.has(group)) continue;
      const id = `${key}@${Math.round(median(group.map((c) => c.amount)))}`;
      const one = asRecurring(id, group, now);
      if (one) {
        found.push(one);
        continue;
      }
      // A plan whose price went up shows as one group that stops and a
      // slightly pricier one that picks up where it left off ($36, $36, $39).
      const successor = groups.find(
        (g) =>
          !used.has(g) &&
          g !== group &&
          g[0].posted > group.at(-1)!.posted &&
          g[0].amount > group.at(-1)!.amount &&
          g[0].amount <= group.at(-1)!.amount * 1.25,
      );
      const merged = successor ? asRecurring(id, [...group, ...successor], now) : null;
      if (merged && successor) {
        found.push(merged);
        used.add(successor);
      }
    }
    // The successor may have matched on its own earlier in the loop; keep the merged one.
    for (const g of used) {
      const id = `${key}@${Math.round(median(g.map((c) => c.amount)))}`;
      const i = found.findIndex((r) => r.id === id);
      if (i >= 0) found.splice(i, 1);
    }
  }

  return found.filter((r) => !ignored.has(r.id)).sort((a, b) => a.nextExpected - b.nextExpected);
}
