/**
 * Net worth goal projection. Pure, so the goal card can re-project instantly
 * while the user edits the assumptions.
 *
 * Model: each month, what you have grows by the expected return, then the
 * month's savings land on top. Simple and transparent beats precise here.
 */

export type GoalSettings = {
  target: number;
  /** Null means "use what I've actually been saving". */
  monthlyContribution: number | null;
  annualReturnPct: number;
};

/** One way of getting to the target: how long it takes, and who paid for it. */
export type Path = {
  /** Null when the target isn't reached within 100 years. */
  months: number | null;
  /** What you put in: today's savings plus every monthly contribution. */
  contributed: number;
  /** What the market added on top. */
  growth: number;
};

export type Projection = {
  current: number;
  /** 0..1 */
  progress: number;
  /** What's been saved per month lately, from the net worth trend; null without enough history. */
  observedMonthly: number | null;
  /** The contribution the projection uses. */
  monthly: number;
  /** When the target is reached; null if it never is at this rate. */
  targetDate: Date | null;
  /** Saving the same amount at the expected return. */
  invested: Path;
  /** Saving the same amount but leaving it in cash (0%). */
  cash: Path;
  /** Investing a little more each month. */
  boosts: { extra: number; months: number | null }[];
};

const MAX_MONTHS = 100 * 12;
const BOOSTS = [500, 1_000];

/**
 * Average monthly change in net worth, as the slope of a least-squares line
 * through the series. Needs a few weeks of history to mean anything.
 */
export function monthlyTrend(series: { date: string; value: number }[]): number | null {
  if (series.length < 21) return null;
  const t0 = Date.parse(series[0].date);
  const xs = series.map((p) => (Date.parse(p.date) - t0) / 86_400_000);
  const ys = series.map((p) => p.value);
  const mx = xs.reduce((a, b) => a + b, 0) / xs.length;
  const my = ys.reduce((a, b) => a + b, 0) / ys.length;
  let num = 0;
  let den = 0;
  for (let i = 0; i < xs.length; i++) {
    num += (xs[i] - mx) * (ys[i] - my);
    den += (xs[i] - mx) ** 2;
  }
  return den ? (num / den) * (365.25 / 12) : null;
}

/** Month-by-month until `start` reaches `target`, tracking what was paid in versus earned. */
function simulate(start: number, target: number, monthly: number, monthlyRate: number): Path {
  let value = start;
  let contributed = Math.max(start, 0);
  if (value >= target) return { months: 0, contributed, growth: 0 };
  for (let m = 1; m <= MAX_MONTHS; m++) {
    // Returns only compound on money you have, not on debt.
    value = value * (1 + (value > 0 ? monthlyRate : 0)) + monthly;
    contributed += monthly;
    if (value >= target) return { months: m, contributed, growth: Math.max(value - contributed, 0) };
  }
  return { months: null, contributed, growth: Math.max(value - contributed, 0) };
}

function addMonths(from: Date, months: number): Date {
  const d = new Date(from);
  d.setMonth(d.getMonth() + months);
  return d;
}

export function project(
  current: number,
  series: { date: string; value: number }[],
  goal: GoalSettings,
  now = new Date(),
): Projection {
  const observedMonthly = monthlyTrend(series);
  const monthly = goal.monthlyContribution ?? Math.max(observedMonthly ?? 0, 0);
  const rate = Math.pow(1 + goal.annualReturnPct / 100, 1 / 12) - 1;

  const invested = simulate(current, goal.target, monthly, rate);

  return {
    current,
    progress: Math.min(Math.max(current / goal.target, 0), 1),
    observedMonthly,
    monthly,
    targetDate: invested.months === null ? null : addMonths(now, invested.months),
    invested,
    cash: simulate(current, goal.target, monthly, 0),
    boosts: BOOSTS.map((extra) => ({ extra, months: simulate(current, goal.target, monthly + extra, rate).months })),
  };
}

/**
 * Prefers recorded daily snapshots once they cover a couple of months; until
 * then, the series reconstructed from transactions.
 */
export function bestSeries(
  snapshots: { date: string; value: number }[],
  reconstructed: { date: string; value: number }[],
): { series: { date: string; value: number }[]; source: "recorded" | "estimated" } {
  if (snapshots.length >= 60) return { series: snapshots, source: "recorded" };
  return { series: reconstructed, source: "estimated" };
}
